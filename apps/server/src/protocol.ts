/**
 * WebSocket wire protocol shared between server and web.
 *
 * Keep this file dependency-free and in sync with `apps/web/src/protocol.ts`.
 */

export type ProviderId = "claude" | "codex";

export interface SessionMeta {
  id: string;
  provider: ProviderId;
  cwd: string;
  title: string;
  status: "running" | "exited";
  exitCode: number | null;
  createdAt: number;
  updatedAt: number;
  /**
   * The CLI's own resumable conversation id, used to revive an exited session
   * via `claude --resume` / `codex resume`. Known immediately for Claude (we
   * force it with `--session-id`); discovered after spawn for Codex. Null until
   * captured — when null the session can be viewed but not reactivated.
   */
  cliSessionId: string | null;
}

/** Messages sent from the browser to the server. */
export type ClientMessage =
  | {
      type: "create";
      provider: ProviderId;
      cwd: string;
      cols: number;
      rows: number;
      /** Optional text auto-submitted to the fresh session (e.g. PR context). */
      initialInput?: string;
    }
  | { type: "attach"; sessionId: string; cols: number; rows: number }
  | { type: "reactivate"; sessionId: string; cols: number; rows: number }
  | { type: "input"; sessionId: string; data: string }
  | { type: "resize"; sessionId: string; cols: number; rows: number }
  | { type: "kill"; sessionId: string };

/** Messages sent from the server to the browser. */
export type ServerMessage =
  | { type: "created"; session: SessionMeta }
  | { type: "attached"; sessionId: string; scrollback: string; session: SessionMeta }
  | { type: "output"; sessionId: string; data: string }
  | { type: "exit"; sessionId: string; exitCode: number | null }
  /** A reactivate couldn't be honoured: no prior CLI conversation to resume. */
  | { type: "unresumable"; sessionId: string; reason: string }
  | { type: "error"; sessionId?: string; message: string };

// ── REST data types (diff viewer + inline review comments) ───────────────────

export type FileStatus = "modified" | "added" | "deleted" | "renamed" | "untracked";

export interface DiffFile {
  path: string;
  oldPath: string | null;
  status: FileStatus;
  additions: number;
  deletions: number;
  binary: boolean;
  diff: string;
  truncated: boolean;
}

export interface DiffResult {
  git: boolean;
  root?: string;
  files: DiffFile[];
  truncatedFiles?: boolean;
}

/** Which side of the diff a comment is anchored to. */
export type CommentSide = "old" | "new";

/**
 * A GitHub-PR-style inline comment on a diff. Anchored to a line range
 * [line, endLine] (inclusive) on one side; `endLine === line` for a single line.
 */
export interface DiffComment {
  id: string;
  sessionId: string;
  file: string;
  side: CommentSide;
  line: number;
  endLine: number;
  body: string;
  createdAt: number;
}

// ── REST data types ('Review with Claude' AI pass over the diff) ─────────────

export type ReviewSeverity = "critical" | "high" | "medium" | "low" | "info";

/**
 * One AI-surfaced issue, anchored to a diff line so it can overlay the viewer
 * the same way human comments do. `line` is null for a file- or change-level
 * finding with no single line, or when the model couldn't pin one.
 */
export interface ReviewFinding {
  file: string;
  side: CommentSide;
  line: number | null;
  severity: ReviewSeverity;
  title: string;
  note: string;
}

/** Cached result of one 'Review with Claude' pass over a session's diff. */
export interface ReviewResult {
  /** ok = ran and produced findings/summary; empty = nothing to review; error = the run failed. */
  status: "ok" | "empty" | "error";
  findings: ReviewFinding[];
  /** The model's short prose overview, shown above the per-line findings. */
  summary: string | null;
  /** When this review was produced (epoch ms). */
  createdAt: number;
  /** Error text when status is 'error' (CLI failure, bad output, etc.). */
  error?: string;
}

// ── REST data types (beads issue tracker, per work folder) ───────────────────

/** One bd issue as surfaced in the UI. Mirrors `bd list --json` fields we use. */
export interface BeadsIssue {
  id: string;
  title: string;
  status: string;
  priority: number;
  issueType: string;
  parent: string | null;
  dependencyCount: number;
  dependentCount: number;
  /** Unblocked and actionable now (from `bd ready`). */
  ready: boolean;
  /** Has unsatisfied dependencies (from `bd blocked`). */
  blocked: boolean;
}

/** Result of listing a folder's bd issues. */
export interface BeadsResult {
  /** True when a bd tracker was found and queried successfully. */
  available: boolean;
  issues: BeadsIssue[];
  /** Why the tracker is unavailable (bd not installed / no .beads here). */
  error?: string;
}

// ── REST data types (open pull requests, per work folder) ────────────────────

/** Rolled-up CI status across a PR's checks. */
export type PrChecks = "passing" | "failing" | "pending" | "none";

/** One open pull request, from `gh pr list`. */
export interface PullRequest {
  number: number;
  title: string;
  url: string;
  /** Source branch (`headRefName`). */
  branch: string;
  /** True for draft PRs. */
  draft: boolean;
  checks: PrChecks;
}

/** Result of listing a folder's open PRs. */
export interface PrListResult {
  /** True when `gh` ran in a repo with a remote and returned a list. */
  available: boolean;
  prs: PullRequest[];
  /** Why PRs are unavailable (gh missing / not authed / not a repo / no remote). */
  error?: string;
}
