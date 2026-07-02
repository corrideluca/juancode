import Foundation

/// Structured-event kinds the CLI writes to its append-only stream-json transcript.
/// A `user` record is the user's own prompt landing (a turn boundary, but not the
/// agent working), so it is excluded from {@link batchHasAgentActivity}; the
/// agent's first `assistant` / `thinking` / `toolUse` / `toolResult` record that
/// follows is the busy pulse. Mirrors the kinds in `apps/server/src/protocol.ts`.
public enum StructuredEventKind: String, Sendable {
    case user
    case assistant
    case thinking
    case toolUse = "tool_use"
    case toolResult = "tool_result"
}

private let agentEventKinds: Set<StructuredEventKind> = [
    .assistant, .thinking, .toolUse, .toolResult,
]

/// True when a batch of normalized transcript kinds carries an agent-produced record.
public func batchHasAgentActivity(_ kinds: [StructuredEventKind]) -> Bool {
    kinds.contains { agentEventKinds.contains($0) }
}

/// Infers whether an agent session is working, finished a turn, or is waiting for
/// the user, fusing two signals (mirrors `apps/server/src/activityDetector.ts`):
///
/// 1. **Structured stream** (preferred). The CLIs write an append-only stream-json
///    transcript as they run; new records appear *only* while the agent is actively
///    producing a turn. `Session` tails that transcript and calls `feedStructured`
///    with each batch of normalized kinds. A batch carrying an agent-produced kind
///    is a wording-independent "the agent is working" pulse — robust to CLI footer
///    copy changes. `structuredTurn` then lets settle classify on the screen's
///    prompt/quiet state instead of waiting for the footer to be erased.
///
/// 2. **Rendered PTY screen** (fallback). The raw byte stream feeds a headless
///    `TerminalScreen`, so the detector reads the *actual rendered screen*. Both
///    `claude` and `codex` paint an "esc to interrupt" footer while a turn runs and
///    an option-menu / yes-no prompt when they pause. This drives **busy** when no
///    transcript is available yet, and distinguishes **waitingInput** from **idle**
///    at turn end (a permission prompt isn't written to the transcript until answered).
///
/// Busy is only ever *entered* via the footer phrase or a structured agent event, so
/// the startup banner and keystroke echoes never trigger it. A prompt can also appear
/// *without* a preceding turn — a startup folder-trust dialog, an auth prompt, or a
/// resumed session re-rendering its pending permission menu — so the screen path also
/// promotes **idle → waitingInput** when a prompt marker settles into the bottom
/// region (juancode-8w5), and demotes back to idle once it is answered away.
///
/// Thread-safety: all work happens on a private serial queue. `feed` /
/// `feedStructured` dispatch onto it; the timers fire on it; `onChange` is invoked on
/// it. Callers hop to the main thread themselves if needed.
public final class ActivityDetector: @unchecked Sendable {
    public typealias ChangeListener = @Sendable (_ state: SessionActivity, _ notify: Bool) -> Void

    /// Quiet period after output stops before we re-classify the screen.
    private let settleMs: Int
    /// Longer silence after which a still-"busy" footer is treated as stale (the
    /// spinner repaints while truly working, so this much silence means done).
    private let watchdogMs: Int

    private let queue: DispatchQueue
    private let onChange: ChangeListener
    private let screen: TerminalScreen
    private var state: SessionActivity = .idle
    private var generation = 0
    /// Whether the *current* busy turn was started by a structured agent event.
    /// When true, settle classifies on the screen's prompt/quiet state instead of
    /// keeping the turn busy on a footer the CLI hasn't repainted yet. Reset on leave.
    private var structuredTurn = false
    /// Label of the last `PromptPattern` that matched, for debugging which shape
    /// tripped a `waitingInput` classification.
    private var lastMatchedPrompt: String?

    public init(
        cols: Int = 120,
        rows: Int = 40,
        settleMs: Int = 250,
        watchdogMs: Int = 8000,
        queue: DispatchQueue = DispatchQueue(label: "juancode.activity"),
        onChange: @escaping ChangeListener
    ) {
        self.settleMs = settleMs
        self.watchdogMs = watchdogMs
        self.queue = queue
        self.onChange = onChange
        self.screen = TerminalScreen(cols: cols, rows: rows)
    }

    public var activity: SessionActivity {
        queue.sync { state }
    }

    /// Which `PromptPattern` label last classified a screen as a prompt, for debugging.
    public var lastPromptMatch: String? {
        queue.sync { lastMatchedPrompt }
    }

    /// A point-in-time snapshot of the whole rendered screen, taken on the detector's
    /// queue so it's consistent with the byte stream fed so far. Used by
    /// `Session.autoSubmit` to detect when the TUI has settled (stable frames).
    public func screenSnapshot() -> String {
        queue.sync { screen.visibleText }
    }

