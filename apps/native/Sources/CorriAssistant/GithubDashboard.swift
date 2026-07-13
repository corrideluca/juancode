import Foundation
import JuancodeServices

enum GithubDashboard {
    private struct RawRepo: Decodable { let nameWithOwner: String? }
    private struct RawLabel: Decodable { let name: String? }
    private struct RawPR: Decodable {
        let number: Int
        let title: String
        let repository: RawRepo
        let url: String
        let updatedAt: String?
        let isDraft: Bool?
    }
    private struct RawIssue: Decodable {
        let number: Int
        let title: String
        let repository: RawRepo
        let url: String
        let updatedAt: String?
        let labels: [RawLabel]?
    }
    private struct RawRun: Decodable {
        let databaseId: Int
        let displayTitle: String?
        let workflowName: String?
        let headBranch: String?
        let status: String?
        let conclusion: String?
        let url: String?
        let updatedAt: String?
    }

    static func load(extraRepositories: [String]) async -> GithubSnapshot {
        async let loginResult = command(["api", "user", "--jq", ".login"])
        async let prsResult = command([
            "search", "prs", "--author=@me", "--state=open", "--limit", "50",
            "--json", "number,title,repository,url,updatedAt,isDraft",
        ])
        async let issuesResult = command([
            "search", "issues", "--assignee=@me", "--state=open", "--limit", "50",
            "--json", "number,title,repository,url,updatedAt,labels",
        ])

        let (loginCapture, prCapture, issueCapture) = await (loginResult, prsResult, issuesResult)
        var errors: [String] = []
        let login = value(loginCapture, label: "GitHub account", errors: &errors)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prs: [PullRequestItem] = decode(prCapture, label: "Pull requests", errors: &errors) { (raw: RawPR) in
            PullRequestItem(number: raw.number, title: raw.title,
                            repository: raw.repository.nameWithOwner ?? "", url: raw.url,
                            updatedAt: DashboardDate.parse(raw.updatedAt), isDraft: raw.isDraft ?? false)
        }
        let issues: [GithubIssueItem] = decode(issueCapture, label: "Assigned issues", errors: &errors) { (raw: RawIssue) in
            GithubIssueItem(number: raw.number, title: raw.title,
                            repository: raw.repository.nameWithOwner ?? "", url: raw.url,
                            updatedAt: DashboardDate.parse(raw.updatedAt),
                            labels: (raw.labels ?? []).compactMap(\.name))
        }

        var repositories = Set(extraRepositories.filter { $0.contains("/") })
        repositories.formUnion(prs.map(\.repository).filter { !$0.isEmpty })
        repositories.formUnion(issues.map(\.repository).filter { !$0.isEmpty })
        let actionResults = await withTaskGroup(of: ([ActionItem], String?).self) { group in
            for repository in repositories.prefix(10) {
                group.addTask { await loadActions(repository: repository) }
            }
            var actions: [ActionItem] = []
            var actionErrors: [String] = []
            for await (items, error) in group {
                actions.append(contentsOf: items)
                if let error { actionErrors.append(error) }
            }
            return (actions, actionErrors)
        }
        errors.append(contentsOf: actionResults.1.prefix(2))
        return GithubSnapshot(
            login: login,
            pullRequests: prs.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) },
            issues: issues.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) },
            actions: actionResults.0.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) },
            errors: errors)
    }

    private static func loadActions(repository: String) async -> ([ActionItem], String?) {
        let fields = "databaseId,displayTitle,workflowName,headBranch,status,conclusion,url,updatedAt"
        let capture = await command(["run", "list", "--repo", repository, "--limit", "8", "--json", fields])
        guard capture.result?.ok == true else {
            return ([], "Actions (\(repository)): \(capture.errorText)")
        }
        do {
            let raw = try JSONDecoder().decode([RawRun].self, from: Data((capture.result?.stdout ?? "").utf8))
            return (raw.map {
                ActionItem(id: $0.databaseId, title: $0.displayTitle ?? "", workflow: $0.workflowName ?? "",
                           repository: repository, branch: $0.headBranch ?? "", status: $0.status ?? "",
                           conclusion: $0.conclusion ?? "", url: $0.url ?? "",
                           updatedAt: DashboardDate.parse($0.updatedAt))
            }, nil)
        } catch {
            return ([], "Actions (\(repository)): invalid response")
        }
    }

    private struct Capture: Sendable {
        let result: ProcessResult?
        let errorText: String
    }

    private static func command(_ args: [String]) async -> Capture {
        do {
            let result = try await ProcessRunner.capture("gh", args, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return Capture(result: result, errorText: message.isEmpty ? "gh exited with \(result.exitCode)" : message)
        } catch let error as ProcessError {
            return Capture(result: nil, errorText: error.message)
        } catch {
            return Capture(result: nil, errorText: String(describing: error))
        }
    }

    private static func value(_ capture: Capture, label: String, errors: inout [String]) -> String {
        guard let result = capture.result, result.ok else {
            errors.append("\(label): \(capture.errorText)")
            return ""
        }
        return result.stdout
    }

    private static func decode<Raw: Decodable, Value>(
        _ capture: Capture, label: String, errors: inout [String], transform: (Raw) -> Value
    ) -> [Value] {
        guard let result = capture.result, result.ok else {
            errors.append("\(label): \(capture.errorText)")
            return []
        }
        do {
            return try JSONDecoder().decode([Raw].self, from: Data(result.stdout.utf8)).map(transform)
        } catch {
            errors.append("\(label): could not read gh response")
            return []
        }
    }
}
