import { describe, expect, it } from "vitest";
import { buildPrompt, parseReviewOutput, runReview } from "./review.ts";
import type { DiffComment, DiffFile } from "./protocol.ts";

const file = (over: Partial<DiffFile> = {}): DiffFile => ({
  path: "src/a.ts",
  oldPath: null,
  status: "modified",
  additions: 1,
  deletions: 0,
  binary: false,
  diff: "@@ -0,0 +1 @@\n+const x = 1;\n",
  truncated: false,
  ...over,
});

const comment = (over: Partial<DiffComment> = {}): DiffComment => ({
  id: "c1",
  sessionId: "s1",
  file: "src/a.ts",
  side: "new",
  line: 1,
  endLine: 1,
  body: "is this right?",
  createdAt: 0,
  ...over,
});

/** Wrap a structured payload the way `claude -p --output-format json` does. */
const envelope = (result: unknown, over: Record<string, unknown> = {}) =>
  JSON.stringify({ type: "result", subtype: "success", is_error: false, result: JSON.stringify(result), ...over });

describe("buildPrompt", () => {
  it("includes each file's diff and stats", () => {
    const prompt = buildPrompt([file()], []);
    expect(prompt).toContain("src/a.ts");
    expect(prompt).toContain("+const x = 1;");
    expect(prompt).toContain("(modified, +1 −0)");
  });

  it("surfaces human inline comments as steering context", () => {
    const prompt = buildPrompt([file()], [comment()]);
    expect(prompt).toContain("inline comments");
    expect(prompt).toContain("src/a.ts:1 (new) — is this right?");
  });

  it("notes binary and truncated files instead of their diff", () => {
    const prompt = buildPrompt([file({ binary: true, diff: "" }), file({ path: "b", truncated: true, diff: "" })], []);
    expect(prompt).toContain("binary file");
    expect(prompt).toContain("diff too large");
  });

  it("caps an enormous diff", () => {
    const huge = file({ diff: "+x\n".repeat(200_000) });
    const prompt = buildPrompt([huge], []);
    expect(prompt).toContain("[diff truncated for length");
    expect(prompt.length).toBeLessThan(210_000);
  });
});

describe("parseReviewOutput", () => {
  it("parses validated findings and summary", () => {
    const out = parseReviewOutput(
      envelope({
        summary: "One issue found.",
        findings: [{ file: "src/a.ts", side: "new", line: 1, severity: "high", title: "Bug", note: "Off by one." }],
      }),
      5,
    );
    expect(out.status).toBe("ok");
    expect(out.summary).toBe("One issue found.");
    expect(out.createdAt).toBe(5);
    expect(out.findings).toEqual([
      { file: "src/a.ts", side: "new", line: 1, severity: "high", title: "Bug", note: "Off by one." },
    ]);
  });

  it("normalizes bad sides/severities/lines and drops empty findings", () => {
    const out = parseReviewOutput(
      envelope({
        summary: 42, // not a string → null
        findings: [
          { file: "a", side: "weird", line: "x", severity: "nope", title: "", note: "kept" },
          { file: "", side: "new", line: 1, severity: "low", title: "x", note: "y" }, // no file → dropped
          { file: "b", side: "old", line: 2, severity: "low", title: "", note: "" }, // empty → dropped
        ],
      }),
      0,
    );
    expect(out.summary).toBeNull();
    expect(out.findings).toEqual([{ file: "a", side: "new", line: null, severity: "info", title: "", note: "kept" }]);
  });

  it("reports CLI-level errors from the envelope", () => {
    const out = parseReviewOutput(
      JSON.stringify({ type: "result", subtype: "success", is_error: true, result: "Credit balance is too low" }),
      0,
    );
    expect(out.status).toBe("error");
    expect(out.error).toBe("Credit balance is too low");
  });

  it("errors on unparseable stdout", () => {
    expect(parseReviewOutput("not json", 0).status).toBe("error");
  });

  it("falls back to prose summary when result isn't schema JSON", () => {
    const out = parseReviewOutput(
      JSON.stringify({ type: "result", subtype: "success", is_error: false, result: "Looks fine to me." }),
      0,
    );
    expect(out.status).toBe("ok");
    expect(out.summary).toBe("Looks fine to me.");
    expect(out.findings).toEqual([]);
  });
});

describe("runReview", () => {
  it("short-circuits to 'empty' with no files (never spawns the CLI)", async () => {
    const out = await runReview("/tmp", [], [], 7);
    expect(out).toEqual({ status: "empty", findings: [], summary: null, createdAt: 7 });
  });
});
