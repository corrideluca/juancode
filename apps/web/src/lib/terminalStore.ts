import { useSyncExternalStore } from "react";
import { Terminal as XTerm } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { socket } from "./socket.ts";
import type { ServerMessage } from "../protocol.ts";

/**
 * Persistent state + live connections for the integrated (VS Code-style) shell
 * terminals, keyed by session id and lifted above the per-session React remount.
 *
 * The problem this solves: the bottom terminal panel used to live entirely in
 * `SessionView`, which the router remounts on every session switch — tearing down
 * its xterms and killing the shell ptys. VS Code instead keeps terminals alive
 * across tab switches. So both the *layout* (which tabs/panes are open, which is
 * active, whether the panel is showing) and the *live connections* (one
 * {@link XTerm} + shell pty per pane) are owned here, at module scope, and merely
 * re-attached to the DOM when a pane's React component mounts.
 *
 * Because each {@link PaneConnection} keeps its socket subscription and xterm
 * buffer alive while hidden, output for a backgrounded session's shells keeps
 * accumulating in the xterm itself — switching back just re-opens the existing
 * terminal into a fresh container, with no loss. The server-side shell scrollback
 * (replayed via `reattachTerminal`) is the fallback for the case where the
 * connection was genuinely lost (a WebSocket reconnect) and the pane has to
 * re-open a pty from scratch.
 */

/** One terminal tab: a horizontal row of one or more split shell panes. */
export interface Group {
  id: string;
  paneIds: string[];
}

/** The persisted, React-observable layout for one session's terminal panel. */
interface SessionTerminals {
  /** Whether the bottom panel is currently shown for this session. */
  open: boolean;
  groups: Group[];
  activeId: string;
}

const uid = () => crypto.randomUUID();
const newGroup = (): Group => ({ id: uid(), paneIds: [uid()] });

const sessions = new Map<string, SessionTerminals>();
const listeners = new Set<() => void>();

function emit(): void {
  for (const l of listeners) l();
}

