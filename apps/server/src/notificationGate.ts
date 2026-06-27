import type { SessionActivity } from "./protocol.ts";

/**
 * Decides whether an activity transition deserves an *alert* (the `notify` flag on
 * the `activity` broadcast), independently of whether the state genuinely changed.
 *
 * The {@link ActivityDetector} already only emits a transition (and `notify`) on a
 * real state change, but a live agent legitimately oscillates
 * `waiting_input → busy → waiting_input` as the CLI repaints its permission menu,
 * and ends many short turns back-to-back — each a genuine transition, but firing a
 * ding/OS-notification on every one is spam, and on mobile a fresh OS notification
 * per flap stacks up. This gate sits between the detector and the broadcast and
 * collapses those bursts:
 *
 *   - only `waiting_input` ("needs you") and `idle` ("done") are ever alertable;
 *   - a repeat of the *same* alert state for a session inside {@link COALESCE_MS}
 *     is suppressed (the flapping permission menu, or a run of tiny turns, alerts
 *     once — not once per repaint);
 *   - a genuine change to the *other* alert state still fires immediately (asking a
 *     question then finishing are two distinct, both-worth-knowing events).
 *
 * One shared instance is keyed by session id so the decision is made once per
 * transition and every connected client sees the same de-spammed `notify` flag
 * (rather than each tab / each reconnect re-deciding and re-alerting).
 */

/** Window within which a repeat of the same alert state for a session is dropped. */
export const COALESCE_MS = 10_000;

interface LastAlert {
  state: SessionActivity;
  at: number;
}

export class NotificationGate {
  private readonly last = new Map<string, LastAlert>();

  /**
   * Whether a transition into `state` for `sessionId` should fire an alert now.
   * `busy` is never alertable; a same-state repeat inside {@link COALESCE_MS} is
   * coalesced away. Records the decision so the next call can dedupe against it.
   */
  shouldNotify(sessionId: string, state: SessionActivity, now: number = Date.now()): boolean {
    if (state !== "waiting_input" && state !== "idle") return false;
    const prev = this.last.get(sessionId);
    if (prev && prev.state === state && now - prev.at < COALESCE_MS) return false;
    this.last.set(sessionId, { state, at: now });
    return true;
  }

  /** Drop a session's history (call when it exits) so ids don't accumulate. */
  forget(sessionId: string): void {
    this.last.delete(sessionId);
  }
}

/** Process-wide gate shared across all sessions and connections. */
export const notificationGate = new NotificationGate();
