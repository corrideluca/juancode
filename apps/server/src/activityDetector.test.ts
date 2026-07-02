import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ActivityDetector, batchHasAgentActivity } from "./activityDetector.ts";
import type { SessionActivity, StructuredEvent } from "./protocol.ts";

/** Minimal structured event of a given kind, for the structured-signal tests. */
const ev = (kind: StructuredEvent["kind"], text = ""): StructuredEvent => ({
  id: `${kind}-${Math.random()}`,
  kind,
  text,
  ts: null,
});

const SETTLE = 300; // a touch over the detector's SETTLE_MS
const WATCHDOG = 8100; // a touch over the detector's WATCHDOG_MS
/** A turn-end frame: clear the screen + home the cursor, tearing down the footer. */
const CLEAR = "\x1b[2J\x1b[H";

describe("ActivityDetector", () => {
  let events: Array<{ state: SessionActivity; notify: boolean }>;
  let det: ActivityDetector;

  beforeEach(() => {
    vi.useFakeTimers();
    events = [];
    det = new ActivityDetector(120, 40, (state, notify) => events.push({ state, notify }));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("goes busy on the working indicator", () => {
    det.feed("✻ Thinking… (3s · esc to interrupt)");
    expect(events).toEqual([{ state: "busy", notify: false }]);
  });

  // Real claude positions the footer segments with same-line cursor moves; the grid
  // renders those as spatial gaps (not glued, not on separate rows), so it matches.
  it.each([
    "✻ Thinking… (esc\x1b[1;44Hto\x1b[1;48Hinterrupt)",
    "✻ Thinking… (esc\x1b[44Gto interrupt)",
    "✻ Thinking… (esc\x1b[40Gto\x1b[44Ginterrupt)",
  ])("goes busy on the cursor-fragmented indicator %j", (frame) => {
    det.feed(frame);
    expect(events).toEqual([{ state: "busy", notify: false }]);
  });

  it("settles to idle (and notifies) when the footer is erased", () => {
    det.feed("✻ Working… (esc to interrupt)");
    det.feed(`${CLEAR}Here is the answer.\n`); // footer torn down, plain result
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([
      { state: "busy", notify: false },
      { state: "idle", notify: true },
    ]);
  });

  it("classifies an option menu as waiting_input", () => {
    det.feed("Running… esc to interrupt");
    det.feed(`${CLEAR}Do you want to proceed?\n ❯ 1. Yes\n   2. No\n`);
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "waiting_input", notify: true });
  });

  it("ignores the startup banner and user typing (no indicator)", () => {
    det.feed("Welcome to Claude Code!\n");
    det.feed("> what is 2 + 2"); // user typing echoed back
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([]);
  });

  // The headline fix: while the footer is still on screen the session stays busy,
  // even across a long quiet stretch. The old quiet-based detector wrongly idled.
  it("stays busy while the footer is visible", () => {
    det.feed("✻ Working… (esc to interrupt)\n"); // footer on its own line
    vi.advanceTimersByTime(SETTLE);
    det.feed("streaming a token…\n"); // output above the footer
    vi.advanceTimersByTime(SETTLE);
    det.feed("more tokens…\n");
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([{ state: "busy", notify: false }]); // never settled early
    // Once the footer is erased, it settles.
    det.feed(`${CLEAR}Done.\n`);
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "idle", notify: true });
  });

  // Safety net: if the footer lingers but the spinner stops emitting, the watchdog
  // demotes the stuck busy.
  it("demotes a stuck busy via the watchdog", () => {
    det.feed("✻ Working… (esc to interrupt)"); // footer stays, no further output
    vi.advanceTimersByTime(WATCHDOG);
    expect(events).toEqual([
      { state: "busy", notify: false },
      { state: "idle", notify: true },
    ]);
  });

  it("returns to idle on reset", () => {
    det.feed("esc to interrupt");
    det.reset();
    expect(events.at(-1)).toEqual({ state: "idle", notify: false });
  });

  // ── Structured stream-json signal (juancode-doq) ──────────────────────────

  it("goes busy on an agent structured event with no footer at all", () => {
    // No "esc to interrupt" text anywhere — the screen path can't see this; the
    // structured pulse is what makes us busy. This is the robustness win.
    det.feedStructured([ev("assistant", "On it.")]);
    expect(events).toEqual([{ state: "busy", notify: false }]);
  });

  it.each(["thinking", "tool_use", "tool_result"] as const)(
    "treats a %s event as agent activity",
    (kind) => {
      det.feedStructured([ev(kind)]);
      expect(events).toEqual([{ state: "busy", notify: false }]);
    },
  );

  it("does not go busy on a lone user event (the user's own prompt)", () => {
    det.feedStructured([ev("user", "do the thing")]);
    expect(events).toEqual([]);
  });

  it("settles a structured turn to idle when the transcript goes quiet", () => {
    det.feedStructured([ev("assistant", "working")]);
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([
      { state: "busy", notify: false },
      { state: "idle", notify: true },
    ]);
  });

  it("settles a structured turn to waiting_input when the screen shows a prompt", () => {
    det.feedStructured([ev("tool_use")]);
    // The permission prompt is rendered to the screen but not (yet) the transcript.
    det.feed("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n");
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "waiting_input", notify: true });
  });

  it("a structured turn settles on quiet even while the footer lingers on screen", () => {
    // The transcript says the agent stopped; the CLI just hasn't erased the
    // footer yet. The structured path must not pin us busy on a stale footer.
    det.feed("✻ Working… (esc to interrupt)"); // footer visible
    det.feedStructured([ev("assistant")]); // upgrades the turn to structured
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "idle", notify: true });
  });

  it("a structured pulse re-arms the settle window so the turn stays busy", () => {
    const TICK = 150; // under the detector's 250ms SETTLE_MS
    det.feedStructured([ev("tool_use")]);
    vi.advanceTimersByTime(TICK);
    det.feedStructured([ev("tool_result")]); // re-arms before settle fires
    vi.advanceTimersByTime(TICK);
    expect(events).toEqual([{ state: "busy", notify: false }]); // never settled
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "idle", notify: true });
  });

  // ── idle → waiting_input without a preceding turn (juancode-8w5) ──────────

  /** Push `text` into the bottom region by prefixing enough blank rows. */
  const atBottom = (text: string) => `${CLEAR}${"\n".repeat(30)}${text}`;

  it("promotes idle→waiting_input on a folder-trust dialog with no working turn", () => {
    det.feed(atBottom("Do you trust the files in this folder?\n ❯ 1. Yes, proceed\n   2. No, exit\n"));
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "waiting_input", notify: true });
    expect(det.lastPromptMatch).toBe("select-cursor");
  });

  it("promotes idle→waiting_input on a y/n prompt with no selection cursor", () => {
    det.feed(atBottom("Overwrite the file? (y/n)"));
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "waiting_input", notify: true });
    expect(det.lastPromptMatch).toBe("yn-paren");
  });

  it("ignores the startup banner (no prompt marker)", () => {
    det.feed(`${CLEAR}✻ Welcome to Claude Code!\n\n  /help for help\n\n> `);
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([]);
    expect(det.activity).toBe("idle");
  });

  it("does not trigger on 'Do you want to' scrolled up in history", () => {
    // The prose sits at the top; the bottom region (where a live prompt would be)
    // is blank, so the bottom-only marker must not match.
    det.feed(`${CLEAR}Earlier I asked: Do you want to refactor this?\n${"\n".repeat(35)}`);
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([]);
    expect(det.activity).toBe("idle");
  });

  it("clears waiting_input back to idle when the prompt is answered away", () => {
    det.feed(atBottom("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"));
    vi.advanceTimersByTime(SETTLE);
    expect(det.activity).toBe("waiting_input");
    // The menu is torn down and replaced with a plain result — no marker left.
    det.feed(`${CLEAR}Done.\n`);
    vi.advanceTimersByTime(SETTLE);
    expect(events.at(-1)).toEqual({ state: "idle", notify: false });
  });

  it("does not flicker to waiting_input during ordinary streaming output", () => {
    // Idle output that happens to contain a '?' but no prompt in the bottom region.
    det.feed(`${CLEAR}The answer to your question is 42.\n${"\n".repeat(35)}`);
    vi.advanceTimersByTime(SETTLE);
    expect(events).toEqual([]);
  });
});

describe("batchHasAgentActivity", () => {
  it("is true when any agent-produced event is present", () => {
    expect(batchHasAgentActivity([ev("user"), ev("assistant")])).toBe(true);
    expect(batchHasAgentActivity([ev("tool_use")])).toBe(true);
  });

  it("is false for an empty batch or only user events", () => {
    expect(batchHasAgentActivity([])).toBe(false);
    expect(batchHasAgentActivity([ev("user")])).toBe(false);
  });
});
