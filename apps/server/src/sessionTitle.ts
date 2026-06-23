import { readdir } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { ProviderId } from "./protocol.ts";

/**
 * Derives a human-readable "what is this session doing" title from the CLI's own
 * transcript files — the same data the CLI shows in its own session list.
 *
 *   - Claude writes an `ai-title` entry (a model-generated summary) into
 *     `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`. We take the latest.
 *   - Codex has no generated title, so we fall back to the first `user_message`
 *     payload in its rollout file (the user's opening prompt).
 *
 * Returns null when nothing is available yet (e.g. before the first turn), in
 * which case the caller keeps the existing placeholder title.
 */

const CLAUDE_PROJECTS = join(homedir(), ".claude", "projects");
const CODEX_SESSIONS = join(homedir(), ".codex", "sessions");

const MAX_TITLE_LEN = 80;

/** Override the transcript roots (used by tests to point at fixtures). */
export interface TitleRoots {
  claudeProjects?: string;
  codexSessions?: string;
}

/**
 * Resolving a transcript file means scanning a whole directory tree, which is
 * wasteful to repeat on every poll. Cache the resolved path per CLI session id
 * once we've found it so later polls read just that one file.
 */
const fileCache = new Map<string, string>();

/** Collapse whitespace and trim/truncate a raw prompt or summary into a title. */
export function tidy(raw: string): string | null {
  const text = raw.replace(/\s+/g, " ").trim();
  if (!text) return null;
  return text.length > MAX_TITLE_LEN ? `${text.slice(0, MAX_TITLE_LEN - 1)}…` : text;
}

/** Find a `.jsonl` file by basename anywhere under `root`. */
async function findByBasename(root: string, basename: string): Promise<string | null> {
  let entries: string[];
  try {
    entries = await readdir(root, { recursive: true });
  } catch {
    return null;
  }
  const match = entries.find((e) => e.endsWith(basename));
  return match ? join(root, match) : null;
}

/** Stream JSONL lines, calling `onRecord`; stop early when it returns false. */
async function forEachRecord(
  file: string,
  onRecord: (rec: Record<string, unknown>) => boolean | void,
): Promise<void> {
  const stream = createReadStream(file, { encoding: "utf8" });
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      let rec: Record<string, unknown>;
      try {
        rec = JSON.parse(line) as Record<string, unknown>;
      } catch {
        continue;
      }
      if (onRecord(rec) === false) return;
    }
  } finally {
    rl.close();
    stream.destroy();
  }
}

/** Latest `ai-title` (model-generated summary) from a Claude transcript. */
export async function deriveClaudeTitle(
  cliSessionId: string,
  root: string = CLAUDE_PROJECTS,
): Promise<string | null> {
  let file = fileCache.get(cliSessionId);
  if (!file) {
    const found = await findByBasename(root, `${cliSessionId}.jsonl`);
    if (!found) return null;
    fileCache.set(cliSessionId, found);
    file = found;
  }
  let title: string | null = null;
  await forEachRecord(file, (rec) => {
    if (rec.type === "ai-title" && typeof rec.aiTitle === "string") {
      title = rec.aiTitle; // keep scanning — take the most recent one
    }
  });
  return title ? tidy(title) : null;
}

/** First user prompt from a Codex rollout, located by its session_meta id. */
export async function deriveCodexTitle(
  cliSessionId: string,
  root: string = CODEX_SESSIONS,
): Promise<string | null> {
  const cached = fileCache.get(cliSessionId);
  const files = cached ? [cached] : await codexRolloutFiles(root);

  for (const full of files) {
    let isMatch = false;
    let prompt: string | null = null;
    await forEachRecord(full, (rec) => {
      if (rec.type === "session_meta") {
        const payload = rec.payload as { id?: string } | undefined;
        if (payload?.id !== cliSessionId) return false; // wrong file — bail
        isMatch = true;
        return;
      }
      const payload = rec.payload as { type?: string; message?: string } | undefined;
      if (isMatch && payload?.type === "user_message" && typeof payload.message === "string") {
        prompt = payload.message;
        return false; // first user message is enough
      }
    });
    if (isMatch) {
      fileCache.set(cliSessionId, full);
      return prompt ? tidy(prompt) : null; // matched; null if no prompt yet
    }
  }
  return null;
}

/** Absolute paths of every Codex rollout file, newest scan each call. */
async function codexRolloutFiles(root: string): Promise<string[]> {
  let entries: string[];
  try {
    entries = await readdir(root, { recursive: true });
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.endsWith(".jsonl") && e.includes("rollout-"))
    .map((e) => join(root, e));
}

export function deriveSessionTitle(
  provider: ProviderId,
  cliSessionId: string,
  roots: TitleRoots = {},
): Promise<string | null> {
  return provider === "claude"
    ? deriveClaudeTitle(cliSessionId, roots.claudeProjects)
    : deriveCodexTitle(cliSessionId, roots.codexSessions);
}
