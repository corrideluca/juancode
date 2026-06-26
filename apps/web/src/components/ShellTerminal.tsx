import { useEffect, useRef } from "react";
import { attachPane, fitPane } from "../lib/terminalStore.ts";

/**
 * One pane of the integrated terminal. The xterm + shell pty are NOT owned here:
 * they live in {@link import("../lib/terminalStore.ts") terminalStore}, keyed by
 * `paneId`, so they survive this component unmounting (e.g. when the session view
 * remounts on a session switch). On mount we re-attach the persistent terminal
 * into our container; on unmount we merely detach it, leaving the shell alive.
 * The pty is killed only when the pane is explicitly closed (via the store).
 *
 * `onExit` fires when the shell itself exits (e.g. the user types `exit`).
 */
export function ShellTerminal({
  paneId,
  cwd,
  onExit,
}: {
  paneId: string;
  cwd: string;
  onExit?: () => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  // Keep the latest onExit without re-running the attach effect.
  const onExitRef = useRef(onExit);
  onExitRef.current = onExit;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const detach = attachPane(paneId, cwd, container, () => onExitRef.current?.());

    const resizeObserver = new ResizeObserver(() => fitPane(paneId));
    resizeObserver.observe(container);

    return () => {
      resizeObserver.disconnect();
      detach();
    };
  }, [paneId, cwd]);

  return <div ref={containerRef} className="h-full w-full p-2" />;
}
