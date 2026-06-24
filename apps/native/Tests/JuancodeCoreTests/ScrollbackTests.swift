import Testing
@testable import JuancodeCore

/// Mirrors apps/server/src/scrollback.test.ts (over bytes instead of chars).
@Suite struct ScrollbackTests {
    private func b(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func appendsWhenUnderLimit() {
        #expect(appendScrollback(b("ab"), b("cd"), limit: 100) == b("abcd"))
    }

    @Test func trimsOldestPastLimit() {
        #expect(appendScrollback(b("abcd"), b("ef"), limit: 4) == b("cdef"))
    }

    @Test func handlesChunkLargerThanLimit() {
        #expect(appendScrollback(b(""), b("abcdef"), limit: 3) == b("def"))
    }

    @Test func keepsExactlyLimitWhenEqual() {
        #expect(appendScrollback(b("ab"), b("cd"), limit: 4) == b("abcd"))
    }

    @Test func structSeedTrimsToLimit() {
        var s = Scrollback(limit: 3, seed: b("abcdef"))
        #expect(s.bytes == b("def"))
        s.append(b("gh"))
        #expect(s.bytes == b("fgh"))
    }
}
