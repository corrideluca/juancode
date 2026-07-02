import Foundation
import JuancodeCore

public struct GithubProjectBoard: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var owner: String
    public var number: Int
    public var url: String
    public var title: String
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: String = UUID().uuidString, owner: String, number: Int, url: String,
                title: String, createdAt: Int, updatedAt: Int) {
        self.id = id
        self.owner = owner
        self.number = number
        self.url = url
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GithubProjectIssue: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var url: String
    public var body: String
    public var number: Int?
    public var repository: String
    public var assignees: [String]
    public var labels: [String]
    public var status: String
    public var priority: String

    public init(id: String, title: String, url: String, body: String, number: Int?,
                repository: String, assignees: [String], labels: [String],
                status: String, priority: String) {
        self.id = id
        self.title = title
        self.url = url
        self.body = body
        self.number = number
        self.repository = repository
        self.assignees = assignees
        self.labels = labels
        self.status = status
        self.priority = priority
    }
}

public struct GithubProjectItemsResult: Sendable, Equatable {
    public var available: Bool
    public var issues: [GithubProjectIssue]
    public var error: String?

    public init(available: Bool, issues: [GithubProjectIssue], error: String? = nil) {
        self.available = available
        self.issues = issues
        self.error = error
    }
}

private struct RawProjectItemsEnvelope: Decodable { var items: [RawProjectItem] }

private struct RawProjectItem: Decodable {
    var id: String?
    var title: String?
    var url: String?
    var status: String?
    var priority: String?
    var assignees: [String]?
    var labels: [String]?
    var repository: String?
    var content: RawProjectContent?
}

private struct RawProjectContent: Decodable {
    var body: String?
    var number: Int?
    var repository: String?
    var title: String?
    var type: String?
    var url: String?
}

public func parseGithubProjectURL(_ raw: String, now: Int) -> GithubProjectBoard? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
          url.host?.lowercased() == "github.com" else { return nil }
    let parts = url.path.split(separator: "/").map(String.init)
    guard parts.count == 4,
          parts[0] == "orgs",
          parts[2] == "projects",
          let number = Int(parts[3]) else { return nil }
    let owner = parts[1]
    return GithubProjectBoard(
        owner: owner,
        number: number,
        url: "https://github.com/orgs/\(owner)/projects/\(number)",
        title: "\(owner) Project #\(number)",
        createdAt: now,
        updatedAt: now)
}

public func getAssignedGithubProjectIssues(_ board: GithubProjectBoard, cwd: String) async -> GithubProjectItemsResult {
    do {
        let r = try await ProcessRunner.capture(
            ghBinForProjects(),
            ["project", "item-list", String(board.number),
             "--owner", board.owner,
             "--format", "json",
             "--limit", "100",
             "--query", "assignee:@me is:issue is:open"],
            cwd: cwd,
            maxBytes: 16 * 1024 * 1024)
        guard r.ok else {
            return GithubProjectItemsResult(
                available: false,
                issues: [],
                error: ghProjectErrorReason(ProcessError(
                    code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
                    launchFailed: false, timedOut: false)))
        }
        let raw = try JSONDecoder().decode(RawProjectItemsEnvelope.self, from: Data(r.stdout.utf8))
        return GithubProjectItemsResult(available: true, issues: parseGithubProjectItems(raw.items))
    } catch {
        return GithubProjectItemsResult(available: false, issues: [], error: ghProjectErrorReason(error))
    }
}

public func createGithubProjectDraftIssue(_ board: GithubProjectBoard, title: String, body: String, cwd: String) async -> String? {
    do {
        let r = try await ProcessRunner.capture(
            ghBinForProjects(),
            ["project", "item-create", String(board.number),
             "--owner", board.owner,
             "--title", title,
             "--body", body,
             "--format", "json"],
            cwd: cwd,
            maxBytes: 16 * 1024 * 1024)
        guard r.ok else { return nil }
        return r.stdout
    } catch {
        return nil
    }
}

private func parseGithubProjectItems(_ raw: [RawProjectItem]) -> [GithubProjectIssue] {
    raw.compactMap { item in
        let type = item.content?.type?.lowercased() ?? "issue"
        guard type == "issue" else { return nil }
        let url = item.content?.url ?? item.url ?? ""
        guard !url.isEmpty else { return nil }
        return GithubProjectIssue(
            id: item.id ?? url,
            title: item.content?.title ?? item.title ?? "",
            url: url,
            body: item.content?.body ?? "",
            number: item.content?.number,
            repository: normalizeProjectRepository(item.content?.repository ?? item.repository ?? ""),
            assignees: item.assignees ?? [],
            labels: item.labels ?? [],
            status: item.status ?? "",
            priority: item.priority ?? "")
    }
}

private func normalizeProjectRepository(_ raw: String) -> String {
    raw.replacingOccurrences(of: "https://github.com/", with: "")
}

private func ghBinForProjects() -> String {
    resolveBin("gh", override: ProcessInfo.processInfo.environment["JUANCODE_GH_BIN"])
}

private func ghProjectErrorReason(_ error: Error) -> String {
    guard let e = error as? ProcessError else { return "gh failed" }
    if e.launchFailed { return "gh CLI not installed" }
    let text = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.contains("project scope") || text.contains("gh auth refresh") {
        return "GitHub project scope missing. Run: gh auth refresh -s project"
    }
    if text.lowercased().contains("authentication") { return "gh not authenticated" }
    return text.split(separator: "\n").first.map(String.init) ?? "gh failed"
}
