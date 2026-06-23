import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { recoverCliSessionId } from "./recoverSession.ts";

const tmp = mkdtempSync(join(tmpdir(), "juancode-recover-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const CWD = "/Users/someone/project";
const OTHER = "/Users/someone/other";
const T0 = Date.parse("2026-06-23T12:00:00.000Z"); // a session's createdAt

const jsonl = (records: unknown[]) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

/** Encode a cwd the way Claude names its project dirs (path separators → dashes). */
const encode = (cwd: string) => cwd.replace(/[/.]/g, "-");

/**
 * Build a Claude projects root containing one transcript per entry, each a
 * `<root>/<encoded-cwd>/<id>.jsonl` whose first record carries the cwd + start.
 */
function claudeRoot(
  name: string,
  transcripts: { id: string; cwd: string; startMs: number }[],
): string {
  const root = join(tmp, name);
  for (const t of transcripts) {
    const dir = join(root, encode(t.cwd));
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, `${t.id}.jsonl`),
      jsonl([
        { type: "mode" }, // no cwd/timestamp — must be skipped
        { type: "user", cwd: t.cwd, timestamp: new Date(t.startMs).toISOString(), message: "hi" },
      ]),
    );
  }
  return root;
}

const recover = (root: string, excludeIds: string[] = [], createdAt = T0) =>
  recoverCliSessionId("claude", CWD, createdAt, new Set(excludeIds), { claudeProjects: root });

describe("recoverCliSessionId (claude)", () => {
  it("picks the transcript that began closest after the session was created", async () => {
    const root = claudeRoot("near", [
      { id: "near", cwd: CWD, startMs: T0 + 30_000 },
      { id: "later", cwd: CWD, startMs: T0 + 9 * 60_000 },
    ]);
    expect(await recover(root)).toBe("near");
  });

  it("skips ids already claimed by another session", async () => {
    const root = claudeRoot("excluded", [
      { id: "near", cwd: CWD, startMs: T0 + 30_000 },
      { id: "later", cwd: CWD, startMs: T0 + 9 * 60_000 },
    ]);
    expect(await recover(root, ["near"])).toBe("later");
  });

  it("ignores transcripts from a different working directory", async () => {
    const root = claudeRoot("other-cwd", [{ id: "elsewhere", cwd: OTHER, startMs: T0 + 30_000 }]);
    expect(await recover(root)).toBeNull();
  });

  it("rejects a match too far after creation (likely a different session)", async () => {
    const root = claudeRoot("too-late", [{ id: "stale", cwd: CWD, startMs: T0 + 20 * 60_000 }]);
    expect(await recover(root)).toBeNull();
  });

  it("rejects a transcript that began before the session was created", async () => {
    const root = claudeRoot("too-early", [{ id: "prior", cwd: CWD, startMs: T0 - 60_000 }]);
    expect(await recover(root)).toBeNull();
  });

  it("returns null when the projects root has nothing for this cwd", async () => {
    const root = claudeRoot("empty", [{ id: "x", cwd: OTHER, startMs: T0 }]);
    expect(await recover(root)).toBeNull();
  });
});
