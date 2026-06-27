import { describe, expect, it } from "vitest";
import { mergeLoginEnv, parseEnvDump } from "./loginEnv.ts";

const SENTINEL = "__JUANCODE_LOGIN_ENV__";

describe("parseEnvDump", () => {
  it("parses simple key=value lines", () => {
    const raw = `${SENTINEL}\nPATH=/usr/bin:/bin\nHOME=/Users/jdoe\n`;
    expect(parseEnvDump(raw)).toEqual({ PATH: "/usr/bin:/bin", HOME: "/Users/jdoe" });
  });

  it("discards banners/MOTD emitted before the sentinel", () => {
    // A login shell often prints noise (last-login, fortune, an `nvm` notice)
    // before our payload. Anything before the sentinel is dropped.
    const raw = [
      "Last login: Mon Jun 23 on ttys001",
      "FAKE=should-be-ignored",
      SENTINEL,
      "PATH=/opt/homebrew/bin:/usr/bin",
    ].join("\n");
    expect(parseEnvDump(raw)).toEqual({ PATH: "/opt/homebrew/bin:/usr/bin" });
  });

  it("keeps '=' characters inside the value (splits on the first '=' only)", () => {
    const raw = `${SENTINEL}\nDATABASE_URL=postgres://u:p@h/db?a=1&b=2\n`;
    expect(parseEnvDump(raw).DATABASE_URL).toBe("postgres://u:p@h/db?a=1&b=2");
  });

  it("joins multi-line values where the continuation isn't itself an assignment", () => {
    // A var whose value spans lines (e.g. an exported multi-line cert/message).
    // A continuation line has no `KEY=` prefix, so it's folded into the value.
    const raw = `${SENTINEL}\nCERT=-----BEGIN-----\nabc123\n-----END-----\nPATH=/usr/bin\n`;
    const parsed = parseEnvDump(raw);
    expect(parsed.CERT).toBe("-----BEGIN-----\nabc123\n-----END-----");
    expect(parsed.PATH).toBe("/usr/bin");
  });

  it("ignores lines that are not valid env-name assignments", () => {
    const raw = `${SENTINEL}\n=novalue\n1BAD=x\nGOOD=y\n`;
    // `=novalue` has an empty key; `1BAD` starts with a digit — both rejected.
    expect(parseEnvDump(raw)).toEqual({ GOOD: "y" });
  });

  it("returns an empty map when there is no parseable output", () => {
    expect(parseEnvDump(`${SENTINEL}\n\n`)).toEqual({});
  });

  it("still parses when no sentinel is present (best-effort)", () => {
    expect(parseEnvDump("PATH=/usr/bin\n")).toEqual({ PATH: "/usr/bin" });
  });
});

describe("mergeLoginEnv", () => {
  it("uses the login-shell value as the base (terminal PATH wins over stripped GUI PATH)", () => {
    const live = { PATH: "/usr/bin" };
    const login = { PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin" };
    expect(mergeLoginEnv(live, login).PATH).toBe("/opt/homebrew/bin:/usr/local/bin:/usr/bin");
  });

  it("preserves live-only vars (e.g. JUANCODE_* overrides) not present in the login env", () => {
    const live = { JUANCODE_CLAUDE_BIN: "/custom/claude", PATH: "/usr/bin" };
    const login = { PATH: "/opt/homebrew/bin" };
    const merged = mergeLoginEnv(live, login);
    expect(merged.JUANCODE_CLAUDE_BIN).toBe("/custom/claude");
    expect(merged.PATH).toBe("/opt/homebrew/bin");
  });

  it("lets the live process win for process-specific keys", () => {
    const live = { PWD: "/Users/jdoe/project", OLDPWD: "/Users/jdoe", PATH: "/usr/bin" };
    const login = { PWD: "/Users/jdoe", OLDPWD: "/", PATH: "/opt/homebrew/bin" };
    const merged = mergeLoginEnv(live, login);
    expect(merged.PWD).toBe("/Users/jdoe/project");
    expect(merged.OLDPWD).toBe("/Users/jdoe");
    // ...but a non-process-specific key still takes the login value.
    expect(merged.PATH).toBe("/opt/homebrew/bin");
  });

  it("merges the union of both envs", () => {
    const live = { A: "1" };
    const login = { B: "2" };
    expect(mergeLoginEnv(live, login)).toEqual({ A: "1", B: "2" });
  });

  it("drops undefined live values", () => {
    const live: Record<string, string | undefined> = { A: undefined, B: "2" };
    expect(mergeLoginEnv(live, {})).toEqual({ B: "2" });
  });
});
