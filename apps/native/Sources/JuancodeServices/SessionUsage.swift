import Foundation
import JuancodeCore

/// Derives per-session token usage (and an estimated cost) from the CLI's own
/// transcript files — the same robust source `SessionTitle.swift` reads, rather
/// than scraping the ANSI TUI stream.
///
///   - Claude writes one `assistant` record per API turn into
///     `~/.claude/projects/<encoded-cwd>/<cliSessionId>.jsonl`, each carrying a
///     `message.usage` block. The same turn can be logged more than once, so we
///     dedup by `message.id` + `requestId` (the key `ccusage` uses) before
///     summing. Cost is summed per message using that message's model.
///   - Codex emits a running `token_count` event whose `info.total_token_usage`
///     is cumulative — we just take the last one.
///
/// Cost is a best-effort *estimate* from published per-MTok rates (below). For a
/// model we don't have a price for — or Codex, which doesn't expose a per-token
/// price (and is usually a subscription) — `costUsd` is nil and only tokens are
/// shown. Subscription users pay nothing per token regardless, so the figure is
/// labelled an estimate in the UI.
///
/// Returns nil when no usage is available yet (e.g. before the first turn).

/// Override the transcript roots (used by tests to point at fixtures).
public struct UsageRoots {
    public var claudeProjects: String?
    public var codexSessions: String?
    public init(claudeProjects: String? = nil, codexSessions: String? = nil) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
    }
}

/// Published input/output price per **million** tokens, by model-id match.
private struct ModelPrice {
    /// Matches against the transcript's model id (substring/prefix), case-insensitive.
    let match: String
    let inputPerMTok: Double
    let outputPerMTok: Double
}

/// Current Claude pricing (USD per 1M tokens). Cache reads bill at ~0.1× input
/// and cache writes at ~1.25× input (5-minute TTL, the default), applied below.
/// Ordered most-specific first; the first match wins.
private let MODEL_PRICES: [ModelPrice] = [
    ModelPrice(match: "opus", inputPerMTok: 5, outputPerMTok: 25),
    ModelPrice(match: "sonnet", inputPerMTok: 3, outputPerMTok: 15),
    ModelPrice(match: "haiku", inputPerMTok: 1, outputPerMTok: 5),
    ModelPrice(match: "fable|mythos", inputPerMTok: 10, outputPerMTok: 50),
]

private let CACHE_READ_MULT = 0.1
private let CACHE_WRITE_MULT = 1.25

