import type { ClientMessage } from "../protocol.ts";

type ResizeMessage = Extract<ClientMessage, { type: "resize" }>;

/**
 * Tracks the latest desired terminal grid per session so a reconnect can re-assert
 * it (juancode-uz6). The *server* now owns recovering a dropped resize — it
 * re-applies the desired grid across the boot window (juancode-1th.3) — so this no
 * longer runs any client-side retry; it exists purely for reconnect replay.
 *
 * Unlike keystrokes (every one matters, buffered in order — see
 * {@link InputAckBuffer}), only the *newest* grid per session matters: an older
 * pending size is obsolete the moment a newer one is measured. So this keeps one
 * desired entry per session, each tagged with a monotonic `seq`.
 *
 * On reconnect the socket re-asserts every tracked grid via {@link pending} so a
 * reattached / respawned pty (which may boot at a default 80×24) is corrected.
 *
 * Pure and framework-free so it can be unit-tested without a real WebSocket.
 */
export class ResizeAckTracker {
  private seq = 0;
  private readonly desired = new Map<string, { cols: number; rows: number; seq: number }>();

  /** Record a session's newest desired grid and return the frame to transmit. */
  track(msg: ResizeMessage): { seq: number; data: string } {
    const seq = ++this.seq;
    this.desired.set(msg.sessionId, { cols: msg.cols, rows: msg.rows, seq });
    return { seq, data: this.frame(msg.sessionId, msg.cols, msg.rows, seq) };
  }

  /**
   * Frames re-asserting every tracked session's latest desired grid, for replay
   * on reconnect. Stamps a fresh `seq` so the ack for the replay matches. Sent
   * immediately (no delay) by the socket.
   */
  pending(): string[] {
    const out: string[] = [];
    for (const [sessionId, d] of this.desired) {
      d.seq = ++this.seq;
      out.push(this.frame(sessionId, d.cols, d.rows, d.seq));
    }
    return out;
  }

  /** Forget a session's desired grid (e.g. it exited). */
  forget(sessionId: string): void {
    this.desired.delete(sessionId);
  }

  /** Drop all tracking (e.g. the server doesn't support `resizeAck`). */
  clear(): void {
    this.desired.clear();
  }

  private frame(sessionId: string, cols: number, rows: number, seq: number): string {
    return JSON.stringify({ type: "resize", sessionId, cols, rows, seq });
  }
}
