import SwiftUI
import AppKit
import SwiftTerm
import JuancodeCore

/// SwiftUI wrapper around SwiftTerm's `TerminalView`, driven by a live `Session`.
/// The view is an in-process subscriber to the session's pty fan-out (replaying
/// scrollback on attach), and routes keystrokes/resize straight back to the pty —
/// no WebSocket hop. Mirrors what the React `Terminal` component does over WS.
struct SwiftTermLive: NSViewRepresentable {
    let session: Session

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(to: tv)
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: Session
        private weak var view: TerminalView?
        private var cancel: (() -> Void)?

        init(session: Session) { self.session = session }

        func attach(to tv: TerminalView) {
            view = tv
            // Replay scrollback, then stream live output. Feed must happen on the
            // main thread (AppKit); the pty callback arrives on a background queue.
            cancel = session.subscribeOutput(replay: true) { [weak tv] bytes in
                DispatchQueue.main.async { tv?.feed(byteArray: bytes[...]) }
            }
        }

        func detach() {
            cancel?()
            cancel = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.write(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { NSWorkspace.shared.open(url) }
        }
        func bell(source: TerminalView) { NSSound.beep() }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// Read-only terminal for an EXITED session: replays persisted scrollback so the
/// conversation history is visible, with no live pty behind it.
struct SwiftTermReplay: NSViewRepresentable {
    let scrollback: [UInt8]

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        if !scrollback.isEmpty { tv.feed(byteArray: scrollback[...]) }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
