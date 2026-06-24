import Foundation

/// Pure parsing of a full-text-search snippet for the native SearchPanel — the
/// SwiftUI analogue of the web `renderSnippet`. The store's FTS `snippet()` wraps
/// each matched term in square brackets (e.g. `…fixed the [bug] in [parse]…`);
/// here we split the string into plain and highlighted runs so the view can
/// emphasise the matched terms. No I/O — string parsing only, which is why it
/// lives in its own unit-tested module.

/// One contiguous run of a search snippet: plain text or a highlighted match.
public struct SnippetRun: Sendable, Equatable {
    public let text: String
    public let highlighted: Bool

    public init(text: String, highlighted: Bool) {
        self.text = text
        self.highlighted = highlighted
    }
}

/// Split `snippet` into runs, turning the store's `[term]` markers into
/// `highlighted` runs and leaving everything else as plain text. Mirrors the web
/// regex `/\[([^\]]*)\]/g`: a `[`…`]` pair (no nested `]`) becomes a highlight of
/// its inner text; an unmatched `[` is treated as literal plain text.
public func parseSearchSnippet(_ snippet: String) -> [SnippetRun] {
    var runs: [SnippetRun] = []
    var plain = ""

    func flushPlain() {
        if !plain.isEmpty {
            runs.append(SnippetRun(text: plain, highlighted: false))
            plain = ""
        }
    }

    let chars = Array(snippet)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "[", let close = chars[(i + 1)...].firstIndex(of: "]") {
            // [term] → highlighted run of the inner text (which may be empty).
            flushPlain()
            let inner = String(chars[(i + 1)..<close])
            runs.append(SnippetRun(text: inner, highlighted: true))
            i = close + 1
        } else {
            plain.append(c)
            i += 1
        }
    }
    flushPlain()
    return runs
}
