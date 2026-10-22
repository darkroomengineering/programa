import Foundation

/// The review panel's answer to "is this workspace's pull request ready to merge?": PR state,
/// CI checks and unresolved review threads, read from GitHub through `gh`.
struct ReviewMergeReadiness: Equatable, Sendable {
    enum PullRequestState: Equatable, Sendable {
        case open
        case draft
        case merged
        case closed
    }

    let state: PullRequestState
    /// Names of failing checks, in GitHub's order, without duplicates.
    let failingCheckNames: [String]
    let pendingCheckCount: Int
    let passingCheckCount: Int
    /// nil when the review-thread query failed.
    let unresolvedThreadCount: Int?
    /// `gh`'s `mergeable`; `.unknown` while GitHub is still computing it, or for an unrecognized value.
    let mergeable: Mergeable
    /// `gh`'s `reviewDecision`; `.none` when the repository requires no review.
    let reviewDecision: ReviewDecision

    enum Mergeable: Equatable, Sendable {
        case mergeable
        case conflicting
        case unknown
    }

    enum ReviewDecision: Equatable, Sendable {
        case approved
        case changesRequested
        case reviewRequired
        case none
        case unknown
    }

    enum MergeBlocker: Equatable, Sendable {
        case conflicts
        case changesRequested
        case reviewRequired
    }

    /// The one blocker worth a row of its own. Pending or unrecognized values block readiness
    /// without a row.
    var mergeBlocker: MergeBlocker? {
        if mergeable == .conflicting { return .conflicts }
        switch reviewDecision {
        case .changesRequested:
            return .changesRequested
        case .reviewRequired:
            return .reviewRequired
        case .approved, .none, .unknown:
            return nil
        }
    }

    var isReadyToMerge: Bool {
        state == .open
            && failingCheckNames.isEmpty
            && pendingCheckCount == 0
            && unresolvedThreadCount == 0
            && mergeable == .mergeable
            && (reviewDecision == .approved || reviewDecision == .none)
    }
}

enum ReviewMergeReadinessResult: Equatable, Sendable {
    case loaded(ReviewMergeReadiness)
    /// `gh` is missing, not signed in, or the lookup failed.
    case unavailable
}

struct ReviewMergeReadinessState: Equatable, Sendable {
    let number: Int
    let url: URL
    /// nil until the first fetch for this pull request finishes.
    let result: ReviewMergeReadinessResult?
}

enum ReviewMergeReadinessProber {
    struct PullRequestCoordinates: Equatable, Sendable {
        let owner: String
        let name: String
        let number: Int
    }

    private static let timeout: TimeInterval = 10
    private static let stdoutLimit = 4 * 1024 * 1024
    private static let stderrLimit = 64 * 1024

