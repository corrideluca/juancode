import Testing
import Foundation
@testable import JuancodeCore

/// Layout-transition gate (juancode-1th.2): panel toggles mark a transition so
/// the terminal coordinators hold intermediate grid pushes and settle once.
@Suite struct LayoutTransitionGateTests {
    @Test func inactiveByDefault() {
        #expect(LayoutTransitionGate().active == false)
    }

    @Test func activeWithinTheWindow() {
        let g = LayoutTransitionGate()
        g.begin(for: .milliseconds(500))
        #expect(g.active == true)
    }

    @Test func expiresAfterTheWindow() async throws {
        let g = LayoutTransitionGate()
        g.begin(for: .milliseconds(30))
        try await Task.sleep(for: .milliseconds(90))
        #expect(g.active == false)
    }

    @Test func laterBeginNeverShortensTheWindow() async throws {
        let g = LayoutTransitionGate()
        g.begin(for: .milliseconds(400))
        // A nested shorter transition (e.g. a divider commit during a fullscreen
        // animation) must not cut the longer window short.
        g.begin(for: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(60))
        #expect(g.active == true)
    }
}
