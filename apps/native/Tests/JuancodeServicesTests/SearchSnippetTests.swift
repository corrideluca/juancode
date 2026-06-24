import XCTest
@testable import JuancodeServices

/// Unit tests for the pure search-snippet marker parser backing the native
/// SearchPanel (juancode-wx9). The store's FTS `snippet()` wraps matched terms in
/// square brackets; `parseSearchSnippet` splits those into plain/highlighted runs.
final class SearchSnippetTests: XCTestCase {

    func testPlainTextHasNoHighlights() {
        XCTAssertEqual(
            parseSearchSnippet("nothing to mark here"),
            [SnippetRun(text: "nothing to mark here", highlighted: false)])
    }

    func testEmptyStringYieldsNoRuns() {
        XCTAssertEqual(parseSearchSnippet(""), [])
    }

    func testSingleMarkerInMiddle() {
        XCTAssertEqual(
            parseSearchSnippet("fixed the [bug] today"),
            [
                SnippetRun(text: "fixed the ", highlighted: false),
                SnippetRun(text: "bug", highlighted: true),
                SnippetRun(text: " today", highlighted: false),
            ])
    }

    func testMultipleMarkers() {
        XCTAssertEqual(
            parseSearchSnippet("[parse] the [diff] now"),
            [
                SnippetRun(text: "parse", highlighted: true),
                SnippetRun(text: " the ", highlighted: false),
                SnippetRun(text: "diff", highlighted: true),
                SnippetRun(text: " now", highlighted: false),
            ])
    }

    func testEllipsisAroundMarkersIsPlain() {
        // Mirrors the store's snippet() ellipsis sentinel '…'.
        XCTAssertEqual(
            parseSearchSnippet("…wrote a [test]…"),
            [
                SnippetRun(text: "…wrote a ", highlighted: false),
                SnippetRun(text: "test", highlighted: true),
                SnippetRun(text: "…", highlighted: false),
            ])
    }

    func testEmptyMarkerProducesEmptyHighlight() {
        XCTAssertEqual(
            parseSearchSnippet("a[]b"),
            [
                SnippetRun(text: "a", highlighted: false),
                SnippetRun(text: "", highlighted: true),
                SnippetRun(text: "b", highlighted: false),
            ])
    }

    func testUnmatchedOpenBracketIsLiteral() {
        // A '[' with no closing ']' stays plain text (matches the web regex).
        XCTAssertEqual(
            parseSearchSnippet("array[0] index"),
            [
                SnippetRun(text: "array", highlighted: false),
                SnippetRun(text: "0", highlighted: true),
                SnippetRun(text: " index", highlighted: false),
            ])
    }

    func testTrailingUnclosedBracketIsLiteral() {
        XCTAssertEqual(
            parseSearchSnippet("dangling ["),
            [SnippetRun(text: "dangling [", highlighted: false)])
    }
}
