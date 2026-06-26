import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

// MARK: - Worktrees (juancode-q6q)

/// A sheet to review and clean up git worktrees across the repos you're working in
/// — the easy "clean worktrees" affordance. Lists each repo's main worktree (kept)
/// plus the linked `juancode/*` ones a session may have created, flags those a live
/// session is still using, and removes the rest with a confirmation.
struct WorktreesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove: Worktree?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Worktrees").font(.title3).bold()
                if model.worktreesLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button { model.loadWorktrees() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Rescan").clickCursor()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            content
        }
        .frame(width: 640, height: 460)
        .onAppear { model.loadWorktrees() }
        .alert("Remove worktree?", isPresented: Binding(
            get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmRemove = nil }
            Button("Remove", role: .destructive) {
                if let wt = confirmRemove { model.removeWorktreeAt(wt.path) }
                confirmRemove = nil
            }
        } message: {
            Text("This deletes the worktree directory — uncommitted changes there are lost. "
                + "The branch is kept.\n\n\(confirmRemove?.path ?? "")")
        }
    }

    @ViewBuilder private var content: some View {
        if model.worktrees.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Image(systemName: "externaldrive").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.worktreesLoading
                     ? "Scanning…"
                     : "No worktrees found in the repos you're working in.")
                    .foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.worktrees, id: \.path) { wt in
                        WorktreeRow(wt: wt, inUse: model.worktreeInUse(wt.path)) { confirmRemove = wt }
                        Divider()
                    }
                }
            }
        }
    }
}

private struct WorktreeRow: View {
    let wt: Worktree
    let inUse: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: wt.main ? "house.fill" : "arrow.triangle.branch")
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text((wt.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(wt.path)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let b = wt.branch {
                Text(b).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).help("Branch")
            }
            if wt.main {
                tag("main", .secondary)
            } else if inUse {
                tag("in use", .blue)
            }
            if !wt.main {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(inUse ? "A live session uses this worktree — removing it will disrupt it"
                                : "Remove worktree")
                    .clickCursor()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Tracked PRs (juancode-38z)

/// The global view of every PR under watch and its CI-fix loop state. Tracking is
/// started from a folder's PR list ("Track"); this panel lets you see them all in
/// one place, jump to the driving session, untrack, and clear surfaced decisions.
struct TrackedPrsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracked PRs").font(.title3).bold()
                Spacer()
                Button("Done") { dismiss() }.clickCursor()
            }
            .padding()
            Divider()
            if model.trackedList.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checklist").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No PRs tracked yet.").foregroundStyle(.secondary).font(.system(size: 13))
                    Text("Open a folder's PR list and hit “Track” to start a CI-fix loop:\nthe agent watches the PR and auto-fixes lint/CI, escalating real decisions.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.trackedList) { pr in
                            TrackedPrRow(pr: pr) { dismiss() }
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 660, height: 480)
    }
}

private struct TrackedPrRow: View {
    @Environment(AppModel.self) private var model
    let pr: TrackedPr
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(pr.number)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(pr.title).font(.system(size: 13)).lineLimit(1).help(pr.title)
                TrackBadge(state: pr.state)
                Spacer(minLength: 8)
                Text((pr.cwd as NSString).lastPathComponent)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 12) {
                Text(pr.branch).font(.system(size: 10).monospaced()).foregroundStyle(.tertiary)
                Spacer()
                Button("Open ↗") {
                    if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Go to session") { dismiss(); model.selection = pr.sessionId }
                    .buttonStyle(.borderless).font(.system(size: 11)).clickCursor()
                Button("Untrack") { model.untrackPr(pr.id) }
                    .buttonStyle(.borderless).font(.system(size: 11))
                    .help("Stop watching this PR (keeps the session)").clickCursor()
            }
            ForEach(pr.notifications) { note in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                    Text(note.message).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Button("Dismiss") {
                        model.resolveNotification(prId: pr.id, notificationId: note.id)
                    }
                    .buttonStyle(.borderless).font(.system(size: 9)).clickCursor()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
