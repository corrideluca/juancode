import SwiftUI
import AppKit
import JuancodeCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DetailView()
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

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Sessions") {
                ForEach(model.sessions, id: \.id) { meta in
                    SessionRow(meta: meta, activity: model.activity(meta.id), live: model.isLive(meta.id))
                        .tag(meta.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(meta.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button { model.showingNewSession = true } label: { Image(systemName: "plus") }
                    .help("New session")
            }
        }
        .navigationTitle("juancode")
    }
}

struct SessionRow: View {
    let meta: SessionMeta
    let activity: SessionActivity?
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.title).lineLimit(1).font(.system(size: 13))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let folder = (meta.cwd as NSString).lastPathComponent
        if let u = meta.usage, u.totalTokens > 0 {
            return "\(folder) · \(u.totalTokens) tok"
        }
        return folder
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
    @EnvironmentObject var model: AppModel

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

struct SessionContainer: View {
    @EnvironmentObject var model: AppModel
    let meta: SessionMeta

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(meta.title).font(.headline).lineLimit(1)
                Spacer()
                if model.isLive(meta.id) {
                    Label("live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Button("Reactivate") { Task { await model.reactivate(meta.id) } }
                        .controlSize(.small)
                }
            }
            .padding(8)
            Divider()
            terminal
        }
        .navigationTitle(meta.title)
    }

    @ViewBuilder
    private var terminal: some View {
        if let session = model.liveSession(meta.id) {
            SwiftTermLive(session: session)
        } else {
            SwiftTermReplay(scrollback: model.scrollback(meta.id))
        }
    }
}

struct NewSessionView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var provider: ProviderId = .claude
    @State private var cwd: String = Config.defaultCwd
    @State private var skipPermissions = false
    @State private var isolateWorktree = false
    @State private var creating = false

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
                    Button("Choose…") { chooseDir() }
                }
                Toggle("Accept all (skip permission prompts)", isOn: $skipPermissions)
                Toggle("Isolate in a fresh git worktree", isOn: $isolateWorktree)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(creating ? "Starting…" : "Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || cwd.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @MainActor
    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: cwd)
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
    }

    private func start() {
        creating = true
        Task {
            let ok = await model.create(provider: provider, cwd: cwd,
                                        skipPermissions: skipPermissions, isolateWorktree: isolateWorktree)
            creating = false
            if ok { dismiss() }
        }
    }
}
