import Foundation

/// Model types mirrored from `apps/server/src/protocol.ts`. Kept dependency-free
/// and in sync with the TS wire protocol — these are what the embedded server
/// (juancode-u34.3) will encode for remote clients.

public enum ProviderId: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
}

/// Inferred live activity of a running session. Derived from the pty stream
/// (see `ActivityDetector`); not persisted — only meaningful for live sessions.
public enum SessionActivity: String, Codable, Sendable {
    case busy
    case idle
    case waitingInput = "waiting_input"
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case exited
}

/// Per-session token usage parsed from the CLI transcript. `costUsd` is a
/// best-effort estimate, nil when not computable.
public struct SessionUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// input + output + cache read + cache write.
    public var totalTokens: Int
    public var costUsd: Double?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        costUsd: Double?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.costUsd = costUsd
    }
}

public struct SessionMeta: Codable, Sendable, Equatable {
    public var id: String
    public var provider: ProviderId
    public var cwd: String
    public var title: String
    public var status: SessionStatus
    public var exitCode: Int?
    /// ms since epoch, matching the TS `Date.now()` shape.
    public var createdAt: Int
    public var updatedAt: Int
    /// The CLI's resumable conversation id. Known immediately for Claude
    /// (pinned via `--session-id`); discovered after spawn for Codex. Nil until
    /// captured — when nil the session can be viewed but not reactivated.
    public var cliSessionId: String?
    /// "Accept all" mode — the CLI runs with no permission/approval prompts.
    public var skipPermissions: Bool
    /// Absolute path of a juancode-owned git worktree, or nil for sessions that
    /// run in an existing directory.
    public var worktreePath: String?
    public var usage: SessionUsage?
    /// Archived sessions are kept in the store but hidden from the default
    /// sidebar list (reachable via a "Show archived" toggle). Defaults to false.
    public var archived: Bool

    public init(
        id: String,
        provider: ProviderId,
        cwd: String,
        title: String,
        status: SessionStatus,
        exitCode: Int?,
        createdAt: Int,
        updatedAt: Int,
        cliSessionId: String?,
        skipPermissions: Bool,
        worktreePath: String?,
        usage: SessionUsage?,
        archived: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.cwd = cwd
        self.title = title
        self.status = status
        self.exitCode = exitCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cliSessionId = cliSessionId
        self.skipPermissions = skipPermissions
        self.worktreePath = worktreePath
        self.usage = usage
        self.archived = archived
    }

    // Custom decode so payloads predating `archived` (older db rows / wire
    // messages from a Node peer that doesn't model it) still decode cleanly.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(ProviderId.self, forKey: .provider)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(SessionStatus.self, forKey: .status)
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        createdAt = try c.decode(Int.self, forKey: .createdAt)
        updatedAt = try c.decode(Int.self, forKey: .updatedAt)
        cliSessionId = try c.decodeIfPresent(String.self, forKey: .cliSessionId)
        skipPermissions = try c.decode(Bool.self, forKey: .skipPermissions)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        usage = try c.decodeIfPresent(SessionUsage.self, forKey: .usage)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

/// Milliseconds since the unix epoch — the timestamp unit the TS layer uses.
@inline(__always)
public func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}
