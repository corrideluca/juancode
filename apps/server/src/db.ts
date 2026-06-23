import { mkdirSync } from "node:fs";
import { join } from "node:path";
import Database from "better-sqlite3";
import { DATA_DIR } from "./config.ts";
import type { DiffComment, ProviderId, ReviewResult, SessionMeta } from "./protocol.ts";

mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(join(DATA_DIR, "juancode.db"));
db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,
    provider        TEXT NOT NULL,
    cwd             TEXT NOT NULL,
    title           TEXT NOT NULL,
    status          TEXT NOT NULL,
    exit_code       INTEGER,
    cli_session_id  TEXT,
    scrollback      TEXT NOT NULL DEFAULT '',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
  );
`);

// Migration: add cli_session_id to databases created before resume support.
const hasCliSessionId = (db.prepare(`PRAGMA table_info(sessions)`).all() as { name: string }[]).some(
  (c) => c.name === "cli_session_id",
);
if (!hasCliSessionId) {
  db.exec(`ALTER TABLE sessions ADD COLUMN cli_session_id TEXT`);
}

// GitHub-PR-style inline comments anchored to a (file, side, line..end_line) range.
db.exec(`
  CREATE TABLE IF NOT EXISTS diff_comments (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL,
    file        TEXT NOT NULL,
    side        TEXT NOT NULL,
    line        INTEGER NOT NULL,
    end_line    INTEGER NOT NULL,
    body        TEXT NOT NULL,
    created_at  INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_diff_comments_session ON diff_comments(session_id);
`);

// Migration: add end_line (multi-line ranges) to pre-existing comment tables,
// backfilling single-line comments so end_line == line.
const hasEndLine = (db.prepare(`PRAGMA table_info(diff_comments)`).all() as { name: string }[]).some(
  (c) => c.name === "end_line",
);
if (!hasEndLine) {
  db.exec(`ALTER TABLE diff_comments ADD COLUMN end_line INTEGER NOT NULL DEFAULT 0`);
  db.exec(`UPDATE diff_comments SET end_line = line WHERE end_line = 0`);
}

// Cached 'Review with Claude' pass — one (latest) result per session, stored as
// the JSON-serialized ReviewResult so the schema can evolve without migrations.
db.exec(`
  CREATE TABLE IF NOT EXISTS diff_reviews (
    session_id  TEXT PRIMARY KEY,
    payload     TEXT NOT NULL,
    created_at  INTEGER NOT NULL
  );
`);

interface Row {
  id: string;
  provider: string;
  cwd: string;
  title: string;
  status: string;
  exit_code: number | null;
  cli_session_id: string | null;
  created_at: number;
  updated_at: number;
}

const rowToMeta = (r: Row): SessionMeta => ({
  id: r.id,
  provider: r.provider as ProviderId,
  cwd: r.cwd,
  title: r.title,
  status: r.status === "running" ? "running" : "exited",
  exitCode: r.exit_code,
  cliSessionId: r.cli_session_id ?? null,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
});

const insertStmt = db.prepare(`
  INSERT INTO sessions (id, provider, cwd, title, status, exit_code, cli_session_id, scrollback, created_at, updated_at)
  VALUES (@id, @provider, @cwd, @title, @status, @exitCode, @cliSessionId, '', @createdAt, @updatedAt)
`);

const updateStmt = db.prepare(`
  UPDATE sessions
  SET title = @title, status = @status, exit_code = @exitCode, cli_session_id = @cliSessionId, scrollback = @scrollback, updated_at = @updatedAt
  WHERE id = @id
`);

const setCliSessionIdStmt = db.prepare(`UPDATE sessions SET cli_session_id = @cliSessionId WHERE id = @id`);
const usedCliSessionIdsStmt = db.prepare(`SELECT cli_session_id FROM sessions WHERE cli_session_id IS NOT NULL`);

const listStmt = db.prepare(`SELECT * FROM sessions ORDER BY created_at DESC`);
const getStmt = db.prepare(`SELECT * FROM sessions WHERE id = ?`);
const scrollbackStmt = db.prepare(`SELECT scrollback FROM sessions WHERE id = ?`);

const deleteSessionStmt = db.prepare(`DELETE FROM sessions WHERE id = ?`);
const deleteSessionCommentsStmt = db.prepare(`DELETE FROM diff_comments WHERE session_id = ?`);
const deleteSessionReviewStmt = db.prepare(`DELETE FROM diff_reviews WHERE session_id = ?`);

// Atomically drop a session and everything anchored to it.
const deleteSessionTxn = db.transaction((id: string): boolean => {
  deleteSessionCommentsStmt.run(id);
  deleteSessionReviewStmt.run(id);
  return deleteSessionStmt.run(id).changes > 0;
});

export const sessionDb = {
  insert(meta: SessionMeta): void {
    insertStmt.run(meta);
  },

  update(meta: SessionMeta, scrollback: string): void {
    updateStmt.run({ ...meta, scrollback });
  },

  setCliSessionId(id: string, cliSessionId: string): void {
    setCliSessionIdStmt.run({ id, cliSessionId });
  },

  /** Every CLI session id already claimed — so recovery can't reuse one. */
  usedCliSessionIds(): Set<string> {
    const rows = usedCliSessionIdsStmt.all() as { cli_session_id: string }[];
    return new Set(rows.map((r) => r.cli_session_id));
  },

  list(): SessionMeta[] {
    return (listStmt.all() as Row[]).map(rowToMeta);
  },

  get(id: string): SessionMeta | undefined {
    const row = getStmt.get(id) as Row | undefined;
    return row ? rowToMeta(row) : undefined;
  },

  getScrollback(id: string): string {
    const row = scrollbackStmt.get(id) as { scrollback: string } | undefined;
    return row?.scrollback ?? "";
  },

  /**
   * Permanently remove a session and its associated comments + cached review.
   * Returns true when a session row was actually deleted.
   */
  delete(id: string): boolean {
    return deleteSessionTxn(id);
  },

  /**
   * On startup, any session still marked "running" is stale — its pty died with
   * the previous server process. Mark them exited so the UI shows truth.
   */
  markOrphansExited(): void {
    db.prepare(`UPDATE sessions SET status = 'exited' WHERE status = 'running'`).run();
  },
};

const insertCommentStmt = db.prepare(`
  INSERT INTO diff_comments (id, session_id, file, side, line, end_line, body, created_at)
  VALUES (@id, @sessionId, @file, @side, @line, @endLine, @body, @createdAt)
`);
const listCommentsStmt = db.prepare(
  `SELECT * FROM diff_comments WHERE session_id = ? ORDER BY created_at ASC`,
);
const deleteCommentStmt = db.prepare(`DELETE FROM diff_comments WHERE id = ? AND session_id = ?`);
const clearCommentsStmt = db.prepare(`DELETE FROM diff_comments WHERE session_id = ?`);

interface CommentRow {
  id: string;
  session_id: string;
  file: string;
  side: string;
  line: number;
  end_line: number;
  body: string;
  created_at: number;
}

const rowToComment = (r: CommentRow): DiffComment => ({
  id: r.id,
  sessionId: r.session_id,
  file: r.file,
  side: r.side === "old" ? "old" : "new",
  line: r.line,
  endLine: r.end_line,
  body: r.body,
  createdAt: r.created_at,
});

export const commentDb = {
  add(c: DiffComment): void {
    insertCommentStmt.run(c);
  },

  list(sessionId: string): DiffComment[] {
    return (listCommentsStmt.all(sessionId) as CommentRow[]).map(rowToComment);
  },

  /** Returns true when a row was deleted (i.e. it belonged to this session). */
  remove(sessionId: string, id: string): boolean {
    return deleteCommentStmt.run(id, sessionId).changes > 0;
  },

  /** Drop all comments for a session (used after a batched review is sent). */
  clear(sessionId: string): number {
    return clearCommentsStmt.run(sessionId).changes;
  },
};

const upsertReviewStmt = db.prepare(`
  INSERT INTO diff_reviews (session_id, payload, created_at)
  VALUES (@sessionId, @payload, @createdAt)
  ON CONFLICT(session_id) DO UPDATE SET payload = @payload, created_at = @createdAt
`);
const getReviewStmt = db.prepare(`SELECT payload FROM diff_reviews WHERE session_id = ?`);

export const reviewDb = {
  /** Store (overwriting) the latest review for a session. */
  save(sessionId: string, result: ReviewResult): void {
    upsertReviewStmt.run({ sessionId, payload: JSON.stringify(result), createdAt: result.createdAt });
  },

  /** The cached review for a session, or null if none has been run. */
  get(sessionId: string): ReviewResult | null {
    const row = getReviewStmt.get(sessionId) as { payload: string } | undefined;
    if (!row) return null;
    try {
      return JSON.parse(row.payload) as ReviewResult;
    } catch {
      return null;
    }
  },
};

export default db;
