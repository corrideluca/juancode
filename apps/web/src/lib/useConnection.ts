import { useSyncExternalStore } from "react";
import { socket, type ConnectionState } from "./socket.ts";

/** Live connection state of the shared socket, for subtle reconnecting UI. */
export function useConnectionState(): ConnectionState {
  return useSyncExternalStore(
    (cb) => socket.subscribeStatus(cb),
    () => socket.connectionState,
    () => "offline" as ConnectionState,
  );
}

/**
 * Count of sent-but-unacknowledged keystrokes buffered by the socket
 * (juancode-1u3), for a subtle "unsent input" hint while reconnecting.
 */
export function useInFlightInput(): number {
  return useSyncExternalStore(
    (cb) => socket.subscribeInFlight(cb),
    () => socket.inFlightInputCount,
    () => 0,
  );
}
