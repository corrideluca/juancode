import Testing
@testable import JuancodeCore

/// Per-session pty grid arbitration (juancode-1th.1). Mirrors the TS
/// `gridArbiter.test.ts` so both twins enforce the same ownership policy.
@Suite struct GridArbiterTests {
    @Test func firstClientClaimsTheGrid() {
        let g = GridArbiter()
        #expect(g.request("a") == true)
        #expect(g.current == "a")
    }

    @Test func secondClientDeniedWhileFirstOwns() {
        let g = GridArbiter()
        _ = g.request("a")
        #expect(g.request("b") == false)
        // A denied request must not steal ownership, or two viewers' resizes
        // would flap the grid last-write-wins.
        #expect(g.current == "a")
    }

    @Test func ownerKeepsDrivingTheGrid() {
        let g = GridArbiter()
        _ = g.request("a")
        #expect(g.request("a") == true)
        #expect(g.request("a") == true)
    }

    @Test func nextClientClaimsAfterOwnerReleases() {
        let g = GridArbiter()
        _ = g.request("a")
        g.release("a")
        #expect(g.current == nil)
        #expect(g.request("b") == true)
        #expect(g.current == "b")
    }

    @Test func releaseFromNonOwnerIsIgnored() {
        let g = GridArbiter()
        _ = g.request("a")
        g.release("b")
        #expect(g.current == "a")
        #expect(g.request("b") == false)
    }

    @Test func localViewPreemptsRemoteOwner() {
        let g = GridArbiter()
        _ = g.request("remote")
        #expect(g.request(GridArbiter.localOwner) == true)
        #expect(g.current == GridArbiter.localOwner)
        #expect(g.request("remote") == false)
    }

    @Test func remoteCanClaimOnceLocalViewReleases() {
        let g = GridArbiter()
        _ = g.request(GridArbiter.localOwner)
        #expect(g.request("remote") == false)
        g.release(GridArbiter.localOwner)
        #expect(g.request("remote") == true)
    }
}
