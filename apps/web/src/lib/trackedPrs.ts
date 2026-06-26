import { useSyncExternalStore } from "react";
import { socket } from "./socket.ts";
import type { PullRequest, ServerMessage, TrackedPrInfo } from "../protocol.ts";

/**
 * Client mirror of the server's tracked-PR registry (juancode-bt2). One shared
 * socket subscription feeds a tiny external store with the server's `trackedPrs`
 * snapshots (always the complete set — replace wholesale), and per-escalation
 * `trackNotification` pings are forwarded to a listener set so a backgrounded tab
 * can alert. The senders (`trackPr` / `untrackPr` / `resolveTrackNotification`)
 * wrap the matching client messages.
 *
 * Tracking is driven entirely server-side (the agent session lives there); this
 * module is a thin observe-and-command surface so the remote web/phone client can
 * start/stop tracking and watch status + needs-decision escalations, exactly as
 * the native app does in-process.
 */

let tracked: TrackedPrInfo[] = [];
const listeners = new Set<() => void>();
type NotifyListener = (n: { trackedId: string; prNumber: number; message: string }) => void;
const notifyListeners = new Set<NotifyListener>();
let started = false;

function emit(): void {
  for (const l of listeners) l();
}

function start(): void {
  if (started) return;
  started = true;
  socket.subscribe((msg: ServerMessage) => {
    if (msg.type === "trackedPrs") {
      tracked = msg.tracked;
      emit();
    } else if (msg.type === "trackNotification") {
      for (const l of notifyListeners) {
        l({ trackedId: msg.trackedId, prNumber: msg.prNumber, message: msg.notification.message });
      }
    }
  });
  // Ask the server for the current snapshot + future updates.
  socket.send({ type: "subscribeTrackedPrs" });
}

function subscribe(cb: () => void): () => void {
  start();
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/** The full tracked-PR watch list, most-recently-polled first (server-ordered). */
export function useTrackedPrs(): TrackedPrInfo[] {
  return useSyncExternalStore(subscribe, () => tracked);
}

/** The tracked PR for a given folder + number, if any (drives a per-PR toggle). */
export function useTrackedPr(cwd: string, number: number): TrackedPrInfo | undefined {
  const all = useTrackedPrs();
  const id = `${cwd}#${number}`;
  return all.find((t) => t.id === id);
}

/** Subscribe to needs-decision escalation pings (for sound / OS notifications). */
export function onTrackNotification(listener: NotifyListener): () => void {
  start();
  notifyListeners.add(listener);
  return () => notifyListeners.delete(listener);
}

/** Start tracking a PR in `cwd` — spawns its driving agent session server-side. */
export function trackPr(cwd: string, pr: PullRequest): void {
  start();
  socket.send({ type: "trackPr", cwd, pr });
}

/** Stop tracking the PR `trackedId` (its agent session is left running). */
export function untrackPr(trackedId: string): void {
  socket.send({ type: "untrackPr", trackedId });
}

/** Dismiss a surfaced needs-decision notification once the user has handled it. */
export function resolveTrackNotification(trackedId: string, notificationId: string): void {
  socket.send({ type: "resolveTrackNotification", trackedId, notificationId });
}
