import Foundation
import JuancodeCore

/// Draft a commit message for a working-tree diff by running the genuine `claude`
/// CLI in headless print mode — same fidelity as 'Review with Claude' (real env,
/// no shadow HOME, nothing overridden). Plain-text output, no JSON schema: the
/// model's reply *is* the message.
///
/// Ported faithfully from `apps/server/src/commit.ts`. The shell-out goes through
/// `ProcessRunner` (environment inherited verbatim — the prime directive). The
/// `claude` binary is resolved like the user's login shell would, honouring
/// `JUANCODE_CLAUDE_BIN` (the same `PROVIDERS.claude.command` resolution the TS used).

private let MAX_PROMPT_BYTES = 100_000

private let TIMEOUT_MS = 120_000

private let MAX_BUFFER = 8 * 1024 * 1024

private let SYSTEM_PROMPT =
    "You write a single git commit message for the given working-tree diff. " +
    "Use Conventional Commits style for the subject (e.g. 'feat: …', 'fix: …'), " +
    "imperative mood, ideally under 72 characters. Add a short body (blank line, then " +
    "concise bullet points) only when it genuinely clarifies the change. " +
    "Respond with ONLY the raw commit message — no code fences, no surrounding quotes, no preamble."

/// A clean, message-bearing error for commit-message generation failures.
public struct CommitMessageError: Error, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Compact the diff into a prompt, capping size so a huge change set is bounded.
func buildDiffPrompt(_ files: [DiffFile]) -> String {
    var parts: [String] = ["Write a commit message for these changes.\n"]
    for f in files {
        let header = (f.oldPath != nil && !(f.oldPath!.isEmpty))
            ? "\(f.oldPath!) → \(f.path)"
            : f.path
        parts.append("### \(header) (\(f.status.rawValue), +\(f.additions) −\(f.deletions))")
        if f.binary {
            parts.append("(binary file)")
        } else if f.truncated {
            parts.append("(diff too large — omitted)")
        } else if !f.diff.isEmpty {
            parts.append("```diff\n" + f.diff + "\n```")
        }
        parts.append("")
    }
    var prompt = parts.joined(separator: "\n")
    // TS uses `prompt.length` (UTF-16 code units in JS). Match that so the cap
    // triggers at the same point, then slice the same number of code units.
    if prompt.utf16.count > MAX_PROMPT_BYTES {
        let ns = prompt as NSString
        prompt = ns.substring(to: MAX_PROMPT_BYTES) + "\n\n[diff truncated for length]"
    }
    return prompt
}

/// Strip any code fences / wrapping quotes the model may add around the message.
/// Mirrors the TS: trim, drop a leading ```lang fence, drop a trailing ``` fence, trim.
func cleanMessage(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // .replace(/^```[a-zA-Z]*\n?/, "")
    s = replaceFirst(s, pattern: "^```[a-zA-Z]*\\n?", with: "")
    // .replace(/\n?```$/, "")
    s = replaceFirst(s, pattern: "\\n?```$", with: "")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

public func generateCommitMessage(_ cwd: String, _ files: [DiffFile]) async throws -> String {
    if files.isEmpty { throw CommitMessageError("No changes to describe.") }
    // Resolve `claude` the same way the TS `PROVIDERS.claude.command` did.
    let command = resolveBin("claude", override: ProcessInfo.processInfo.environment["JUANCODE_CLAUDE_BIN"])
    let prompt = buildDiffPrompt(files)

    // The TS spawns `claude -p --append-system-prompt <SYSTEM_PROMPT>`, writes the
    // prompt to stdin, with a 120s timeout and an 8 MiB output cap; on close it
    // resolves with stdout if non-empty, else rejects with stderr (or an exit-code
    // message). ProcessRunner.capture mirrors all of that: stdin forwarding,
    // timeout (throws timedOut), maxBytes cap, and a result for any exit code.
    let result: ProcessResult
    do {
        result = try await ProcessRunner.capture(
            command,
            ["-p", "--append-system-prompt", SYSTEM_PROMPT],
            cwd: cwd,
            timeout: TimeInterval(TIMEOUT_MS) / 1000,
            stdin: prompt,
            maxBytes: MAX_BUFFER)
    } catch let e as ProcessError {
        // capture throws only on launch-failure or timeout.
        if e.timedOut { throw CommitMessageError("Commit-message generation timed out.") }
        // Launch failure ≈ the child `error` event in TS, which rejects with `e`.
        throw CommitMessageError(e.message)
    }

    // TS close handler: if stdout has any non-whitespace content, resolve with the
    // raw stdout (even on a non-zero exit); otherwise reject with trimmed stderr,
    // or `claude exited with code <code>` when stderr is empty too.
    let stdout: String
    if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        stdout = result.stdout
    } else {
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommitMessageError(err.isEmpty ? "claude exited with code \(result.exitCode)" : err)
    }

    let message = cleanMessage(stdout)
    if message.isEmpty { throw CommitMessageError("Empty commit message.") }
    return message
}

// MARK: - small regex helper (mirroring the TS String.replace calls)

/// Replace the first match of `pattern` in `s` with `replacement`, mirroring
/// JS `String.replace(regexp, replacement)` for a non-global regex.
private func replaceFirst(_ s: String, pattern: String, with replacement: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
    let ns = s as NSString
    guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else {
        return s
    }
    return ns.replacingCharacters(in: m.range, with: replacement)
}
