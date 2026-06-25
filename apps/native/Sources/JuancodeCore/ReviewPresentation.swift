import Foundation

/// Pure presentation helpers for the 'Review with Claude' overlay (juancode-7ha).
/// Kept in JuancodeCore (SwiftUI-free) so they are unit-testable without a view
/// layer — the color/label mapping that needs SwiftUI lives in the view (mirroring
/// how `VimSyntaxPalette` keeps `Color` out of the pure tokenizer).
///
/// Mirrors the web `ChangesPanel`'s `findingsByFile` grouping and the relative
/// ordering implied by `SEVERITY_STYLE` (critical → info).

extension ReviewSeverity {
    /// Rank used to order findings most-severe first. Mirrors the `SEVERITIES`
    /// array order in `Review.swift` / the web's `SEVERITY_STYLE` key order.
    public var rank: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        case .info: return 4
        }
    }
}

public enum ReviewPresentation {
    /// Group a review's findings by their `file` path, preserving first-seen file
    /// order. Mirrors the web `findingsByFile` `useMemo`.
    public static func findingsByFile(_ findings: [ReviewFinding]) -> [String: [ReviewFinding]] {
        var map: [String: [ReviewFinding]] = [:]
        for f in findings {
            map[f.file, default: []].append(f)
        }
        return map
    }

    /// The findings for one file path (empty when none) — the per-file slice the
    /// diff viewer overlays. Convenience over `findingsByFile` when only one file
    /// is needed.
    public static func findings(for path: String, in findings: [ReviewFinding]) -> [ReviewFinding] {
        findings.filter { $0.file == path }
    }
}
