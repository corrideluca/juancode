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

    // MARK: - alternate-buffer resync (juancode garbled-TUI fix)

    private let enterAlt = "\u{1B}[?1049h"
    private let exitAlt = "\u{1B}[?1049l"

    @Test func replayIsRawOnNormalBuffer() {
        var s = Scrollback(limit: 100)
        s.append(b("hello"))
        #expect(!s.inAlternateBuffer)
        #expect(s.replay == b("hello"))
    }

    @Test func replayPrependsResyncInAltBuffer() {
        var s = Scrollback(limit: 100)
        s.append(b(enterAlt + "frame"))
        #expect(s.inAlternateBuffer)
        #expect(s.replay == Scrollback.altResync + b(enterAlt + "frame"))
    }

    @Test func exitAltClearsState() {
        var s = Scrollback(limit: 100)
        s.append(b(enterAlt))
        s.append(b(exitAlt + "back to normal"))
        #expect(!s.inAlternateBuffer)
        #expect(s.replay == b(enterAlt + exitAlt + "back to normal"))
    }

    @Test func altStateSurvivesTrimmingOfEnterSequence() {
        // A long-running TUI: the enter-alt sequence is trimmed past the cap, but
        // the state is retained so replay still resyncs the parser.
        var s = Scrollback(limit: 8)
        s.append(b(enterAlt))
        s.append(b("abcdefghij")) // pushes the enter-alt out of `bytes`
        #expect(s.bytes == b("cdefghij"))
        #expect(s.inAlternateBuffer)
        #expect(s.replay == Scrollback.altResync + b("cdefghij"))
    }

    @Test func detectsEnterSplitAcrossChunks() {
        var s = Scrollback(limit: 100)
        let mid = enterAlt.index(enterAlt.startIndex, offsetBy: 4)
        s.append(b(String(enterAlt[..<mid])))
        s.append(b(String(enterAlt[mid...]) + "x"))
        #expect(s.inAlternateBuffer)
    }

    @Test func seedRecoversAltStateAndStripsResyncPrefix() {
        // A seed shaped like a prior `replay`: resync prefix + trimmed alt content.
        let seed = Scrollback.altResync + b("frame-content")
        let s = Scrollback(limit: 100, seed: seed)
        #expect(s.inAlternateBuffer)
        // The synthetic prefix is dropped from `bytes` so it isn't compounded…
        #expect(s.bytes == b("frame-content"))
        // …but `replay` re-adds exactly one.
        #expect(s.replay == Scrollback.altResync + b("frame-content"))
    }
}
