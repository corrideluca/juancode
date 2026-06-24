/// Capped scrollback buffer (mirrors `apps/server/src/scrollback.ts`).
///
/// We keep bytes, not a decoded String: the pty stream is raw and chunk
/// boundaries can split multibyte UTF-8 or escape sequences, so trimming on
/// byte length and replaying bytes verbatim is the faithful choice. Replay feeds
/// these bytes straight into a SwiftTerm `feed(byteArray:)` (or a WS client).

/// Append `chunk` to `buffer`, keeping at most `limit` trailing bytes.
public func appendScrollback(_ buffer: [UInt8], _ chunk: [UInt8], limit: Int) -> [UInt8] {
    var next = buffer
    next.append(contentsOf: chunk)
    if next.count > limit {
        next.removeFirst(next.count - limit)
    }
    return next
}

/// Mutable wrapper around the capped buffer.
public struct Scrollback {
    public let limit: Int
    public private(set) var bytes: [UInt8]

    public init(limit: Int, seed: [UInt8] = []) {
        self.limit = limit
        self.bytes = seed.count > limit ? Array(seed.suffix(limit)) : seed
    }

    public mutating func append(_ chunk: [UInt8]) {
        bytes = appendScrollback(bytes, chunk, limit: limit)
    }
}
