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
