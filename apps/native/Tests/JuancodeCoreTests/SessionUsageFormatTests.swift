import XCTest
@testable import JuancodeCore

final class SessionUsageFormatTests: XCTestCase {
    // MARK: - tokens (mirrors web formatTokens)

    func testTokenFormatting() {
        XCTAssertEqual(SessionUsageFormat.tokens(0), "0")
        XCTAssertEqual(SessionUsageFormat.tokens(980), "980")
        XCTAssertEqual(SessionUsageFormat.tokens(999), "999")
        XCTAssertEqual(SessionUsageFormat.tokens(1000), "1.0k")
        XCTAssertEqual(SessionUsageFormat.tokens(12_400), "12k")
        XCTAssertEqual(SessionUsageFormat.tokens(9_999), "10.0k")
        XCTAssertEqual(SessionUsageFormat.tokens(3_200_000), "3.2M")
    }

    // MARK: - cost (mirrors web formatCost)

    func testCostFormatting() {
        XCTAssertNil(SessionUsageFormat.cost(nil))
        XCTAssertEqual(SessionUsageFormat.cost(0), "$0.00")
        XCTAssertEqual(SessionUsageFormat.cost(0.004), "<$0.01")
        XCTAssertEqual(SessionUsageFormat.cost(0.42), "$0.42")
        XCTAssertEqual(SessionUsageFormat.cost(12.5), "$12.50")
    }

    // MARK: - badgeLabel

    func testBadgeLabelHidesWhenZeroTokens() {
        let u = SessionUsage(
            inputTokens: 0, outputTokens: 0, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 0, costUsd: nil)
        XCTAssertNil(u.badgeLabel)
    }

    func testBadgeLabelWithCost() {
        let u = SessionUsage(
            inputTokens: 1000, outputTokens: 200, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 12_400, costUsd: 0.42)
        XCTAssertEqual(u.badgeLabel, "12k tok · $0.42")
    }

    func testBadgeLabelWithoutCost() {
        let u = SessionUsage(
            inputTokens: 5, outputTokens: 5, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 10, costUsd: nil)
        XCTAssertEqual(u.badgeLabel, "10 tok")
    }

    // MARK: - aggregateUsage (mirrors web aggregateUsage)

    private func meta(_ id: String, _ usage: SessionUsage?) -> SessionMeta {
        SessionMeta(
            id: id, provider: .claude, cwd: "/x", title: id,
            status: .running, exitCode: nil, createdAt: 0, updatedAt: 0,
            cliSessionId: nil, skipPermissions: false, worktreePath: nil,
            usage: usage)
    }

    func testAggregateReturnsNilWhenNoUsage() {
        XCTAssertNil([meta("a", nil), meta("b", nil)].aggregateUsage())
        XCTAssertNil([SessionMeta]().aggregateUsage())
    }

    func testAggregateSumsTokensAndMixesCost() {
        let priced = SessionUsage(
            inputTokens: 100, outputTokens: 50, cacheReadTokens: 10,
            cacheWriteTokens: 5, totalTokens: 165, costUsd: 0.25)
        let unpriced = SessionUsage(
            inputTokens: 200, outputTokens: 60, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 260, costUsd: nil)
        let agg = [meta("a", priced), meta("b", unpriced), meta("c", nil)]
            .aggregateUsage()!
        XCTAssertEqual(agg.inputTokens, 300)
        XCTAssertEqual(agg.outputTokens, 110)
        XCTAssertEqual(agg.cacheReadTokens, 10)
        XCTAssertEqual(agg.cacheWriteTokens, 5)
        XCTAssertEqual(agg.totalTokens, 425)
        // Partial cost: only the priced session contributes.
        XCTAssertEqual(agg.costUsd!, 0.25, accuracy: 1e-9)
    }

    func testAggregateCostNilWhenNoneePriced() {
        let unpriced = SessionUsage(
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheWriteTokens: 0, totalTokens: 2, costUsd: nil)
        let agg = [meta("a", unpriced)].aggregateUsage()!
        XCTAssertEqual(agg.totalTokens, 2)
        XCTAssertNil(agg.costUsd)
    }
}
