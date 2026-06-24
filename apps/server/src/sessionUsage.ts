import {
  CLAUDE_PROJECTS,
  CODEX_SESSIONS,
  codexRolloutFiles,
  findByBasename,
  forEachRecord,
} from "./sessionTitle.ts";
import type { ProviderId, SessionUsage } from "./protocol.ts";

/**
 * Derives per-session token usage (and an estimated cost) from the CLI's own
 * transcript files — the same robust source `sessionTitle.ts` reads, rather
 * than scraping the ANSI TUI stream.
 *
 *   - Claude writes one `assistant` record per API turn into
 *     `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`, each carrying a
 *     `message.usage` block. The same turn can be logged more than once, so we
 *     dedup by `message.id` + `requestId` (the key `ccusage` uses) before
 *     summing. Cost is summed per message using that message's model.
 *   - Codex emits a running `token_count` event whose `info.total_token_usage`
 *     is cumulative — we just take the last one.
 *
 * Cost is a best-effort *estimate* from published per-MTok rates (below). For a
 * model we don't have a price for — or Codex, which doesn't expose a per-token
 * price (and is usually a subscription) — `costUsd` is null and only tokens are
 * shown. Subscription users pay nothing per token regardless, so the figure is
 * labelled an estimate in the UI.
 *
 * Returns null when no usage is available yet (e.g. before the first turn).
 */

/** Override the transcript roots (used by tests to point at fixtures). */
export interface UsageRoots {
  claudeProjects?: string;
  codexSessions?: string;
}

/** Published input/output price per **million** tokens, by model-id match. */
interface ModelPrice {
  /** Matches against the transcript's model id (substring/prefix). */
  match: RegExp;
  inputPerMTok: number;
  outputPerMTok: number;
}

/**
 * Current Claude pricing (USD per 1M tokens). Cache reads bill at ~0.1× input
 * and cache writes at ~1.25× input (5-minute TTL, the default), applied below.
 * Ordered most-specific first; the first match wins.
 */
const MODEL_PRICES: readonly ModelPrice[] = [
  { match: /opus/i, inputPerMTok: 5, outputPerMTok: 25 },
  { match: /sonnet/i, inputPerMTok: 3, outputPerMTok: 15 },
  { match: /haiku/i, inputPerMTok: 1, outputPerMTok: 5 },
  { match: /fable|mythos/i, inputPerMTok: 10, outputPerMTok: 50 },
];

const CACHE_READ_MULT = 0.1;
const CACHE_WRITE_MULT = 1.25;

function priceFor(model: string): ModelPrice | null {
  return MODEL_PRICES.find((p) => p.match.test(model)) ?? null;
}

/**
 * Resolving a transcript path means scanning a directory tree, wasteful to
 * repeat on every poll. Cache the resolved path per CLI session id once found.
 */
const fileCache = new Map<string, string>();

const empty = (): SessionUsage => ({
  inputTokens: 0,
  outputTokens: 0,
  cacheReadTokens: 0,
  cacheWriteTokens: 0,
  totalTokens: 0,
  costUsd: 0,
});

/** Token usage + estimated cost for a Claude session, summed across messages. */
export async function deriveClaudeUsage(
  cliSessionId: string,
  root: string = CLAUDE_PROJECTS,
): Promise<SessionUsage | null> {
  let file = fileCache.get(cliSessionId);
  if (!file) {
    const found = await findByBasename(root, `${cliSessionId}.jsonl`);
    if (!found) return null;
    fileCache.set(cliSessionId, found);
    file = found;
  }

  const usage = empty();
  const seen = new Set<string>();
  let sawTurn = false;
  // Stays true only while every priced turn had a known model; a `<synthetic>`
  // (local, no API call) message contributes no tokens and no cost.
  let costKnown = true;

  await forEachRecord(file, (rec) => {
    if (rec.type !== "assistant") return;
    const msg = rec.message as
      | { id?: string; model?: string; usage?: Record<string, number> }
      | undefined;
    const u = msg?.usage;
    if (!u) return;

    // Dedup: the same API response is sometimes written multiple times.
    const key = `${msg?.id ?? ""}:${(rec.requestId as string) ?? ""}`;
    if (key !== ":" && seen.has(key)) return;
    seen.add(key);

    const model = msg?.model ?? "";
    if (model === "<synthetic>") return; // local message, not a billed API call

    const input = u.input_tokens ?? 0;
    const output = u.output_tokens ?? 0;
    const cacheRead = u.cache_read_input_tokens ?? 0;
    const cacheWrite = u.cache_creation_input_tokens ?? 0;

    sawTurn = true;
    usage.inputTokens += input;
    usage.outputTokens += output;
    usage.cacheReadTokens += cacheRead;
    usage.cacheWriteTokens += cacheWrite;

    const price = priceFor(model);
    if (price) {
      usage.costUsd! +=
        (input * price.inputPerMTok +
          cacheRead * price.inputPerMTok * CACHE_READ_MULT +
          cacheWrite * price.inputPerMTok * CACHE_WRITE_MULT +
          output * price.outputPerMTok) /
        1_000_000;
    } else {
      costKnown = false; // an un-priced model means the total is only partial
    }
  });

  if (!sawTurn) return null;
  usage.totalTokens =
    usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens;
  if (!costKnown) usage.costUsd = null;
  return usage;
}

/** Token usage for a Codex session: the last cumulative `token_count` event. */
export async function deriveCodexUsage(
  cliSessionId: string,
  root: string = CODEX_SESSIONS,
): Promise<SessionUsage | null> {
  const cached = fileCache.get(cliSessionId);
  const files = cached ? [cached] : await codexRolloutFiles(root);

  for (const full of files) {
    let isMatch = cached === full;
    let total: Record<string, number> | null = null;
    await forEachRecord(full, (rec) => {
      const payload = rec.payload as
        | { type?: string; id?: string; info?: { total_token_usage?: Record<string, number> } }
        | undefined;
      if (rec.type === "session_meta") {
        if (payload?.id !== cliSessionId) return false; // wrong file — bail
        isMatch = true;
        return;
      }
      // Cumulative tally; keep the latest. (When reading a cached file directly
      // we never see session_meta, but isMatch is already true.)
      if (isMatch && payload?.type === "token_count" && payload.info?.total_token_usage) {
        total = payload.info.total_token_usage;
      }
    });
    if (isMatch) {
      fileCache.set(cliSessionId, full);
      if (!total) return null; // matched the session but no turn has run yet
      // Codex `input_tokens` already includes the cached portion, so subtract
      // it out to report fresh input separately. No per-token price → no cost.
      const t: Record<string, number> = total;
      const cacheRead = t.cached_input_tokens ?? 0;
      const input = Math.max(0, (t.input_tokens ?? 0) - cacheRead);
      const output = t.output_tokens ?? 0;
      return {
        inputTokens: input,
        outputTokens: output,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: 0,
        totalTokens: t.total_tokens ?? input + output + cacheRead,
        costUsd: null,
      };
    }
  }
  return null;
}

export function deriveSessionUsage(
  provider: ProviderId,
  cliSessionId: string,
  roots: UsageRoots = {},
): Promise<SessionUsage | null> {
  return provider === "claude"
    ? deriveClaudeUsage(cliSessionId, roots.claudeProjects)
    : deriveCodexUsage(cliSessionId, roots.codexSessions);
}
