import { useEffect, useRef, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import { api } from "../lib/api.ts";
import { socket } from "../lib/socket.ts";
import type { ServerMessage } from "../protocol.ts";
import { BeadsPanel } from "./BeadsPanel.tsx";
import { ChangesPanel } from "./ChangesPanel.tsx";
import { Terminal } from "./Terminal.tsx";

/** Which auxiliary view, if any, is open in the collapsible right panel. */
type SidePanel = "changes" | "issues" | null;

export function SessionView({ id }: { id: string }) {
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: api.sessions });
  const meta = sessions.data?.find((s) => s.id === id);
  const [side, setSide] = useState<SidePanel>(null);

  // Track status live off the socket so the header reflects reality without
  // waiting for the next sessions poll (kill → exited, reactivate → running).
  const [liveStatus, setLiveStatus] = useState<"running" | "exited" | null>(null);
  useEffect(() => {
    setLiveStatus(null);
    return socket.subscribe((msg: ServerMessage) => {
      if (!("sessionId" in msg) || msg.sessionId !== id) return;
      if (msg.type === "attached") setLiveStatus(msg.session.status);
      else if (msg.type === "exit") setLiveStatus("exited");
    });
  }, [id]);

  // Auto-resume: opening a session that already exited (but is resumable) should
  // bring it back to life rather than leave a dead transcript. We decide once per
  // session view, off the *persisted* status — so killing a session mid-view
  // doesn't immediately respawn it.
  const decidedFor = useRef<string | null>(null);
  useEffect(() => {
    decidedFor.current = null;
  }, [id]);
  useEffect(() => {
    if (decidedFor.current === id || !meta) return;
    decidedFor.current = id;
    if (meta.status === "exited" && meta.cliSessionId) {
      setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
      socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
    }
  }, [id, meta]);

  const status = liveStatus ?? meta?.status;
  const canReactivate = status === "exited" && Boolean(meta?.cliSessionId);

  const toggle = (p: Exclude<SidePanel, null>) => setSide((cur) => (cur === p ? null : p));

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between border-b border-neutral-800 px-4 py-2">
        <div className="min-w-0">
          <div className="truncate text-sm font-medium">{meta?.title ?? id}</div>
          <div className="truncate font-mono text-[11px] text-neutral-500">{meta?.cwd}</div>
        </div>
        <nav className="mr-auto ml-4 flex gap-1 text-xs">
          {(["changes", "issues"] as const).map((p) => (
            <button
              key={p}
              onClick={() => toggle(p)}
              className={`rounded-md px-2.5 py-1 capitalize ${
                side === p ? "bg-neutral-800 text-neutral-100" : "text-neutral-400 hover:text-neutral-200"
              }`}
            >
              {p}
            </button>
          ))}
        </nav>
        {status === "running" && (
          <button
            onClick={() => socket.send({ type: "kill", sessionId: id })}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-red-500 hover:text-red-400"
          >
            Kill
          </button>
        )}
        {canReactivate && (
          <button
            onClick={() => {
              setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
              socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
            }}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            Reactivate
          </button>
        )}
      </header>
      <div className="min-h-0 flex-1 bg-[#0b0d10]">
        {/* The terminal panel is always mounted so the pty/xterm state and scroll
            position survive opening/closing the side panel. xterm refits itself
            via its ResizeObserver as the split is dragged. */}
        <PanelGroup direction="horizontal" autoSaveId="juancode-session-split">
          <Panel id="terminal" order={1} minSize={25} className="overflow-hidden">
            <Terminal key={id} sessionId={id} />
          </Panel>
          {side && (
            <>
              <PanelResizeHandle className="w-1.5 bg-neutral-800 transition-colors hover:bg-neutral-600 data-[resize-handle-state=drag]:bg-neutral-500" />
              <Panel id="side" order={2} defaultSize={45} minSize={25} className="overflow-hidden">
                {side === "changes" ? <ChangesPanel sessionId={id} /> : <BeadsPanel sessionId={id} />}
              </Panel>
            </>
          )}
        </PanelGroup>
      </div>
    </div>
  );
}
