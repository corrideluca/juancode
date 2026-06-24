import Foundation
import Combine
import JuancodeCore
import JuancodeServices
import JuancodePersistence
import JuancodeServer

/// Observable view-model bridging the SwiftUI shell to the shared `AppState`. The
/// local UI is an in-process subscriber to the same `SessionRegistry` the
/// embedded server drives — there is no WS hop for the local view.
@MainActor
final class AppModel: ObservableObject {
    let appState: AppState

    @Published var sessions: [SessionMeta] = []
    @Published var activities: [String: SessionActivity] = [:]
    @Published var selection: String?
    @Published var showingNewSession = false
    @Published var errorMessage: String?

    private var activityCancels: [String: () -> Void] = [:]

    init(appState: AppState) {
        self.appState = appState
        appState.registry.onCreate { [weak self] s in
            Task { @MainActor in self?.watch(s); self?.refresh() }
        }
        for s in appState.registry.all() { watch(s) }
        refresh()
    }

    /// Persisted sessions (incl. exited), with live registry meta preferred for
    /// running ones so status/title/usage reflect the live pty.
    func refresh() {
        let persisted = appState.store.list()
        let live = Dictionary(appState.registry.all().map { ($0.id, $0.meta) }, uniquingKeysWith: { a, _ in a })
        sessions = persisted.map { live[$0.id] ?? $0 }
    }

    func activity(_ id: String) -> SessionActivity? { activities[id] }

    func isLive(_ id: String) -> Bool { appState.registry.get(id) != nil }

    func liveSession(_ id: String) -> Session? { appState.registry.get(id) }

    func scrollback(_ id: String) -> [UInt8] {
        appState.registry.get(id)?.getScrollback() ?? appState.store.getScrollback(id) ?? []
    }

    private func watch(_ s: Session) {
        activities[s.id] = s.activity
        activityCancels[s.id]?()
        activityCancels[s.id] = s.onActivity { [weak self] st, _ in
            Task { @MainActor in self?.activities[s.id] = st }
        }
        s.onExit { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    @discardableResult
    func create(provider: ProviderId, cwd: String, skipPermissions: Bool, isolateWorktree: Bool) async -> Bool {
        do {
            var workCwd = cwd
            var worktreePath: String? = nil
            if isolateWorktree {
                let wt = try await createWorktree(cwd, String(UUID().uuidString.prefix(8)).lowercased())
                workCwd = wt.path
                worktreePath = wt.path
            }
            let s = try appState.registry.create(
                provider: provider, cwd: workCwd, cols: 80, rows: 24,
                opts: SpawnOptions(skipPermissions: skipPermissions), worktreePath: worktreePath)
            refresh()
            selection = s.id
            return true
        } catch {
            errorMessage = "Failed to start \(provider.rawValue): \(error)"
            return false
        }
    }

    /// Revive an exited session (mirrors the WS `reactivate` path).
    func reactivate(_ id: String) async {
        if isLive(id) { return }
        guard var meta = appState.store.get(id) else { return }
        if meta.cliSessionId == nil {
            if let recovered = await recoverCliSessionId(
                meta.provider, cwd: meta.cwd, createdAtMs: meta.createdAt,
                excludeIds: appState.store.usedCliSessionIds()) {
                appState.store.setCliSessionId(id, cliSessionId: recovered)
                meta.cliSessionId = recovered
            }
        }
        guard meta.cliSessionId != nil else {
            errorMessage = "No prior CLI conversation could be found to resume this session."
            return
        }
        do {
            let prior = appState.store.getScrollback(id) ?? []
            let seed: [UInt8] = prior.isEmpty
                ? [] : prior + Array("\r\n\u{1B}[2m── session resumed ──\u{1B}[0m\r\n".utf8)
            _ = try appState.registry.resume(meta, cols: 80, rows: 24, priorScrollback: seed)
            refresh()
        } catch {
            errorMessage = "Failed to resume: \(error)"
        }
    }

    func delete(_ id: String) {
        let meta = appState.store.get(id)
        appState.registry.get(id)?.kill()
        appState.store.delete(id)
        activityCancels[id]?(); activityCancels[id] = nil
        if selection == id { selection = nil }
        refresh()
        if let wt = meta?.worktreePath {
            Task { try? await removeWorktree(wt) }
        }
    }
}
