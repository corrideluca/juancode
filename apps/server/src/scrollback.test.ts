import { describe, expect, it } from "vitest";
import { ALT_RESYNC, Scrollback, appendScrollback } from "./scrollback.ts";

describe("appendScrollback", () => {
  it("appends when under the limit", () => {
    expect(appendScrollback("ab", "cd", 100)).toBe("abcd");
  });

  it("trims oldest characters past the limit", () => {
    expect(appendScrollback("abcd", "ef", 4)).toBe("cdef");
  });

  it("handles a chunk larger than the limit", () => {
    expect(appendScrollback("", "abcdef", 3)).toBe("def");
  });

  it("keeps exactly the limit when equal", () => {
    expect(appendScrollback("ab", "cd", 4)).toBe("abcd");
  });
});

// Alternate-buffer resync (juancode garbled-TUI fix).
describe("Scrollback alt-buffer resync", () => {
  const ENTER = "\x1b[?1049h";
  const EXIT = "\x1b[?1049l";

  it("replays raw text on the normal buffer", () => {
    const s = new Scrollback(100);
    s.append("hello");
    expect(s.inAlternateBuffer).toBe(false);
    expect(s.replay).toBe("hello");
  });

  it("prepends a resync prefix in the alternate buffer", () => {
    const s = new Scrollback(100);
    s.append(`${ENTER}frame`);
    expect(s.inAlternateBuffer).toBe(true);
    expect(s.replay).toBe(`${ALT_RESYNC}${ENTER}frame`);
  });

  it("clears the state on exit-alt", () => {
    const s = new Scrollback(100);
    s.append(ENTER);
    s.append(`${EXIT}back to normal`);
    expect(s.inAlternateBuffer).toBe(false);
    expect(s.replay).toBe(`${ENTER}${EXIT}back to normal`);
  });

  it("retains alt state after the enter sequence is trimmed", () => {
    const s = new Scrollback(8);
    s.append(ENTER);
    s.append("abcdefghij"); // pushes the enter-alt out of the kept window
    expect(s.bytes).toBe("cdefghij");
    expect(s.inAlternateBuffer).toBe(true);
    expect(s.replay).toBe(`${ALT_RESYNC}cdefghij`);
  });

  it("detects an enter sequence split across chunks", () => {
    const s = new Scrollback(100);
    s.append(ENTER.slice(0, 4));
    s.append(`${ENTER.slice(4)}x`);
    expect(s.inAlternateBuffer).toBe(true);
  });

  it("recovers alt state from a replay-shaped seed and strips the prefix", () => {
    const s = new Scrollback(100, `${ALT_RESYNC}frame-content`);
    expect(s.inAlternateBuffer).toBe(true);
    expect(s.bytes).toBe("frame-content");
    expect(s.replay).toBe(`${ALT_RESYNC}frame-content`);
  });
});
