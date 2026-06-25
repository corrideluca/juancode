import Testing
@testable import JuancodeCore

/// Covers the pure presentation helpers backing the native 'Review with Claude'
/// overlay (juancode-7ha): grouping findings by file, the per-file slice, and the
/// severity ordering rank.
@Suite struct ReviewPresentationTests {
    private func finding(_ file: String, line: Int? = 1, side: CommentSide = .new,
                         severity: ReviewSeverity = .info) -> ReviewFinding {
        ReviewFinding(file: file, side: side, line: line, severity: severity,
                      title: "t", note: "n")
    }

    @Test func findingsByFileGroupsAndKeepsOrder() {
        let findings = [
            finding("a.swift", line: 1),
            finding("b.swift", line: 2),
            finding("a.swift", line: 3),
        ]
        let grouped = ReviewPresentation.findingsByFile(findings)
        #expect(grouped["a.swift"]?.map(\.line) == [1, 3])
        #expect(grouped["b.swift"]?.map(\.line) == [2])
        #expect(grouped["c.swift"] == nil)
    }

    @Test func findingsForPathFiltersByFile() {
        let findings = [finding("a.swift"), finding("b.swift"), finding("a.swift")]
        #expect(ReviewPresentation.findings(for: "a.swift", in: findings).count == 2)
        #expect(ReviewPresentation.findings(for: "missing", in: findings).isEmpty)
    }

    @Test func severityRankOrdersMostSevereFirst() {
        let ranks = [ReviewSeverity.critical, .high, .medium, .low, .info].map(\.rank)
        #expect(ranks == [0, 1, 2, 3, 4])
    }
}
