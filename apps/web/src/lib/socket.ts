import type { ClientMessage, ServerMessage } from "../protocol.ts";
import { getToken, promptForToken } from "./auth.ts";

type Listener = (msg: ServerMessage) => void;

/** A single shared WebSocket to the juancode server, with auto-reconnect. */
class JuancodeSocket {
  private ws: WebSocket | null = null;
  private readonly listeners = new Set<Listener>();
  private readonly queue: string[] = [];
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  // Tracks connections that never opened, to distinguish an auth rejection
  // (immediate close before open) from an ordinary dropped connection.
  private opened = false;
  private failedCloses = 0;

  private url(): string {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    // Browsers can't set headers on a WebSocket, so the token rides as a query
    // param. The cookie also carries it once set; either suffices server-side.
    // When auth is disabled there is no token and the URL is unchanged.
    const token = getToken();
    const q = token ? `?token=${encodeURIComponent(token)}` : "";
    return `${proto}://${location.host}/ws${q}`;
  }

  private connect(): void {
    if (this.ws && (this.ws.readyState === WebSocket.OPEN || this.ws.readyState === WebSocket.CONNECTING))
      return;

    const ws = new WebSocket(this.url());
    this.ws = ws;
    this.opened = false;

    ws.onopen = () => {
      this.opened = true;
      this.failedCloses = 0;
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
      // A close before the socket ever opened most likely means the upgrade was
      // rejected (401 — wrong/missing token). After a couple of such failures,
      // prompt for a token rather than reconnecting forever.
      if (!this.opened) {
        this.failedCloses += 1;
        if (this.failedCloses >= 2) {
          promptForToken();
          return;
        }
      }
      if (!this.reconnectTimer) {
        this.reconnectTimer = setTimeout(() => {
          this.reconnectTimer = null;
          if (this.listeners.size > 0) this.connect();
        }, 1000);
      }
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
