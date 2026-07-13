import AppKit
import SwiftUI

struct DashboardView: View {
    @Bindable var model: AssistantModel
    @State private var showingSettings = false
    @State private var workFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $model.selectedSection) {
                Label("Work", systemImage: "tray.full").tag(0)
                Label("Agenda", systemImage: "calendar").tag(1)
                Label("Ask", systemImage: "sparkles").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14).padding(.bottom, 10)

            Divider()
            Group {
                switch model.selectedSection {
                case 1: agenda
                case 2: assistant
                default: work
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 360, idealWidth: 410, minHeight: 560)
        .background(.ultraThickMaterial)
        .sheet(isPresented: $showingSettings) { settings }
        .task { model.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.gradient)
                Image(systemName: "sparkles").foregroundStyle(.white).font(.system(size: 14, weight: .bold))
            }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Corri Assistant").font(.system(size: 14, weight: .semibold))
                Text(model.login.isEmpty ? "Your work, at a glance" : "@\(model.login)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh now")
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
        .padding(14)
    }

    private var work: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter issues, PRs, actions…", text: $workFilter)
                        .textFieldStyle(.plain)
                    if !workFilter.isEmpty {
                        Button { workFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                if !model.errors.isEmpty { errorCard }
                SummaryStrip(model: model)
                DashboardSection(title: "Assigned to me", icon: "person.crop.circle.badge.checkmark",
                                 count: filteredIssues.count) {
                    if filteredIssues.isEmpty { EmptyRow(text: workFilter.isEmpty ? "No open GitHub issues assigned to you" : "No matching issues") }
                    ForEach(filteredIssues) { issue in
                        IssueRow(issue: issue, initialNote: model.note(for: issue.id)) {
                            model.saveNote($0, for: issue.id)
                        }
                    }
                }
                DashboardSection(title: "Open pull requests", icon: "arrow.triangle.pull",
                                 count: filteredPullRequests.count) {
                    if filteredPullRequests.isEmpty { EmptyRow(text: workFilter.isEmpty ? "No open pull requests created by you" : "No matching pull requests") }
                    ForEach(filteredPullRequests) { PullRequestRow(item: $0) }
                }
                DashboardSection(title: "GitHub Actions", icon: "play.square.stack",
                                 count: filteredActions.filter { $0.isRunning || $0.isProblem }.count) {
                    let visible = Array(filteredActions.prefix(16))
                    if visible.isEmpty { EmptyRow(text: "Add a repository in Settings to monitor Actions") }
                    ForEach(visible) { ActionRow(item: $0) }
                }
            }.padding(12)
        }
    }

    private var agenda: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.calendarAccessDenied {
                    MessageCard(icon: "calendar.badge.exclamationmark", title: "Calendar access is off",
                                detail: "Enable Corri Assistant in System Settings → Privacy & Security → Calendars.")
                } else if model.events.isEmpty {
                    MessageCard(icon: "calendar", title: "Your next 7 days are clear",
                                detail: "Google Calendar events appear here through the Calendar account on your Mac.")
                }
                if let next = nextEvent {
                    NextMeetingCard(item: next)
                }
                let today = model.events.filter { Calendar.current.isDateInToday($0.start) && !$0.isAllDay }
                if !today.isEmpty {
                    TodayTimeline(events: today)
                }
                ForEach(groupedEvents, id: \.0) { day, events in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                        ForEach(events) { event in EventRow(item: event); Divider().padding(.leading, 62) }
                    }
                    .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(12)
        }
    }

    private var assistant: some View {
        VStack(spacing: 0) {
            if model.chatMessages.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "sparkles").font(.system(size: 32)).foregroundStyle(.tint)
                    Text("Ask about your workday").font(.headline)
                    Text("Prioritize my issues · Draft a status update\nWhat should I prepare for today?")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.chatMessages) { message in ChatBubble(message: message).id(message.id) }
                            if model.isAsking { HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary); Spacer() }.padding(10) }
                        }.padding(12)
                    }
                    .onChange(of: model.chatMessages.count) { _, _ in
                        if let id = model.chatMessages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask your assistant…", text: $model.chatInput, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).padding(9)
                    .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                    .onSubmit { model.ask() }
                Button { model.ask() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 23)) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                    .disabled(model.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAsking)
            }.padding(12)
        }
    }

    private var errorCard: some View {
        MessageCard(icon: "exclamationmark.triangle.fill", title: "Some sources need attention",
                    detail: model.errors.joined(separator: "\n"), color: .orange)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Settings").font(.title2.bold()); Spacer() }
            VStack(alignment: .leading, spacing: 6) {
                Text("Repositories to monitor").font(.headline)
                Text("Comma-separated owner/repo names. Repositories from your PRs and issues are included automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("owner/repo, owner/another-repo", text: $model.repositoryText)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Notify me about new assignments and Action results", isOn: Binding(
                get: { model.notificationEnabled }, set: { model.setNotifications($0) }))
            Text("GitHub uses your existing `gh` login. Google Calendar uses the accounts already connected to macOS Calendar. Quick Ask uses your authenticated `claude` CLI.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Save") { model.saveRepositories(); showingSettings = false }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 430)
    }

    private var groupedEvents: [(Date, [CalendarItem])] {
        Dictionary(grouping: model.events) { Calendar.current.startOfDay(for: $0.start) }
            .sorted { $0.key < $1.key }
    }

    private var nextEvent: CalendarItem? {
        model.events.first { $0.end > Date() && !$0.isAllDay }
    }

    private var filteredIssues: [GithubIssueItem] {
        guard !normalizedFilter.isEmpty else { return model.issues }
        return model.issues.filter { "\($0.title) \($0.repository) \($0.number) \($0.labels.joined(separator: " ")) \(model.note(for: $0.id))".lowercased().contains(normalizedFilter) }
    }

    private var filteredPullRequests: [PullRequestItem] {
        guard !normalizedFilter.isEmpty else { return model.pullRequests }
        return model.pullRequests.filter { "\($0.title) \($0.repository) \($0.number)".lowercased().contains(normalizedFilter) }
    }

    private var filteredActions: [ActionItem] {
        guard !normalizedFilter.isEmpty else { return model.actions }
        return model.actions.filter { "\($0.title) \($0.workflow) \($0.repository) \($0.branch) \($0.status) \($0.conclusion)".lowercased().contains(normalizedFilter) }
    }

    private var normalizedFilter: String {
        workFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private struct NextMeetingCard: View {
    let item: CalendarItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.14))
                    Image(systemName: item.start <= context.date ? "video.fill" : "calendar.badge.clock")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.tint)
                }.frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status(at: context.date)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tint)
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(metadata).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let meetingURL = item.meetingURL {
                    Button("Join") { NSWorkspace.shared.open(meetingURL) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.18)))
        }
    }

    private func status(at now: Date) -> String {
        if item.start <= now && item.end > now { return "HAPPENING NOW" }
        let seconds = max(0, item.start.timeIntervalSince(now))
        if seconds < 3600 { return "STARTS IN \(max(1, Int(ceil(seconds / 60)))) MIN" }
        if Calendar.current.isDateInToday(item.start) {
            return "STARTS IN \(Int(seconds / 3600)) HR"
        }
        return "NEXT MEETING"
    }

    private var metadata: String {
        let time = "\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened))"
        return [time, item.calendar, item.location].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct TodayTimeline: View {
    let events: [CalendarItem]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Today at a glance").font(.system(size: 11, weight: .semibold)); Spacer(); Text(context.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary) }
                GeometryReader { proxy in
                    let rangeStart = context.date.addingTimeInterval(-3 * 3600)
                    let rangeEnd = context.date.addingTimeInterval(6 * 3600)
                    ZStack(alignment: .topLeading) {
                        ForEach(0..<10, id: \.self) { hour in
                            let x = proxy.size.width * CGFloat(hour) / 9
                            Rectangle().fill(Color.secondary.opacity(0.12)).frame(width: 1, height: 36).offset(x: x)
                        }
                        ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                            if event.end > rangeStart && event.start < rangeEnd {
                                let start = max(0, event.start.timeIntervalSince(rangeStart) / rangeEnd.timeIntervalSince(rangeStart))
                                let end = min(1, event.end.timeIntervalSince(rangeStart) / rangeEnd.timeIntervalSince(rangeStart))
                                Capsule().fill(Color.accentColor.opacity(0.28)).overlay(Capsule().stroke(Color.accentColor.opacity(0.8)))
                                    .frame(width: max(5, proxy.size.width * CGFloat(end - start)), height: 8)
                                    .offset(x: proxy.size.width * CGFloat(start), y: CGFloat(index % 3) * 11 + 2)
                                    .help(event.title)
                            }
                        }
                        Rectangle().fill(Color.red).frame(width: 2, height: 38).offset(x: proxy.size.width / 3)
                    }
                }.frame(height: 38)
                HStack { Text("−3h"); Spacer(); Text("now").foregroundStyle(.red); Spacer(); Text("+6h") }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(11).background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct SummaryStrip: View {
    let model: AssistantModel
    var body: some View {
        HStack(spacing: 0) {
            metric("Issues", model.issues.count, .orange)
            Divider().frame(height: 28)
            metric("PRs", model.pullRequests.count, .purple)
            Divider().frame(height: 28)
            metric("Actions", model.actions.filter { $0.isRunning || $0.isProblem }.count, .blue)
            Divider().frame(height: 28)
            metric("Today", model.events.filter { Calendar.current.isDateInToday($0.start) }.count, .green)
        }.padding(.vertical, 9).background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) { Text("\(value)").font(.system(size: 15, weight: .bold)).foregroundStyle(color); Text(label).font(.system(size: 9)).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }
}

private struct DashboardSection<Content: View>: View {
    let title: String; let icon: String; let count: Int; @ViewBuilder let content: Content
    @State private var expanded = true
    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack { Image(systemName: icon).foregroundStyle(.tint); Text(title).font(.system(size: 13, weight: .semibold)); Text("\(count)").font(.caption).foregroundStyle(.secondary); Spacer(); Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    .padding(10).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded { Divider(); VStack(spacing: 0) { content } }
        }.background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct IssueRow: View {
    let issue: GithubIssueItem
    let initialNote: String
    let save: (String) -> Void
    @State private var note: String
    @State private var editing = false
    init(issue: GithubIssueItem, initialNote: String, save: @escaping (String) -> Void) {
        self.issue = issue; self.initialNote = initialNote; self.save = save; _note = State(initialValue: initialNote)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { open(issue.url) } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "smallcircle.filled.circle").foregroundStyle(.green).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.title).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.leading).lineLimit(2)
                        Text("\(issue.repository)#\(issue.number)").font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer(); Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if editing {
                TextField("Notes, next step, context…", text: $note, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                    .onSubmit { save(note); editing = false }
                HStack { Spacer(); Button("Done") { save(note); editing = false }.controlSize(.small) }
            } else {
                Button { editing = true } label: {
                    HStack { Image(systemName: note.isEmpty ? "note.text.badge.plus" : "note.text"); Text(note.isEmpty ? "Add a note" : note).lineLimit(2); Spacer() }
                        .font(.system(size: 10)).foregroundStyle(note.isEmpty ? .tertiary : .secondary)
                }.buttonStyle(.plain)
            }
        }.padding(10)
        Divider().padding(.leading, 34)
    }
}

