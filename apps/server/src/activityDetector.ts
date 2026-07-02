import type { SessionActivity, SessionPrompt, StructuredEvent } from "./protocol.ts";
import { TerminalScreen } from "./terminalScreen.ts";
import { parsePrompt } from "./promptParse.ts";

/**
 * Infers whether an agent session is working, has finished a turn, or is waiting
 * for the user. There are two signals, and the detector fuses them:
 *
 * 1. **Structured stream** (preferred). The CLIs write an append-only
 *    stream-json transcript as they run; new records appear *only* while the
 *    agent is actively producing a turn (an `assistant` / `thinking` / `tool_use`
 *    / `tool_result` block). {@link Session} tails that transcript and calls
 *    {@link feedStructured} with each batch of normalized events. A batch that
 *    carries any agent-produced event is an unambiguous "the agent is working"
 *    pulse that does not depend on rendered TUI wording at all — robust to CLI
 *    footer/spinner copy changes. This is the headline of juancode-doq.
 *
 * 2. **Rendered PTY screen** (fallback). The raw pty byte stream is fed into a
 *    headless {@link TerminalScreen}, so the detector can read the *actual
 *    rendered screen*. Both `claude` and `codex` paint an "esc to interrupt"
 *    footer while a turn runs and an option-menu / yes-no prompt when they pause
 *    for the user. This path still drives **busy** when no transcript is
 *    available (e.g. before the CLI session id is known, or a provider/mode that
 *    writes no transcript), and — crucially — it is what distinguishes
 *    **waiting_input** from **idle** at turn end, since a permission prompt is
 *    *not* written to the transcript until the user answers it.
 *
 * In both cases the lifecycle is the same: a busy pulse (re)arms a short settle
 * timer and a long watchdog. On settle we re-read the rendered screen — an
 * option menu / yes-no prompt visible => **waiting_input**, otherwise **idle**
 * (unless the working footer is still up *and* we have no structured turn-end
 * yet, in which case we stay busy). The watchdog demotes a stuck busy if both
 * streams go silent.
 *
 * Because busy is only ever entered via a working footer or a structured agent
 * event, the startup banner and the user's own keystroke echoes — which carry
 * neither — are never mistaken for agent activity. Best-effort: with no
 * transcript, a CLI footer-wording change can still defeat the screen patterns,
 * which is exactly why the structured path exists.
 *
 * A prompt can also appear *without* any preceding turn — a startup folder-trust
 * dialog, an auth prompt, or a resumed session re-rendering its pending permission
 * menu. Those would otherwise read as idle (green dot, no notification) while the
 * session is really blocked on the user, so the screen path also promotes
 * **idle → waiting_input** when a prompt marker settles into the bottom region
 * (juancode-8w5), and demotes it back to idle once the prompt is answered away.
 */

/** Quiet period after a busy pulse before we re-classify the screen. */
const SETTLE_MS = 250;
/** Longer silence after which a still-"busy" session is treated as stale. */
const WATCHDOG_MS = 8000;

/**
 * Rows of the bottom screen region treated as the footer / input / dialog area.
 * The prose-like prompt markers ({@link PROMPT_PATTERNS} `bottomOnly`) are only
 * matched here so the same words scrolled up in conversation history don't
 * masquerade as a live prompt (juancode-8w5).
 */
const PROMPT_REGION_ROWS = 20;

/** The "esc to interrupt" working line, tolerant of wording ("Esc again to…"). */
const WORKING_RE = /\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b/i;

/** Runs of intra-line whitespace (not newlines), collapsed before matching. */
const WS_RE = /[^\S\n]{2,}/g;