    /// The bottom `rows` of the rendered screen — the footer / input-box region —
    /// so `Session.autoSubmit` can confirm a seeded prompt landed in (or left) the
    /// input box without matching the same text echoed up in the conversation.
    public func inputRegionSnapshot(rows: Int) -> String {
        queue.sync { screen.bottomText(rows) }
    }

    /// Feed a chunk of raw pty output.
    public func feed(_ data: String) {
        queue.async { self._feed(data) }
    }

    /// Feed a batch of normalized structured-event kinds from the session's
    /// transcript tail (the preferred signal). A batch carrying an agent-produced
    /// kind is a wording-independent "the agent is working" pulse: it enters/keeps
    /// busy and (re)arms the settle/watchdog clocks exactly like footer output does.
    public func feedStructured(_ kinds: [StructuredEventKind]) {
        queue.async { self._feedStructured(kinds) }
    }

    /// Keep the screen model in step with the pty size so cursor/erase math stays
    /// accurate. Called from `Session.resize`.
    public func resize(cols: Int, rows: Int) {
        queue.async { self.screen.resize(cols: cols, rows: rows) }
    }

    /// The session ended — cancel any pending timers and return to idle.
    public func reset() {
        queue.async {
            self.generation += 1
            self.structuredTurn = false
            self.transition(.idle, notify: false)
        }
    }

    // MARK: - internals (always on `queue`)

    private func _feed(_ data: String) {
        // The screen must see every byte to stay an accurate mirror.
        screen.feed(data)
        if state == .busy {
            // Already working: any output (re)starts the settle/watchdog clocks.
            armTimers()
            return
        }
        let lower = data.lowercased()
        if lower.contains("interrupt"), Self.workingRe.firstMatch(in: normalizedScreen()) {
            // Cheap gate: only a frame that could carry the working footer is worth
            // re-reading the screen for. If the footer is now visible we go busy.
            structuredTurn = false
            transition(.busy, notify: false)
            armTimers()
            return
        }
        // Idle/waiting: a prompt can appear with no preceding working turn — a startup
        // folder-trust dialog, an auth prompt, a resumed session's pending permission
        // menu (juancode-8w5). Gate on cheap markers, then re-read on settle. While
        // already waiting we re-check on *any* output, since the answer that clears the
        // menu carries no marker of its own.
        if state == .waitingInput || Self.promptGate.contains(where: { lower.contains($0) }) {
            armPromptTimer()
        }
    }

    private func _feedStructured(_ kinds: [StructuredEventKind]) {
        guard batchHasAgentActivity(kinds) else { return }
        // A structured pulse is authoritative for this turn, whether it starts the
        // turn or upgrades one the screen path already opened (so settle no longer
        // waits on the footer being erased).
        structuredTurn = true
        if state != .busy { transition(.busy, notify: false) }
        armTimers()
    }

