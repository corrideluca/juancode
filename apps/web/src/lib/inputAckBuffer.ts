import type { ClientMessage } from "../protocol.ts";

type InputMessage = Extract<ClientMessage, { type: "input" }>;

/**
 * Buffer of `input` messages the server hasn't acknowledged yet (juancode-1u3).
 *
 * Client `input` is best-effort over the wire: a connection drop mid-write used
 * to silently swallow keystrokes. To fix that, each input is tagged with a
 * monotonic per-socket `seq`; the server replies with an `inputAck` once it has
 * written the data (gated on the `inputAck` server capability). This buffer
 * holds every sent-but-unacked input so the socket can:
 *   - resend the whole buffer on reconnect (covers keystrokes in flight when a
 *     socket dropped, which the plain offline queue never sees — those frames
 *     were already handed to an open socket), and
 *   - expose an in-flight count for a subtle "unsent keystrokes" indicator.
 *
 * Delivery is at-least-once: if a socket drops after the server wrote the input
 * but before its ack reached the client, the resend writes it a second time.
 * That's the accepted trade-off — the ticket's failure mode is *silent loss*,
 * and a rare duplicated keystroke is the lesser evil (and far rarer than loss).
 *
 * Pure and framework-free so it can be unit-tested without a real WebSocket;
 * the socket owns the transport and the listener fan-out.
 */
export class InputAckBuffer {
  private seq = 0;
  // seq -> the exact JSON string to (re)send. Insertion order === seq order,
  // so iteration replays in the order the user typed.
  private readonly unacked = new Map<number, string>();

  /**
   * Assign the next `seq` to an input message, remember its serialized frame,
   * and return both the seq and the wire string to transmit.
   */
  track(msg: InputMessage): { seq: number; data: string } {
    const seq = ++this.seq;
    const data = JSON.stringify({ ...msg, seq });
    this.unacked.set(seq, data);
    return { seq, data };
  }

  /** Clear an acknowledged input. Returns true if the seq was still pending. */
  ack(seq: number): boolean {
    return this.unacked.delete(seq);
  }

  /** The still-unacked frames, in the order they were sent (seq order). */
  pending(): string[] {
    return [...this.unacked.values()];
  }

  /** How many inputs are sent-but-unacked right now. */
  get size(): number {
    return this.unacked.size;
  }

  /** Drop all buffered inputs (e.g. the server doesn't support `inputAck`). */
  clear(): void {
    this.unacked.clear();
  }
}
