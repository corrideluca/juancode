import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadEnvFile, parseEnv } from "./load-env.ts";

describe("parseEnv", () => {
  it("parses KEY=value, export, comments, blanks, and quotes", () => {
    const parsed = parseEnv(
      [
        "# a comment",
        "",
        "TELEGRAM_BOT_TOKEN=123:abc",
        "export ALLOWED_USER_IDS=5547517536",
        'QUOTED="with spaces"',
        "SINGLE='val'",
        "bad line no equals",
        "=novalue",
        "123BAD=x",
      ].join("\n"),
    );
    expect(parsed).toEqual({
      TELEGRAM_BOT_TOKEN: "123:abc",
      ALLOWED_USER_IDS: "5547517536",
      QUOTED: "with spaces",
      SINGLE: "val",
    });
  });
});

describe("loadEnvFile", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-env-test-"));
  });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("returns [] for a missing file (no throw)", () => {
    expect(loadEnvFile(join(dir, "nope.env"), {})).toEqual([]);
  });

  it("sets only keys not already present (a shell export wins)", () => {
    const path = join(dir, ".env");
    writeFileSync(path, "TELEGRAM_BOT_TOKEN=from-file\nALLOWED_USER_IDS=1");
    const env: NodeJS.ProcessEnv = { TELEGRAM_BOT_TOKEN: "from-shell" };
    const set = loadEnvFile(path, env);
    expect(env.TELEGRAM_BOT_TOKEN).toBe("from-shell");
    expect(env.ALLOWED_USER_IDS).toBe("1");
    expect(set).toEqual(["ALLOWED_USER_IDS"]);
  });
});
