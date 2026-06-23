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

/** A file dropped onto the session, uploaded to the server and fed to the prompt. */
interface Attachment {
  id: string;
  name: string;
  size: number;
  isImage: boolean;
  /** Object URL for an image thumbnail (revoked on removal / session switch). */
  previewUrl?: string;
  status: "uploading" | "done" | "error";
  /** Absolute server path once uploaded. */
  path?: string;
  error?: string;
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function SessionView({ id }: { id: string }) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const sessions = useQuery({ queryKey: ["sessions"], queryFn: api.sessions });
  const meta = sessions.data?.find((s) => s.id === id);
  const [side, setSide] = useState<SidePanel>(null);

  // Track status live off the socket so the header reflects reality without
  // waiting for the next sessions poll (kill → exited, reactivate → running).
  const [liveStatus, setLiveStatus] = useState<"running" | "exited" | null>(null);
  // Set when the server reports it found no prior CLI conversation to resume —
  // then the only way forward is a fresh chat in the same folder.
  const [unresumable, setUnresumable] = useState(false);
  useEffect(() => {
    setLiveStatus(null);
    setUnresumable(false);
    return socket.subscribe((msg: ServerMessage) => {
      if (!("sessionId" in msg) || msg.sessionId !== id) return;
      if (msg.type === "attached") setLiveStatus(msg.session.status);
      else if (msg.type === "exit") setLiveStatus("exited");
      else if (msg.type === "unresumable") {
        setLiveStatus("exited");
        setUnresumable(true);
      }
    });
  }, [id]);

  // Auto-resume: opening a session that already exited should bring it back to
  // life rather than leave a dead transcript. Even sessions with no captured CLI
  // id get a shot — the server tries to recover it from the CLI's transcript. We
  // decide once per session view, off the *persisted* status, so killing a
  // session mid-view doesn't immediately respawn it.
  const decidedFor = useRef<string | null>(null);
  useEffect(() => {
    decidedFor.current = null;
  }, [id]);
  useEffect(() => {
    if (decidedFor.current === id || !meta) return;
    decidedFor.current = id;
    if (meta.status === "exited") {
      setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
      socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
    }
  }, [id, meta]);

  const status = liveStatus ?? meta?.status;
  const canReactivate = status === "exited" && !unresumable;

  /** Resume the session (server resumes its CLI conversation, recovering the id if needed). */
  const reactivate = () => {
    setUnresumable(false);
    setLiveStatus("running"); // optimistic — pty spawn is synchronous server-side
    socket.send({ type: "reactivate", sessionId: id, cols: 80, rows: 24 });
  };

  /** Fallback when a conversation can't be resumed: start a fresh one in the same folder. */
  const startFreshHere = () => {
    if (!meta) return;
    const unsub = socket.subscribe((msg) => {
      if (msg.type === "created") {
        unsub();
        void queryClient.invalidateQueries({ queryKey: ["sessions"] });
        void navigate({ to: "/session/$id", params: { id: msg.session.id } });
      } else if (msg.type === "error") {
        unsub();
      }
    });
    socket.send({ type: "create", provider: meta.provider, cwd: meta.cwd, cols: 80, rows: 24 });
  };

  const toggle = (p: Exclude<SidePanel, null>) => setSide((cur) => (cur === p ? null : p));

  // ── Drag-and-drop file attachments ─────────────────────────────────────────
  // Browsers don't expose a dragged file's real path, so we upload the bytes to
  // the local server, then type the saved path into the pty prompt (the CLI on
  // this same machine can then read it). A tray shows a preview of each drop.
  const [attachments, setAttachments] = useState<Attachment[]>([]);
  const [dragging, setDragging] = useState(false);
  // dragenter/dragleave fire for every child element; a depth counter keeps the
  // overlay from flickering as the cursor moves across the terminal.
  const dragDepth = useRef(0);
  const attachmentsRef = useRef<Attachment[]>([]);
  attachmentsRef.current = attachments;

  // Clear the tray (and free thumbnails) when switching sessions or unmounting.
  useEffect(() => {
    setAttachments([]);
    return () => {
      for (const a of attachmentsRef.current) if (a.previewUrl) URL.revokeObjectURL(a.previewUrl);
    };
  }, [id]);