    /// (Re)arm both the short settle timer and the long stuck-busy watchdog. The
    /// generation guard cancels stale timers (busy *or* prompt) when newer output arrives.
    private func armTimers() {
        generation += 1
        let gen = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(settleMs)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.settle(demoteStaleFooter: false)
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(watchdogMs)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.settle(demoteStaleFooter: true)
        }
    }

    /// (Re)arm the idle→waiting settle. Shares the generation counter with
    /// `armTimers`, so starting a busy turn cancels a pending prompt re-read and
    /// vice versa — the latest frame always wins (juancode-8w5).
    private func armPromptTimer() {
        generation += 1
        let gen = generation
        queue.asyncAfter(deadline: .now() + .milliseconds(settleMs)) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.settlePrompt()
        }
    }

    /// Re-read the screen and classify. Only meaningful while busy: it ends a turn.
    /// `demoteStaleFooter` (the watchdog path) ignores a lingering footer and
    /// settles anyway, so we never hang on busy after the spinner has gone silent.
    private func settle(demoteStaleFooter: Bool) {
        guard state == .busy else { return }
        if !demoteStaleFooter, !structuredTurn, Self.workingRe.firstMatch(in: normalizedScreen()) {
            return // still working (screen path) — leave it busy
        }
        let next: SessionActivity = matchPrompt() != nil ? .waitingInput : .idle
        // We're leaving busy on a real turn boundary, so notify.
        transition(next, notify: true)
    }

    /// Re-classify a non-busy screen: a prompt in the trusted region enters
    /// `waitingInput` (notify), and a prompt that has since cleared demotes a stale
    /// `waitingInput` back to idle. Never touches a busy turn (that's `settle`).
    private func settlePrompt() {
        guard state == .idle || state == .waitingInput else { return }
        if matchPrompt() != nil {
            if state != .waitingInput { transition(.waitingInput, notify: true) }
        } else if state == .waitingInput {
            // The prompt was answered / repainted away — back to idle (no ding).
            transition(.idle, notify: false)
        }
    }

    /// The label of the first `PromptPattern` visible on the settled screen, or nil.
    /// Full-screen markers (the selection cursor) are matched everywhere; prose-like
    /// markers only in the bottom region. Records the hit in `lastMatchedPrompt`.
    private func matchPrompt() -> String? {
        let full = normalizedScreen()
        let bottom = normalizedBottom()
        for p in Self.promptPatterns where p.re.firstMatch(in: p.bottomOnly ? bottom : full) {
            lastMatchedPrompt = p.label
            return p.label
        }
        lastMatchedPrompt = nil
        return nil
    }

    private func transition(_ next: SessionActivity, notify: Bool) {
        if next == state { return }
        state = next
        if next != .busy { structuredTurn = false }
        onChange(next, notify)
    }

    /// The visible screen with runs of intra-line whitespace collapsed to a single
    /// space. The grid renders cursor-positioned footer segments as the *actual*
    /// column gap (many spaces); collapsing restores a compact line so the
    /// distance-bounded `workingRe` (`[^\n]{0,40}`) matches as intended.
    private func normalizedScreen() -> String {
        Self.wsRe.replacingMatches(in: screen.visibleText, with: " ")
    }

    /// The bottom `promptRegionRows` rows, whitespace-collapsed like `normalizedScreen`.
    private func normalizedBottom() -> String {
        Self.wsRe.replacingMatches(in: screen.bottomText(Self.promptRegionRows), with: " ")
    }

    // MARK: - patterns (ICU translations of the TS regexes)

    /// Rows of the bottom screen region treated as the footer / input / dialog area.
    /// Prose-like prompt markers are only matched here so the same words scrolled up
    /// in conversation history don't masquerade as a live prompt (juancode-8w5).
    private static let promptRegionRows = 20

    /// The "esc to interrupt" working line, tolerant of wording.
    private static let workingRe = Regex(
        #"\besc(?:ape)?\b[^\n]{0,40}\binterrupt\b"#, caseInsensitive: true)

    /// Runs of spaces/tabs within a line (not newlines), collapsed before matching.
    private static let wsRe = Regex(#"[^\S\n]{2,}"#, caseInsensitive: false)

    /// A prompt marker with the region it is trusted in. The `❯ 1.` selection cursor
    /// is the CLI's own menu UI — never in prose — so it is matched across the whole
    /// screen (a centered trust/permission dialog paints its cursor above any fixed
    /// bottom band). Prose-like markers could appear as ordinary scrolled-up text, so
    /// they are trusted only in the bottom region.
    struct PromptPattern {
        let label: String
        let re: Regex
        let bottomOnly: Bool
    }

    private static let promptPatterns: [PromptPattern] = [
        PromptPattern(label: "select-cursor", re: Regex(#"❯\s*\d+\.\s"#, caseInsensitive: false), bottomOnly: false),
        PromptPattern(label: "do-you-want", re: Regex(#"\bDo you want to\b"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "do-you-trust", re: Regex(#"\bDo you trust\b"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "proceed", re: Regex(#"\bProceed\?"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "allow", re: Regex(#"\bAllow\b[^\n]{0,40}\?"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "yn-paren", re: Regex(#"\(y/n\)"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "yn-bracket", re: Regex(#"\[y/n\]"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "press-enter", re: Regex(#"\bPress Enter to continue\b"#, caseInsensitive: true), bottomOnly: true),
        PromptPattern(label: "esc-cancel", re: Regex(#"\(esc to cancel\)"#, caseInsensitive: true), bottomOnly: true),
    ]

    /// Cheap lowercase substrings that gate the idle→waiting re-read: only a frame
    /// whose bytes could carry (part of) a prompt marker is worth re-scanning for. A
    /// false positive here just costs one wasted regex pass; it never alone changes state.
    private static let promptGate: [String] = ["?", "❯", "y/n", "trust", "continue", "esc to cancel"]
}

/// Thin NSRegularExpression wrapper so the patterns above read cleanly.
///
/// `@unchecked Sendable`: the sole stored property `re` is an immutable `let`
/// `NSRegularExpression`, which Apple documents as thread-safe for concurrent
/// matching. There is no mutable state, so sharing instances across threads is
/// safe.
struct Regex: @unchecked Sendable {
    private let re: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool) {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        // Patterns are compile-time constants; a bad one is a programmer error.
        re = try! NSRegularExpression(pattern: pattern, options: opts)
    }
    func firstMatch(in s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range) != nil
    }
    func replacingMatches(in s: String, with template: String) -> String {
        guard !s.isEmpty else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
