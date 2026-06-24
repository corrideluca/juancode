import Foundation

/// Discovers a Codex session's resumable id by watching its rollout files
/// (mirrors `apps/server/src/codexSession.ts`).
///
/// Codex has no flag to pin a session id (unlike Claude's `--session-id`), so
/// after spawning we find the rollout file it just created and read the id from
/// its `session_meta` header. Files live at:
///
///   ~/.codex/sessions/YYYY/MM/DD/rollout-<ISO-ts>-<uuid>.jsonl
///
/// and the first JSONL line is `{ type: "session_meta", payload: { id, cwd, ... } }`.
/// We match on `cwd` (so concurrent sessions elsewhere don't confuse us) and pick
/// the newest file modified at/after the spawn time.
public enum CodexSessionDiscovery {
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    private struct Header { let id: String; let cwd: String }

    /// Read just the first non-empty JSONL line and pull out the session_meta payload.
    private static func readHeader(_ url: URL) -> Header? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        // Read until the first newline (header is the first line) or a cap.
        while buf.count < 1 << 20 {
            let n = stream.read(&chunk, maxLength: chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if let nl = buf.firstIndex(of: 0x0A) {
                buf = Array(buf[0..<nl])
                break
            }
        }
        guard !buf.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(buf)) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let payload = obj["payload"] as? [String: Any],
              let id = payload["id"] as? String,
              let cwd = payload["cwd"] as? String
        else { return nil }
        return Header(id: id, cwd: cwd)
    }

    /// One scan pass: newest rollout file for `cwd` modified at/after `sinceMs`.
    static func scanOnce(cwd: String, sinceMs: Int, root: URL = defaultRoot) -> String? {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (id: String, mtimeMs: Int)?
        for case let url as URL in en {
            let name = url.lastPathComponent
            guard name.hasSuffix(".jsonl"), name.contains("rollout-") else { continue }
            let mtimeMs: Int
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate {
                mtimeMs = Int(date.timeIntervalSince1970 * 1000)
            } else { continue }
            // Allow a small clock-skew grace window before the spawn timestamp.
            if mtimeMs < sinceMs - 2000 { continue }
            if let best, mtimeMs <= best.mtimeMs { continue }
            if let header = readHeader(url), header.cwd == cwd {
                best = (header.id, mtimeMs)
            }
        }
        return best?.id
    }

    /// Poll for the Codex session id created at/after `sinceMs` in `cwd`. Returns
    /// the id once the rollout file appears, or nil if it never shows within the
    /// timeout (e.g. Codex exited before writing one).
    public static func capture(
        cwd: String,
        sinceMs: Int,
        timeoutMs: Int = 30_000,
        intervalMs: Int = 1500,
        root: URL = defaultRoot
    ) async -> String? {
        let deadline = sinceMs + timeoutMs
        while true {
            if let id = scanOnce(cwd: cwd, sinceMs: sinceMs, root: root) { return id }
            if nowMs() >= deadline { return nil }
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }
    }
}
