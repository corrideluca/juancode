import Foundation
import JuancodeCore

// Headless smoke test for the u34.2 core: spawn the REAL claude/codex through
// SessionRegistry + DefaultBinaryResolver and prove bytes flow + env is intact.
//
//   swift run juancode-smoke [claude|codex] [seconds]
//
// Prints a summary to stderr. Exits non-zero if nothing spawned / no output.

let args = Array(CommandLine.arguments.dropFirst())
let provider: ProviderId = (args.first.flatMap(ProviderId.init(rawValue:))) ?? .claude
let seconds = Double(args.dropFirst().first ?? "") ?? 3.0
let cwd = FileManager.default.currentDirectoryPath

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

let registry = SessionRegistry()
let session: Session
do {
    session = try registry.create(provider: provider, cwd: cwd, cols: 100, rows: 30)
} catch {
    log("✗ failed to create session: \(error)")
    exit(1)
}

let byteCount = NSLock()
var total = 0
session.subscribeOutput { bytes in byteCount.withLock { total += bytes.count } }

log("spawned \(provider.rawValue) pid via core, session \(session.id)")
Thread.sleep(forTimeInterval: seconds)

let scroll = session.getScrollback().count
let bytes = byteCount.withLock { total }
log("── core smoke summary ──")
log("  scrollback bytes : \(scroll)")
log("  fan-out bytes    : \(bytes)")
log("  activity         : \(session.activity.rawValue)")
log("  cliSessionId     : \(session.meta.cliSessionId ?? "(none)")")
// Env fidelity is by construction (forkpty + execvp inherit environ — see
// PtyProcess); the u34.1 spike verified the child's HOME/PATH via `ps eww`.
log("  process HOME     : \(ProcessInfo.processInfo.environment["HOME"] ?? "(unset)")")

session.kill()
Thread.sleep(forTimeInterval: 0.3)

if scroll > 0 && bytes > 0 {
    log("✓ core spawned the real CLI and streamed output")
    exit(0)
} else {
    log("✗ no output captured")
    exit(2)
}
