import Foundation
import JuancodeCore

/// Pure unified-diff parsing for the native ChangesPanel — the SwiftUI analogue of
/// the web's `react-diff-view` `parseDiff` + change-key machinery. Given the raw
/// per-file unified diff that `getDiff` already produces, it yields hunks of typed
/// lines, each carrying its old/new line numbers and a stable anchor (side+line)
/// so inline comments can attach to a line on either side. No git here — this is
/// string parsing only, which is why it lives in its own unit-tested module.

/// One line within a parsed diff hunk.
public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context   // unchanged line present on both sides
        case insert    // added line (new side only)
        case delete    // removed line (old side only)
    }
    public let kind: Kind
    /// 1-based line number on the old side, or nil for inserts.
    public let oldLine: Int?
    /// 1-based line number on the new side, or nil for deletes.
    public let newLine: Int?
    /// The line content without its leading +/-/space marker.
    public let text: String

    public init(kind: Kind, oldLine: Int?, newLine: Int?, text: String) {
        self.kind = kind; self.oldLine = oldLine; self.newLine = newLine; self.text = text
    }

    /// The side+line a comment anchors to: the new line for inserts/context, else
    /// the old line for deletes. Mirrors the web `anchorOf`.
    public var anchor: (side: CommentSide, line: Int)? {
        if let n = newLine { return (.new, n) }
        if let o = oldLine { return (.old, o) }
        return nil
    }
}

/// A single `@@ … @@` hunk: its header text plus the lines it contains.
public struct DiffHunk: Sendable, Equatable {
    public let header: String
    public let lines: [DiffLine]
    public init(header: String, lines: [DiffLine]) {
        self.header = header; self.lines = lines
    }
}

/// Parse a file's unified diff into hunks. Lines outside any hunk (the `diff --git`,
/// `index`, `---`/`+++` file headers) are skipped. Tolerant of a trailing
/// "\ No newline at end of file" marker. Returns `[]` when there are no hunks.
public func parseUnifiedDiff(_ diff: String) -> [DiffHunk] {
    guard !diff.isEmpty else { return [] }
    var hunks: [DiffHunk] = []
    var header: String? = nil
    var lines: [DiffLine] = []
    var oldNo = 0
    var newNo = 0

    func flush() {
        if let h = header { hunks.append(DiffHunk(header: h, lines: lines)) }
        header = nil
        lines = []
    }

    for raw in diff.components(separatedBy: "\n") {
        if raw.hasPrefix("@@") {
            flush()
            header = raw
            let (o, n) = parseHunkStarts(raw)
            oldNo = o
            newNo = n
            continue
        }
        guard header != nil else { continue } // pre-hunk file headers
        if raw.hasPrefix("\\") { continue }    // "\ No newline at end of file"
        let marker = raw.first
        let body = raw.isEmpty ? "" : String(raw.dropFirst())
        switch marker {
        case "+":
            lines.append(DiffLine(kind: .insert, oldLine: nil, newLine: newNo, text: body))
            newNo += 1
        case "-":
            lines.append(DiffLine(kind: .delete, oldLine: oldNo, newLine: nil, text: body))
            oldNo += 1
        case " ":
            lines.append(DiffLine(kind: .context, oldLine: oldNo, newLine: newNo, text: body))
            oldNo += 1
            newNo += 1
        default:
            // A blank line inside a hunk is an empty context line ("" with no marker).
            if raw.isEmpty {
                lines.append(DiffLine(kind: .context, oldLine: oldNo, newLine: newNo, text: ""))
                oldNo += 1
                newNo += 1
            }
            // Anything else (e.g. a stray header line) is ignored.
        }
    }
    flush()
    return hunks
}

/// Extract the old/new starting line numbers from a `@@ -a,b +c,d @@` header.
/// Defaults the counts to line 1 when a hunk omits them (`@@ -a +c @@`).
private func parseHunkStarts(_ header: String) -> (old: Int, new: Int) {
    // Find the "-" and "+" groups between the leading and trailing "@@".
    var old = 1
    var new = 1
    let tokens = header.split(separator: " ")
    for t in tokens {
        if t.hasPrefix("-") {
            old = Int(t.dropFirst().split(separator: ",").first ?? "1") ?? 1
        } else if t.hasPrefix("+") {
            new = Int(t.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
    }
    return (old, new)
}

/// A human label for a comment's anchored range, e.g. "L10" or "L10–14 (old)".
/// Mirrors the web `rangeLabel`.
public func commentRangeLabel(side: CommentSide, line: Int, endLine: Int) -> String {
    let lines = line == endLine ? "L\(line)" : "L\(line)–\(endLine)"
    return side == .old ? "\(lines) (old)" : lines
}

/// Compose every pending comment (+ an optional closing note) into one prompt for
/// the agent, grouped by file in diff order. Mirrors the web `composeReviewPrompt`
/// so the native "submit review" injects the same text the web pastes into the pty.
public func composeReviewPrompt(files: [DiffFile], comments: [DiffComment], finalNote: String) -> String {
    var byFile: [String: [DiffComment]] = [:]
    var fileOrder: [String] = []
    for c in comments {
        if byFile[c.file] == nil { byFile[c.file] = []; fileOrder.append(c.file) }
        byFile[c.file]?.append(c)
    }
    var out: [String] = ["Here are my review comments on the current working-tree changes:", ""]
    // Walk files in diff order, then any commented files not in the current diff.
    var order = files.map(\.path)
    order.append(contentsOf: fileOrder)
    var seen = Set<String>()
    for path in order {
        if seen.contains(path) { continue }
        seen.insert(path)
        guard let list = byFile[path], !list.isEmpty else { continue }
        out.append("### \(path)")
        for c in list.sorted(by: { $0.line < $1.line }) {
            // Indent any continuation lines so multi-line bodies stay under the bullet.
            let body = c.body.replacingOccurrences(of: "\n", with: "\n  ")
            out.append("- \(commentRangeLabel(side: c.side, line: c.line, endLine: c.endLine)): \(body)")
        }
        out.append("")
    }
    let note = finalNote.trimmingCharacters(in: .whitespacesAndNewlines)
    if !note.isEmpty { out.append(note) }
    // .trimEnd() — drop trailing whitespace/newlines.
    return out.joined(separator: "\n").replacingOccurrences(
        of: "\\s+$", with: "", options: .regularExpression)
}