/**
 * A prompt marker with the region it is trusted in. The `❯ 1.` selection cursor
 * is Claude/Codex's own menu UI — it never appears in prose, so it is matched
 * across the whole screen (a centered trust/permission dialog paints its cursor
 * above any fixed bottom band). The prose-like markers ("Do you want to",
 * "Proceed?", trust wording, y/n footers, "Press Enter to continue") could plausibly
 * appear as ordinary text scrolled up in history, so they are trusted only in the
 * bottom region. `label` is surfaced via {@link ActivityDetector.lastPromptMatch}
 * for debugging which shape tripped the classification.
 */
interface PromptPattern {
  readonly label: string;
  readonly re: RegExp;
  readonly bottomOnly: boolean;
}

const PROMPT_PATTERNS: readonly PromptPattern[] = [
  { label: "select-cursor", re: /❯\s*\d+\.\s/, bottomOnly: false }, // permission / option menus
  { label: "do-you-want", re: /\bDo you want to\b/i, bottomOnly: true },
  { label: "do-you-trust", re: /\bDo you trust\b/i, bottomOnly: true }, // startup folder-trust dialog
  { label: "proceed", re: /\bProceed\?/i, bottomOnly: true },
  { label: "allow", re: /\bAllow\b[^\n]{0,40}\?/i, bottomOnly: true },
  { label: "yn-paren", re: /\(y\/n\)/i, bottomOnly: true },
  { label: "yn-bracket", re: /\[y\/n\]/i, bottomOnly: true },
  { label: "press-enter", re: /\bPress Enter to continue\b/i, bottomOnly: true },
  { label: "esc-cancel", re: /\(esc to cancel\)/i, bottomOnly: true }, // interactive selection footer
];

/**
 * Cheap lowercase substrings that gate the idle→waiting re-read: only a frame
 * whose bytes could carry (part of) a prompt marker is worth re-scanning the
 * screen for. A false positive here just costs one wasted regex pass on settle;
 * it never on its own changes state.
 */
const PROMPT_GATE: readonly string[] = ["?", "❯", "y/n", "trust", "continue", "esc to cancel"];

/**
 * Structured-event kinds that mean the agent is actively producing a turn. A
 * `user` record is the user's own prompt landing — also a turn boundary, but it
 * doesn't by itself mean the agent is working, so it is excluded here (the
 * agent's first `assistant`/`thinking`/`tool_use` record that follows is the
 * busy pulse).
 */
const AGENT_EVENT_KINDS: ReadonlySet<StructuredEvent["kind"]> = new Set([
  "assistant",
  "thinking",
  "tool_use",
  "tool_result",
]);

/** True when a batch of normalized events contains an agent-produced record. */
export function batchHasAgentActivity(events: readonly StructuredEvent[]): boolean {
  return events.some((e) => AGENT_EVENT_KINDS.has(e.kind));
}

type ChangeListener = (state: SessionActivity, notify: boolean) => void;

export class ActivityDetector {
  private state: SessionActivity = "idle";
  private readonly screen: TerminalScreen;
  private settleTimer: NodeJS.Timeout | null = null;
  private watchdogTimer: NodeJS.Timeout | null = null;
  /** Settle timer for the idle→waiting_input prompt re-read (juancode-8w5). */
  private promptTimer: NodeJS.Timeout | null = null;
  /** Label of the last {@link PROMPT_PATTERNS} entry that matched, for debugging. */
  private lastMatchedPrompt: string | null = null;
  /**
   * Whether the *current* busy turn was started by a structured agent event.
   * When true we don't keep the turn busy just because the footer regex still
   * matches — the transcript is authoritative, so settle classifies on the
   * screen's prompt/quiet state instead of waiting for the footer to be erased.
   * Reset whenever we leave busy.
   */
  private structuredTurn = false;

  constructor(
    cols: number,
    rows: number,
    private readonly onChange: ChangeListener,
  ) {
    this.screen = new TerminalScreen(cols, rows);
  }