private struct PullRequestRow: View {
    let item: PullRequestItem
    var body: some View {
        Button { open(item.url) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: item.isDraft ? "arrow.triangle.pull" : "arrow.triangle.merge")
                    .foregroundStyle(item.isDraft ? Color.secondary : Color.purple)
                VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading); Text("\(item.repository)#\(item.number)" + (item.isDraft ? " · Draft" : "")).font(.system(size: 10).monospaced()).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Divider().padding(.leading, 34)
    }
}

private struct ActionRow: View {
    let item: ActionItem
    var body: some View {
        Button { open(item.url) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) { Text(item.title.isEmpty ? item.workflow : item.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading); Text("\(item.repository) · \(item.workflow)" + (item.branch.isEmpty ? "" : " · \(item.branch)")).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Divider().padding(.leading, 34)
    }
    private var icon: String { item.isRunning ? "clock.arrow.circlepath" : item.isProblem ? "xmark.circle.fill" : "checkmark.circle.fill" }
    private var color: Color { item.isRunning ? .blue : item.isProblem ? .red : .green }
    private var label: String { item.isRunning ? "RUNNING" : (item.conclusion.isEmpty ? item.status : item.conclusion).uppercased() }
}

private struct EventRow: View {
    let item: CalendarItem
    var body: some View {
        Button { if let url = item.url { NSWorkspace.shared.open(url) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(item.isAllDay ? "ALL" : item.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.tint).frame(width: 40, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: 3, height: 30)
                VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2); Text(item.calendar).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack { if message.role == .user { Spacer(minLength: 42) }; Text(message.text).font(.system(size: 12)).textSelection(.enabled).padding(10).background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(message.role == .user ? .white : .primary); if message.role == .assistant { Spacer(minLength: 42) } }
    }
}

private struct EmptyRow: View { let text: String; var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(18) } }
private struct MessageCard: View {
    let icon: String; let title: String; let detail: String; var color: Color = .accentColor
    var body: some View { HStack(alignment: .top, spacing: 10) { Image(systemName: icon).foregroundStyle(color); VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }; Spacer() }.padding(12).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
}

private func open(_ raw: String) { if let url = URL(string: raw) { NSWorkspace.shared.open(url) } }
