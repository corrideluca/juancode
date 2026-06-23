import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { PrChecks, PrListResult, PullRequest } from "./protocol.ts";

const exec = promisify(execFile);

const MAX_BUFFER = 16 * 1024 * 1024;
const MAX_PRS = 50;

/** The `gh pr list --json` fields we request. */
const FIELDS = "number,title,url,headRefName,isDraft,statusCheckRollup";

/** One entry of gh's `statusCheckRollup` array (CheckRun or StatusContext). */
interface RollupCheck {
  // CheckRun uses status/conclusion; legacy StatusContext uses state.
  status?: string;
  conclusion?: string;
  state?: string;
}

interface RawPr {
  number: number;
  title: string;
  url: string;
  headRefName: string;
  isDraft: boolean;
  statusCheckRollup?: RollupCheck[] | null;
}

/** Collapse a PR's individual checks into a single failing/pending/passing/none. */
export function rollupChecks(checks: RollupCheck[] | null | undefined): PrChecks {
  if (!checks || checks.length === 0) return "none";
  let pending = false;
  for (const c of checks) {
    const conclusion = (c.conclusion ?? "").toUpperCase();
    const state = (c.state ?? "").toUpperCase();
    const status = (c.status ?? "").toUpperCase();
    if (["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"].includes(conclusion))
      return "failing";
    if (["FAILURE", "ERROR"].includes(state)) return "failing";
    // Not yet concluded: a CheckRun still running, or a pending commit status.
    if (status && status !== "COMPLETED") pending = true;
    if (state === "PENDING") pending = true;
  }
  return pending ? "pending" : "passing";
}

/** Map gh's raw JSON into our wire shape. Exported for testing. */
export function parsePrs(raw: RawPr[]): PullRequest[] {
  return raw.map((p) => ({
    number: p.number,
    title: p.title,
    url: p.url,
    branch: p.headRefName,
    draft: p.isDraft,
    checks: rollupChecks(p.statusCheckRollup),
  }));
}

/**
 * List a folder's open pull requests via the real `gh` CLI (the user's own auth,
 * never a shadow env — same philosophy as spawning the genuine agent CLIs).
 *
 * Returns `{ available: false, error }` rather than throwing when gh is missing,
 * unauthenticated, or the cwd isn't a repo with a remote, so the UI can hide the
 * badge gracefully.
 */
export async function getOpenPrs(cwd: string): Promise<PrListResult> {
  let stdout: string;
  try {
    ({ stdout } = await exec("gh", ["pr", "list", "--state", "open", "--limit", String(MAX_PRS), "--json", FIELDS], {
      cwd,
      maxBuffer: MAX_BUFFER,
    }));
  } catch (err) {
    return { available: false, prs: [], error: ghErrorReason(err) };
  }
  try {
    const raw = JSON.parse(stdout) as RawPr[];
    return { available: true, prs: parsePrs(raw) };
  } catch {
    return { available: false, prs: [], error: "Could not parse gh output" };
  }
}

/** Turn an execFile failure into a short, user-facing reason. */
function ghErrorReason(err: unknown): string {
  const e = err as { code?: string | number; stderr?: string };
  if (e.code === "ENOENT") return "gh CLI not installed";
  const stderr = (e.stderr ?? "").toLowerCase();
  if (stderr.includes("no git remotes") || stderr.includes("not a git repository"))
    return "Not a GitHub repo";
  if (stderr.includes("auth") || stderr.includes("logged")) return "gh not authenticated";
  return (e.stderr ?? "gh failed").trim().split("\n")[0] || "gh failed";
}
