import Foundation
import Testing
@testable import JuancodeCore

/// Mirrors the intent of apps/server/src/codexSession.ts: find the newest rollout
/// file whose `session_meta.cwd` matches, and read its id. Runs against a fixture
/// dir via the injectable `root`.
@Suite struct CodexSessionDiscoveryTests {
    private func makeFixtureRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-fixture-\(UUID().uuidString)")
    }

    private func writeRollout(_ root: URL, day: String, id: String, cwd: String, mtime: Date) throws {
        let dir = root.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout-2026-06-24T00-00-00-\(id).jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#
        try (header + "\n{\"type\":\"event\"}\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
    }

    @Test func findsMatchingCwdSessionId() async throws {
        let root = makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        try writeRollout(root, day: "2026/06/24", id: "match-me", cwd: "/work/proj", mtime: now)
        try writeRollout(root, day: "2026/06/24", id: "other", cwd: "/somewhere/else", mtime: now)

        let id = CodexSessionDiscovery.scanOnce(
            cwd: "/work/proj", sinceMs: Int(now.timeIntervalSince1970 * 1000) - 5000, root: root)
        #expect(id == "match-me")
    }

    @Test func picksNewestWhenMultipleMatch() async throws {
        let root = makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-100)
        let new = Date()
        try writeRollout(root, day: "2026/06/23", id: "old", cwd: "/work/proj", mtime: old)
        try writeRollout(root, day: "2026/06/24", id: "new", cwd: "/work/proj", mtime: new)

        let id = CodexSessionDiscovery.scanOnce(
            cwd: "/work/proj", sinceMs: Int(old.timeIntervalSince1970 * 1000) - 5000, root: root)
        #expect(id == "new")
    }

    @Test func ignoresFilesOlderThanSince() async throws {
        let root = makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Date().addingTimeInterval(-3600)
        try writeRollout(root, day: "2026/06/24", id: "stale", cwd: "/work/proj", mtime: old)

        let id = CodexSessionDiscovery.scanOnce(
            cwd: "/work/proj", sinceMs: Int(Date().timeIntervalSince1970 * 1000), root: root)
        #expect(id == nil)
    }

    @Test func returnsNilWhenRootMissing() async {
        let id = CodexSessionDiscovery.scanOnce(
            cwd: "/x", sinceMs: 0,
            root: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(id == nil)
    }
}
