import Foundation
import Bonsplit

// MARK: - GitMetadataProber
//
// Stateless git/GitHub CLI probing library: given a working directory, runs `git`/`gh`
// commands and parses their output into workspace sidebar git/PR metadata. Extracted from
// TabManager (which owns the stateful scheduling/timers/dedup around these probes) so the
// probing logic itself has no dependency on TabManager instance state and can be tested and
// reasoned about independently. A `struct` (not an `enum` namespace) so TabManager can hold
// a thin owned instance; the API surface itself remains static/stateless.
struct GitMetadataProber {
    enum WorkspacePullRequestSnapshot: Equatable {
        case unsupportedRepository
        case notFound
        case resolved(SidebarPullRequestState)
        case transientFailure
    }

    struct InitialWorkspaceGitMetadataSnapshot: Equatable {
        let branch: String?
        let isDirty: Bool
        let pullRequest: WorkspacePullRequestSnapshot
    }

    private struct CommandResult {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

    struct GitHubPullRequestProbeItem: Decodable, Equatable {
        let number: Int
        let state: String
        let url: String
        let updatedAt: String?
    }

    private struct GitHubPullRequestCheckItem: Decodable {
        let bucket: String?
        let state: String?
    }

    private nonisolated static let workspacePullRequestProbeTimeout: TimeInterval = 5.0

    // Widened from `private` to `internal`: called from TabManager.swift.
    nonisolated static func initialWorkspaceGitMetadataSnapshot(
        for directory: String
    ) -> InitialWorkspaceGitMetadataSnapshot {
        let branch = normalizedBranchName(runGitCommand(directory: directory, arguments: ["branch", "--show-current"]))
        guard let branch else {
            return InitialWorkspaceGitMetadataSnapshot(
                branch: nil,
                isDirty: false,
                pullRequest: .notFound
            )
        }

        let statusOutput = runGitCommand(directory: directory, arguments: ["status", "--porcelain", "-uno"])
        let isDirty = !(statusOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let pullRequest = workspacePullRequestSnapshot(directory: directory, branch: branch)
        return InitialWorkspaceGitMetadataSnapshot(branch: branch, isDirty: isDirty, pullRequest: pullRequest)
    }

    private nonisolated static func runGitCommand(directory: String, arguments: [String]) -> String? {
        runCommand(
            directory: directory,
            executable: "git",
            arguments: arguments
        )
    }

    private nonisolated static func workspacePullRequestSnapshot(
        directory: String,
        branch: String
    ) -> WorkspacePullRequestSnapshot {
        guard !shouldSkipWorkspacePullRequestLookup(branch: branch) else {
            return .notFound
        }

        let repoSlugs = githubRepositorySlugs(directory: directory)
        guard !repoSlugs.isEmpty else {
            return .unsupportedRepository
        }

        var sawTransientFailure = false
        for repoSlug in repoSlugs {
            switch workspacePullRequestSnapshot(directory: directory, branch: branch, repoSlug: repoSlug) {
            case .resolved(let pullRequest):
                return .resolved(pullRequest)
            case .transientFailure:
                sawTransientFailure = true
            case .notFound, .unsupportedRepository:
                continue
            }
        }

        return sawTransientFailure ? .transientFailure : .notFound
    }

    private nonisolated static func workspacePullRequestSnapshot(
        directory: String,
        branch: String,
        repoSlug: String
    ) -> WorkspacePullRequestSnapshot {
        let result = runCommandResult(
            directory: directory,
            executable: "gh",
            arguments: [
                "pr", "list",
                "--repo", repoSlug,
                "--state", "all",
                "--head", branch,
                "--json", "number,state,url,updatedAt",
            ],
            timeout: workspacePullRequestProbeTimeout
        )

        guard let result else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=nil"
            )
#endif
            return .transientFailure
        }

        guard !result.timedOut,
              result.executionError == nil,
              let exitStatus = result.exitStatus else {
#if DEBUG
            let statusText: String
            if result.timedOut {
                statusText = "timeout"
            } else if let executionError = result.executionError {
                statusText = "error=\(executionError)"
            } else {
                statusText = "unknown"
            }
            let stderr = debugLogSnippet(result.stderr) ?? "none"
            dlog(
                "workspace.gitProbe.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=\(statusText) stderr=\(stderr)"
            )
#endif
            return .transientFailure
        }

        if exitStatus != 0 {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.fail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) status=exit=\(exitStatus) stderr=\(debugLogSnippet(result.stderr) ?? "none")"
            )
#endif
            return .transientFailure
        }

        let output = result.stdout ?? ""
        guard let pullRequests = decodeJSON([GitHubPullRequestProbeItem].self, from: output) else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.parseFail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) output=\(debugLogSnippet(output) ?? "none")"
            )