  const removeAttachment = (attId: string) =>
    setAttachments((list) => {
      const found = list.find((a) => a.id === attId);
      if (found?.previewUrl) URL.revokeObjectURL(found.previewUrl);
      return list.filter((a) => a.id !== attId);
    });

  const handleFile = async (file: File) => {
    const attId = crypto.randomUUID();
    const isImage = file.type.startsWith("image/");
    const previewUrl = isImage ? URL.createObjectURL(file) : undefined;
    setAttachments((list) => [
      ...list,
      { id: attId, name: file.name, size: file.size, isImage, previewUrl, status: "uploading" },
    ]);
    try {
      const { path } = await api.uploadFile(file);
      setAttachments((list) => list.map((a) => (a.id === attId ? { ...a, status: "done", path } : a)));
      // The saved basename is sanitised server-side to be space-free, so the
      // path can be typed verbatim. Trailing space keeps the prompt usable.
      socket.send({ type: "input", sessionId: id, data: `${path} ` });
    } catch (err) {
      const error = err instanceof Error ? err.message : String(err);
      setAttachments((list) => list.map((a) => (a.id === attId ? { ...a, status: "error", error } : a)));
    }
  };

  const hasFiles = (e: React.DragEvent) => e.dataTransfer.types.includes("Files");
  const onDragEnter = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current += 1;
    setDragging(true);
  };
  const onDragOver = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  };
  const onDragLeave = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    dragDepth.current -= 1;
    if (dragDepth.current <= 0) {
      dragDepth.current = 0;
      setDragging(false);
    }
  };
  const onDrop = (e: React.DragEvent) => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    dragDepth.current = 0;
    setDragging(false);
    for (const file of Array.from(e.dataTransfer.files)) void handleFile(file);
  };

  return (
    <div
      className="relative flex h-full flex-col"
      onDragEnter={onDragEnter}
      onDragOver={onDragOver}
      onDragLeave={onDragLeave}
      onDrop={onDrop}
    >
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
            onClick={reactivate}
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            Reactivate
          </button>
        )}
        {unresumable && (
          <button
            onClick={startFreshHere}
            title="This conversation can't be resumed — start a new one in the same folder"
            className="rounded-md border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:border-emerald-500 hover:text-emerald-400"
          >
            New chat here
          </button>
        )}
      </header>
      {attachments.length > 0 && (
        <div className="flex flex-wrap gap-2 border-b border-neutral-800 bg-neutral-900/40 px-3 py-2">
          {attachments.map((a) => (
            <div
              key={a.id}
              className="flex items-center gap-2 rounded-md border border-neutral-700 bg-neutral-900 py-1 pl-1 pr-2 text-xs"
              title={a.path ?? a.name}
            >
              {a.isImage && a.previewUrl ? (
                <img src={a.previewUrl} alt={a.name} className="h-8 w-8 rounded object-cover" />
              ) : (
                <div className="flex h-8 w-8 items-center justify-center rounded bg-neutral-800 text-neutral-400">
                  📄
                </div>
              )}
              <div className="min-w-0">
                <div className="max-w-[12rem] truncate text-neutral-200">{a.name}</div>
                <div
                  className={`text-[10px] ${a.status === "error" ? "text-red-400" : "text-neutral-500"}`}
                >
                  {a.status === "uploading"
                    ? "uploading…"
                    : a.status === "error"
                      ? (a.error ?? "failed")
                      : formatSize(a.size)}
                </div>
              </div>
              <button
                onClick={() => removeAttachment(a.id)}
                className="ml-1 text-neutral-500 hover:text-neutral-200"
                title="Remove from tray"
              >
                ✕
              </button>
            </div>
          ))}
        </div>
      )}
      {dragging && (
        <div className="pointer-events-none absolute inset-0 z-20 flex items-center justify-center bg-neutral-950/70 backdrop-blur-sm">
          <div className="rounded-xl border-2 border-dashed border-emerald-500/70 px-8 py-6 text-sm text-emerald-300">
            Drop files to attach their path
          </div>
        </div>
      )}
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