  /** Feed a chunk of raw pty output (the screen / fallback signal). */
  feed(data: string): void {
    // The screen must see every byte to stay an accurate mirror.
    this.screen.feed(data);
    if (this.state === "busy") {
      // Already working: any output (re)starts the settle/watchdog clocks.
      this.armTimers();
      return;
    }
    const lower = data.toLowerCase();
    if (lower.includes("interrupt") && WORKING_RE.test(this.normalizedScreen())) {
      // Cheap gate: only a frame that could carry the working footer is worth
      // re-reading the screen for. If the footer is now visible we go busy.
      this.structuredTurn = false;
      this.transition("busy", false);
      this.armTimers();
      return;
    }
    // Idle/waiting: a prompt can appear with no preceding working turn — a startup
    // folder-trust dialog, an auth prompt, a resumed session's pending permission
    // menu (juancode-8w5). Gate on cheap markers, then re-read on settle. While
    // already waiting we re-check on *any* output, since the answer that clears the
    // menu carries no marker of its own.
    if (this.state === "waiting_input" || PROMPT_GATE.some((s) => lower.includes(s))) {
      this.armPromptTimer();
    }
  }

  /**
   * Feed a batch of normalized structured events from the session's transcript
   * tail (the preferred signal). A batch carrying an agent-produced record is a
   * wording-independent "the agent is working" pulse: it enters/keeps busy and
   * (re)arms the settle/watchdog clocks exactly like footer output does.
   */
  feedStructured(events: readonly StructuredEvent[]): void {
    if (!batchHasAgentActivity(events)) return;
    // A structured pulse is authoritative for this turn, whether it starts the
    // turn or upgrades one the screen path already opened (so settle no longer
    // waits on the footer being erased).
    this.structuredTurn = true;
    if (this.state !== "busy") this.transition("busy", false);
    this.armTimers();
  }

  get activity(): SessionActivity {
    return this.state;
  }

  /** Which {@link PROMPT_PATTERNS} label last classified a screen as a prompt, for debugging. */
  get lastPromptMatch(): string | null {
    return this.lastMatchedPrompt;
  }

  /**
   * The pending question + options parsed from the current screen when the
   * session is waiting on the user, else null. Best-effort (see `promptParse.ts`)
   * and only meaningful while `waiting_input`.
   */
  extractPrompt(): SessionPrompt | null {
    if (this.state !== "waiting_input") return null;
    return parsePrompt(this.screen.visibleText);
  }

  /**
   * A snapshot of the whole rendered screen — used by {@link Session.autoSubmit}
   * to detect when the TUI has settled (stable frames) before pasting.
   */
  screenSnapshot(): string {
    return this.screen.visibleText;
  }

  /**
   * Every rendered row of the screen (stable count, trailing spaces trimmed) —
   * the source for the live phone screen stream (see `Session.onScreen`).
   */
  screenRows(): string[] {
    return this.screen.rows();
  }

  /**
   * The bottom `rows` of the rendered screen — the footer / input-box region — so
   * {@link Session.autoSubmit} can confirm a seeded prompt landed in (or left) the
   * input box without matching the same text echoed up in the conversation.
   */
  inputRegionSnapshot(rows: number): string {
    return this.screen.bottomText(rows);
  }

  /** Keep the screen model in step with the pty size. Called from Session.resize. */
  resize(cols: number, rows: number): void {
    this.screen.resize(cols, rows);
  }

  /** The session ended — cancel any pending timers and return to idle. */
  reset(): void {
    this.clearTimers();
    this.structuredTurn = false;
    this.transition("idle", false);
  }

  /** (Re)arm both the short settle timer and the long stuck-busy watchdog. */
  private armTimers(): void {
    this.clearTimers();
    this.settleTimer = setTimeout(() => {
      this.settleTimer = null;
      this.settle(false);
    }, SETTLE_MS);
    this.watchdogTimer = setTimeout(() => {
      this.watchdogTimer = null;
      this.settle(true);
    }, WATCHDOG_MS);
  }

