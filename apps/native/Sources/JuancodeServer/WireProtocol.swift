import Foundation
import JuancodeCore

/// The WebSocket wire protocol, a faithful Codable mirror of the `ClientMessage`
/// / `ServerMessage` tagged unions in `apps/server/src/protocol.ts` (and its twin
/// `apps/web/src/protocol.ts`). The discriminator is the `type` field; every
/// other field sits flat alongside it, exactly as the TS JSON does — so the
/// existing React web client talks to this embedded server unchanged.
///
/// Keep this in sync with the two protocol.ts files.

// MARK: - Client → server

public enum ClientMessage: Sendable {
    case create(provider: String, cwd: String, cols: Int, rows: Int,
                initialInput: String?, skipPermissions: Bool?, isolateWorktree: Bool?)
    case attach(sessionId: String, cols: Int, rows: Int)
    case reactivate(sessionId: String, cols: Int, rows: Int)
    /// Adopt an external CLI conversation (one started in a plain terminal) by its
    /// own resumable id, persisting a juancode session row and resuming it live.
    case adoptExternal(provider: String, cliSessionId: String, cwd: String,
                       startMs: Int, cols: Int, rows: Int)
    case setSkipPermissions(sessionId: String, skipPermissions: Bool, cols: Int, rows: Int)
    case input(sessionId: String, data: String)
    case resize(sessionId: String, cols: Int, rows: Int)
    case kill(sessionId: String)
    case openEditor(cwd: String, file: String, cols: Int, rows: Int)
    case openTerminal(cwd: String, cols: Int, rows: Int, requestId: String)
}

extension ClientMessage: Decodable {
    private enum K: String, CodingKey {
        case type, provider, cwd, cols, rows, initialInput, skipPermissions, isolateWorktree
        case sessionId, data, file, requestId, cliSessionId, startMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "create":
            self = .create(
                provider: try c.decode(String.self, forKey: .provider),
                cwd: try c.decode(String.self, forKey: .cwd),
                cols: try c.decode(Int.self, forKey: .cols),
                rows: try c.decode(Int.self, forKey: .rows),
                initialInput: try c.decodeIfPresent(String.self, forKey: .initialInput),
                skipPermissions: try c.decodeIfPresent(Bool.self, forKey: .skipPermissions),
                isolateWorktree: try c.decodeIfPresent(Bool.self, forKey: .isolateWorktree)
            )
        case "attach":
            self = .attach(sessionId: try c.decode(String.self, forKey: .sessionId),
                           cols: try c.decode(Int.self, forKey: .cols),
                           rows: try c.decode(Int.self, forKey: .rows))
        case "reactivate":
            self = .reactivate(sessionId: try c.decode(String.self, forKey: .sessionId),
                               cols: try c.decode(Int.self, forKey: .cols),
                               rows: try c.decode(Int.self, forKey: .rows))
        case "adoptExternal":
            self = .adoptExternal(provider: try c.decode(String.self, forKey: .provider),
                                  cliSessionId: try c.decode(String.self, forKey: .cliSessionId),
                                  cwd: try c.decode(String.self, forKey: .cwd),
                                  startMs: try c.decode(Int.self, forKey: .startMs),
                                  cols: try c.decode(Int.self, forKey: .cols),
                                  rows: try c.decode(Int.self, forKey: .rows))
        case "setSkipPermissions":
            self = .setSkipPermissions(sessionId: try c.decode(String.self, forKey: .sessionId),
                                       skipPermissions: try c.decode(Bool.self, forKey: .skipPermissions),
                                       cols: try c.decode(Int.self, forKey: .cols),
                                       rows: try c.decode(Int.self, forKey: .rows))
        case "input":
            self = .input(sessionId: try c.decode(String.self, forKey: .sessionId),
                          data: try c.decode(String.self, forKey: .data))
        case "resize":
            self = .resize(sessionId: try c.decode(String.self, forKey: .sessionId),
                           cols: try c.decode(Int.self, forKey: .cols),
                           rows: try c.decode(Int.self, forKey: .rows))
        case "kill":
            self = .kill(sessionId: try c.decode(String.self, forKey: .sessionId))
        case "openEditor":
            self = .openEditor(cwd: try c.decode(String.self, forKey: .cwd),
                               file: try c.decode(String.self, forKey: .file),
                               cols: try c.decode(Int.self, forKey: .cols),
                               rows: try c.decode(Int.self, forKey: .rows))
        case "openTerminal":
            self = .openTerminal(cwd: try c.decode(String.self, forKey: .cwd),
                                 cols: try c.decode(Int.self, forKey: .cols),
                                 rows: try c.decode(Int.self, forKey: .rows),
                                 requestId: try c.decode(String.self, forKey: .requestId))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown client message type: \(type)")
        }
    }
}

// MARK: - Server → client

public enum ServerMessage: Sendable {
    case created(session: SessionMeta)
    case attached(sessionId: String, scrollback: String, session: SessionMeta)
    case output(sessionId: String, data: String)
    case exit(sessionId: String, exitCode: Int?)
    case activity(sessionId: String, state: SessionActivity, notify: Bool)
    case editorReady(editorId: String)
    case terminalReady(terminalId: String, requestId: String)
    case unresumable(sessionId: String, reason: String)
    case error(sessionId: String?, message: String)
}

extension ServerMessage: Encodable {
    private enum K: String, CodingKey {
        case type, session, sessionId, scrollback, data, exitCode, state, notify
        case editorId, terminalId, requestId, reason, message
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .created(session):
            try c.encode("created", forKey: .type)
            try c.encode(session, forKey: .session)
        case let .attached(sessionId, scrollback, session):
            try c.encode("attached", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(scrollback, forKey: .scrollback)
            try c.encode(session, forKey: .session)
        case let .output(sessionId, data):
            try c.encode("output", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(data, forKey: .data)
        case let .exit(sessionId, exitCode):
            try c.encode("exit", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            // `exitCode: number | null` is always present in the TS — emit null,
            // not an omitted key, when there's no code.
            try c.encode(exitCode, forKey: .exitCode)
        case let .activity(sessionId, state, notify):
            try c.encode("activity", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(state, forKey: .state)
            try c.encode(notify, forKey: .notify)
        case let .editorReady(editorId):
            try c.encode("editorReady", forKey: .type)
            try c.encode(editorId, forKey: .editorId)
        case let .terminalReady(terminalId, requestId):
            try c.encode("terminalReady", forKey: .type)
            try c.encode(terminalId, forKey: .terminalId)
            try c.encode(requestId, forKey: .requestId)
        case let .unresumable(sessionId, reason):
            try c.encode("unresumable", forKey: .type)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encode(reason, forKey: .reason)
        case let .error(sessionId, message):
            try c.encode("error", forKey: .type)
            // `sessionId?` is optional in the TS — omit when nil.
            try c.encodeIfPresent(sessionId, forKey: .sessionId)
            try c.encode(message, forKey: .message)
        }
    }

    /// JSON string for sending over the socket.
    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
