import XCTest
import JuancodeCore
@testable import JuancodeServices

/// Port of `apps/server/src/review.test.ts`.
final class ReviewTests: XCTestCase {

    // MARK: - fixtures (mirror the TS `file` / `comment` / `envelope` helpers)

    private func file(
        path: String = "src/a.ts",
        oldPath: String? = nil,
        status: FileStatus = .modified,
        additions: Int = 1,
        deletions: Int = 0,
        binary: Bool = false,
        diff: String = "@@ -0,0 +1 @@\n+const x = 1;\n",
        truncated: Bool = false
    ) -> DiffFile {
        DiffFile(path: path, oldPath: oldPath, status: status, additions: additions,
                 deletions: deletions, binary: binary, diff: diff, truncated: truncated)
    }

    private func comment(
        id: String = "c1",
        sessionId: String = "s1",
        file: String = "src/a.ts",
        side: CommentSide = .new,
        line: Int = 1,
        endLine: Int = 1,
        body: String = "is this right?",
        createdAt: Int = 0
    ) -> DiffComment {
        DiffComment(id: id, sessionId: sessionId, file: file, side: side, line: line,
                    endLine: endLine, body: body, createdAt: createdAt)
    }

    /// Wrap a structured payload the way `claude -p --output-format json` does:
    /// the `result` field is the schema JSON encoded as a *string*.
    private func envelope(_ result: Any, _ over: [String: Any] = [:]) -> String {
        let resultData = try! JSONSerialization.data(withJSONObject: result, options: [])
        var obj: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": String(decoding: resultData, as: UTF8.self),
        ]
        for (k, v) in over { obj[k] = v }
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - buildPrompt

    func testBuildPromptIncludesEachFilesDiffAndStats() {
        let prompt = buildPrompt([file()], [])
        XCTAssertTrue(prompt.contains("src/a.ts"))
        XCTAssertTrue(prompt.contains("+const x = 1;"))
        XCTAssertTrue(prompt.contains("(modified, +1 −0)"))
    }

    func testBuildPromptSurfacesHumanInlineComments() {
        let prompt = buildPrompt([file()], [comment()])
        XCTAssertTrue(prompt.contains("inline comments"))
        XCTAssertTrue(prompt.contains("src/a.ts:1 (new) — is this right?"))
    }

    func testBuildPromptNotesBinaryAndTruncatedFiles() {
        let prompt = buildPrompt(
            [file(binary: true, diff: ""), file(path: "b", diff: "", truncated: true)],
            []
        )
        XCTAssertTrue(prompt.contains("binary file"))
        XCTAssertTrue(prompt.contains("diff too large"))
    }

    func testBuildPromptCapsAnEnormousDiff() {
        let huge = file(diff: String(repeating: "+x\n", count: 200_000))
        let prompt = buildPrompt([huge], [])
        XCTAssertTrue(prompt.contains("[diff truncated for length"))
        XCTAssertLessThan(prompt.count, 210_000)
    }

    // MARK: - parseReviewOutput

    func testParseReviewOutputParsesValidatedFindingsAndSummary() {
        let out = parseReviewOutput(
            envelope([
                "summary": "One issue found.",
                "findings": [
                    ["file": "src/a.ts", "side": "new", "line": 1, "severity": "high", "title": "Bug", "note": "Off by one."],
                ],
            ]),
            5
        )
        XCTAssertEqual(out.status, .ok)
        XCTAssertEqual(out.summary, "One issue found.")
        XCTAssertEqual(out.createdAt, 5)
        XCTAssertEqual(out.findings, [
            ReviewFinding(file: "src/a.ts", side: .new, line: 1, severity: .high, title: "Bug", note: "Off by one."),
        ])
    }

    func testParseReviewOutputNormalizesBadFieldsAndDropsEmpty() {
        let out = parseReviewOutput(
            envelope([
                "summary": 42, // not a string → null
                "findings": [
                    ["file": "a", "side": "weird", "line": "x", "severity": "nope", "title": "", "note": "kept"],
                    ["file": "", "side": "new", "line": 1, "severity": "low", "title": "x", "note": "y"], // no file → dropped
                    ["file": "b", "side": "old", "line": 2, "severity": "low", "title": "", "note": ""], // empty → dropped
                ],
            ]),
            0
        )
        XCTAssertNil(out.summary)
        XCTAssertEqual(out.findings, [
            ReviewFinding(file: "a", side: .new, line: nil, severity: .info, title: "", note: "kept"),
        ])
    }