  /**
   * (Re)arm the idle→waiting settle. Independent of the busy settle/watchdog: it
   * only ever runs while we're *not* busy, and re-reads the screen for a prompt
   * after the quiet window (juancode-8w5).
   */
  private armPromptTimer(): void {
    if (this.promptTimer) clearTimeout(this.promptTimer);
    this.promptTimer = setTimeout(() => {
      this.promptTimer = null;
      this.settlePrompt();
    }, SETTLE_MS);
  }

  /**
   * Re-classify a non-busy screen: a prompt in the trusted region enters
   * waiting_input (notify), and a prompt that has since cleared demotes a stale
   * waiting_input back to idle. Never touches a busy turn (that's {@link settle}).
   */
  private settlePrompt(): void {
    if (this.state !== "idle" && this.state !== "waiting_input") return;
    const match = this.matchPrompt();
    if (match) {
      if (this.state !== "waiting_input") this.transition("waiting_input", true);
    } else if (this.state === "waiting_input") {
      // The prompt was answered / repainted away — back to idle (no ding).
      this.transition("idle", false);
    }
  }

  /**
   * Re-read the screen and classify. Only meaningful while busy: it ends a turn.
   * `demoteStaleFooter` (the watchdog path) ignores a lingering footer and settles
   * anyway, so we never hang on busy after both streams have gone silent.
   *
   * The footer regex only *holds* a turn busy when the turn was driven by the
   * screen path (no structured signal). A structured turn settles on the screen's
   * prompt/quiet state directly: the transcript already told us the agent stopped
   * emitting, so a footer the CLI hasn't repainted yet must not pin us busy.
   */
  private settle(demoteStaleFooter: boolean): void {
    if (this.state !== "busy") return;
    if (!demoteStaleFooter && !this.structuredTurn && WORKING_RE.test(this.normalizedScreen())) {
      return; // still working (screen path) — leave it busy
    }
    const next: SessionActivity = this.matchPrompt() ? "waiting_input" : "idle";
    // We're leaving busy on a real turn boundary, so notify.
    this.transition(next, true);
  }

  /**
   * The label of the first {@link PROMPT_PATTERNS} entry visible on the settled
   * screen, or null. Full-screen markers (the selection cursor) are matched
   * everywhere; prose-like markers only in the bottom region. Records the hit in
   * {@link lastMatchedPrompt} for debugging.
   */
  private matchPrompt(): string | null {
    const full = this.normalizedScreen();
    const bottom = this.normalizedBottom();
    for (const p of PROMPT_PATTERNS) {
      if (p.re.test(p.bottomOnly ? bottom : full)) {
        this.lastMatchedPrompt = p.label;
        return p.label;
      }
    }
    this.lastMatchedPrompt = null;
    return null;
  }

  private transition(state: SessionActivity, notify: boolean): void {
    if (state === this.state) return;
    this.state = state;
    if (state !== "busy") this.structuredTurn = false;
    this.onChange(state, notify);
  }

  /**
   * The visible screen with runs of intra-line whitespace collapsed to a single
   * space. The grid renders cursor-positioned footer segments as the *actual*
   * column gap (many spaces); collapsing restores a compact line so the
   * distance-bounded WORKING_RE (`[^\n]{0,40}`) matches as intended.
   */
  private normalizedScreen(): string {
    return this.screen.visibleText.replace(WS_RE, " ");
  }

  /** The bottom {@link PROMPT_REGION_ROWS} rows, whitespace-collapsed like {@link normalizedScreen}. */
  private normalizedBottom(): string {
    return this.screen.bottomText(PROMPT_REGION_ROWS).replace(WS_RE, " ");
  }

  private clearTimers(): void {
    if (this.settleTimer) {
      clearTimeout(this.settleTimer);
      this.settleTimer = null;
    }
    if (this.watchdogTimer) {
      clearTimeout(this.watchdogTimer);
      this.watchdogTimer = null;
    }
    if (this.promptTimer) {
      clearTimeout(this.promptTimer);
      this.promptTimer = null;
    }
  }
}
