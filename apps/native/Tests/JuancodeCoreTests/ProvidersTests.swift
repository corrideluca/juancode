import Testing
@testable import JuancodeCore

/// Mirrors apps/server/src/providers.test.ts.
@Suite struct ProvidersTests {
    let id = "11111111-1111-1111-1111-111111111111"
    let sid = "abc-123"

    @Test func startArgsNoAcceptAllByDefault() {
        #expect(Providers.claude.startArgs(id, SpawnOptions()) == ["--session-id", id])
        #expect(Providers.codex.startArgs(id, SpawnOptions()) == [])
    }

    @Test func startArgsActivatesAcceptAllFlag() {
        #expect(Providers.claude.startArgs(id, SpawnOptions(skipPermissions: true))
            == ["--session-id", id, "--dangerously-skip-permissions"])
        #expect(Providers.codex.startArgs(id, SpawnOptions(skipPermissions: true))
            == ["--dangerously-bypass-approvals-and-sandbox"])
    }

    @Test func resumeArgsNoAcceptAllByDefault() {
        #expect(Providers.claude.resumeArgs(sid, SpawnOptions()) == ["--resume", sid])
        #expect(Providers.codex.resumeArgs(sid, SpawnOptions()) == ["resume", sid])
    }

    @Test func resumeArgsActivatesAcceptAllFlag() {
        #expect(Providers.claude.resumeArgs(sid, SpawnOptions(skipPermissions: true))
            == ["--resume", sid, "--dangerously-skip-permissions"])
        #expect(Providers.codex.resumeArgs(sid, SpawnOptions(skipPermissions: true))
            == ["resume", "--dangerously-bypass-approvals-and-sandbox", sid])
    }

    @Test func pinsSessionIdFlags() {
        #expect(Providers.claude.pinsSessionId == true)
        #expect(Providers.codex.pinsSessionId == false)
    }
}
