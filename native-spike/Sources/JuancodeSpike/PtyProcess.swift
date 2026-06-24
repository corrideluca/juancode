import Darwin
import Foundation

/// Owns a real pty whose child process is an UNMODIFIED CLI binary (claude/codex).
///
/// The whole point of the spike: the child is spawned with `forkpty` + `execvp`,
/// which inherits the parent process's `environ` *verbatim*. We never construct an
/// envp, never inject a shadow HOME / CODEX_HOME, never override mcpServers — so
/// user-scope MCP (~/.claude.json), connectors, ~/.codex/config.toml and project
/// .mcp.json all resolve exactly as they would in a normal terminal. Env fidelity
/// is therefore true *by construction*, not by careful copying.
///
/// The pty is owned HERE, not by SwiftTerm. Output bytes are handed to `onData`;
/// the caller feeds them into a `TerminalView` via `feed(byteArray:)`. This is the
/// fan-out seam that the real port (juancode-u34.2) will generalise to N subscribers.
final class PtyProcess {
    let masterFd: Int32
    let pid: pid_t
    private let onData: ([UInt8]) -> Void
    private let onExit: (Int32) -> Void
    private var readSource: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "juancode.pty.read")

    init?(executable: String,
          args: [String],
          cols: Int,
          rows: Int,
          onData: @escaping ([UInt8]) -> Void,
          onExit: @escaping (Int32) -> Void) {
        self.onData = onData
        self.onExit = onExit

        var master: Int32 = 0
        var winp = winsize(ws_row: UInt16(rows),
                           ws_col: UInt16(cols),
                           ws_xpixel: 0,
                           ws_ypixel: 0)

        let childPid = forkpty(&master, nil, nil, &winp)
        if childPid < 0 {
            perror("forkpty")
            return nil
        }

        if childPid == 0 {
            // ---- child ----
            // execvp does PATH lookup and inherits the current `environ`. No envp is
            // passed, so the environment is untouched. If exec returns, it failed.
            let argv: [UnsafeMutablePointer<CChar>?] =
                ([executable] + args).map { strdup($0) } + [nil]
            execvp(executable, argv)
            perror("execvp(\(executable))")
            _exit(127)
        }

        // ---- parent ----
        self.masterFd = master
        self.pid = childPid
        startReading()
    }

    private func startReading() {
        let fd = masterFd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                self.onData(Array(buf[0..<n]))
            } else {
                // 0 = EOF, <0 = error (child gone). Reap and report.
                self.readSource?.cancel()
                var status: Int32 = 0
                waitpid(self.pid, &status, WNOHANG)
                self.onExit(status)
            }
        }
        readSource = src
        src.resume()
    }

    /// Keystrokes / paste from the TerminalView -> child stdin.
    func write(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        let data = Array(bytes)
        let fd = masterFd
        readQueue.async {
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    /// Propagate a view resize into the pty so the CLI re-lays out its TUI.
    func resize(cols: Int, rows: Int) {
        var ws = winsize(ws_row: UInt16(rows),
                         ws_col: UInt16(cols),
                         ws_xpixel: 0,
                         ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &ws)
    }

    func terminate() {
        kill(pid, SIGTERM)
        readSource?.cancel()
    }
}