    func testParseReviewOutputReportsCliLevelErrors() {
        // is_error true + a plain (non-schema) result string → error result.
        let stdout = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"result\":\"Credit balance is too low\"}"
        let out = parseReviewOutput(stdout, 0)
        XCTAssertEqual(out.status, .error)
        XCTAssertEqual(out.error, "Credit balance is too low")
    }

    func testParseReviewOutputErrorsOnUnparseableStdout() {
        XCTAssertEqual(parseReviewOutput("not json", 0).status, .error)
    }

    func testParseReviewOutputFallsBackToProseSummary() {
        let stdout = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"Looks fine to me.\"}"
        let out = parseReviewOutput(stdout, 0)
        XCTAssertEqual(out.status, .ok)
        XCTAssertEqual(out.summary, "Looks fine to me.")
        XCTAssertEqual(out.findings, [])
    }

    // MARK: - runReview

    func testRunReviewShortCircuitsToEmptyWithNoFiles() async {
        // Never spawns the CLI — uses a resolver that would fail if invoked.
        let out = await runReview(cwd: "/tmp", files: [], comments: [], now: 7,
                                  resolver: ExplodingResolver())
        XCTAssertEqual(out, ReviewResult(status: .empty, findings: [], summary: nil, createdAt: 7))
    }

    /// Extra (beyond TS): exercise the genuine claude invocation path by pointing
    /// the resolver at a throwaway shell script that echoes a canned JSON envelope,
    /// the same way the TS would stub the binary via a path override. Confirms the
    /// prompt is fed and the envelope round-trips through `parseReviewOutput`.
    func testRunReviewInvokesResolvedClaudeAndParsesOutput() async throws {
        let payload = envelope([
            "summary": "One issue found.",
            "findings": [
                ["file": "src/a.ts", "side": "new", "line": 1, "severity": "high", "title": "Bug", "note": "Off by one."],
            ],
        ])
        let script = try makeStubScript(stdout: payload, exitCode: 0)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let out = await runReview(cwd: NSTemporaryDirectory(), files: [file()], comments: [],
                                  now: 9, resolver: FixedResolver(path: script))
        XCTAssertEqual(out.status, .ok)
        XCTAssertEqual(out.summary, "One issue found.")
        XCTAssertEqual(out.createdAt, 9)
        XCTAssertEqual(out.findings, [
            ReviewFinding(file: "src/a.ts", side: .new, line: 1, severity: .high, title: "Bug", note: "Off by one."),
        ])
    }

    /// Extra: a non-zero exit with empty stdout surfaces stderr as the error,
    /// matching `runClaude`'s fallback (`stderr.trim() || claude exited ...`).
    func testRunReviewErrorsWhenCliFailsWithNoStdout() async throws {
        let script = try makeStubScript(stdout: "", stderr: "boom", exitCode: 1)
        defer { try? FileManager.default.removeItem(atPath: script) }

        let out = await runReview(cwd: NSTemporaryDirectory(), files: [file()], comments: [],
                                  now: 0, resolver: FixedResolver(path: script))
        XCTAssertEqual(out.status, .error)
        XCTAssertEqual(out.error, "boom")
    }

    // MARK: - helpers

    /// A resolver that returns a fixed absolute path (our stub script).
    private struct FixedResolver: BinaryResolver {
        let path: String
        func command(for provider: ProviderId) -> String { path }
    }

    /// A resolver that must never be called (guards the no-spawn short-circuit).
    private struct ExplodingResolver: BinaryResolver {
        func command(for provider: ProviderId) -> String {
            XCTFail("resolver should not be invoked when there are no files")
            return "/bin/false"
        }
    }

    /// Write an executable shell stub that emits the given streams and exit code,
    /// standing in for the real `claude` binary.
    private func makeStubScript(stdout: String, stderr: String = "", exitCode: Int32) throws -> String {
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("claude-stub-\(UUID().uuidString).sh")
        // Drain stdin so the prompt write doesn't EPIPE, then echo canned output.
        let body = """
        #!/bin/sh
        cat > /dev/null
        printf '%s' \(shellQuote(stdout))
        printf '%s' \(shellQuote(stderr)) 1>&2
        exit \(exitCode)
        """
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// Single-quote a string for safe embedding in the /bin/sh stub.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
