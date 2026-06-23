import { spawn } from "node:child_process";
import { PROVIDERS } from "./providers.ts";
import type {
  DiffComment,
  DiffFile,
  ReviewFinding,
  ReviewResult,
  ReviewSeverity,
} from "./protocol.ts";

/**
 * 'Review with Claude' — run the genuine `claude` CLI in headless print mode
 * over a session's working-tree diff and return structured findings to overlay
 * on the diff viewer.
 *
 * Faithful to juancode's core promise: we launch the user's resolved `claude`
 * binary with their real environment (auth, config, MCP) untouched — exactly
 * like a session pty. We add no shadow HOME and override nothing. The only
 * thing we ask of the CLI is `-p` (non-interactive) with a JSON schema so the
 * output is machine-readable.
 */

/** Cap the diff we feed the model so a huge change set can't blow up cost/latency. */
const MAX_PROMPT_BYTES = 200_000;
const REVIEW_TIMEOUT_MS = 240_000;
const MAX_BUFFER = 16 * 1024 * 1024;

const SEVERITIES: ReviewSeverity[] = ["critical", "high", "medium", "low", "info"];

/** JSON Schema handed to `claude --json-schema` so findings come back validated. */
const FINDINGS_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    summary: { type: "string" },
    findings: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          file: { type: "string", description: "Repo-relative path exactly as it appears in the diff header" },
          side: { type: "string", enum: ["old", "new"], description: "'new' for added/context lines, 'old' for removed lines" },
          line: {
            type: ["integer", "null"],
            description: "Line number on the chosen side; null for a file-level finding with no single line",
          },
          severity: { type: "string", enum: SEVERITIES },
          title: { type: "string", description: "One-line summary of the issue" },
          note: { type: "string", description: "What's wrong and how to fix it" },
        },
        required: ["file", "side", "line", "severity", "title", "note"],
      },
    },
  },
  required: ["summary", "findings"],
} as const;

const SYSTEM_PROMPT =
  "You are a meticulous senior code reviewer. You are given a unified git diff of a working tree. " +
  "Review ONLY the changes shown — bugs, correctness, security, error handling, and clear quality issues. " +
  "Anchor each finding to the file and line it concerns, using the line numbers from the diff's new side " +
  "(removed lines use the old side). Be concrete and skip nitpicks and style preferences. " +
  "If the diff looks clean, return an empty findings array with a short summary saying so. " +
  "Respond ONLY via the structured output schema.";

/** Build the user prompt: the diff plus any human inline comments as steering context. */
export function buildPrompt(files: DiffFile[], comments: DiffComment[]): string {
  const parts: string[] = [];
  parts.push("Review the following working-tree changes.\n");

  if (comments.length > 0) {
    parts.push(
      "The human reviewer left these inline comments — treat them as priorities and respond to their concerns where relevant:",
    );
    for (const c of comments) {
      const lines = c.endLine > c.line ? `${c.line}-${c.endLine}` : `${c.line}`;
      parts.push(`- ${c.file}:${lines} (${c.side}) — ${c.body}`);
    }
    parts.push("");
  }

  parts.push("Unified diff:\n");
  for (const f of files) {
    const header = f.oldPath ? `${f.oldPath} → ${f.path}` : f.path;
    parts.push(`### ${header} (${f.status}, +${f.additions} −${f.deletions})`);
    if (f.binary) parts.push("(binary file — no textual diff)");
    else if (f.truncated) parts.push("(diff too large — omitted)");
    else if (f.diff) parts.push("```diff\n" + f.diff + "\n```");
    parts.push("");
  }

  let prompt = parts.join("\n");
  if (prompt.length > MAX_PROMPT_BYTES) {
    prompt = prompt.slice(0, MAX_PROMPT_BYTES) + "\n\n[diff truncated for length — review what is shown]";
  }
  return prompt;
}

interface ClaudeEnvelope {
  type?: string;
  subtype?: string;
  is_error?: boolean;
  result?: string;
}

