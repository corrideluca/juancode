import Foundation
import Testing
@testable import JuancodeCore

/// Mirrors apps/server/src/activityDetector.test.ts. The TS suite uses fake
/// timers; we use a short real `settleMs` and poll, since the Swift detector is
/// queue/clock-driven.
@Suite struct ActivityDetectorTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(SessionActivity, Bool)] = []
        func record(_ s: SessionActivity, _ n: Bool) { lock.withLock { events.append((s, n)) } }
        var snapshot: [(SessionActivity, Bool)] { lock.withLock { events } }
        var states: [SessionActivity] { snapshot.map(\.0) }
    }

    private func poll(_ timeout: TimeInterval = 1.0, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func sleepMs(_ ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    @Test func goesBusyOnWorkingIndicator() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("✻ Thinking… (3s · esc to interrupt)")
        await poll { c.snapshot.contains { $0.0 == .busy } }
        #expect(c.states == [.busy])
    }

    @Test func settlesToIdleWhenIndicatorStops() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("✻ Working… (esc to interrupt)")
        det.feed("Here is the answer.\n")
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.map { [$0.0.rawValue, "\($0.1)"] }
            == [["busy", "false"], ["idle", "true"]])
    }

    @Test func classifiesOptionMenuAsWaitingInput() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("Running… esc to interrupt")
        det.feed("Do you want to proceed?\n ❯ 1. Yes\n   2. No\n")
        await poll { c.snapshot.last?.0 == .waitingInput }
        #expect(c.snapshot.last?.0 == .waitingInput)
        #expect(c.snapshot.last?.1 == true)
    }

    @Test func ignoresBannerAndTyping() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("Welcome to Claude Code!\n")
        det.feed("> what is 2 + 2")
        await sleepMs(200) // past the settle window
        #expect(c.snapshot.isEmpty)
    }

    @Test func staysBusyOnStreamingOutput() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 200) { c.record($0, $1) }
        det.feed("esc to interrupt") // phrase appears once at turn start
        await sleepMs(100)
        det.feed("streaming a token…") // later frames carry no phrase
        await sleepMs(100)
        det.feed("more tokens…")
        await sleepMs(100)
        #expect(c.states == [.busy]) // never settled early
        // and it does eventually settle once output goes quiet
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
    }

    @Test func returnsToIdleOnReset() async {
        let c = Collector()
        let det = ActivityDetector(settleMs: 60) { c.record($0, $1) }
        det.feed("esc to interrupt")
        await poll { c.snapshot.contains { $0.0 == .busy } }
        det.reset()
        await poll { c.snapshot.last?.0 == .idle }
        #expect(c.snapshot.last?.0 == .idle)
        #expect(c.snapshot.last?.1 == false)
    }
}