private func priceFor(_ model: String) -> ModelPrice? {
    // Mirrors `MODEL_PRICES.find((p) => p.match.test(model))` with case-insensitive
    // regex matching; the last entry uses an alternation (`fable|mythos`).
    return MODEL_PRICES.first { p in
        model.range(of: p.match, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Resolving a transcript path means scanning a directory tree, wasteful to
/// repeat on every poll. Cache the resolved path per CLI session id once found.
///
/// (Separate from `SessionTitle`'s cache, mirroring the per-module `Map` in TS.)
private final class FileCache: @unchecked Sendable {
    private var map: [String: String] = [:]
    private let lock = NSLock()
    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return map[key]
    }
    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        map[key] = value
    }
}
private let fileCache = FileCache()

/// A zeroed `SessionUsage` with cost starting at 0 (becomes nil if a turn's model
/// is un-priced). Mirrors the TS `empty()` accumulator.
private func empty() -> SessionUsage {
    SessionUsage(
        inputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        totalTokens: 0,
        costUsd: 0
    )
}

/// Coerce a JSON numeric value to Int (transcript token fields are integers).
/// Falls back to `fallback` when absent or non-numeric, matching `?? 0`.
private func intField(_ dict: [String: Any]?, _ key: String, _ fallback: Int = 0) -> Int {
    guard let v = dict?[key] else { return fallback }
    if let n = v as? Int { return n }
    if let n = v as? Double { return Int(n) }
    if let n = v as? NSNumber { return n.intValue }
    return fallback
}

/// Token usage + estimated cost for a Claude session, summed across messages.
public func deriveClaudeUsage(
    _ cliSessionId: String,
    _ root: String = CLAUDE_PROJECTS
) async -> SessionUsage? {
    var file = fileCache.get(cliSessionId)
    if file == nil {
        guard let found = await findByBasename(root, "\(cliSessionId).jsonl") else { return nil }
        fileCache.set(cliSessionId, found)
        file = found
    }

    var usage = empty()
    var seen = Set<String>()
    var sawTurn = false
    // Stays true only while every priced turn had a known model; a `<synthetic>`
    // (local, no API call) message contributes no tokens and no cost.
    var costKnown = true

    await forEachRecord(file!) { rec in
        if rec["type"] as? String != "assistant" { return nil }
        let msg = rec["message"] as? [String: Any]
        let u = msg?["usage"] as? [String: Any]
        guard let u else { return nil }

        // Dedup: the same API response is sometimes written multiple times.
        let msgId = msg?["id"] as? String ?? ""
        let requestId = rec["requestId"] as? String ?? ""
        let key = "\(msgId):\(requestId)"
        if key != ":" && seen.contains(key) { return nil }
        seen.insert(key)

        let model = msg?["model"] as? String ?? ""
        if model == "<synthetic>" { return nil }  // local message, not a billed API call

        let input = intField(u, "input_tokens")
        let output = intField(u, "output_tokens")
        let cacheRead = intField(u, "cache_read_input_tokens")
        let cacheWrite = intField(u, "cache_creation_input_tokens")

        sawTurn = true
        usage.inputTokens += input
        usage.outputTokens += output
        usage.cacheReadTokens += cacheRead
        usage.cacheWriteTokens += cacheWrite

        if let price = priceFor(model) {
            usage.costUsd! +=
                (Double(input) * price.inputPerMTok
                    + Double(cacheRead) * price.inputPerMTok * CACHE_READ_MULT
                    + Double(cacheWrite) * price.inputPerMTok * CACHE_WRITE_MULT
                    + Double(output) * price.outputPerMTok)
                / 1_000_000
        } else {
            costKnown = false  // an un-priced model means the total is only partial
        }
        return nil
    }

    if !sawTurn { return nil }
    usage.totalTokens =
        usage.inputTokens + usage.outputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
    if !costKnown { usage.costUsd = nil }
    return usage
}

/// Token usage for a Codex session: the last cumulative `token_count` event.
public func deriveCodexUsage(
    _ cliSessionId: String,
    _ root: String = CODEX_SESSIONS
) async -> SessionUsage? {
    let cached = fileCache.get(cliSessionId)
    let files = cached != nil ? [cached!] : await codexRolloutFiles(root)

    for full in files {
        var isMatch = cached == full
        var total: [String: Any]? = nil
        await forEachRecord(full) { rec in
            let payload = rec["payload"] as? [String: Any]
            if rec["type"] as? String == "session_meta" {
                if (payload?["id"] as? String) != cliSessionId { return false }  // wrong file — bail
                isMatch = true
                return nil
            }
            // Cumulative tally; keep the latest. (When reading a cached file directly
            // we never see session_meta, but isMatch is already true.)
            if isMatch, payload?["type"] as? String == "token_count",
               let info = payload?["info"] as? [String: Any],
               let totalUsage = info["total_token_usage"] as? [String: Any] {
                total = totalUsage
            }
            return nil
        }
        if isMatch {
            fileCache.set(cliSessionId, full)
            guard let t = total else { return nil }  // matched the session but no turn has run yet
            // Codex `input_tokens` already includes the cached portion, so subtract
            // it out to report fresh input separately. No per-token price → no cost.
            let cacheRead = intField(t, "cached_input_tokens")
            let input = max(0, intField(t, "input_tokens") - cacheRead)
            let output = intField(t, "output_tokens")
            let totalTokens = intField(t, "total_tokens", input + output + cacheRead)
            return SessionUsage(
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: 0,
                totalTokens: totalTokens,
                costUsd: nil
            )
        }
    }
    return nil
}

public func deriveSessionUsage(
    _ provider: ProviderId,
    _ cliSessionId: String,
    _ roots: UsageRoots = UsageRoots()
) async -> SessionUsage? {
    if provider == .terminal {
        return nil
    } else if provider == .claude {
        return await deriveClaudeUsage(cliSessionId, roots.claudeProjects ?? CLAUDE_PROJECTS)
    } else {
        return await deriveCodexUsage(cliSessionId, roots.codexSessions ?? CODEX_SESSIONS)
    }
}
