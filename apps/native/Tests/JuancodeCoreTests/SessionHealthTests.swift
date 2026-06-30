import Testing
@testable import JuancodeCore

/// Unit tests for the pure session-health classifier that backs the periodic
/// health-check sweep (juancode-0me pillar 3 / juancode-02k).
@Suite struct SessionHealthTests {
    /// Build an input with healthy-by-default fields, overriding only what a test cares about.
    private func input(
        id: String = "s1",
        status: SessionStatus = .running,
        isLive: Bool = true,
        activity: SessionActivity? = .idle,
        lastOutputMs: Int = 1_000,
        resumable: Bool = true
    ) -> SessionHealthInput {
        SessionHealthInput(id: id, status: status, isLive: isLive,
                           activity: activity, lastOutputMs: lastOutputMs, resumable: resumable)
    }

    @Test func liveIdleSessionIsHealthy() {
        #expect(SessionHealth.classify(input(activity: .idle), nowMs: 10_000_000) == .healthy)
    }

    @Test func liveBusySessionWithRecentOutputIsHealthy() {
        // Busy and emitted output just now — a working turn, not a stall.
        let s = input(activity: .busy, lastOutputMs: 9_999_000)
        #expect(SessionHealth.classify(s, nowMs: 10_000_000) == .healthy)
    }

    @Test func exitedSessionIsDead() {
        let s = input(status: .exited, isLive: false, activity: nil)
        #expect(SessionHealth.classify(s, nowMs: 10_000_000) == .dead)
    }

    @Test func runningButNotLiveIsDead() {
        // Store still says running, but the registry lost the pty (onExit never fired).
        let s = input(status: .running, isLive: false, activity: nil)
        #expect(SessionHealth.classify(s, nowMs: 10_000_000) == .dead)
    }

    @Test func busySessionWithNoOutputPastBudgetIsStale() {
        let s = input(activity: .busy, lastOutputMs: 0)
        #expect(SessionHealth.classify(s, nowMs: SessionHealth.defaultStaleBusyMs + 1) == .stale)
    }

    @Test func idleSessionIsNeverStaleNoMatterHowLong() {
        // An idle session waiting for the user is normal, not a fault — even after hours.
        let s = input(activity: .idle, lastOutputMs: 0)
        #expect(SessionHealth.classify(s, nowMs: 24 * 60 * 60 * 1000) == .healthy)
    }

    @Test func waitingInputSessionIsNeverStale() {
        let s = input(activity: .waitingInput, lastOutputMs: 0)
        #expect(SessionHealth.classify(s, nowMs: SessionHealth.defaultStaleBusyMs + 1) == .healthy)
    }

    @Test func staleThresholdIsExactlyInclusive() {
        let s = input(activity: .busy, lastOutputMs: 0)
        #expect(SessionHealth.classify(s, nowMs: SessionHealth.defaultStaleBusyMs - 1) == .healthy)
        #expect(SessionHealth.classify(s, nowMs: SessionHealth.defaultStaleBusyMs) == .stale)
    }

    @Test func sweepReturnsOnlyUnhealthyInInputOrder() {
        let inputs = [
            input(id: "healthy", activity: .idle),
            input(id: "dead", status: .exited, isLive: false, activity: nil, resumable: false),
            input(id: "stale", activity: .busy, lastOutputMs: 0),
        ]
        let reports = SessionHealth.sweep(inputs, nowMs: SessionHealth.defaultStaleBusyMs + 1)
        #expect(reports.map(\.id) == ["dead", "stale"])
        #expect(reports.map(\.state) == [.dead, .stale])
        // resumable is carried through for the UI's reactivate affordance.
        #expect(reports.first(where: { $0.id == "dead" })?.resumable == false)
    }

    @Test func sweepOfAllHealthyIsEmpty() {
        let inputs = [input(id: "a"), input(id: "b", activity: .busy, lastOutputMs: 10_000_000)]
        #expect(SessionHealth.sweep(inputs, nowMs: 10_000_001).isEmpty)
    }

    // MARK: - idleToClose (auto-close idle sessions)

    @Test func idleToCloseSelectsOnlyLiveSessionsPastTheThreshold() {
        let hourMs = 60 * 60 * 1000
        let inputs = [
            input(id: "fresh", lastOutputMs: 10_000_000),                 // recent → keep
            input(id: "idle", lastOutputMs: 10_000_000 - hourMs),         // 1h old → close
            input(id: "dead", isLive: false, lastOutputMs: 0),            // not live → ignore
        ]
        let ids = SessionHealth.idleToClose(inputs, nowMs: 10_000_000, idleMs: hourMs)
        #expect(ids == ["idle"])
    }

    @Test func idleToCloseClosesRegardlessOfActivityWhenSilent() {
        // A long-silent session is closed whether it reads idle or (wedged) busy —
        // freshness of output, not activity, is the gate.
        let inputs = [
            input(id: "busy-silent", activity: .busy, lastOutputMs: 0),
            input(id: "waiting", activity: .waitingInput, lastOutputMs: 0),
        ]
        let ids = SessionHealth.idleToClose(inputs, nowMs: 60 * 60 * 1000, idleMs: 60 * 60 * 1000)
        #expect(ids == ["busy-silent", "waiting"])
    }

    @Test func idleToCloseThresholdIsExactlyInclusive() {
        let s = input(id: "edge", lastOutputMs: 0)
        #expect(SessionHealth.idleToClose([s], nowMs: 999, idleMs: 1000).isEmpty)
        #expect(SessionHealth.idleToClose([s], nowMs: 1000, idleMs: 1000) == ["edge"])
    }

    @Test func idleToCloseDisabledWhenThresholdNotPositive() {
        // 0 (and below) expresses the "Never" setting — nothing is ever closed.
        let s = input(id: "ancient", lastOutputMs: 0)
        #expect(SessionHealth.idleToClose([s], nowMs: 24 * 60 * 60 * 1000, idleMs: 0).isEmpty)
        #expect(SessionHealth.idleToClose([s], nowMs: 24 * 60 * 60 * 1000, idleMs: -1).isEmpty)
    }
}
