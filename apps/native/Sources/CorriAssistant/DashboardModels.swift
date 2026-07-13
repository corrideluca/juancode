import Foundation

struct PullRequestItem: Codable, Identifiable, Equatable, Sendable {
    let number: Int
    let title: String
    let repository: String
    let url: String
    let updatedAt: Date?
    let isDraft: Bool

    var id: String { url }
}

struct GithubIssueItem: Codable, Identifiable, Equatable, Sendable {
    let number: Int
    let title: String
    let repository: String
    let url: String
    let updatedAt: Date?
    let labels: [String]

    var id: String { url }
}

struct ActionItem: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let workflow: String
    let repository: String
    let branch: String
    let status: String
    let conclusion: String
    let url: String
    let updatedAt: Date?

    var isProblem: Bool {
        ["failure", "cancelled", "timed_out", "action_required"].contains(conclusion.lowercased())
    }

    var isRunning: Bool { status.lowercased() != "completed" }
}

struct CalendarItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let calendar: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let url: URL?
    let meetingURL: URL?
    let location: String
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

struct GithubSnapshot: Sendable {
    let login: String
    let pullRequests: [PullRequestItem]
    let issues: [GithubIssueItem]
    let actions: [ActionItem]
    let errors: [String]
}

enum DashboardDate {
    static let github: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return github.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
