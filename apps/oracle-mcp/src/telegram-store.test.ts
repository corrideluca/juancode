import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  clearTelegramSession,
  getTelegramSession,
  setTelegramSession,
} from "./telegram-store.ts";

describe("telegram session store", () => {
  let dir: string;
  const prev = process.env.JUANCODE_ORACLE_DIR;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "oracle-telegram-test-"));
    process.env.JUANCODE_ORACLE_DIR = dir;
  });

  afterEach(() => {
    if (prev === undefined) delete process.env.JUANCODE_ORACLE_DIR;
    else process.env.JUANCODE_ORACLE_DIR = prev;
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns null for an unknown chat", async () => {
    expect(await getTelegramSession(42)).toBeNull();
  });

  it("binds a chat to a session id", async () => {
    await setTelegramSession(42, "sess-1", 1000);
    expect(await getTelegramSession(42)).toBe("sess-1");
  });

  it("rebinds the same chat to a new session id", async () => {
    await setTelegramSession(42, "sess-1", 1000);
    await setTelegramSession(42, "sess-2", 2000);
    expect(await getTelegramSession(42)).toBe("sess-2");
  });

  it("keeps chats independent", async () => {
    await setTelegramSession(1, "a", 1000);
    await setTelegramSession(2, "b", 1000);
    expect(await getTelegramSession(1)).toBe("a");
    expect(await getTelegramSession(2)).toBe("b");
  });

  it("clears a chat's binding so the next message starts fresh", async () => {
    await setTelegramSession(42, "sess-1", 1000);
    await clearTelegramSession(42);
    expect(await getTelegramSession(42)).toBeNull();
  });

  it("rejects an empty session id", async () => {
    await expect(setTelegramSession(42, "")).rejects.toThrow();
  });

  it("tolerates a corrupt store file", async () => {
    writeFileSync(join(dir, "oracle-telegram-sessions.json"), "{ not json");
    expect(await getTelegramSession(42)).toBeNull();
  });
});
