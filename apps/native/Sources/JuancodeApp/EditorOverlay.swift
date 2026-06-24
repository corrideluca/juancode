import SwiftUI
import AppKit
import SwiftTerm
import JuancodeServices

/// SwiftUI port of the web `EditorModal`. A terminal overlay that opens ONE file in
/// the user's real editor (`$VISUAL`/`$EDITOR`, default nvim) through an ephemeral
/// pty, so the file is edited with the genuine editor config (plugins, colors,
/// tree-sitter). On the editor exiting (e.g. `:q`) the overlay dismisses and the
/// caller refetches the diff; the pty is killed on dismiss if still alive.
///
/// Lifecycle: the pty is spawned by `AppModel.openEditor` BEFORE this view appears
/// (so the binding is non-optional and never races the handshake), handed in here,
/// rendered by `SwiftTermEphemeral`, and torn down by `onExit`/`onDisappear`.
struct EditorOverlay: View {
    let file: String
    let pty: EphemeralPty
    /// Called (on the main actor) once the editor pty has exited, so the overlay
    /// should dismiss. `@Sendable` because the pty's exit fires off the main thread.
    let onExit: @Sendable () -> Void
    /// User-initiated force close (kills the pty, discarding an unsaved buffer).
    let onForceClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Editing").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(file)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(":q in the editor to close")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Button("Force close", action: onForceClose)
                    .controlSize(.small)
                    .help("Force close (discards an unsaved buffer)")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            SwiftTermEphemeral(pty: pty, onExit: onExit)
                .background(Color.black)
        }
        .frame(minWidth: 640, minHeight: 420)
    }
}

/// SwiftUI wrapper around SwiftTerm's `TerminalView`, driven by a live `EphemeralPty`
/// (an editor/shell pty). The sibling of `SwiftTermLive` for the non-persisted,
/// non-replayed ephemeral ptys: it subscribes to the pty's raw output fan-out, routes
/// keystrokes/resize back, and reports exit. Output feed + exit both hop to the main
/// thread (AppKit) since the pty callbacks arrive on a background queue.
struct SwiftTermEphemeral: NSViewRepresentable {
    let pty: EphemeralPty
    let onExit: @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pty: pty, onExit: onExit) }

    func makeNSView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        tv.terminalDelegate = context.coordinator
        context.coordinator.attach(to: tv)
        // Sync the freshly spawned pty to the view's real size so the editor repaints.
        let t = tv.getTerminal()
        pty.resize(cols: t.cols, rows: t.rows)
        DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        return tv
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let pty: EphemeralPty
        /// Marked `@Sendable` so it can be invoked from the pty's exit callback
        /// (which runs off the main thread); `EditorOverlay` builds it to hop to the
        /// main actor itself.
        private let onExit: @Sendable () -> Void
        private weak var view: TerminalView?
        private var cancelOutput: (() -> Void)?
        private var cancelExit: (() -> Void)?

        init(pty: EphemeralPty, onExit: @escaping @Sendable () -> Void) {
            self.pty = pty
            self.onExit = onExit
        }

        func attach(to tv: TerminalView) {
            view = tv
            cancelOutput = pty.onOutput { [weak tv] bytes in
                DispatchQueue.main.async { tv?.feed(byteArray: bytes[...]) }
            }
            // Capture the exit handler directly (not `self`) so the `@Sendable`
            // closure doesn't pull in the non-Sendable Coordinator.
            let fire = onExit
            cancelExit = pty.onExit { _ in fire() }
        }

        func detach() {
            cancelOutput?(); cancelOutput = nil
            cancelExit?(); cancelExit = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty.write(Array(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            pty.resize(cols: newCols, rows: newRows)
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
