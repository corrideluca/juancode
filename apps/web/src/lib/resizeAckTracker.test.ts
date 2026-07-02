import { describe, expect, it } from "vitest";
import { ResizeAckTracker } from "./resizeAckTracker.ts";

const resize = (sessionId: string, cols: number, rows: number) =>
  ({ type: "resize", sessionId, cols, rows }) as const;

describe("ResizeAckTracker", () => {
  it("assigns a monotonic seq and stamps it into the frame", () => {
    const t = new ResizeAckTracker();
    const a = t.track(resize("s1", 80, 24));
    const b = t.track(resize("s1", 100, 30));
    expect(a.seq).toBe(1);
    expect(b.seq).toBe(2);
    expect(JSON.parse(b.data)).toEqual({
      type: "resize",
      sessionId: "s1",
      cols: 100,
      rows: 30,
      seq: 2,
    });
  });

  it("keeps only the latest desired grid per session (newer supersedes older)", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.track(resize("s1", 120, 40));
    // The reconnect replay re-asserts one frame — the newest — not both.
    const pending = t.pending().map((d) => JSON.parse(d));
    expect(pending).toHaveLength(1);
    expect(pending[0]).toMatchObject({ cols: 120, rows: 40 });
  });

  it("forgets a session's grid so it isn't replayed after exit", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.track(resize("s2", 100, 30));
    t.forget("s1");
    const sessions = t.pending().map((d) => JSON.parse(d).sessionId);
    expect(sessions).toEqual(["s2"]);
  });

  it("replays every tracked grid on reconnect with fresh seqs", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.track(resize("s2", 100, 30));
    const frames = t.pending().map((d) => JSON.parse(d));
    expect(frames.map((f) => f.sessionId).sort()).toEqual(["s1", "s2"]);
    // Fresh seqs (> the 2 assigned by track) so replay acks match.
    expect(frames.every((f) => f.seq > 2)).toBe(true);
  });

  it("drops all tracking on clear (server can't ack)", () => {
    const t = new ResizeAckTracker();
    t.track(resize("s1", 80, 24));
    t.clear();
    expect(t.pending()).toEqual([]);
  });
});
