import AppKit
import EventKit
import Foundation
import Observation
import UserNotifications
import JuancodeServices

@MainActor @Observable
final class AssistantModel {
    var login = ""
    var pullRequests: [PullRequestItem] = []
    var issues: [GithubIssueItem] = []
    var actions: [ActionItem] = []
    var events: [CalendarItem] = []
    var errors: [String] = []
    var isRefreshing = false
    var lastRefresh: Date?
    var selectedSection = 0
    var chatInput = ""
    var chatMessages: [ChatMessage] = []
    var isAsking = false
    var calendarAccessDenied = false
    var notificationEnabled = UserDefaults.standard.object(forKey: "assistant.notifications") as? Bool ?? true
    var repositoryText = UserDefaults.standard.string(forKey: "assistant.repositories") ?? ""

    private let eventStore = EKEventStore()
    private var refreshTask: Task<Void, Never>?
    private var knownActionStates: [Int: String] = [:]
    private var knownIssueIDs = Set<String>()
    private var completedFirstRefresh = false

    func start() {
        guard refreshTask == nil else { return }
        if notificationEnabled { requestNotifications() }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let repositories = repositoryText.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        async let github = GithubDashboard.load(extraRepositories: repositories)
        async let calendar = loadCalendar()
        let (snapshot, calendarItems) = await (github, calendar)
        login = snapshot.login
        pullRequests = snapshot.pullRequests
        issues = snapshot.issues
        actions = snapshot.actions
        errors = snapshot.errors
        events = calendarItems
        lastRefresh = Date()
        isRefreshing = false
        sendChangeNotifications(snapshot)
        completedFirstRefresh = true
    }

    func saveRepositories() {
        UserDefaults.standard.set(repositoryText, forKey: "assistant.repositories")
        Task { await refresh() }
    }

    func setNotifications(_ enabled: Bool) {
        notificationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "assistant.notifications")
        if enabled { requestNotifications() }
    }

    func note(for id: String) -> String {
        UserDefaults.standard.string(forKey: noteKey(id)) ?? ""
    }

    func saveNote(_ note: String, for id: String) {
        UserDefaults.standard.set(note, forKey: noteKey(id))
    }

    func ask() {
        let prompt = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isAsking else { return }
        chatInput = ""
        chatMessages.append(ChatMessage(role: .user, text: prompt))
        isAsking = true
        let context = assistantContext()
        Task {
            let answer: String
            do {
                let result = try await ProcessRunner.capture(
                    "claude", ["-p", "--output-format", "text", context + "\n\nUser request: " + prompt],
                    cwd: FileManager.default.homeDirectoryForCurrentUser.path, timeout: 120)
                answer = result.ok
                    ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                answer = "I couldn't reach the Claude CLI. Make sure `claude` is installed and authenticated."
            }
            chatMessages.append(ChatMessage(role: .assistant, text: answer.isEmpty ? "No response." : answer))
            isAsking = false
        }
    }

    private func loadCalendar() async -> [CalendarItem] {
        let granted: Bool
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: granted = true
        case .denied, .restricted: granted = false
        default:
            granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        }
        calendarAccessDenied = !granted
        guard granted else { return [] }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(604_800)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        return eventStore.events(matching: predicate).map {
            CalendarItem(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Untitled event",
                         calendar: $0.calendar.title, start: $0.startDate, end: $0.endDate,
                         isAllDay: $0.isAllDay, url: $0.url)
        }.sorted { $0.start < $1.start }
    }

    private func assistantContext() -> String {
        let issueLines = issues.prefix(20).map { "- [issue] \($0.repository)#\($0.number): \($0.title). Note: \(note(for: $0.id))" }
        let prLines = pullRequests.prefix(20).map { "- [PR] \($0.repository)#\($0.number): \($0.title)" }
        let eventLines = events.prefix(12).map { "- [calendar] \($0.start.formatted()): \($0.title)" }
        return """
        You are a concise personal work assistant. Help prioritize, summarize, plan, and draft communication.
        Do not suggest code changes unless explicitly asked. Current dashboard:
        \((issueLines + prLines + eventLines).joined(separator: "\n"))
        """
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func sendChangeNotifications(_ snapshot: GithubSnapshot) {
        defer {
            knownActionStates = Dictionary(uniqueKeysWithValues: snapshot.actions.map { ($0.id, "\($0.status):\($0.conclusion)") })
            knownIssueIDs = Set(snapshot.issues.map(\.id))
        }
        guard completedFirstRefresh, notificationEnabled else { return }
        for action in snapshot.actions {
            let state = "\(action.status):\(action.conclusion)"
            guard let previous = knownActionStates[action.id], previous != state,
                  action.isProblem || action.conclusion.lowercased() == "success" else { continue }
            notify(title: action.isProblem ? "GitHub Action needs attention" : "GitHub Action passed",
                   body: "\(action.repository) · \(action.workflow)")
        }
        for issue in snapshot.issues where !knownIssueIDs.contains(issue.id) {
            notify(title: "New issue assigned to you", body: "\(issue.repository)#\(issue.number) · \(issue.title)")
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func noteKey(_ id: String) -> String {
        "assistant.note." + Data(id.utf8).base64EncodedString()
    }
}
