import AppKit
import SwiftUI

@main
@MainActor
final class CorriAssistantApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AssistantModel()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = CorriAssistantApp()
        app.delegate = delegate
        app.run()
        _ = delegate
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createPanel()
        createStatusItem()
        showPanel()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "Corri Assistant"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.level = .floating
        // Keep the assistant visible in screenshots/screen sharing. NSPanel's
        // default sharing mode is `.none`, which makes a useful work dashboard
        // mysteriously disappear for collaborators on a call.
        panel.sharingType = .readOnly
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.minSize = NSSize(width: 360, height: 520)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DashboardView(model: model))
        self.panel = panel
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Corri Assistant")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Corri Assistant", action: #selector(showFromMenu), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh", action: #selector(refreshFromMenu), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        panel?.isVisible == true ? panel?.orderOut(nil) : showPanel()
    }

    @objc private func showFromMenu() { showPanel() }
    @objc private func refreshFromMenu() { Task { await model.refresh() } }

    private func showPanel() {
        guard let panel else { return }
        positionAtRightEdge(panel)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionAtRightEdge(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let height = min(max(panel.frame.height, 600), visible.height - 20)
        panel.setFrame(NSRect(x: visible.maxX - panel.frame.width - 10,
                              y: visible.minY + (visible.height - height) / 2,
                              width: panel.frame.width, height: height), display: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
