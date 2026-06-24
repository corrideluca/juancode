import SwiftUI
import AppKit
import JuancodeCore
import JuancodeServices

/// One open editor overlay: the file being edited and its live ephemeral pty.
/// `Identifiable` so it can drive a SwiftUI `.sheet(item:)`.
private struct EditorTarget: Identifiable {
    let id = UUID()
    let file: String
    let pty: EphemeralPty
}

/// Native SwiftUI port of the web `ChangesPanel` (+ `GitActions`), re-laid-out as a
/// VS Code-style "Source Control" view (juancode-dxg): a resizable SIDE panel with a
/// directory FILE TREE of changed files on the left and the selected file's diff
/// (hunks + inline comments) on the right. Inline line-range comments are staged
/// in-memory with a "Submit review" that injects them into the agent, and commit /
/// push / PR run via AppModel — all in-process (no WS hop), mirroring FolderPrs /
/// FolderIssues. AI review pass (juancode-7ha) and base-branch diff (juancode-49w)
/// are out of scope; this view is self-contained so the later Changes/Issues tab
/// switcher (juancode-fmh) can host it as-is.
struct ChangesPanel: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String

    /// Free-text filter over changed-file paths.
    @State private var query = ""
    /// Directory node ids currently expanded in the tree.
    @State private var expanded: Set<String> = []
    /// Whether the tree's expansion has been seeded for the current file set.
    @State private var seededExpansion = false
    /// The path of the file selected in the tree (its diff shows on the right).
    @State private var selectedPath: String?
    /// Closing-note composer for "Submit review".
    @State private var showSubmit = false
    @State private var finalNote = ""
    /// The file currently open in the editor overlay, if any.
    @State private var editing: EditorTarget?
    /// Persisted width of the tree pane in the split.
    @AppStorage("changes.treeWidth") private var treeWidth: Double = 260

    private var diff: DiffResult? { model.diff(sessionId) }
    private var loading: Bool { model.diffLoading.contains(sessionId) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !model.comments(sessionId).isEmpty {
                Divider()
                submitBar
            }
        }
        .onAppear { if diff == nil { model.loadChanges(sessionId) } }
        .onChange(of: diff) { _, _ in syncSelectionAndExpansion() }
        .sheet(item: $editing) { target in
            EditorOverlay(
                file: target.file,
                pty: target.pty,
                onExit: { [id = target.id] in Task { @MainActor in closeEditor(id) } },
                onForceClose: { target.pty.kill(); closeEditor(target.id) })
        }
    }

    /// Keep the tree selection valid as the diff reloads, and expand all folders the
    /// first time we have a file set so the tree opens fully (IDE behaviour).
    private func syncSelectionAndExpansion() {
        let files = diff?.files ?? []
        if !seededExpansion, !files.isEmpty {
            expanded = directoryNodeIDs(buildFileTree(files))
            seededExpansion = true
        }
        if files.isEmpty {
            selectedPath = nil
        } else if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = files.first?.path
        }
    }

    /// Open `file` in the user's real editor via an ephemeral pty (spawned now so the
    /// overlay binds a live pty). No-op if the spawn fails (AppModel sets a note).
    private func openEditor(_ file: String) {
        guard editing == nil else { return }
        if let pty = model.openEditor(sessionId, file: file, cols: 80, rows: 24) {
            editing = EditorTarget(file: file, pty: pty)
        }
    }

    /// Dismiss the overlay (idempotent) and refresh the diff, since the editor may
    /// have changed the file. Mirrors the web `onClose` → refetch.
    private func closeEditor(_ id: UUID) {
        guard editing?.id == id else { return }
        editing = nil
        model.loadChanges(sessionId)
    }

    // MARK: - Header (counts, filter, refresh, git actions)

    private var totals: (add: Int, del: Int) {
        (diff?.files ?? []).reduce((0, 0)) { ($0.0 + $1.additions, $0.1 + $1.deletions) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let files = diff?.files {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("+\(totals.add)").font(.system(size: 11)).foregroundStyle(.green)
                Text("−\(totals.del)").font(.system(size: 11)).foregroundStyle(.red)
                if diff?.truncatedFiles == true {
                    Text("(list capped)").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            TextField("Filter files…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 150)
            Button("Refresh") { model.loadChanges(sessionId) }
                .controlSize(.small)
            GitActionsView(sessionId: sessionId)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content (tree + diff split)

    private var visibleFiles: [DiffFile] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let files = diff?.files ?? []
        return q.isEmpty ? files : files.filter { $0.path.lowercased().contains(q) }
    }

    private var tree: [FileTreeNode] { buildFileTree(visibleFiles) }

    @ViewBuilder
    private var content: some View {
        if loading && diff == nil {
            centered("Loading changes…")
        } else if let d = diff, !d.git {
            centered("Not a git repository — nothing to diff.")
        } else if (diff?.files ?? []).isEmpty {
            centered("No changes in the working tree.")
        } else {
            splitView
        }
    }

    /// The resizable tree | diff split. A draggable divider sets the tree pane width
    /// (persisted via @AppStorage), clamped to a sensible range.
    private var splitView: some View {
        HStack(spacing: 0) {
            treePane
                .frame(width: CGFloat(treeWidth))
            ResizeHandle(width: $treeWidth, min: 160, max: 520)
            diffPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { syncSelectionAndExpansion() }
    }

    // MARK: - Tree pane

    @ViewBuilder
    private var treePane: some View {
        if visibleFiles.isEmpty {
            Text("No files match “\(query)”.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tree) { node in
                        FileTreeRows(
                            node: node,
                            depth: 0,
                            selectedPath: $selectedPath,
                            expanded: $expanded)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.3))
        }
    }

    // MARK: - Diff pane (selected file)

    @ViewBuilder
    private var diffPane: some View {
        if let path = selectedPath, let file = visibleFiles.first(where: { $0.path == path }) {
            ScrollView {
                FileCard(
                    sessionId: sessionId,
                    file: file,
                    comments: model.comments(sessionId).filter { $0.file == file.path },
                    collapsed: false,
                    onToggleCollapse: {},
                    onEdit: { openEditor(file.path) },
                    collapsible: false)
                    .padding(10)
            }
        } else {
            centered("Select a file to view its diff.")
        }
    }

    private func centered(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Submit-review bar

    private var submitBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showSubmit {
                TextEditor(text: $finalNote)
                    .font(.system(size: 12))
                    .frame(height: 48)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Text("Comments are written into the terminal prompt — press Enter there to send.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                let n = model.comments(sessionId).count
                Text("\(n) comment\(n == 1 ? "" : "s") pending")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if showSubmit {
                    Button("Cancel") { showSubmit = false }.controlSize(.small)
                }
                Button(showSubmit ? "Send to agent" : "Submit review →") {
                    if showSubmit {
                        model.submitReview(sessionId, finalNote: finalNote)
                        showSubmit = false
                        finalNote = ""
                    } else {
                        showSubmit = true
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
    }
}

// MARK: - File card (header + hunks + inline comments)

private struct FileCard: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String
    let file: DiffFile
    let comments: [DiffComment]
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let onEdit: () -> Void
    /// When false (the side-by-side diff pane), the collapse chevron is hidden — the
    /// single selected file is always shown fully expanded.
    var collapsible: Bool = true

    /// The (side, line) a new comment is being composed on, if any.
    @State private var composing: (side: CommentSide, line: Int)?
    @State private var draft = ""

    private var hunks: [DiffHunk] { parseUnifiedDiff(file.diff) }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            if !collapsed {
                if file.binary {
                    note("Binary file — diff not shown.")
                } else if file.truncated {
                    note("Diff too large to display.")
                } else if hunks.isEmpty {
                    note("No textual changes.")
                } else {
                    hunkBody
                }
            }
        }
        .background(Color(NSColor.textBackgroundColor).opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Button(action: onToggleCollapse) {
                HStack(spacing: 6) {
                    if collapsible {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(file.status.rawValue)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(statusColor)
                    Text(file.oldPath != nil ? "\(file.oldPath!) → \(file.path)" : file.path)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .disabled(!collapsible)
            Spacer(minLength: 6)
            Text("+\(file.additions)").font(.system(size: 10)).foregroundStyle(.green)
            Text("−\(file.deletions)").font(.system(size: 10)).foregroundStyle(.red)
            Button(action: onEdit) {
                Image(systemName: "square.and.pencil").font(.system(size: 10))
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .disabled(file.status == .deleted)
            .help(file.status == .deleted ? "File was deleted" : "Open in your editor ($EDITOR)")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08))
    }

    private var hunkBody: some View {
        VStack(spacing: 0) {
            ForEach(Array(hunks.enumerated()), id: \.offset) { _, hunk in
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    DiffLineRow(line: line) { anchor in beginCompose(anchor) }
                    if let a = line.anchor {
                        // Existing comments anchored to this line.
                        ForEach(comments.filter { $0.side == a.side && $0.endLine == a.line }, id: \.id) { c in
                            CommentRow(comment: c) { model.deleteComment(sessionId, commentId: c.id) }
                        }
                        // The composer, if active for this line.
                        if let comp = composing, comp.side == a.side, comp.line == a.line {
                            composer(side: comp.side, line: comp.line)
                        }
                    }
                }
            }
        }
    }

    private func beginCompose(_ anchor: (side: CommentSide, line: Int)) {
        composing = anchor
        draft = ""
    }

    private func composer(side: CommentSide, line: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Line \(line)\(side == .old ? " (old)" : "")")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(size: 12))
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Comment") {
                    model.addComment(sessionId, file: file.path, side: side,
                                     line: line, endLine: line, body: draft)
                    composing = nil
                    draft = ""
                }
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { composing = nil }.controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch file.status {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

/// One diff line, clickable on its gutter to start a comment on that side+line.
private struct DiffLineRow: View {
    let line: DiffLine
    let onComment: ((side: CommentSide, line: Int)) -> Void

    var body: some View {
        HStack(spacing: 0) {
            gutter(line.oldLine)
            gutter(line.newLine)
            Text(marker + line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .textSelection(.enabled)
        }
        .background(bgColor)
        .contentShape(Rectangle())
        .onTapGesture {
            if let a = line.anchor { onComment(a) }
        }
        .help("Click to comment on this line")
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .insert: return "+"
        case .delete: return "-"
        case .context: return " "
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .insert: return .green
        case .delete: return .red
        case .context: return .primary
        }
    }

    private var bgColor: Color {
        switch line.kind {
        case .insert: return Color.green.opacity(0.10)
        case .delete: return Color.red.opacity(0.10)
        case .context: return .clear
        }
    }
}

/// A staged inline comment row.
private struct CommentRow: View {
    let comment: DiffComment
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(commentRangeLabel(side: comment.side, line: comment.line, endLine: comment.endLine))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Text(comment.body)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button { onDelete() } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Delete comment")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }
}

// MARK: - Git actions (commit / push / PR)

/// Commit / Push / PR controls for the changes panel header — the SwiftUI port of
/// the web `GitActions`. Operates on the session's cwd in-process via AppModel.
private struct GitActionsView: View {
    @EnvironmentObject var model: AppModel
    let sessionId: String

    @State private var showCommit = false
    @State private var showPr = false
    @State private var message = ""
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var prDraft = false
    @State private var prResult: PrCreateResult?
    @State private var busy = false

    private var state: GitState? { model.gitState(sessionId) }
    private var note: AppModel.GitNote? { model.gitNoteBySession[sessionId] }

    var body: some View {
        if let s = state, !s.git {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                if let note {
                    Text(note.text)
                        .font(.system(size: 10))
                        .foregroundStyle(note.ok ? .green : .red)
                        .lineLimit(1).frame(maxWidth: 180).help(note.text)
                }
                Button("Commit\(dirty ? " •" : "")") {
                    prefillBranch(); showCommit.toggle(); showPr = false
                }
                .controlSize(.small)
                .disabled(!dirty)
                .popover(isPresented: $showCommit, arrowEdge: .bottom) { commitForm }

                Button(state?.ahead ?? 0 > 0 ? "Push \(state!.ahead)" : "Push") {
                    Task { busy = true; await model.push(sessionId); busy = false }
                }
                .controlSize(.small)
                .disabled(!canPush || busy)

                Button("PR") {
                    prefillBranch(); showPr.toggle(); showCommit = false
                }
                .controlSize(.small)
                .disabled(!(state?.remote ?? false) || (state?.detached ?? false))
                .popover(isPresented: $showPr, arrowEdge: .bottom) { prForm }
            }
        }
    }

    private var dirty: Bool { state?.dirty ?? false }
    private var canPush: Bool { (state?.remote ?? false) && (state?.ahead ?? 0) > 0 && !(state?.detached ?? false) }

    private func prefillBranch() {
        if prTitle.isEmpty, let b = state?.branch { prTitle = humanizeBranch(b) }
    }

    private var commitForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $message)
                .font(.system(size: 12))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("✨ Generate") {
                    Task {
                        busy = true
                        if let m = await model.generateCommitMessage(sessionId) { message = m }
                        busy = false
                    }
                }
                .controlSize(.small).disabled(busy)
                Spacer()
                Button("Commit all") {
                    Task {
                        busy = true
                        await model.commit(sessionId, message: message)
                        busy = false
                        message = ""
                        showCommit = false
                    }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(busy || message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Stages every change (git add -A) then commits.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 320)
    }

    private var prForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let r = prResult {
                Text(r.created ? "Pull request opened." : "A PR already exists for this branch.")
                    .font(.system(size: 12))
                Link(r.url, destination: URL(string: r.url) ?? URL(string: "https://github.com")!)
                    .font(.system(size: 11)).lineLimit(1)
                Button("Done") { prResult = nil; showPr = false }.controlSize(.small)
            } else {
                TextField("PR title", text: $prTitle)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                TextEditor(text: $prBody)
                    .font(.system(size: 12))
                    .frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Toggle("Draft", isOn: $prDraft).toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Button("Create PR") {
                        Task {
                            busy = true
                            prResult = await model.createPullRequest(
                                sessionId, title: prTitle, body: prBody, draft: prDraft)
                            busy = false
                        }
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Pushes the branch first, then opens the PR.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(12).frame(width: 320)
    }
}

// MARK: - File tree (rows + resize handle)

/// Renders one tree node and (for a folder) its children recursively. A folder row
/// toggles its expansion; a file row selects itself so its diff shows on the right.
private struct FileTreeRows: View {
    let node: FileTreeNode
    let depth: Int
    @Binding var selectedPath: String?
    @Binding var expanded: Set<String>

    var body: some View {
        if node.isDirectory {
            folderRow
            if expanded.contains(node.id), let kids = node.children {
                ForEach(kids) { child in
                    FileTreeRows(node: child, depth: depth + 1,
                                 selectedPath: $selectedPath, expanded: $expanded)
                }
            }
        } else if let file = node.file {
            fileRow(file)
        }
    }

    private var folderRow: some View {
        Button {
            if expanded.contains(node.id) { expanded.remove(node.id) } else { expanded.insert(node.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 10)
                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(node.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileRow(_ file: DiffFile) -> some View {
        let selected = selectedPath == file.path
        return Button {
            selectedPath = file.path
        } label: {
            HStack(spacing: 5) {
                // Align the file glyph with folder names (account for the chevron slot).
                Text(statusGlyph(file.status))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 18)
                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if file.additions > 0 {
                    Text("+\(file.additions)").font(.system(size: 9)).foregroundStyle(.green)
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)").font(.system(size: 9)).foregroundStyle(.red)
                }
            }
            .padding(.leading, indent).padding(.trailing, 8).padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var indent: CGFloat { 8 + CGFloat(depth) * 14 }

    private func statusGlyph(_ s: FileStatus) -> String {
        switch s {
        case .modified: return "M"
        case .added, .untracked: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        }
    }

    private func statusColor(_ s: FileStatus) -> Color {
        switch s {
        case .modified: return .orange
        case .added, .untracked: return .green
        case .deleted: return .red
        case .renamed: return .blue
        }
    }
}

/// A thin draggable vertical divider that resizes the pane to its left by writing
/// `width` (clamped to [min, max]). Shows a resize cursor on hover.
private struct ResizeHandle: View {
    @Binding var width: Double
    let min: Double
    let max: Double

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 1)
            .overlay(
                Rectangle().fill(Color.clear).frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                width = Swift.min(max, Swift.max(min, width + value.translation.width))
                            })
            )
    }
}

/// Turn a branch like "juan/add-git-ctas" into a readable default PR title.
/// Mirrors the web `humanizeBranch`.
func humanizeBranch(_ branch: String) -> String {
    let tail = branch.split(separator: "/").last.map(String.init) ?? branch
    let words = tail.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    guard let first = words.first else { return branch }
    return first.uppercased() + words.dropFirst()
}
