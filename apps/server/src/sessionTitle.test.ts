import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { deriveClaudeTitle, deriveCodexTitle, tidy } from "./sessionTitle.ts";

const tmp = mkdtempSync(join(tmpdir(), "juancode-title-"));
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

const jsonl = (records: unknown[]) => records.map((r) => JSON.stringify(r)).join("\n") + "\n";

/** Write a Claude transcript under <root>/<encoded-cwd>/<id>.jsonl and return root. */
function claudeFixture(id: string, records: unknown[]): string {
  const root = join(tmp, `claude-${id}`);
  const dir = join(root, "-Users-someone-project");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${id}.jsonl`), jsonl(records));
  return root;
}

function codexFixture(id: string, records: unknown[], name = "rollout-x.jsonl"): string {
  const root = join(tmp, `codex-${id}`);
  const dir = join(root, "2026", "06", "23");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), jsonl(records));
  return root;
}

describe("tidy", () => {
  it("collapses whitespace and trims", () => {
    expect(tidy("  fix   the\n\tbug ")).toBe("fix the bug");
  });

  it("returns null for blank input", () => {
    expect(tidy("   \n  ")).toBeNull();
  });

  it("truncates with an ellipsis past the max length", () => {
    const out = tidy("x".repeat(200))!;
    expect(out.length).toBe(80);
    expect(out.endsWith("…")).toBe(true);
  });
});

describe("deriveClaudeTitle", () => {
  it("returns the latest ai-title", async () => {
    const id = "11111111-1111-1111-1111-111111111111";
    const root = claudeFixture(id, [
      { type: "user", message: "hi" },
      { type: "ai-title", aiTitle: "First guess", sessionId: id },
      { type: "assistant", message: "..." },
      { type: "ai-title", aiTitle: "Fix the auth redirect bug", sessionId: id },
    ]);
    expect(await deriveClaudeTitle(id, root)).toBe("Fix the auth redirect bug");
  });

  it("returns null when no ai-title is present yet", async () => {
    const id = "22222222-2222-2222-2222-222222222222";
    const root = claudeFixture(id, [{ type: "user", message: "hi" }]);
    expect(await deriveClaudeTitle(id, root)).toBeNull();
  });

  it("returns null when the transcript file is missing", async () => {
    const root = claudeFixture("present", [{ type: "ai-title", aiTitle: "x" }]);
    expect(await deriveClaudeTitle("33333333-missing", root)).toBeNull();
  });
});

describe("deriveCodexTitle", () => {
  it("returns the first user_message for the matching session", async () => {
    const id = "44444444-4444-4444-4444-444444444444";
    const root = codexFixture(id, [
      { type: "session_meta", payload: { id, cwd: "/x" } },
      { type: "response_item", payload: { type: "message", role: "user", content: "AGENTS.md…" } },
      { type: "event_msg", payload: { type: "user_message", message: "Add a dark mode toggle" } },
      { type: "event_msg", payload: { type: "user_message", message: "second prompt" } },
    ]);
    expect(await deriveCodexTitle(id, root)).toBe("Add a dark mode toggle");
  });

  it("returns null when the matching session has no prompt yet", async () => {
    const id = "55555555-5555-5555-5555-555555555555";
    const root = codexFixture(id, [{ type: "session_meta", payload: { id, cwd: "/x" } }]);
    expect(await deriveCodexTitle(id, root)).toBeNull();
  });

  it("ignores rollouts belonging to other sessions", async () => {
    const root = codexFixture("other", [
      { type: "session_meta", payload: { id: "other", cwd: "/x" } },
      { type: "event_msg", payload: { type: "user_message", message: "not mine" } },
    ]);
    expect(await deriveCodexTitle("66666666-nope", root)).toBeNull();
  });
});
