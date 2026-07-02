import Foundation
import JuancodeCore

public struct GithubActionRun: Identifiable, Sendable, Equatable {
    public var id: Int
    public var title: String
    public var workflowName: String
    public var event: String
    public var status: String
    public var conclusion: String
    public var branch: String
    public var sha: String
    public var url: String
    public var createdAt: Date?
    public var startedAt: Date?
    public var updatedAt: Date?

    public init(id: Int, title: String, workflowName: String, event: String,
                status: String, conclusion: String, branch: String, sha: String,
                url: String, createdAt: Date?, startedAt: Date?, updatedAt: Date?) {
        self.id = id
        self.title = title
        self.workflowName = workflowName
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.branch = branch
        self.sha = sha
        self.url = url
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public struct GithubActionsResult: Sendable, Equatable {
    public var available: Bool
    public var runs: [GithubActionRun]
    public var error: String?

    public init(available: Bool, runs: [GithubActionRun], error: String? = nil) {
        self.available = available
        self.runs = runs
        self.error = error
    }
}

private struct RawActionRun: Decodable {
    var databaseId: Int?
    var displayTitle: String?
    var workflowName: String?
    var event: String?
    var status: String?
    var conclusion: String?
    var headBranch: String?
    var headSha: String?
    var url: String?
    var createdAt: String?
    var startedAt: String?
    var updatedAt: String?
}

private let actionRunFields = [
    "databaseId", "displayTitle", "workflowName", "event", "status",
    "conclusion", "headBranch", "headSha", "url", "createdAt", "startedAt", "updatedAt"
].joined(separator: ",")

public func getGithubActionRuns(repo: String, cwd: String, limit: Int = 30) async -> GithubActionsResult {
    do {
        let r = try await ProcessRunner.capture(
            ghBinForActions(),
            ["run", "list", "--repo", repo, "--limit", String(limit), "--json", actionRunFields],
            cwd: cwd,
            maxBytes: 16 * 1024 * 1024)
        guard r.ok else {
            return GithubActionsResult(
                available: false,
                runs: [],
                error: ghActionsErrorReason(ProcessError(
                    code: r.exitCode, stdout: r.stdout, stderr: r.stderr,
                    launchFailed: false, timedOut: false)))
        }
        let raw = try JSONDecoder().decode([RawActionRun].self, from: Data(r.stdout.utf8))
        return GithubActionsResult(available: true, runs: parseGithubActionRuns(raw))
    } catch {
        return GithubActionsResult(available: false, runs: [], error: ghActionsErrorReason(error))
    }
}

private func parseGithubActionRuns(_ raw: [RawActionRun]) -> [GithubActionRun] {
    raw.compactMap { r in
        guard let id = r.databaseId else { return nil }
        return GithubActionRun(
            id: id,
            title: r.displayTitle ?? "",
            workflowName: r.workflowName ?? "",
            event: r.event ?? "",
            status: r.status ?? "",
            conclusion: r.conclusion ?? "",
            branch: r.headBranch ?? "",
            sha: r.headSha ?? "",
            url: r.url ?? "",
            createdAt: parseGithubDate(r.createdAt),
            startedAt: parseGithubDate(r.startedAt),
            updatedAt: parseGithubDate(r.updatedAt))
    }
}

private func parseGithubDate(_ raw: String?) -> Date? {
    guard let raw else { return nil }
    return ISO8601DateFormatter().date(from: raw)
}

private func ghBinForActions() -> String {
    resolveBin("gh", override: ProcessInfo.processInfo.environment["JUANCODE_GH_BIN"])
}

private func ghActionsErrorReason(_ error: Error) -> String {
    guard let e = error as? ProcessError else { return "gh failed" }
    if e.launchFailed { return "gh CLI not installed" }
    let text = e.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.lowercased().contains("authentication") { return "gh not authenticated" }
    return text.split(separator: "\n").first.map(String.init) ?? "gh failed"
}
