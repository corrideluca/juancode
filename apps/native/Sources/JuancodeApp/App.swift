import SwiftUI
import JuancodeCore
import JuancodePersistence
import JuancodeServer

/// The native juancode app (juancode-u34.4): the local SwiftUI shell AND the host
/// of the embedded WS+HTTP server. The local view and remote browser/phone
/// clients are both subscribers to the one in-process `SessionRegistry` — the
/// pty always runs here on the Mac (the u34 prime directive). Run: `swift run juancode`.
@main
struct JuancodeApp: App {
    @StateObject private var model: AppModel

    init() {
        let state: AppState
        do {
            state = try AppState()
        } catch {
            fatalError("Failed to open juancode database: \(error)")
        }
        _model = StateObject(wrappedValue: AppModel(appState: state))

        // Boot the embedded server so remote clients can attach to the same
        // registry. Best-effort: if the port is taken (e.g. a dev server is
        // running) the local shell still works fully.
        let host = ProcessInfo.processInfo.environment["JUANCODE_HOST"] ?? "127.0.0.1"
        Task.detached {
            do {
                try await JuancodeServer.run(state: state, host: host, port: Config.port)
            } catch {
                NSLog("juancode: embedded server did not start: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") { model.showingNewSession = true }
                    .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }
}
