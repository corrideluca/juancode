import AppKit
import Darwin
import Foundation
import SwiftTerm

// ---------------------------------------------------------------------------
// juancode Swift spike (juancode-u34.1)
//
// Go/no-go gate for the native macOS port. Proves two things:
//   1. A real `claude`/`codex` binary spawns via forkpty with the user env
//      UNTOUCHED (see PtyProcess — env fidelity is by construction).
//   2. SwiftTerm's engine-level Terminal.feed path renders a stream faithfully
//      when the pty is owned EXTERNALLY — i.e. plain `TerminalView` fed via
//      `feed(byteArray:)`, NOT `LocalProcessTerminalView` (which bundles its own
//      pty and would fight a shared registry).
//
// Usage:  swift run JuancodeSpike [binary] [args...]
//         defaults to `claude`.  e.g.  swift run JuancodeSpike codex
// ---------------------------------------------------------------------------

/// Dump enough of the inherited environment to PROVE we didn't shadow it.
/// Printed to stderr at launch so it shows up in `swift run` logs.
func dumpEnvFidelity() {
    let env = ProcessInfo.processInfo.environment
    let home = env["HOME"] ?? "(unset)"
    FileHandle.standardError.write(Data("""
    ── env fidelity check ──────────────────────────────────────────────
      HOME            = \(home)
      CODEX_HOME      = \(env["CODEX_HOME"] ?? "(unset — good, not shadowed)")
      PATH present    = \(env["PATH"] != nil)
      ~/.claude.json  = \(FileManager.default.fileExists(atPath: home + "/.claude.json"))
      ~/.codex/config.toml = \(FileManager.default.fileExists(atPath: home + "/.codex/config.toml"))
      (the child inherits THIS exact environ via execvp — no envp constructed)
    ─────────────────────────────────────────────────────────────────────

    """.utf8))
}

final class AppDelegate: NSObject, NSApplicationDelegate, TerminalViewDelegate {
    var window: NSWindow!
    var terminalView: TerminalView!
    var pty: PtyProcess?

    func applicationDidFinishLaunching(_ note: Notification) {
        dumpEnvFidelity()

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        terminalView = TerminalView(frame: frame)
        terminalView.terminalDelegate = self

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "juancode spike — claude via forkpty + SwiftTerm.feed"
        window.contentView = terminalView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let term = terminalView.getTerminal()
        let cols = term.cols
        let rows = term.rows

        let argv = Array(CommandLine.arguments.dropFirst())
        let exe = argv.first ?? "claude"
        let extra = Array(argv.dropFirst())

        pty = PtyProcess(
            executable: exe,
            args: extra,
            cols: cols,
            rows: rows,
            onData: { [weak self] bytes in
                // pty read queue -> main: feed the engine. This IS the seam.
                DispatchQueue.main.async {
                    self?.terminalView.feed(byteArray: bytes[...])
                }
            },
            onExit: { [weak self] status in
                DispatchQueue.main.async {
                    let msg = "\r\n[\(exe) exited, status \(status)]\r\n"
                    self?.terminalView.feed(text: msg)
                }
            }
        )

        if pty == nil {
            terminalView.feed(text: "failed to spawn \(exe) via forkpty\r\n")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        pty?.terminate()
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        pty?.write(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        pty?.resize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        window?.title = title.isEmpty ? "juancode spike" : title
    }

    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: TerminalView) { NSSound.beep() }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
