import SwiftUI
import AppKit
import JuancodeServices

struct GithubActionsDock: View {
    @Environment(AppModel.self) private var model
    @AppStorage("githubActions.panel.width") private var panelWidth: Double = 560
    private static let minWidth: Double = 420
    private static let maxWidth: Double = 900

    var body: some View {
        ZStack(alignment: .trailing) {
            if model.showingGithubActions {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.showingGithubActions = false }
                    .transition(.opacity)
            }
            panel
                .offset(x: model.showingGithubActions ? 0 : hiddenOffset)
                .allowsHitTesting(model.showingGithubActions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .allowsHitTesting(model.showingGithubActions)
        .animation(.easeOut(duration: 0.16), value: model.showingGithubActions)
    }

    private var hiddenOffset: Double {
        min(Self.maxWidth, max(Self.minWidth, panelWidth)) + 60
    }

    private var panel: some View {
        let w = min(Self.maxWidth, max(Self.minWidth, panelWidth))
        return HStack(spacing: 0) {
            DragResizeHandle(axis: .vertical, value: $panelWidth,
                             min: Self.minWidth, max: Self.maxWidth, invert: true,
                             previewOnly: true)
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .frame(width: w)
        }
        .frame(maxHeight: .infinity)
        .background(Color.appPanel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.appHairline(0.12)).frame(width: 1)
        }
        .shadow(radius: 24, x: -6)
        .background {
            if model.showingGithubActions {
                Button("") { model.showingGithubActions = false }
                    .keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.square.stack").foregroundStyle(.tint).padding(.leading, 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("GitHub Actions").font(.system(size: 13, weight: .semibold))
                Text(model.githubActionsRepo).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
            if model.githubActionsLoading { ProgressView().controlSize(.small) }
            headerButton("arrow.clockwise", help: "Refresh workflow runs") {
                model.refreshGithubActions()
            }
            headerButton("safari", help: "Open Actions in GitHub") {
                if let url = URL(string: "https://github.com/\(model.githubActionsRepo)/actions") {
                    NSWorkspace.shared.open(url)
                }
            }
            headerButton("chevron.right", help: "Close") {
                model.showingGithubActions = false
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func headerButton(_ icon: String, help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon) }
            .buttonStyle(.borderless)
            .help(help)
            .clickCursor()
    }

    @ViewBuilder private var content: some View {
        if let error = model.githubActionsError {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.githubActionsRuns.isEmpty && model.githubActionsLoading {
            VStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.githubActionsRuns.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "play.square.stack")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No workflow runs found.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.githubActionsRuns) { run in
                        GithubActionRunRow(run: run)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct GithubActionRunRow: View {
    let run: GithubActionRun

    var body: some View {
        Button {
            if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: actionRunIcon(run))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(actionRunColor(run))
                    .frame(width: 20, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    Text(run.title.isEmpty ? run.workflowName : run.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if !run.branch.isEmpty {
                            Text(run.branch)
                                .font(.system(size: 10).monospaced())
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.16))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        Text(actionRunStatusLabel(run))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(actionRunColor(run))
                        if let label = runDuration(run) {
                            Text(label)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(relativeDate(run.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .clickCursor()
    }

    private var subtitle: String {
        let sha = run.sha.isEmpty ? "" : String(run.sha.prefix(7))
        let workflow = run.workflowName.isEmpty ? "Workflow" : run.workflowName
        let event = run.event.isEmpty ? "" : " · \(run.event)"
        let commit = sha.isEmpty ? "" : " · \(sha)"
        return "\(workflow)\(event)\(commit)"
    }
}

func actionRunProblem(_ run: GithubActionRun) -> Bool {
    let conclusion = run.conclusion.lowercased()
    return ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion)
        || run.status.lowercased() == "failure"
}

private func actionRunIcon(_ run: GithubActionRun) -> String {
    let status = run.status.lowercased()
    let conclusion = run.conclusion.lowercased()
    if status != "completed" { return "clock.arrow.circlepath" }
    if conclusion == "success" { return "checkmark.circle.fill" }
    if conclusion == "cancelled" { return "minus.circle.fill" }
    return "xmark.circle.fill"
}

private func actionRunColor(_ run: GithubActionRun) -> Color {
    let status = run.status.lowercased()
    let conclusion = run.conclusion.lowercased()
    if status != "completed" { return .blue }
    if conclusion == "success" { return .green }
    if conclusion == "cancelled" { return .secondary }
    return .red
}

private func actionRunStatusLabel(_ run: GithubActionRun) -> String {
    let status = run.status.trimmingCharacters(in: .whitespacesAndNewlines)
    let conclusion = run.conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
    if status.lowercased() == "completed", !conclusion.isEmpty { return conclusion.capitalized }
    return status.isEmpty ? "Unknown" : status.capitalized
}

private func runDuration(_ run: GithubActionRun) -> String? {
    guard let start = run.startedAt, let end = run.updatedAt else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: max(0, end.timeIntervalSince(start)))
}

private func relativeDate(_ date: Date?) -> String {
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