function subscribe(cb: () => void): () => void {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

function ensure(sessionId: string): SessionTerminals {
  let s = sessions.get(sessionId);
  if (!s) {
    const g = newGroup();
    s = { open: false, groups: [g], activeId: g.id };
    sessions.set(sessionId, s);
  }
  return s;
}

/** Replace a session's layout (without emitting); callers emit once at the end. */
function set(sessionId: string, next: SessionTerminals): void {
  sessions.set(sessionId, next);
}

// ── React hooks ───────────────────────────────────────────────────────────────

/** Whether the integrated terminal panel is open for `sessionId`. */
export function useTerminalOpen(sessionId: string): boolean {
  return useSyncExternalStore(
    subscribe,
    () => sessions.get(sessionId)?.open ?? false,
  );
}

/** The tab/pane layout for `sessionId` (creating the initial single tab lazily). */
export function useTerminalLayout(sessionId: string): SessionTerminals {
  return useSyncExternalStore(subscribe, () => {
    const existing = sessions.get(sessionId);
    if (existing) return existing;
    // Don't mutate during render; return a stable default and let the panel's
    // first interaction (or `setTerminalOpen`) materialise the real state.
    return DEFAULT_LAYOUT;
  });
}

const DEFAULT_LAYOUT: SessionTerminals = { open: false, groups: [], activeId: "" };

// ── Layout mutations ────────────────────────────────────────────────────────

export function setTerminalOpen(sessionId: string, open: boolean): void {
  const s = ensure(sessionId);
  set(sessionId, { ...s, open });
  emit();
}

export function toggleTerminalOpen(sessionId: string): void {
  const s = ensure(sessionId);
  set(sessionId, { ...s, open: !s.open });
  emit();
}

export function setActiveTab(sessionId: string, groupId: string): void {
  const s = ensure(sessionId);
  if (s.activeId === groupId) return;
  set(sessionId, { ...s, activeId: groupId });
  emit();
}

export function addTab(sessionId: string): void {
  const s = ensure(sessionId);
  const g = newGroup();
  set(sessionId, { ...s, groups: [...s.groups, g], activeId: g.id });
  emit();
}

export function splitActive(sessionId: string): void {
  const s = ensure(sessionId);
  set(sessionId, {
    ...s,
    groups: s.groups.map((g) =>
      g.id === s.activeId ? { ...g, paneIds: [...g.paneIds, uid()] } : g,
    ),
  });
  emit();
}

/**
 * Remove one pane (disposing its live connection). Drops the tab if it empties,
 * and closes the panel if nothing remains. Returns whether the panel should
 * close (the last pane went away).
 */
export function closePane(sessionId: string, groupId: string, paneId: string): boolean {
  const s = ensure(sessionId);
  disposePane(paneId);
  const groups = s.groups
    .map((g) => (g.id === groupId ? { ...g, paneIds: g.paneIds.filter((p) => p !== paneId) } : g))
    .filter((g) => g.paneIds.length > 0);
  if (groups.length === 0) {
    // Reset to a fresh single tab so re-opening the panel starts clean.
    const g = newGroup();
    set(sessionId, { open: false, groups: [g], activeId: g.id });
    emit();
    return true;
  }
  const activeId = groups.some((g) => g.id === s.activeId)
    ? s.activeId
    : groups[groups.length - 1]!.id;
  set(sessionId, { ...s, groups, activeId });
  emit();
  return false;
}

export function closeTab(sessionId: string, groupId: string): boolean {
  const s = sessions.get(sessionId);
  const g = s?.groups.find((x) => x.id === groupId);
  if (!g) return false;
  let closed = false;
  // Copy the ids — closePane mutates the live group list as it goes.
  for (const p of [...g.paneIds]) closed = closePane(sessionId, groupId, p) || closed;
  return closed;
}

// ── Live per-pane connections (xterm + shell pty), kept alive across remounts ──

interface PaneConnection {
  term: XTerm;
  fit: FitAddon;
  /** The server pty id once learned; null while the open handshake is pending. */
  terminalId: string | null;
  /** Our own tag to match the `terminalReady` / `terminalReattached` reply. */
  requestId: string;
  unsubscribe: () => void;
  onDataDisposable: { dispose: () => void };
  /** Fired when the shell pty exits (e.g. the user typed `exit`). */
  onExit: (() => void) | null;
  /** The container this term is currently opened into, if mounted. */
  container: HTMLElement | null;
}

const panes = new Map<string, PaneConnection>();

/**
 * Get (creating on first use) the persistent connection for a pane. `cwd` is only
 * used when first spawning the shell. The connection keeps its socket
 * subscription and xterm buffer alive even while no React component is mounted,
 * so a backgrounded session's shells accumulate output rather than dying.
 */
function getOrCreatePane(paneId: string, cwd: string): PaneConnection {
  const existing = panes.get(paneId);
  if (existing) return existing;

  const term = new XTerm({
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace',
    fontSize: 13,
    cursorBlink: true,
    scrollback: 10000,
    theme: { background: "#0b0d10" },
    allowProposedApi: true,
  });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.loadAddon(new WebLinksAddon());

  const conn: PaneConnection = {
    term,
    fit,
    terminalId: null,
    requestId: uid(),
    unsubscribe: () => {},
    onDataDisposable: { dispose: () => {} },
    onExit: null,
    container: null,
  };

  const dims = () => ({ cols: term.cols || 80, rows: term.rows || 24 });

  conn.onDataDisposable = term.onData((data) => {
    if (conn.terminalId) socket.send({ type: "input", sessionId: conn.terminalId, data });
  });

  conn.unsubscribe = socket.subscribe((msg: ServerMessage) => {
    if (msg.type === "terminalReady" || msg.type === "terminalReattached") {
      if (msg.requestId !== conn.requestId) return;
      conn.terminalId = msg.terminalId;
      if (msg.type === "terminalReattached" && msg.scrollback) {
        // Re-opened a pty from scratch after a lost connection: replay history.
        conn.term.reset();
        conn.term.write(msg.scrollback);
      }
      socket.send({ type: "resize", sessionId: conn.terminalId, ...dims() });
      return;
    }
    if (!("sessionId" in msg) || msg.sessionId !== conn.terminalId) return;
    switch (msg.type) {
      case "output":
        conn.term.write(msg.data);
        break;
      case "exit":
        conn.onExit?.();
        break;
      case "error":
        conn.term.write(`\r\n\x1b[31m${msg.message}\x1b[0m\r\n`);
        break;
    }
  });

  // Subscribe before opening so we don't miss the terminalReady reply.
  socket.send({ type: "openTerminal", cwd, ...dims(), requestId: conn.requestId });

  panes.set(paneId, conn);
  return conn;
}

/**
 * Mount a pane's persistent xterm into `container`. Called every time the React
 * component for the pane mounts; the underlying terminal + pty are reused (and
 * created on first call). Returns a detach callback that leaves the connection
 * alive — only {@link disposePane} actually kills the shell.
 */
export function attachPane(
  paneId: string,
  cwd: string,
  container: HTMLElement,
  onExit: () => void,
): () => void {
  const conn = getOrCreatePane(paneId, cwd);
  conn.onExit = onExit;
  // Re-open into the new container. xterm's `open` moves its DOM into the given
  // element; calling it again on remount re-parents the existing buffer.
  conn.term.open(container);
  conn.container = container;
  try {
    conn.fit.fit();
    if (conn.terminalId) {
      socket.send({
        type: "resize",
        sessionId: conn.terminalId,
        cols: conn.term.cols,
        rows: conn.term.rows,
      });
    }
  } catch {
    /* container not laid out yet */
  }
  conn.term.focus();

  return () => {
    // Detach only: keep the terminal + pty alive so the session can be revisited.
    if (conn.container === container) conn.container = null;
    conn.onExit = null;
  };
}

/** Re-fit a mounted pane to its container and tell the pty about the new size. */
export function fitPane(paneId: string): void {
  const conn = panes.get(paneId);
  if (!conn || !conn.container) return;
  try {
    conn.fit.fit();
    if (conn.terminalId) {
      socket.send({
        type: "resize",
        sessionId: conn.terminalId,
        cols: conn.term.cols,
        rows: conn.term.rows,
      });
    }
  } catch {
    /* hidden / detached */
  }
}

/** Permanently tear down a pane's terminal + shell pty. */
function disposePane(paneId: string): void {
  const conn = panes.get(paneId);
  if (!conn) return;
  conn.onDataDisposable.dispose();
  conn.unsubscribe();
  if (conn.terminalId) socket.send({ type: "kill", sessionId: conn.terminalId });
  conn.term.dispose();
  panes.delete(paneId);
}