#endif
            return .transientFailure
        }

        guard let pullRequest = preferredPullRequest(from: pullRequests) else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.none dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug)"
            )
#endif
            return .notFound
        }

        guard let status = pullRequestStatus(from: pullRequest.state),
              let url = URL(string: pullRequest.url) else {
#if DEBUG
            dlog(
                "workspace.gitProbe.pr.parseFail dir=\(directory) branch=\(branch) " +
                "repo=\(repoSlug) output=\(debugLogSnippet(output) ?? "none")"
            )
#endif
            return .transientFailure
        }

        let checks = status == .open
            ? pullRequestChecksStatus(number: pullRequest.number, directory: directory, repoSlug: repoSlug)
            : nil

#if DEBUG
        dlog(
            "workspace.gitProbe.pr.success dir=\(directory) branch=\(branch) " +
            "repo=\(repoSlug) number=\(pullRequest.number) state=\(status.rawValue) checks=\(checks?.rawValue ?? "none")"
        )
#endif
        return .resolved(
            SidebarPullRequestState(
                number: pullRequest.number,
                label: "PR",
                url: url,
                status: status,
                branch: branch,
                checks: checks
            )
        )
    }

    nonisolated static func preferredPullRequest(
        from pullRequests: [GitHubPullRequestProbeItem]
    ) -> GitHubPullRequestProbeItem? {
        func statusPriority(_ status: SidebarPullRequestStatus) -> Int {
            switch status {
            case .open:
                return 3
            case .merged:
                return 2
            case .closed:
                return 1
            }
        }

        func isPreferred(
            candidate: GitHubPullRequestProbeItem,
            over current: GitHubPullRequestProbeItem
        ) -> Bool {
            guard let candidateStatus = pullRequestStatus(from: candidate.state),
                  let currentStatus = pullRequestStatus(from: current.state) else {
                return false
            }

            let candidatePriority = statusPriority(candidateStatus)
            let currentPriority = statusPriority(currentStatus)
            if candidatePriority != currentPriority {
                return candidatePriority > currentPriority
            }

            let candidateUpdatedAt = candidate.updatedAt ?? ""
            let currentUpdatedAt = current.updatedAt ?? ""
            if candidateUpdatedAt != currentUpdatedAt {
                return candidateUpdatedAt > currentUpdatedAt
            }

            return candidate.number > current.number
        }

        var best: GitHubPullRequestProbeItem?
        for pullRequest in pullRequests {
            guard pullRequestStatus(from: pullRequest.state) != nil,
                  URL(string: pullRequest.url) != nil else {
                continue
            }
            guard let currentBest = best else {
                best = pullRequest
                continue
            }
            if isPreferred(candidate: pullRequest, over: currentBest) {
                best = pullRequest
            }
        }
        return best
    }

    private nonisolated static func pullRequestChecksStatus(
        number: Int,
        directory: String,
        repoSlug: String
    ) -> SidebarPullRequestChecksStatus? {
        let result = runCommandResult(
            directory: directory,
            executable: "gh",
            arguments: [
                "pr", "checks", String(number),
                "--repo", repoSlug,
                "--json", "bucket,state"
            ],
            timeout: workspacePullRequestProbeTimeout
        )

        guard let result,
              !result.timedOut,
              result.executionError == nil,
              let output = result.stdout,
              let exitStatus = result.exitStatus,
              exitStatus == 0 || exitStatus == 8,
              let checks = decodeJSON([GitHubPullRequestCheckItem].self, from: output) else {
            return nil
        }

        var sawPending = false
        var sawPass = false

        for check in checks {
            let bucket = check.bucket?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let state = check.state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if isFailingCheckState(bucket: bucket, state: state) {
                return .fail
            }
            if isPendingCheckState(bucket: bucket, state: state) {
                sawPending = true
                continue
            }
            if isPassingCheckState(bucket: bucket, state: state) {
                sawPass = true
            }
        }

        if sawPending {
            return .pending
        }
        if sawPass {
            return .pass
        }
        return nil
    }

    private nonisolated static func pullRequestStatus(
        from rawState: String
    ) -> SidebarPullRequestStatus? {
        switch rawState.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN":
            return .open
        case "MERGED":
            return .merged
        case "CLOSED":
            return .closed
        default:
            return nil
        }
    }

    private nonisolated static func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private nonisolated static func isFailingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "fail", "failure", "failed", "error", "timed_out", "timedout",
             "cancel", "cancelled", "canceled", "action_required", "startup_failure":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPendingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "pending", "queued", "in_progress", "requested", "waiting", "expected":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isPassingCheckState(bucket: String?, state: String?) -> Bool {
        switch bucket ?? state ?? "" {
        case "pass", "success", "successful", "completed", "neutral", "skipping", "skipped":
            return true
        default:
            return false
        }
    }

    private nonisolated static let fallbackCommandSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    nonisolated static func resolvedCommandPathForTesting(
        executable: String,
        environment: [String: String],
        fallbackDirectories: [String]
    ) -> String? {
        resolvedCommandPath(
            executable: executable,
            environment: environment,
            fallbackDirectories: fallbackDirectories
        )
    }

    private nonisolated static func resolvedCommandPath(
        executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = fallbackCommandSearchDirectories
    ) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        var searchDirectories: [String] = []
        var seenDirectories: Set<String> = []

        func appendSearchPath(_ path: String?) {
            guard let path else { return }
            for rawComponent in path.split(separator: ":") {
                let component = String(rawComponent).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !component.isEmpty,
                      seenDirectories.insert(component).inserted else {
                    continue
                }
                searchDirectories.append(component)
            }
        }

        appendSearchPath(environment["PATH"])
        appendSearchPath(getenv("PATH").map { String(cString: $0) })
        if let bundledBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            appendSearchPath(bundledBinPath)
        }
        fallbackDirectories.forEach { appendSearchPath($0) }
        appendSearchPath("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func runCommand(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> String? {
        let result = runCommandResult(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        guard let result,
              result.exitStatus == 0,
              !result.timedOut else {
            return nil
        }
        return result.stdout
    }

    private nonisolated static func runCommandResult(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        if let resolvedExecutable = resolvedCommandPath(executable: executable) {
            process.executableURL = URL(fileURLWithPath: resolvedExecutable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = stdout
        process.standardError = stderr

        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: false,
                executionError: String(describing: error)
            )
        }

        if let timeout,
           completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return CommandResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                timedOut: true,
                executionError: nil
            )
        } else if timeout == nil {
            completion.wait()
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            stdout: String(data: stdoutData, encoding: .utf8),
            stderr: String(data: stderrData, encoding: .utf8),
            exitStatus: process.terminationStatus,
            timedOut: false,
            executionError: nil
        )
    }

    nonisolated static func githubRepositorySlugs(fromGitRemoteVOutput output: String) -> [String] {
        var slugByRemoteName: [String: String] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3 else { continue }

            let remoteName = String(parts[0])
            let remoteURL = String(parts[1])
            let remoteKind = String(parts[2])
            guard remoteKind == "(fetch)",
                  let repoSlug = githubRepositorySlug(fromRemoteURL: remoteURL) else {
                continue
            }

            if slugByRemoteName[remoteName] == nil {
                slugByRemoteName[remoteName] = repoSlug
            }
        }

        let orderedRemoteNames = slugByRemoteName.keys.sorted { lhs, rhs in
            let lhsPriority = githubRemotePriority(lhs)
            let rhsPriority = githubRemotePriority(rhs)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }

        var orderedSlugs: [String] = []
        var seen: Set<String> = []
        for remoteName in orderedRemoteNames {
            guard let repoSlug = slugByRemoteName[remoteName],
                  seen.insert(repoSlug).inserted else {
                continue
            }
            orderedSlugs.append(repoSlug)
        }
        return orderedSlugs
    }

    private nonisolated static func githubRepositorySlugs(directory: String) -> [String] {
        guard let output = runGitCommand(directory: directory, arguments: ["remote", "-v"]) else {
            return []
        }
        return githubRepositorySlugs(fromGitRemoteVOutput: output)
    }

    private nonisolated static func githubRemotePriority(_ remoteName: String) -> Int {
        switch remoteName.lowercased() {
        case "upstream":
            return 0
        case "origin":
            return 1
        default:
            return 2
        }
    }

    private nonisolated static func githubRepositorySlug(fromRemoteURL remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let githubPrefixes = [
            "git@github.com:",
            "ssh://git@github.com/",
            "https://github.com/",
            "http://github.com/",
            "git://github.com/",
        ]
        for prefix in githubPrefixes where trimmed.hasPrefix(prefix) {
            let path = String(trimmed.dropFirst(prefix.count))
            return normalizedGitHubRepositorySlug(path)
        }

        guard let url = URL(string: trimmed),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }

        return normalizedGitHubRepositorySlug(url.path)
    }

    private nonisolated static func normalizedGitHubRepositorySlug(_ rawPath: String) -> String? {
        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else { return nil }
        let components = trimmedPath.split(separator: "/").map(String.init)
        guard components.count >= 2 else { return nil }
        let owner = components[0]
        var repo = components[1]
        if repo.hasSuffix(".git") {
            repo.removeLast(4)
        }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)"
    }

    private nonisolated static func debugLogSnippet(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(180))
    }

    // Widened from `private` to `internal`: called from TabManager.swift.
    nonisolated static func normalizedBranchName(_ branch: String?) -> String? {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func shouldSkipWorkspacePullRequestLookup(branch: String) -> Bool {
        switch normalizedBranchName(branch) {
        case "main", "master":
            return true
        default:
            return false
        }
    }
}
