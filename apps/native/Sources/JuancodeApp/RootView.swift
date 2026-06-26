import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JuancodeCore
import JuancodeServices

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(OracleModel.self) private var oracle

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
        }
        .preferredColorScheme(.dark)
        .background(WindowBackground(color: .black))
        // Global command bar (juancode-6sw): Oracle, global Issues, Tracked PRs and
        // Worktrees live in the window toolbar — reachable from any session.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showingTrackedPrs = true } label: {
                    Label("Tracked PRs", systemImage: "checklist")
                }
                .help("PRs under watch — CI-fix loops")
                .clickCursor()
                Button { model.showingWorktrees = true; model.loadWorktrees() } label: {
                    Label("Worktrees", systemImage: "externaldrive.badge.minus")
                }
                .help("Manage / clean git worktrees")
                .clickCursor()
                Button { oracle.open(tab: .issues) } label: {
                    Label("Issues", systemImage: "tray.full")
                }
                .help("Global issues (Oracle tracker)")
                .clickCursor()
                Button { oracle.open(tab: .chat) } label: {
                    Label("Oracle", systemImage: "sparkles")
                }
                .help("Oracle — global orchestration (⌃Space)")
                .clickCursor()
            }
        }
        // The Oracle helper opens as a centered overlay over the whole window,
        // from the toolbar or ⌃Space (juancode-wjg / juancode-6sw).
        .overlay { OracleDock() }
        .sheet(isPresented: $model.showingWorktrees) {
            WorktreesSheet()
        }
        .sheet(isPresented: $model.showingTrackedPrs) {
            TrackedPrsSheet()
        }
        .sheet(isPresented: $model.showingNewSession) {
            NewSessionView()
        }
        .alert("Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Sets the host `NSWindow`'s background to a solid color (and makes the title bar
/// transparent) so the whole window matches the black SwiftTerm views rather than
/// the default system-gray window background. Used as a hidden `.background(...)`.
private struct WindowBackground: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in apply(to: v?.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(to: nsView?.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.backgroundColor = color
        window.titlebarAppearsTransparent = true
    }
}

/// A folder's sessions, mirroring the web `FolderGroup` (groupByFolder).
private struct FolderGroup: Identifiable {
    let cwd: String
    /// Last path segment of the cwd, shown as the header label.
    let name: String
    let sessions: [SessionMeta]
    let running: Int
    var id: String { cwd }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    /// Free-text filter over folder names/paths + session titles.
    @State private var query = ""
    /// When off (default) archived sessions are hidden from the list.
    @State private var showArchived = false
    /// Project folders the user has collapsed (by cwd); their session rows are hidden.
    @State private var collapsedFolders: Set<String> = []
    /// The session currently being renamed (drives the rename alert).
    @State private var renaming: SessionMeta?
    @State private var renameText = ""
    /// Whether the full-text transcript search sheet is open (juancode-wx9).
    @State private var showingSearch = false
    /// Whether the auth & MCP status sheet is open (juancode-daw).
    @State private var showingStatus = false

    /// How many archived sessions exist (for the toggle label / visibility).
    private var archivedCount: Int { model.sessions.filter(\.archived).count }

    /// Aggregate token/cost usage across visible non-archived sessions, for the
    /// sidebar footer total. Nil when nothing has usage yet.
    private var totalUsage: SessionUsage? {
        model.sessions.filter { !$0.archived }.aggregateUsage()
    }

    /// Sessions filtered by `query` (case-insensitive over title + cwd) and the
    /// archived toggle, then grouped by folder and sorted stably by cwd — mirrors
    /// the web sidebar.
    private var groups: [FolderGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Own sessions + discovered terminal sessions, grouped by project together.
        // Hide the pinned Oracle agent session — it's reachable from the Oracle dock,
        // not the per-project sidebar (juancode-wjg).
        let nonOracle = (model.sessions + model.externalSessions).filter { $0.cwd != OraclePaths.controlDir }
        let visible = showArchived ? nonOracle : nonOracle.filter { !$0.archived }
        let filtered = q.isEmpty
            ? visible
            : visible.filter {
                $0.title.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
            }
        let byCwd = Dictionary(grouping: filtered, by: \.cwd)
        return byCwd.map { cwd, sessions in
            FolderGroup(
                cwd: cwd,
                name: (cwd as NSString).lastPathComponent.isEmpty ? cwd : (cwd as NSString).lastPathComponent,
                sessions: sessions,
                running: sessions.filter { model.isLive($0.id) }.count)
        }
        .sorted { $0.cwd.localizedCompare($1.cwd) == .orderedAscending }
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            TextField("Filter sessions…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            List(selection: $model.selection) {
                ForEach(groups) { group in
                    Section {
                        if !collapsedFolders.contains(group.cwd) {
                            ForEach(group.sessions, id: \.id) { meta in
                                let external = model.isExternal(meta.id)
                                SessionRow(meta: meta, activity: model.activity(meta.id),
                                           live: model.isLive(meta.id), external: external,
                                           tracked: external ? nil : model.trackedPr(forSession: meta.id),
                                           onResume: external ? { model.importExternalSession(meta.id) } : nil)
                                    .tag(meta.id)
                                    .selectionDisabled(external)
                                    .contextMenu {
                                        if model.isExternal(meta.id) {
                                            Button("Resume in juancode") { model.importExternalSession(meta.id) }
                                        } else {
                                            Button("Rename…") { beginRename(meta) }
                                            if meta.archived {
                                                Button("Unarchive") { model.setArchived(meta.id, false) }
                                            } else {
                                                Button("Archive") { model.setArchived(meta.id, true) }
                                            }
                                            Divider()
                                            Button("Delete", role: .destructive) { model.delete(meta.id) }
                                        }
                                    }
                            }
                        }
                    } header: {
                        FolderHeader(group: group, collapsed: collapsedFolders.contains(group.cwd)) {
                            if collapsedFolders.contains(group.cwd) {
                                collapsedFolders.remove(group.cwd)
                            } else {
                                collapsedFolders.insert(group.cwd)
                            }
                        }
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "No sessions yet." : "No matching sessions.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                if model.externalHasMore {
                    Button { model.loadMoreExternalSessions() } label: {
                        Label("Load more terminal sessions", systemImage: "ellipsis.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .clickCursor()
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            if let total = totalUsage, let label = total.badgeLabel {
                Divider()
                HStack(spacing: 4) {
                    Text("Total").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(label)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .help("Total token usage across visible sessions"
                    + (total.costUsd != nil ? " · estimated cost" : ""))
            }
            if archivedCount > 0 {
                Divider()
                Toggle(isOn: $showArchived) {
                    Text("Show archived (\(archivedCount))").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
        .background(Color.black)
        .onAppear { model.loadExternalSessions() }
        .toolbar {
            ToolbarItem {
                Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .help("Search transcripts")
                    .clickCursor()
            }
            ToolbarItem {
                Button { showingStatus = true } label: { Image(systemName: "shield.lefthalf.filled") }
                    .help("Auth & MCP status")
                    .clickCursor()
            }
            ToolbarItem {
                Button { model.showingNewSession = true } label: { Image(systemName: "plus") }
                    .help("New session")
                    .clickCursor()
            }
        }
        .sheet(isPresented: $showingSearch) {
            SearchPanel()
        }
        .sheet(isPresented: $showingStatus) {
            StatusPanel()
        }
        .navigationTitle("juancode")
        .alert("Rename session", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let target = renaming { model.rename(target.id, to: renameText) }
                renaming = nil
            }
        }
        .perfTrackBody()
    }

    private func beginRename(_ meta: SessionMeta) {
        renameText = meta.title
        renaming = meta
    }
}

/// Collapsible section header for a folder: name (full path as tooltip), a
/// running-session badge, and a per-folder "+" agent menu that spawns a new
/// session in this folder. Mirrors the web sidebar's folder `<summary>`.
private struct FolderHeader: View {
    @Environment(AppModel.self) private var model
    let group: FolderGroup
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Chevron + name + running-count form the collapse toggle; the "+" menu
            // and PR/issue badges stay separately clickable.
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(group.name).lineLimit(1).help(group.cwd)
                    if group.running > 0 {
                        Text("\(group.running) running")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickCursor()
            Spacer()
            Menu {
                ForEach(ProviderId.allCases, id: \.self) { p in
                    Button(Providers.spec(for: p).label) {
                        model.createInFolder(provider: p, cwd: group.cwd)
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New session in \(group.cwd)")
            .clickCursor()
            FolderIssues(cwd: group.cwd)
            FolderPrs(cwd: group.cwd)
        }
        .onAppear { model.loadPrs(group.cwd); model.loadBeads(group.cwd) }
    }
}

/// Build the single-line seed prompt auto-submitted to a PR-context session.
/// Mirrors the web `prPrompt`.
func prPrompt(_ pr: PullRequest) -> String {
    "Please help me work on pull request #\(pr.number) \"\(pr.title)\" (branch \(pr.branch)): \(pr.url) — start by reviewing the PR and its diff."
}

/// Per-folder open-PR badge + popover. Renders nothing unless the folder is a
/// GitHub repo with at least one open PR, so it stays invisible unless useful.
/// Mirrors the web `FolderPrs`: list with rolled-up CI status, free-text search,
/// "Mine" (author) and "Assigned to me" (assignee) filters, and per-PR
/// Open / Work on / Track actions.
private struct FolderPrs: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    @State private var showing = false
    @State private var query = ""
    @State private var mineOnly = false
    @State private var assignedOnly = false

    private var result: PrListResult? { model.prs(cwd) }
    private var all: [PullRequest] {
        guard let r = result, r.available else { return [] }
        return r.prs
    }
    private var viewer: String { result?.viewer ?? "" }
    private var mineCount: Int {
        viewer.isEmpty ? 0 : all.filter { $0.author == viewer }.count
    }
    private var assignedCount: Int {
        viewer.isEmpty ? 0 : all.filter { $0.assignees.contains(viewer) }.count
    }
    /// Offer the viewer-scoped filters only when we know who the viewer is.
    private var canFilterViewer: Bool { !viewer.isEmpty && all.count > 1 }

    private var list: [PullRequest] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { pr in
            if mineOnly && canFilterViewer && pr.author != viewer { return false }
            if assignedOnly && canFilterViewer && !pr.assignees.contains(viewer) { return false }
            if !q.isEmpty {
                let hay = "#\(pr.number) \(pr.title) \(pr.branch)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        if all.isEmpty {
            EmptyView()
        } else {
            Button {
                showing.toggle()
            } label: {
                Text("\(all.count) PR\(all.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("\(all.count) open pull request\(all.count == 1 ? "" : "s")")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                popover
            }
            .clickCursor()
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Search + viewer filters.
            HStack(spacing: 6) {
                TextField("Filter PRs…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                if canFilterViewer {
                    Toggle("Mine (\(mineCount))", isOn: $mineOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .clickCursor()
                    Toggle("Assigned (\(assignedCount))", isOn: $assignedOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .clickCursor()
                }
            }
            .padding(8)
            Divider()
            if list.isEmpty {
                Text(query.isEmpty && !mineOnly && !assignedOnly ? "No open PRs" : "No matching PRs")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list, id: \.number) { pr in
                            PrRow(pr: pr, cwd: cwd) { showing = false }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

/// One PR in the popover: CI-status dot, title, draft badge, and the
/// Open / Work on / Track actions.
private struct PrRow: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequest
    let cwd: String
    /// Called to dismiss the popover after an action that navigates away.
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(checkColor).frame(width: 7, height: 7).help(checkLabel)
                Text("#\(pr.number)").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(pr.title).font(.system(size: 12)).lineLimit(1).help(pr.title)
                if pr.draft {
                    Text("draft")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer(minLength: 4)
                Text(checkLabel).font(.system(size: 10)).foregroundStyle(checkColor)
            }
            HStack(spacing: 12) {
                Button("Open ↗") {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .clickCursor()
                Button("Work on") {
                    dismiss()
                    model.workOnPr(pr, cwd: cwd)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .clickCursor()
                // Track (juancode-it5): hand the PR to a dedicated agent session that
                // watches for new review comments / CI status and auto-fixes the
                // obvious ones, escalating real decisions back here.
                if let t = tracked {
                    TrackBadge(state: t.state)
                    Button("Untrack") { model.untrackPr(t.id) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Stop watching this PR (keeps the session)")
                        .clickCursor()
                } else {
                    Button("Track") { model.trackPr(pr, cwd: cwd) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .help("Watch this PR — auto-fix review comments & CI, escalate decisions")
                        .clickCursor()
                }
                Spacer()
            }
            .padding(.leading, 13)
            // Decisions the tracker won't make on its own — surfaced for the user.
            if let t = tracked, !t.notifications.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(t.notifications) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9)).foregroundStyle(.orange)
                            Text(note.message).font(.system(size: 10)).foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            Button("Open") {
                                dismiss()
                                model.selection = t.sessionId
                            }
                            .buttonStyle(.borderless).font(.system(size: 9))
                            .clickCursor()
                            Button("Dismiss") {
                                model.resolveNotification(prId: t.id, notificationId: note.id)
                            }
                            .buttonStyle(.borderless).font(.system(size: 9))
                            .clickCursor()
                        }
                    }
                }
                .padding(.leading, 13)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var tracked: TrackedPr? { model.trackedPr(cwd: cwd, number: pr.number) }

    private var checkColor: Color {
        switch pr.checks {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .orange
        case .none: return .secondary
        }
    }

    private var checkLabel: String {
        switch pr.checks {
        case .passing: return "Checks passing"
        case .failing: return "Checks failing"
        case .pending: return "Checks running"
        case .none: return "No checks"
        }
    }
}

/// A small pill showing what a tracked PR is currently doing.
struct TrackBadge: View {
    let state: TrackState
    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(help)
    }
    private var label: String {
        switch state {
        case .watching: return "watching"
        case .fixing: return "fixing"
        case .needsDecision: return "needs you"
        }
    }
    private var color: Color {
        switch state {
        case .watching: return .secondary
        case .fixing: return .blue
        case .needsDecision: return .orange
        }
    }
    private var help: String {
        switch state {
        case .watching: return "Tracking — CI green, watching for new activity"
        case .fixing: return "Tracking — CI is running/failing; the agent is on it"
        case .needsDecision: return "Tracking — a change needs your decision"
        }
    }
}

/// Per-folder bd-issue badge + popover (juancode-sfh). Renders nothing unless the
/// folder has a beads tracker with at least one issue, so it stays invisible
/// otherwise. Mirrors `FolderPrs`: a count badge opening a searchable list with a
/// "Ready" filter and a per-issue "Work on" action that injects the issue's
/// context into the folder's focused session.
private struct FolderIssues: View {
    @Environment(AppModel.self) private var model
    let cwd: String
    @State private var showing = false
    @State private var query = ""
    @State private var readyOnly = false

    private var result: BeadsResult? { model.beads(cwd) }
    private var all: [BeadsIssue] {
        guard let r = result, r.available else { return [] }
        // Open work only — closed issues aren't actionable to "work on".
        return r.issues.filter { $0.status != "closed" }
    }
    private var readyCount: Int { all.filter { $0.ready }.count }
    /// Offer the Ready filter only when it would change the list.
    private var canFilterReady: Bool { readyCount > 0 && readyCount < all.count }

    private var list: [BeadsIssue] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { issue in
            if readyOnly && canFilterReady && !issue.ready { return false }
            if !q.isEmpty {
                let hay = "\(issue.id) \(issue.title)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    var body: some View {
        if all.isEmpty {
            EmptyView()
        } else {
            Button {
                showing.toggle()
            } label: {
                Text("\(all.count) issue\(all.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("\(all.count) open bd issue\(all.count == 1 ? "" : "s")")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                popover
            }
            .clickCursor()
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter issues…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                if canFilterReady {
                    Toggle("Ready (\(readyCount))", isOn: $readyOnly)
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .font(.system(size: 10))
                        .clickCursor()
                }
            }
            .padding(8)
            Divider()
            if list.isEmpty {
                Text(query.isEmpty && !readyOnly ? "No open issues" : "No matching issues")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(list, id: \.id) { issue in
                            IssueRow(issue: issue, cwd: cwd) { showing = false }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

/// One bd issue in the popover: status dot, id, title, and a "Work on" action
/// that injects the issue's context into the folder's focused agent session.
private struct IssueRow: View {
    @Environment(AppModel.self) private var model
    let issue: BeadsIssue
    let cwd: String
    /// Called to dismiss the popover after an action that navigates away.
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7).help(statusLabel)
                Text(issue.id).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(issue.title).font(.system(size: 12)).lineLimit(1).help(issue.title)
                if issue.blocked {
                    Text("blocked")
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.2))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Spacer(minLength: 4)
                Text("p\(issue.priority)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Work on") {
                    dismiss()
                    model.workOnIssue(issue, cwd: cwd)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Inject this issue's context into the focused session (starts one if none)")
                .clickCursor()
                Spacer()
            }
            .padding(.leading, 13)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var statusColor: Color {
        if issue.blocked { return .orange }
        if issue.ready { return .green }
        return .secondary
    }
    private var statusLabel: String {
        if issue.blocked { return "Blocked" }
        if issue.ready { return "Ready" }
        return issue.status
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    let activity: SessionActivity?
    let live: Bool
    /// A discovered terminal session not yet imported — shown with a marker and an
    /// explicit Resume button (so it isn't triggered by hover/selection).
    var external: Bool = false
    /// The PR this session is tracking, if any — drives the PR label (juancode-kxy).
    var tracked: TrackedPr? = nil
    /// Resume action for an external row; the row is otherwise non-interactive.
    var onResume: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.title).lineLimit(1).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let t = tracked {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.pull").font(.system(size: 8))
                    Text("#\(t.number)").font(.system(size: 9, weight: .semibold).monospacedDigit())
                }
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(trackColor(t.state).opacity(0.2))
                .foregroundStyle(trackColor(t.state))
                .clipShape(Capsule())
                .help("Tracking PR #\(t.number) — \(t.state.rawValue)")
            }
            if external {
                Image(systemName: "terminal")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("From your terminal")
                if let onResume {
                    Button(action: onResume) {
                        Image(systemName: "play.circle").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Resume this conversation in juancode")
                    .clickCursor()
                }
            }
            if let label = meta.usage?.badgeLabel {
                Text(label)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Token usage" + (meta.usage?.costUsd != nil ? " · estimated cost" : ""))
            }
            if meta.skipPermissions {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Accept all (skip permission prompts) is on")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        (meta.cwd as NSString).lastPathComponent
    }

    private func trackColor(_ state: TrackState) -> Color {
        switch state {
        case .watching: return .secondary
        case .fixing: return .blue
        case .needsDecision: return .orange
        }
    }

    private var dotColor: Color {
        guard live else { return .secondary.opacity(0.4) }
        switch activity {
        case .busy: return .orange
        case .waitingInput: return .blue
        case .idle, .none: return .green
        }
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.selection, let meta = model.sessions.first(where: { $0.id == id }) {
            SessionContainer(meta: meta)
                .id(id) // fresh terminal per session
        } else {
            ContentUnavailableView(
                "No session selected",
                systemImage: "terminal",
                description: Text("Pick a session, or create one with +.")
            )
        }
    }
}

/// The two views the session's right-side panel can show: the working-tree
/// changes panel (diff + inline comments + git actions) or the folder's bd issues.
private enum SidePanelTab: String, CaseIterable { case changes = "Changes", issues = "Issues" }

struct SessionContainer: View {
    @Environment(AppModel.self) private var model
    let meta: SessionMeta
    /// Active right-panel tab, remembered app-wide.
    @AppStorage("session.sidePanel.tab") private var tabRaw: String = SidePanelTab.changes.rawValue
    /// Whether the right-side panel is shown. Toggled from the header CTA.
    @AppStorage("session.sidePanel.shown") private var panelShown: Bool = true
    /// Persisted width of the right-side panel in the split.
    @AppStorage("session.sidePanel.width") private var panelWidth: Double = 420
    /// Whether the bottom terminal panel is shown. Toggled from the header CTA.
    @AppStorage("session.bottomPanel.shown") private var bottomShown: Bool = false
    /// Persisted height of the bottom terminal panel in the split.
    @AppStorage("session.bottomPanel.height") private var bottomHeight: Double = 240

    private var tab: SidePanelTab {
        get { SidePanelTab(rawValue: tabRaw) ?? .changes }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    /// Show the queue composer only while the session is live and mid-turn (busy or
    /// waiting) — when idle the user just types into the terminal — or whenever a
    /// draft is already buffered (so the "Queued" pill stays visible until it sends).
    /// Mirrors the web SessionView render condition.
    private var showMessageQueue: Bool {
        guard model.isLive(meta.id) else { return false }
        if model.queuedDraft(meta.id) != nil { return true }
        switch model.activity(meta.id) {
        case .busy, .waitingInput: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(meta.title).font(.headline).lineLimit(1)
                Spacer()
                if let label = meta.usage?.badgeLabel {
                    Text(label)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Token usage" + (meta.usage?.costUsd != nil ? " · estimated cost" : ""))
                }
                if model.isLive(meta.id) {
                    acceptAllToggle
                    Label("live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button("Reactivate") { Task { await model.reactivate(meta.id) } }
                        .controlSize(.small)
                        .clickCursor()
                }
                Button {
                    bottomShown.toggle()
                    // Opening an empty panel for this folder seeds the first terminal.
                    if bottomShown, model.terminalPanel(meta.cwd).isEmpty {
                        model.openTerminalTab(cwd: meta.cwd)
                    }
                } label: {
                    Image(systemName: bottomShown ? "menubar.dock.rectangle.badge.record" : "menubar.dock.rectangle")
                }
                .help(bottomShown ? "Hide the terminal panel" : "Show the terminal panel")
                .clickCursor()
                Button {
                    panelShown.toggle()
                } label: {
                    Image(systemName: panelShown ? "sidebar.right" : "sidebar.squares.right")
                }
                .help(panelShown ? "Hide the Changes / Issues panel" : "Show the Changes / Issues panel")
                .clickCursor()
            }
            .padding(8)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    terminal
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showMessageQueue {
                        Divider()
                        MessageQueueComposer(sessionId: meta.id)
                    }
                    if bottomShown {
                        DragResizeHandle(axis: .horizontal, value: $bottomHeight, min: 120, max: 720)
                        BottomTerminalPanel(cwd: meta.cwd)
                            .frame(height: CGFloat(bottomHeight))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if panelShown {
                    DragResizeHandle(axis: .vertical, value: $panelWidth, min: 280, max: 760)
                    sidePanel
                        .frame(width: CGFloat(panelWidth))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(meta.title)
        .perfTrackBody()
    }

    /// The right-side panel: a Changes | Issues tab switcher hosting the existing
    /// self-contained `ChangesPanel` (session diff) and `IssuesPanel` (folder bd
    /// issues). The active tab is remembered app-wide via @AppStorage.
    private var sidePanel: some View {
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { tab = $0 })) {
                ForEach(SidePanelTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            switch tab {
            case .changes: ChangesPanel(sessionId: meta.id)
            case .issues: IssuesPanel(cwd: meta.cwd)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    /// Per-session accept-all switch. Flipping it resume-restarts the CLI at the
    /// new permission level (conversation + scrollback preserved). Disabled while
    /// the flip is in flight.
    private var acceptAllToggle: some View {
        let flipping = model.flippingPermissions.contains(meta.id)
        return Toggle("Accept all", isOn: Binding(
            get: { meta.skipPermissions },
            set: { skip in Task { await model.setSkipPermissions(meta.id, to: skip) } }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.caption)
        .disabled(flipping)
        .help("Skip permission prompts for this session (restarts the CLI, keeping the conversation)")
    }

    @ViewBuilder
    private var terminal: some View {
        if let session = model.liveSession(meta.id) {
            // Key by the Session's object identity: a permissions flip swaps in a
            // brand-new Session (same juancode id) behind the same pty, so this
            // forces a fresh terminal that subscribes to the new pty and replays
            // the carried-forward scrollback.
            SwiftTermLive(session: session)
                .id(ObjectIdentifier(session))
        } else {
            SwiftTermReplay(scrollback: model.scrollback(meta.id))
        }
    }
}

/// A small composer for queueing a follow-up instruction while the agent is still
/// mid-turn (busy or waiting). The draft is buffered in `AppModel.queuedDrafts`
/// (keyed by session id) and auto-sent on the next idle edge by the activity
/// subscription — so the user can line up their next message without watching for
/// the turn to finish. Mirrors the web `MessageQueue`: shows a "Queued" pill with a
/// Cancel button when something is buffered, otherwise a TextField + Queue button.
private struct MessageQueueComposer: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var draft = ""

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.queueDraft(sessionId, text)
        draft = ""
    }

    var body: some View {
        if let queued = model.queuedDraft(sessionId) {
            HStack(spacing: 8) {
                Text("Queued")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.2))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(queued)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .help(queued)
                Spacer(minLength: 4)
                Text("sends when the agent is idle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    model.cancelQueuedDraft(sessionId)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .help("Cancel queued message")
                .clickCursor()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        } else {
            HStack(spacing: 8) {
                TextField("Queue a follow-up to send when the agent is done…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { submit() }
                Button("Queue") { submit() }
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Buffer this message; it sends automatically when the agent goes idle")
                    .clickCursor()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }
}

struct NewSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ProviderId = .claude
    @State private var cwd: String = Config.defaultCwd
    // New sessions default to accept-all (skip permission prompts); toggle off per session.
    @State private var skipPermissions = true
    @State private var isolateWorktree = false
    @State private var creating = false
    @State private var showingDirPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Session").font(.title2).bold()
            Form {
                Picker("Agent", selection: $provider) {
                    ForEach(ProviderId.allCases, id: \.self) { p in
                        Text(Providers.spec(for: p).label).tag(p)
                    }
                }
                HStack {
                    TextField("Working directory", text: $cwd)
                    Button("Choose…") { showingDirPicker = true }
                        .clickCursor()
                }
                Toggle("Accept all (skip permission prompts)", isOn: $skipPermissions)
                Toggle("Isolate in a fresh git worktree", isOn: $isolateWorktree)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).clickCursor()
                Button(creating ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || cwd.trimmingCharacters(in: .whitespaces).isEmpty)
                    .clickCursor()
            }
        }
        .padding(20)
        .frame(width: 480)
        // SwiftUI's native folder picker — unlike NSOpenPanel.runModal(), it does
        // not spin a nested modal run loop inside the sheet (which deadlocks).
        .fileImporter(isPresented: $showingDirPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let needsScope = url.startAccessingSecurityScopedResource()
                cwd = url.path
                if needsScope { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func start() {
        creating = true
        Task {
            let session = await model.create(provider: provider, cwd: cwd,
                                             skipPermissions: skipPermissions, isolateWorktree: isolateWorktree)
            creating = false
            if session != nil { dismiss() }
        }
    }
}