    // SHORTCUT: counts the first 100 review threads. ceiling: a PR with more than 100 threads
    // undercounts. upgrade: paginate on pageInfo.endCursor once a PR that large shows up.
    private static let reviewThreadsQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) { nodes { isResolved } }
        }
      }
    }
    """

    /// Owner, repository and number from a `https://github.com/<owner>/<repo>/pull/<n>` URL.
    nonisolated static func coordinates(from url: URL) -> PullRequestCoordinates? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else {
            return nil
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 4,
              components[2] == "pull",
              let number = Int(components[3]), number > 0,
              !components[0].isEmpty, !components[1].isEmpty else {
            return nil
        }
        return PullRequestCoordinates(owner: components[0], name: components[1], number: number)
    }

    /// Runs `gh` twice (PR view, then the review-thread GraphQL query). Blocks; call off-main.
    nonisolated static func fetch(pullRequestURL: URL, directory: String) -> ReviewMergeReadinessResult {
        guard let coordinates = coordinates(from: pullRequestURL),
              let pullRequestJSON = runGitHubCLI(
                  [
                      "pr", "view", pullRequestURL.absoluteString,
                      "--json", "state,isDraft,statusCheckRollup,mergeable,reviewDecision",
                  ],
                  directory: directory
              ) else {
            return .unavailable
        }
        let reviewThreadsJSON = runGitHubCLI(
            [
                "api", "graphql",
                "-f", "query=\(reviewThreadsQuery)",
                "-f", "owner=\(coordinates.owner)",
                "-f", "name=\(coordinates.name)",
                "-F", "number=\(coordinates.number)",
            ],
            directory: directory
        )
        guard let readiness = parse(pullRequestJSON: pullRequestJSON, reviewThreadsJSON: reviewThreadsJSON) else {
            return .unavailable
        }
        return .loaded(readiness)
    }

    private nonisolated static func runGitHubCLI(_ arguments: [String], directory: String) -> String? {
        let result = CanonicalSubprocessRunner.run(
            executable: "gh",
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit,
            environmentOverrides: CanonicalSubprocessRunner.automaticGitEnvironment
        )
        guard result.outcome == .exited, result.exitStatus == 0 else { return nil }
        return result.stdout
    }

    // MARK: - Parsing

    private struct PullRequestPayload: Decodable {
        let state: String
        let isDraft: Bool?
        let statusCheckRollup: [CheckPayload]?
        let mergeable: String?
        let reviewDecision: String?
    }

    /// `CheckRun` entries carry `name`/`status`/`conclusion`; `StatusContext` entries carry
    /// `context`/`state`.
    private struct CheckPayload: Decodable {
        let name: String?
        let context: String?
        let status: String?
        let conclusion: String?
        let state: String?
    }

    private struct ReviewThreadsPayload: Decodable {
        struct DataPayload: Decodable { let repository: RepositoryPayload? }
        struct RepositoryPayload: Decodable { let pullRequest: PullRequestThreadsPayload? }
        struct PullRequestThreadsPayload: Decodable { let reviewThreads: ThreadConnection }
        struct ThreadConnection: Decodable { let nodes: [ThreadNode?] }
        struct ThreadNode: Decodable { let isResolved: Bool }

        let data: DataPayload?
    }

    private enum CheckOutcome {
        case failing
        case pending
        case passing
    }

    /// Parses `gh pr view --json state,isDraft,statusCheckRollup,mergeable,reviewDecision` and the review-thread GraphQL
    /// response. nil when the PR JSON is unusable; a missing or unusable thread response leaves
    /// `unresolvedThreadCount` nil.
    nonisolated static func parse(pullRequestJSON: String, reviewThreadsJSON: String?) -> ReviewMergeReadiness? {
        guard let payload = decode(PullRequestPayload.self, from: pullRequestJSON) else { return nil }

        let state: ReviewMergeReadiness.PullRequestState
        switch payload.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN":
            state = payload.isDraft == true ? .draft : .open
        case "MERGED":
            state = .merged
        case "CLOSED":
            state = .closed
        default:
            return nil
        }

        var failingCheckNames: [String] = []
        var pendingCheckCount = 0
        var passingCheckCount = 0
        for check in payload.statusCheckRollup ?? [] {
            switch outcome(of: check) {
            case .failing:
                let name = normalized(check.name) ?? normalized(check.context)
                    ?? String(localized: "review.readiness.checks.unnamed", defaultValue: "Unnamed check")
                if !failingCheckNames.contains(name) {
                    failingCheckNames.append(name)
                }
            case .pending:
                pendingCheckCount += 1
            case .passing:
                passingCheckCount += 1
            }
        }

        return ReviewMergeReadiness(
            state: state,
            failingCheckNames: failingCheckNames,
            pendingCheckCount: pendingCheckCount,
            passingCheckCount: passingCheckCount,
            unresolvedThreadCount: reviewThreadsJSON.flatMap(unresolvedThreadCount(from:)),
            mergeable: mergeable(from: payload.mergeable),
            reviewDecision: reviewDecision(from: payload.reviewDecision)
        )
    }

    private nonisolated static func mergeable(from raw: String?) -> ReviewMergeReadiness.Mergeable {
        switch normalized(raw)?.uppercased() {
        case "MERGEABLE":
            return .mergeable
        case "CONFLICTING":
            return .conflicting
        default:
            return .unknown
        }
    }

    private nonisolated static func reviewDecision(from raw: String?) -> ReviewMergeReadiness.ReviewDecision {
        switch normalized(raw)?.uppercased() {
        case nil:
            return .none
        case "APPROVED":
            return .approved
        case "CHANGES_REQUESTED":
            return .changesRequested
        case "REVIEW_REQUIRED":
            return .reviewRequired
        default:
            return .unknown
        }
    }

    private nonisolated static func unresolvedThreadCount(from json: String) -> Int? {
        guard let threads = decode(ReviewThreadsPayload.self, from: json)?.data?.repository?.pullRequest?.reviewThreads else {
            return nil
        }
        return threads.nodes.compactMap { $0 }.filter { !$0.isResolved }.count
    }

    /// Fails closed: a completed check is passing only for a known passing value, so STALE or
    /// any value GitHub adds later counts as failing.
    private nonisolated static func outcome(of check: CheckPayload) -> CheckOutcome {
        if let conclusion = normalized(check.conclusion)?.lowercased() {
            switch conclusion {
            case "success", "neutral", "skipped":
                return .passing
            default:
                return .failing
            }
        }
        if let state = normalized(check.state)?.lowercased() {
            switch state {
            case "success":
                return .passing
            case "pending", "expected":
                return .pending
            default:
                return .failing
            }
        }
        if let status = normalized(check.status)?.lowercased(), status != "completed" {
            return .pending
        }
        return .failing
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private nonisolated static func decode<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
