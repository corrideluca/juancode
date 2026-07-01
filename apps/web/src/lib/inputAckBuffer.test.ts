import { describe, expect, it } from "vitest";
import { InputAckBuffer } from "./inputAckBuffer.ts";

const input = (sessionId: string, data: string) =>
  ({ type: "input", sessionId, data }) as const;

describe("InputAckBuffer", () => {
  it("assigns a monotonic seq and stamps it into the frame", () => {
    const buf = new InputAckBuffer();
    const a = buf.track(input("s1", "a"));
    const b = buf.track(input("s1", "b"));
    expect(a.seq).toBe(1);
    expect(b.seq).toBe(2);
    expect(JSON.parse(a.data)).toEqual({ type: "input", sessionId: "s1", data: "a", seq: 1 });
    expect(JSON.parse(b.data)).toEqual({ type: "input", sessionId: "s1", data: "b", seq: 2 });
  });

  it("counts sent-but-unacked inputs", () => {
    const buf = new InputAckBuffer();
    expect(buf.size).toBe(0);
    buf.track(input("s1", "a"));
    buf.track(input("s1", "b"));
    expect(buf.size).toBe(2);
  });

  it("clears an acked input and reports whether it was pending", () => {
    const buf = new InputAckBuffer();
    const a = buf.track(input("s1", "a"));
    expect(buf.ack(a.seq)).toBe(true);
    expect(buf.size).toBe(0);
    // A duplicate / stale ack for an already-cleared seq is a no-op.
    expect(buf.ack(a.seq)).toBe(false);
    // An ack for a never-sent seq is a no-op too.
    expect(buf.ack(999)).toBe(false);
  });

  it("replays only the still-unacked frames, in seq order", () => {
    const buf = new InputAckBuffer();
    const a = buf.track(input("s1", "a"));
    buf.track(input("s1", "b"));
    const c = buf.track(input("s1", "c"));
    // Ack out of order: the middle one stays pending.
    buf.ack(a.seq);
    buf.ack(c.seq);
    expect(buf.pending().map((d) => JSON.parse(d).data)).toEqual(["b"]);
  });

  it("preserves send order across many pending inputs", () => {
    const buf = new InputAckBuffer();
    for (const ch of ["a", "b", "c", "d"]) buf.track(input("s1", ch));
    expect(buf.pending().map((d) => JSON.parse(d).data)).toEqual(["a", "b", "c", "d"]);
  });

  it("drops everything on clear (server can't ack) without resetting the seq", () => {
    const buf = new InputAckBuffer();
    buf.track(input("s1", "a"));
    buf.clear();
    expect(buf.size).toBe(0);
    expect(buf.pending()).toEqual([]);
    // seq keeps climbing so a later ack-capable reconnect can't collide.
    expect(buf.track(input("s1", "b")).seq).toBe(2);
  });
});
