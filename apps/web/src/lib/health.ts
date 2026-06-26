import { useSyncExternalStore } from "react";
import { socket } from "./socket.ts";
import type { ServerMessage, SessionHealthReport } from "../protocol.ts";

/**
 * A tiny store of the periodic health-check sweep's results, fed by the server's
 * `health` broadcasts (one shared socket subscription) — pillar 3 of the
 * orchestration loop (juancode-02k). The sidebar reads it to surface dead/stale
 * sessions and offer reactivation.
 *
 * Each sweep replaces the whole set (the server always sends the complete list).
 * A user can dismiss a flagged session; the dismissal is cleared automatically
 * once that session drops out of a later sweep (i.e. it recovered), so a fresh
 * failure re-alerts rather than staying silently muted.
 */

let reports: SessionHealthReport[] = [];
let dismissed = new Set<string>();
const listeners = new Set<() => void>();
let started = false;

function emit(): void {
  for (const l of listeners) l();
}

function start(): void {
  if (started) return;
  started = true;
  socket.subscribe((msg: ServerMessage) => {
    if (msg.type !== "health") return;
    reports = msg.reports;
    // Drop dismissals for sessions that are no longer flagged — they recovered,
    // so a future re-failure should alert again.
    const flagged = new Set(reports.map((r) => r.id));
    let changed = false;
    for (const id of dismissed) {
      if (!flagged.has(id)) {
        dismissed.delete(id);
        changed = true;
      }
    }
    if (changed) dismissed = new Set(dismissed);
    emit();
  });
}

function subscribe(cb: () => void): () => void {
  start();
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/** The full set of unhealthy sessions, minus the ones the user dismissed. */
export function useHealthReports(): SessionHealthReport[] {
  const all = useSyncExternalStore(subscribe, () => reports);
  const muted = useSyncExternalStore(subscribe, () => dismissed);
  return all.filter((r) => !muted.has(r.id));
}

/** Hide a flagged session until it recovers and re-fails. */
export function dismissHealth(id: string): void {
  if (dismissed.has(id)) return;
  dismissed = new Set(dismissed).add(id);
  emit();
}
