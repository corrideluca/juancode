import Foundation
import Testing
@testable import JuancodeCore

/// Tests for `SessionMeta.adopting` (juancode-iqi): the shared factory both the
/// in-process AppModel path and the server `.adoptExternal` wire path use to build
/// a persisted row for an external CLI conversation.
@Suite struct SessionMetaAdoptingTests {
    @Test func setsCliSessionIdAndCarriesStartMs() {
        let meta = SessionMeta.adopting(provider: .claude, cliSessionId: "conv-42",
                                        cwd: "/Users/me/project", startMs: 1_700_000_000_000)
        #expect(meta.cliSessionId == "conv-42")
        #expect(meta.provider == .claude)
        #expect(meta.cwd == "/Users/me/project")
        #expect(meta.status == .running)
        #expect(meta.exitCode == nil)
        // startMs becomes createdAt so the adopted row sorts by its real age.
        #expect(meta.createdAt == 1_700_000_000_000)
        #expect(meta.worktreePath == nil)
        #expect(meta.usage == nil)
        #expect(meta.archived == false)
    }

    @Test func freshJuancodeIdDistinctFromCliSessionId() {
        let meta = SessionMeta.adopting(provider: .codex, cliSessionId: "conv-1",
                                        cwd: "/tmp/x", startMs: 1)
        // The juancode id is our own key, not the CLI's conversation id.
        #expect(meta.id != "conv-1")
        #expect(!meta.id.isEmpty)
        let a = SessionMeta.adopting(provider: .codex, cliSessionId: "conv-1", cwd: "/tmp/x", startMs: 1)
        let b = SessionMeta.adopting(provider: .codex, cliSessionId: "conv-1", cwd: "/tmp/x", startMs: 1)
        #expect(a.id != b.id) // fresh each call
    }

    @Test func titleUsesProviderLabelAndFolder() {
        let meta = SessionMeta.adopting(provider: .claude, cliSessionId: "c",
                                        cwd: "/Users/me/project", startMs: 1)
        let label = Providers.spec(for: .claude).label
        #expect(meta.title == "\(label) · project")
    }

    @Test func skipPermissionsDefaultsTrueAndIsOverridable() {
        #expect(SessionMeta.adopting(provider: .codex, cliSessionId: "c", cwd: "/tmp", startMs: 1)
            .skipPermissions == true)
        #expect(SessionMeta.adopting(provider: .codex, cliSessionId: "c", cwd: "/tmp", startMs: 1,
                                     skipPermissions: false).skipPermissions == false)
    }
}
