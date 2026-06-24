import Foundation
import JuancodeCore
import JuancodeServices
import JuancodePersistence

/// Shared, process-wide state the embedded server (and the local SwiftUI shell)
/// both drive: the live session registry (owning the real ptys), the SQLite
/// store, and the ephemeral editor/terminal ptys. Mirrors the module-level
/// singletons of the Node server (`registry`, `sessionDb`, `editors`,
/// `terminals`) — but here a single owned object so the GUI can hold it too.
public final class AppState: @unchecked Sendable {
    public let store: GRDBStore
    public let registry: SessionRegistry
    public let ephemeral = EphemeralPtyRegistry()

    public init(store: GRDBStore) {
        self.store = store
        // The registry's session env carries the real seams: login-shell binary
        // resolution, this store, Codex id discovery, and title/usage polling.
        self.registry = SessionRegistry(env: .live(store: store))
        // Any session still "running" in the db is stale — its pty died with the
        // previous process. Mark them exited so the UI shows truth.
        store.markOrphansExited()
    }

    public convenience init(dbPath: String? = nil) throws {
        self.init(store: try GRDBStore(path: dbPath))
    }

    /// Tear down every live pty (sessions + ephemeral) on shutdown.
    public func shutdown() {
        registry.killAll()
        ephemeral.killAll()
    }
}
