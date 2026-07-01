import { useEffect, useState } from "react";
import { useConnectionState, useInFlightInput } from "../lib/useConnection.ts";

// Don't flash the banner on momentary blips (a single dropped frame, a fast
// reconnect). Only surface it once we've been disconnected a beat.
const SHOW_DELAY_MS = 1200;

/**
 * A subtle, non-blocking "Reconnecting…" pill shown while the shared socket is
 * not open. Replaces the old failure mode where a backgrounded phone resumed to
 * a hard "Failed to fetch" error — here the client just reconnects quietly and
 * this is the only hint the user sees.
 */
export function ConnectionBanner() {
  const state = useConnectionState();
  // Keystrokes buffered but not yet acknowledged by the server (juancode-1u3).
  // While reconnecting these are held and will be resent, so surface the count
  // as reassurance that nothing was lost.
  const inFlight = useInFlightInput();
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (state === "online") {
      setVisible(false);
      return;
    }
    const t = setTimeout(() => setVisible(true), SHOW_DELAY_MS);
    return () => clearTimeout(t);
  }, [state]);

  if (!visible) return null;

  return (
    <div className="pointer-events-none fixed inset-x-0 top-2 z-50 flex justify-center">
      <div className="pointer-events-auto flex items-center gap-2 rounded-full border border-amber-900/60 bg-amber-950/80 px-3 py-1 text-xs text-amber-200 shadow-lg backdrop-blur-sm">
        <span className="h-2 w-2 animate-pulse rounded-full bg-amber-400" />
        Reconnecting…
        {inFlight > 0 && (
          <span className="text-amber-300/80">
            · {inFlight} unsent keystroke{inFlight === 1 ? "" : "s"}
          </span>
        )}
      </div>
    </div>
  );
}
