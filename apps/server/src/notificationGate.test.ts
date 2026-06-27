import { describe, expect, it } from "vitest";
import { COALESCE_MS, NotificationGate } from "./notificationGate.ts";

describe("NotificationGate", () => {
  it("never alerts on busy", () => {
    const gate = new NotificationGate();
    expect(gate.shouldNotify("s", "busy", 0)).toBe(false);
    expect(gate.shouldNotify("s", "busy", 1_000_000)).toBe(false);
  });

  it("alerts on the first waiting_input and the first idle", () => {
    const gate = new NotificationGate();
    expect(gate.shouldNotify("s", "waiting_input", 0)).toBe(true);
    // A genuine change to the other alert state fires immediately.
    expect(gate.shouldNotify("s", "idle", 100)).toBe(true);
  });

  it("coalesces a flapping permission menu (repeat waiting_input) inside the window", () => {
    const gate = new NotificationGate();
    expect(gate.shouldNotify("s", "waiting_input", 0)).toBe(true);
    // waiting_input → busy → waiting_input repaint within the window: one alert.
    expect(gate.shouldNotify("s", "busy", 200)).toBe(false); // busy never alerts
    expect(gate.shouldNotify("s", "waiting_input", 400)).toBe(false);
    expect(gate.shouldNotify("s", "waiting_input", COALESCE_MS - 1)).toBe(false);
  });

  it("re-alerts the same state once the window has passed", () => {
    const gate = new NotificationGate();
    expect(gate.shouldNotify("s", "waiting_input", 0)).toBe(true);
    expect(gate.shouldNotify("s", "waiting_input", COALESCE_MS + 1)).toBe(true);
  });

  it("dedupes per session independently", () => {
    const gate = new NotificationGate();
    expect(gate.shouldNotify("a", "idle", 0)).toBe(true);
    expect(gate.shouldNotify("b", "idle", 0)).toBe(true); // different session, not coalesced
    expect(gate.shouldNotify("a", "idle", 1)).toBe(false); // same session, within window
  });

  it("forgets a session so it can alert fresh after restart", () => {
    const gate = new NotificationGate();
    expect(gate.shouldNotify("s", "idle", 0)).toBe(true);
    expect(gate.shouldNotify("s", "idle", 1)).toBe(false);
    gate.forget("s");
    expect(gate.shouldNotify("s", "idle", 2)).toBe(true);
  });
});
