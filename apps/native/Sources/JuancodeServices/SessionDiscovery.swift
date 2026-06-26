import Foundation
import JuancodeCore

/// A CLI conversation found on disk that juancode didn't create — e.g. a claude or
/// codex session you started in your terminal. Surfaced (opt-in) in the sidebar so
/// you can resume it inside juancode. `id` is the CLI's own resumable session id.
public struct ExternalSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let provider: ProviderId
    public let cwd: String
    public let title: String
    public let lastActiveMs: Int

    public init(id: String, provider: ProviderId, cwd: String, title: String, lastActiveMs: Int) {
        self.id = id
        self.provider = provider
        self.cwd = cwd
        self.title = title
        self.lastActiveMs = lastActiveMs
    }
}

/// Discover resumable terminal conversations, newest first, paged so we never read
/// every transcript at once. We stat all candidate files cheaply (no content read)
/// to order them by recency, then read the content of only the `limit` most recent
/// — so "Load more" (a larger limit) costs one extra batch of reads, not a full scan.
///
/// - `limit`: how many to return (the centralized list starts at 10 and grows).
/// - `excluding`: CLI session ids juancode already owns, so its own sessions (which
///   also write transcripts here) aren't surfaced as duplicates.
/// - Returns the sessions plus `hasMore` — whether candidates remain past the limit.
public func discoverExternalSessions(
    limit: Int,
    excluding: Set<String>,
    roots: TitleRoots = TitleRoots()
) async -> (sessions: [ExternalSession], hasMore: Bool) {
    var candidates: [Candidate] = []
    for path in claudeTranscriptFiles(roots.claudeProjects ?? CLAUDE_PROJECTS) {
        // Claude's session id is the file's basename, so we can dedup before reading.
        let id = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !id.isEmpty, !excluding.contains(id), let mtime = mtimeMs(path) else { continue }
        candidates.append(Candidate(path: path, provider: .claude, mtime: mtime, claudeId: id))
    }
    for path in await codexRolloutFiles(roots.codexSessions ?? CODEX_SESSIONS) {
        guard let mtime = mtimeMs(path) else { continue }
        candidates.append(Candidate(path: path, provider: .codex, mtime: mtime, claudeId: nil))
    }
    candidates.sort { $0.mtime > $1.mtime }

    var sessions: [ExternalSession] = []
    var consumed = 0
    for cand in candidates {
        if sessions.count >= limit { break }
        consumed += 1
        if let s = await readExternal(cand, excluding) { sessions.append(s) }
    }
    return (sessions, consumed < candidates.count)
}

private struct Candidate {
    let path: String
    let provider: ProviderId
    let mtime: Int
    let claudeId: String?
}

private func mtimeMs(_ path: String) -> Int? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let date = attrs[.modificationDate] as? Date else { return nil }
    return Int(date.timeIntervalSince1970 * 1000)
}

/// Read one candidate's content into an `ExternalSession` (nil if unreadable or, for
/// codex, already owned — its id isn't known until we read `session_meta`).
private func readExternal(_ cand: Candidate, _ excluding: Set<String>) async -> ExternalSession? {
    cand.provider == .claude
        ? await readClaude(cand)
        : await readCodex(cand, excluding)
}

private func readClaude(_ cand: Candidate) async -> ExternalSession? {
    guard let id = cand.claudeId else { return nil }
    var cwd: String?
    var aiTitle: String?
    var firstUser: String?
    await forEachRecord(cand.path) { rec in
        if cwd == nil, let c = rec["cwd"] as? String { cwd = c }
        if aiTitle == nil, rec["type"] as? String == "ai-title", let t = rec["aiTitle"] as? String { aiTitle = t }
        if firstUser == nil, rec["type"] as? String == "user" { firstUser = claudeUserText(rec) }
        // Stop as soon as we have a cwd and something to title with.
        return (cwd != nil && (aiTitle != nil || firstUser != nil)) ? false : nil
    }
    guard let cwd else { return nil }
    let title = tidy(aiTitle ?? firstUser ?? "") ?? (cwd as NSString).lastPathComponent
    return ExternalSession(id: id, provider: .claude, cwd: cwd, title: title, lastActiveMs: cand.mtime)
}

/// Pull the first text out of a Claude `user` record, whose `message.content` is
/// either a plain string or an array of typed parts.
private func claudeUserText(_ rec: [String: Any]) -> String? {
    guard let message = rec["message"] as? [String: Any] else { return nil }
    if let s = message["content"] as? String { return s }
    if let parts = message["content"] as? [[String: Any]] {
        for part in parts where part["type"] as? String == "text" {
            if let t = part["text"] as? String { return t }
        }
    }
    return nil
}

private func readCodex(_ cand: Candidate, _ excluding: Set<String>) async -> ExternalSession? {
    var id: String?
    var cwd: String?
    var prompt: String?
    await forEachRecord(cand.path) { rec in
        if rec["type"] as? String == "session_meta", let payload = rec["payload"] as? [String: Any] {
            id = payload["id"] as? String
            cwd = payload["cwd"] as? String
        }
        if prompt == nil, let payload = rec["payload"] as? [String: Any],
           payload["type"] as? String == "user_message", let m = payload["message"] as? String {
            prompt = m
        }
        return (id != nil && cwd != nil && prompt != nil) ? false : nil
    }
    guard let id, let cwd, !excluding.contains(id) else { return nil }
    let title = tidy(prompt ?? "") ?? (cwd as NSString).lastPathComponent
    return ExternalSession(id: id, provider: .codex, cwd: cwd, title: title, lastActiveMs: cand.mtime)
}

/// Absolute paths of every Claude transcript `.jsonl`, gathered synchronously (the
/// directory enumerator can't be driven from an async context).
private func claudeTranscriptFiles(_ root: String) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
    var out: [String] = []
    for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
        out.append((root as NSString).appendingPathComponent(rel))
    }
    return out
}
