/**
 * Capped scrollback buffer (mirrored 1:1 by `apps/native/.../Scrollback.swift`).
 *
 * Trimming the oldest characters is lossy in one way that matters: a full-screen
 * TUI (claude/codex run on the terminal's *alternate screen*) emits its enter-alt
 * sequence once at startup. A long-running agent overflows the cap, so that
 * sequence gets trimmed away — and a late subscriber then replays the remaining
 * text into the *normal* buffer, where the program's absolute cursor moves and
 * redraws land at the wrong offsets → garbage. We therefore track the alt-buffer
 * state across appends and, on `replay`, re-establish it with a synthetic resync
 * prefix so the parser is in the same screen mode the program believes it is.
 */

/** Append `chunk` to `buffer`, keeping at most `limit` trailing characters. */
export function appendScrollback(buffer: string, chunk: string, limit: number): string {
  const next = buffer + chunk;
  return next.length > limit ? next.slice(next.length - limit) : next;
}

/** `ESC[?1049h` (enter alternate screen) + `ESC[2J` (clear) + `ESC[H` (home). */
export const ALT_RESYNC = "\x1b[?1049h\x1b[2J\x1b[H";

// DEC private-mode toggles for the alternate screen (xterm 1049/1047, legacy 47).
const ENTER_ALT = ["\x1b[?1049h", "\x1b[?1047h", "\x1b[?47h"];
const EXIT_ALT = ["\x1b[?1049l", "\x1b[?1047l", "\x1b[?47l"];

/**
 * Walk `data`, returning the alt-buffer state after the last enter/exit token,
 * starting from `initial`.
 */
export function scanAlternate(initial: boolean, data: string): boolean {
  let state = initial;
  for (let i = 0; i < data.length; i++) {
    if (data.charCodeAt(i) !== 0x1b) continue; // only escape sequences toggle it
    const enter = ENTER_ALT.find((t) => data.startsWith(t, i));
    if (enter) {
      state = true;
      i += enter.length - 1;
      continue;
    }
    const exit = EXIT_ALT.find((t) => data.startsWith(t, i));
    if (exit) {
      state = false;
      i += exit.length - 1;
    }
  }
  return state;
}

/** Mutable wrapper around the capped buffer (mirrors the Swift `Scrollback`). */
export class Scrollback {
  private buffer: string;
  /**
   * Whether the stream is currently in the terminal's alternate screen buffer.
   * Retained across appends so `replay` can re-establish it even after the
   * original enter-alt sequence has been trimmed past the cap.
   */
  inAlternateBuffer: boolean;

  constructor(
    private readonly limit: number,
    seed = "",
  ) {
    let kept = seed.length > limit ? seed.slice(seed.length - limit) : seed;
    // A seed produced by `replay` carries the synthetic resync prefix; drop it so
    // it isn't compounded the next time we replay.
    if (kept.startsWith(ALT_RESYNC)) kept = kept.slice(ALT_RESYNC.length);
    this.buffer = kept;
    // Scan the *full* seed, not just the kept tail, so the alt-buffer state is
    // recovered even when its enter sequence sits before the trim point.
    this.inAlternateBuffer = scanAlternate(false, seed);
  }

  append(chunk: string): void {
    // Carry the tail so an enter/exit sequence split across the chunk boundary is
    // still detected (the longest token is 8 chars).
    const carry = this.buffer.slice(-7);
    this.inAlternateBuffer = scanAlternate(this.inAlternateBuffer, carry + chunk);
    this.buffer = appendScrollback(this.buffer, chunk, this.limit);
  }

  /** Raw trailing characters (for persistence/search). */
  get bytes(): string {
    return this.buffer;
  }

  /**
   * Text to feed a freshly-attached terminal. In the alternate buffer we prepend a
   * resync (enter-alt + clear + home) so the parser starts in the right screen
   * mode; otherwise the raw trailing text (normal-buffer scrollback) as before.
   */
  get replay(): string {
    return this.inAlternateBuffer ? ALT_RESYNC + this.buffer : this.buffer;
  }
}
