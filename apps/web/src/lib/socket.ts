import type { ClientMessage, ServerMessage } from "../protocol.ts";
import { getToken, promptForToken } from "./auth.ts";

type Listener = (msg: ServerMessage) => void;

/**
 * Connection state for the shared socket.
 * - `online`     — the socket is open and messages flow.
 * - `connecting` — a connect/reconnect attempt is in flight or scheduled.
 * - `offline`    — idle (no listeners) or the browser reports no network.
 *
 * The UI treats anything other than `online` (while sessions are mounted) as a
 * transient "reconnecting" state rather than a hard error.
 */
export type ConnectionState = "online" | "connecting" | "offline";

type StatusListener = (state: ConnectionState) => void;

// Reconnect backoff: start gentle, grow exponentially, cap so a long outage
// still retries roughly every few seconds rather than backing off forever.
const BACKOFF_BASE_MS = 500;
const BACKOFF_MAX_MS = 10_000;

/** A single shared WebSocket to the juancode server, with auto-reconnect. */
class JuancodeSocket {
  private ws: WebSocket | null = null;
  private readonly listeners = new Set<Listener>();
  private readonly statusListeners = new Set<StatusListener>();
  private readonly queue: string[] = [];
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  private state: ConnectionState = "offline";
  // Consecutive failed reconnect attempts; drives the backoff delay.
  private attempts = 0;

  // Tracks connections that never opened, to distinguish an auth rejection
  // (immediate close before open) from an ordinary dropped connection.
  private opened = false;
  // Once a connection has ever succeeded we never treat a later drop as an auth
  // failure — it's just the network (phone locked, tab backgrounded, wifi
  // blip), so we reconnect silently instead of prompting for a token.
  private everOpened = false;
  private failedCloses = 0;

  constructor() {
    if (typeof window !== "undefined") this.installLifecycleHandlers();
  }

  /**
   * Reconnect promptly when the environment suggests the link is back: the tab
   * becomes visible again, the browser fires `online`, or the page is restored
   * from the bfcache (`pageshow`). Mobile Safari/Chrome suspend timers and tear
   * down sockets while backgrounded, so the scheduled backoff timer alone is not
   * enough — these events are what actually fire on resume.
   */
  private installLifecycleHandlers(): void {
    const kick = () => {
      if (this.listeners.size === 0) return;
      if (this.ws?.readyState === WebSocket.OPEN) return;
      // A fresh user-visible resume: drop any pending backoff and retry now.
      this.attempts = 0;
      if (this.reconnectTimer) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = null;
      }
      this.connect();
    };
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") kick();
    });
    window.addEventListener("online", kick);
    window.addEventListener("offline", () => {
      // No point hammering connect while the OS says we're offline; reflect it
      // in the UI and let the `online` event resume us.
      if (this.listeners.size > 0) this.setState("offline");
    });
    window.addEventListener("pageshow", kick);
  }

  private setState(state: ConnectionState): void {
    if (this.state === state) return;
    this.state = state;
    for (const l of this.statusListeners) l(state);
  }

  get connectionState(): ConnectionState {
    return this.state;
  }

  /** Subscribe to connection-state changes; fires immediately with the current state. */
  subscribeStatus(listener: StatusListener): () => void {
    this.statusListeners.add(listener);
    listener(this.state);
    return () => this.statusListeners.delete(listener);
  }

  private url(): string {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    // Browsers can't set headers on a WebSocket, so the token rides as a query
    // param. The cookie also carries it once set; either suffices server-side.
    // When auth is disabled there is no token and the URL is unchanged.
    const token = getToken();
    const q = token ? `?token=${encodeURIComponent(token)}` : "";
    return `${proto}://${location.host}/ws${q}`;
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer) return;
    if (this.listeners.size === 0) {
      this.setState("offline");
      return;
    }
    const delay = Math.min(BACKOFF_BASE_MS * 2 ** this.attempts, BACKOFF_MAX_MS);
    this.attempts += 1;
    this.setState("connecting");
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      if (this.listeners.size > 0) this.connect();
    }, delay);
  }

  private connect(): void {
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING))
      return;

    this.setState("connecting");
    const ws = new WebSocket(this.url());
    this.ws = ws;
    this.opened = false;

    ws.onopen = () => {
      this.opened = true;
      this.everOpened = true;
      this.failedCloses = 0;
      this.attempts = 0;
      this.setState("online");
      while (this.queue.length) ws.send(this.queue.shift()!);
    };
    ws.onmessage = (ev) => {
      let msg: ServerMessage;
      try {
        msg = JSON.parse(ev.data as string) as ServerMessage;
      } catch {
        return;
      }
      for (const l of this.listeners) l(msg);
    };
    ws.onclose = () => {
      this.ws = null;
      // A close before the socket ever opened — and before any connection has
      // ever succeeded this session — most likely means the upgrade was rejected
      // (401 — wrong/missing token). After a couple of such failures, prompt for
      // a token. We only do this for a never-opened socket while the browser
      // reports it's online, so a backgrounded phone or a wifi blip on an
      // already-working session never trips the token prompt.
      if (!this.opened && !this.everOpened && navigator.onLine) {
        this.failedCloses += 1;
        if (this.failedCloses >= 2) {
          this.setState("offline");
          promptForToken();
          return;
        }
      }
      this.scheduleReconnect();
    };
    ws.onerror = () => ws.close();
  }

  send(msg: ClientMessage): void {
    const data = JSON.stringify(msg);
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(data);
    } else {
      this.queue.push(data);
      this.connect();
    }
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    this.connect();
    return () => this.listeners.delete(listener);
  }
}

export const socket = new JuancodeSocket();
