import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import { ShellTerminal } from "./ShellTerminal.tsx";
import {
  addTab,
  closePane,
  closeTab,
  setActiveTab,
  splitActive,
  useTerminalLayout,
} from "../lib/terminalStore.ts";

/**
 * The integrated terminal: a VS Code-style panel of plain shells, all rooted at
 * the session's `cwd`. Each tab is a horizontal row of one or more split panes;
 * every pane is a {@link ShellTerminal} wired to its own server shell pty.
 *
 * All durable state — which tabs/panes exist, which is active, and the live
 * xterm/pty per pane — lives in {@link import("../lib/terminalStore.ts")
 * terminalStore}, keyed by `sessionId`, so it survives this component (and the
 * whole session view) remounting on a session switch. This component is a thin,
 * stateless view over that store. `onClose` fires when the last pane is closed,
 * so the parent can collapse the bottom split.
 */
export function TerminalPanel({
  sessionId,
  cwd,
  onClose,
}: {
  sessionId: string;
  cwd: string;
  onClose: () => void;
}) {
  const { groups, activeId } = useTerminalLayout(sessionId);

  const onClosePane = (groupId: string, paneId: string) => {
    if (closePane(sessionId, groupId, paneId)) onClose();
  };
  const onCloseTab = (groupId: string) => {
    if (closeTab(sessionId, groupId)) onClose();
  };

  return (
    <div className="flex h-full flex-col bg-[#0b0d10]">
      <div className="flex items-center gap-1 border-b border-neutral-800 bg-neutral-900/60 px-2 py-1 text-xs">
        <div className="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto">
          {groups.map((g, i) => (
            <div
              key={g.id}
              onClick={() => setActiveTab(sessionId, g.id)}
              className={`group flex cursor-pointer items-center gap-1.5 rounded px-2 py-0.5 transition-colors ${
                g.id === activeId
                  ? "bg-neutral-800 text-neutral-100 hover:bg-neutral-700"
                  : "text-neutral-400 hover:bg-neutral-800/60 hover:text-neutral-200"
              }`}
            >
              <span className="font-mono">{`zsh ${i + 1}`}</span>
              <button
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab(g.id);
                }}
                title="Close terminal"
                className="text-neutral-500 opacity-0 hover:text-neutral-200 group-hover:opacity-100"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
        <button
          onClick={() => splitActive(sessionId)}
          title="Split terminal"
          className="rounded px-1.5 py-0.5 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          ⊟
        </button>
        <button
          onClick={() => addTab(sessionId)}
          title="New terminal"
          className="rounded px-1.5 py-0.5 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          +
        </button>
        <button
          onClick={onClose}
          title="Hide terminal panel"
          className="rounded px-1.5 py-0.5 text-neutral-400 hover:bg-neutral-800 hover:text-neutral-200"
        >
          ⌄
        </button>
      </div>
      <div className="relative min-h-0 flex-1">
        {groups.map((g) => (
          <div key={g.id} className={`absolute inset-0 ${g.id === activeId ? "" : "hidden"}`}>
            <PanelGroup direction="horizontal">
              {g.paneIds.map((paneId, i) => (
                <PaneSlot key={paneId} order={i + 1} showHandle={i > 0}>
                  <div className="group relative h-full w-full">
                    <ShellTerminal
                      paneId={paneId}
                      cwd={cwd}
                      onExit={() => onClosePane(g.id, paneId)}
                    />
                    {g.paneIds.length > 1 && (
                      <button
                        onClick={() => onClosePane(g.id, paneId)}
                        title="Close pane"
                        className="absolute right-1 top-1 z-10 rounded bg-neutral-900/80 px-1.5 text-xs text-neutral-400 opacity-0 hover:text-neutral-200 group-hover:opacity-100"
                      >
                        ✕
                      </button>
                    )}
                  </div>
                </PaneSlot>
              ))}
            </PanelGroup>
          </div>
        ))}
      </div>
    </div>
  );
}

/** A split pane plus the resize handle that precedes it (omitted for the first). */
function PaneSlot({
  order,
  showHandle,
  children,
}: {
  order: number;
  showHandle: boolean;
  children: React.ReactNode;
}) {
  return (
    <>
      {showHandle && (
        <PanelResizeHandle className="relative w-px bg-neutral-800 transition-colors after:absolute after:inset-y-0 after:-left-1 after:w-2 hover:bg-neutral-600 data-[resize-handle-state=drag]:bg-neutral-500" />
      )}
      <Panel order={order} minSize={15} className="overflow-hidden">
        {children}
      </Panel>
    </>
  );
}