/**
 * Parse `claude -p --output-format json` stdout into findings.
 * The envelope's `result` field holds the schema-validated JSON as a string.
 * Returns an error result on any failure rather than throwing — the route maps
 * it straight to the UI.
 */
export function parseReviewOutput(stdout: string, createdAt: number): ReviewResult {
  let envelope: ClaudeEnvelope;
  try {
    envelope = JSON.parse(stdout) as ClaudeEnvelope;
  } catch {
    return { status: "error", findings: [], summary: null, createdAt, error: "Could not parse CLI output." };
  }
  if (envelope.is_error || envelope.subtype !== "success" || typeof envelope.result !== "string") {
    return {
      status: "error",
      findings: [],
      summary: null,
      createdAt,
      error: typeof envelope.result === "string" && envelope.result ? envelope.result : "Review run failed.",
    };
  }

  let payload: { summary?: unknown; findings?: unknown };
  try {
    payload = JSON.parse(envelope.result) as { summary?: unknown; findings?: unknown };
  } catch {
    // No schema-shaped JSON — keep the prose as the summary so the user still sees something.
    return { status: "ok", findings: [], summary: envelope.result.trim() || null, createdAt };
  }

  const findings = Array.isArray(payload.findings)
    ? payload.findings.map(normalizeFinding).filter((f): f is ReviewFinding => f !== null)
    : [];
  const summary = typeof payload.summary === "string" ? payload.summary.trim() || null : null;
  return { status: "ok", findings, summary, createdAt };
}

function normalizeFinding(raw: unknown): ReviewFinding | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.file !== "string" || !r.file) return null;
  const side = r.side === "old" ? "old" : "new";
  const line = Number.isInteger(r.line) ? (r.line as number) : null;
  const severity = SEVERITIES.includes(r.severity as ReviewSeverity) ? (r.severity as ReviewSeverity) : "info";
  const title = typeof r.title === "string" ? r.title : "";
  const note = typeof r.note === "string" ? r.note : "";
  if (!title && !note) return null;
  return { file: r.file, side, line, severity, title, note };
}

/** Run the CLI, feeding the prompt over stdin so a large diff can't hit ARG_MAX. */
function runClaude(prompt: string, cwd: string): Promise<string> {
  const spec = PROVIDERS.claude;
  return new Promise((resolve, reject) => {
    const child = spawn(
      spec.command,
      ["-p", "--output-format", "json", "--json-schema", JSON.stringify(FINDINGS_SCHEMA), "--append-system-prompt", SYSTEM_PROMPT],
      { cwd, env: process.env },
    );

    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (fn: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(new Error("Review timed out.")));
    }, REVIEW_TIMEOUT_MS);

    child.stdout.on("data", (d: Buffer) => {
      stdout += d.toString();
      if (stdout.length > MAX_BUFFER) {
        child.kill("SIGKILL");
        finish(() => reject(new Error("Review output too large.")));
      }
    });
    child.stderr.on("data", (d: Buffer) => {
      stderr += d.toString();
    });
    child.on("error", (err) => finish(() => reject(err)));
    child.on("close", (code) => {
      // claude -p exits non-zero on hard failure; the JSON envelope (when present)
      // carries the real error, so prefer stdout and only fall back to stderr.
      if (stdout.trim()) finish(() => resolve(stdout));
      else finish(() => reject(new Error(stderr.trim() || `claude exited with code ${code}`)));
    });

    child.stdin.on("error", () => {
      /* CLI may close stdin early; ignore EPIPE so it doesn't crash the server. */
    });
    child.stdin.end(prompt);
  });
}

/** Run a full review pass and return a result ready to cache and serve. */
export async function runReview(
  cwd: string,
  files: DiffFile[],
  comments: DiffComment[],
  now: number,
): Promise<ReviewResult> {
  if (files.length === 0) {
    return { status: "empty", findings: [], summary: null, createdAt: now };
  }
  try {
    const stdout = await runClaude(buildPrompt(files, comments), cwd);
    return parseReviewOutput(stdout, now);
  } catch (err) {
    return {
      status: "error",
      findings: [],
      summary: null,
      createdAt: now,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
