import Foundation
import Bonsplit
import Darwin

struct CanonicalSubprocessResult {
    enum Outcome: Equatable {
        case exited
        case launchError(String)
        case timedOut
        case stdoutLimitExceeded
        case stderrLimitExceeded
        case decodingFailure
        case pipeReadFailure
    }

    let stdout: String?
    let stderr: String?
    let exitStatus: Int32?
    let outcome: Outcome

    var timedOut: Bool { outcome == .timedOut }
    var executionError: String? {
        switch outcome {
        case .exited:
            nil
        case .launchError(let message):
            message
        case .timedOut:
            nil
        case .stdoutLimitExceeded:
            "stdout exceeded its byte limit"
        case .stderrLimitExceeded:
            "stderr exceeded its byte limit"
        case .decodingFailure:
            "process output was not valid UTF-8"
        case .pipeReadFailure:
            "failed to read process output"
        }
    }
}

enum CanonicalSubprocessRunner {
    private static let terminationGrace: DispatchTimeInterval = .milliseconds(200)
    private static let pipeDrainGrace: DispatchTimeInterval = .milliseconds(500)

    private final class BoundedPipeCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var overflowed = false
        private var readFailed = false

        init(limit: Int) {
            self.limit = max(0, limit)
        }

        func consume(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !overflowed else { return }
            guard chunk.count <= limit - data.count else {
                overflowed = true
                data.removeAll(keepingCapacity: false)
                return
            }
            data.append(chunk)
        }

        func markReadFailed() {
            lock.lock()
            readFailed = true
            data.removeAll(keepingCapacity: false)
            lock.unlock()
        }

        func snapshot() -> (data: Data, overflowed: Bool, readFailed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, overflowed, readFailed)
        }
    }

    private final class WaitStatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?

        func store(_ status: Int32) {
            lock.lock()
            self.status = status
            lock.unlock()
        }

        func load() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            return status
        }
    }

    private static let fallbackSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String,
        timeout: TimeInterval?,
        stdoutLimit: Int,
        stderrLimit: Int,
        executableURL: URL? = nil,
        environmentOverrides: [String: String] = [:]
    ) -> CanonicalSubprocessResult {
        let stdout = Pipe()
        let stderr = Pipe()
        let launchPath: String
        let launchArguments: [String]
        if let resolvedURL = executableURL ?? resolvedExecutableURL(for: executable) {
            launchPath = resolvedURL.path
            launchArguments = arguments
        } else {
            launchPath = "/usr/bin/env"
            launchArguments = [executable] + arguments
        }

        let completion = DispatchSemaphore(value: 0)
        let processID: pid_t
        switch spawn(
            path: launchPath,
            arguments: launchArguments,
            currentDirectory: currentDirectory,
            environmentOverrides: environmentOverrides,
            stdout: stdout,
            stderr: stderr
        ) {
        case .success(let pid):
            processID = pid
        case .failure(let message):
            closeAllEnds(stdout, stderr)
            return CanonicalSubprocessResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                outcome: .launchError(message)
            )
        }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let waitStatus = WaitStatusBox()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 {
                if errno == EINTR { continue }
                break
            }
            waitStatus.store(status)
            completion.signal()
        }

        let stdoutCollector = BoundedPipeCollector(limit: stdoutLimit)
        let stderrCollector = BoundedPipeCollector(limit: stderrLimit)
        let readers = DispatchGroup()
        drain(stdout.fileHandleForReading, into: stdoutCollector, group: readers)
        drain(stderr.fileHandleForReading, into: stderrCollector, group: readers)

        let didTimeOut: Bool
        if let timeout {
            didTimeOut = completion.wait(timeout: .now() + timeout) == .timedOut
        } else {
            completion.wait()
            didTimeOut = false
        }

        if didTimeOut {
            _ = kill(-processID, SIGTERM)
            let leaderStillRunning = completion.wait(timeout: .now() + terminationGrace) == .timedOut
            // Always send SIGKILL after the grace period: the group leader may have exited on
            // SIGTERM while a descendant ignored it and still owns the output pipes.
            _ = kill(-processID, SIGKILL)
            if leaderStillRunning {
                _ = completion.wait(timeout: .now() + terminationGrace)
            }
            closeReadEnds(stdout, stderr)
        }

        if readers.wait(timeout: .now() + pipeDrainGrace) == .timedOut {
            closeReadEnds(stdout, stderr)
            guard readers.wait(timeout: .now() + terminationGrace) == .success else {
                return CanonicalSubprocessResult(
                    stdout: nil,
                    stderr: nil,
                    exitStatus: nil,
                    outcome: didTimeOut ? .timedOut : .pipeReadFailure
                )
            }
        }
        if didTimeOut {
            return CanonicalSubprocessResult(
                stdout: nil,
                stderr: nil,
                exitStatus: nil,
                outcome: .timedOut
            )
        }

        let exitStatus = waitStatus.load().map(terminationStatus(from:))
        let stdoutSnapshot = stdoutCollector.snapshot()
        let stderrSnapshot = stderrCollector.snapshot()
        if stdoutSnapshot.readFailed || stderrSnapshot.readFailed {
            return CanonicalSubprocessResult(
                stdout: nil,
                stderr: nil,
                exitStatus: exitStatus,
                outcome: .pipeReadFailure
            )
        }
        if stdoutSnapshot.overflowed {
            return CanonicalSubprocessResult(
                stdout: nil,
                stderr: nil,
                exitStatus: exitStatus,
                outcome: .stdoutLimitExceeded
            )
        }
        if stderrSnapshot.overflowed {
            return CanonicalSubprocessResult(
                stdout: nil,
                stderr: nil,
                exitStatus: exitStatus,
                outcome: .stderrLimitExceeded
            )
        }
        guard
            let stdoutString = String(data: stdoutSnapshot.data, encoding: .utf8),
            let stderrString = String(data: stderrSnapshot.data, encoding: .utf8)
        else {
            return CanonicalSubprocessResult(
                stdout: nil,
                stderr: nil,
                exitStatus: exitStatus,
                outcome: .decodingFailure
            )
        }
        return CanonicalSubprocessResult(
            stdout: stdoutString,
            stderr: stderrString,
            exitStatus: exitStatus,
            outcome: .exited
        )
    }

    private enum SpawnResult {
        case success(pid_t)
        case failure(String)
    }

    /// Uses `POSIX_SPAWN_SETPGROUP` so the child becomes a group leader atomically, before any
    /// executable code can fork. Timeout cleanup can therefore signal the exact launched tree
    /// without racing `exec` or risking Programa's own process group.
    private static func spawn(
        path: String,
        arguments: [String],
        currentDirectory: String,
        environmentOverrides: [String: String],
        stdout: Pipe,
        stderr: Pipe
    ) -> SpawnResult {
        var fileActions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            return .failure("could not initialize subprocess file actions")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            return .failure("could not initialize subprocess attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let stdoutReadFD = stdout.fileHandleForReading.fileDescriptor
        let stdoutWriteFD = stdout.fileHandleForWriting.fileDescriptor
        let stderrReadFD = stderr.fileHandleForReading.fileDescriptor
        let stderrWriteFD = stderr.fileHandleForWriting.fileDescriptor
        let actionResults = [
            posix_spawn_file_actions_adddup2(&fileActions, stdoutWriteFD, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, stderrWriteFD, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, stdoutReadFD),
            posix_spawn_file_actions_addclose(&fileActions, stderrReadFD),
            posix_spawn_file_actions_addclose(&fileActions, stdoutWriteFD),
            posix_spawn_file_actions_addclose(&fileActions, stderrWriteFD),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            return .failure("could not configure subprocess output pipes")
        }
        // The _np variant exists in every supported SDK; the non-_np name is
        // missing from the macOS 15 SDK, so referencing it breaks that build.
        let chdirResult = currentDirectory.withCString { directory in
            posix_spawn_file_actions_addchdir_np(&fileActions, directory)
        }
        guard chdirResult == 0 else {
            return .failure("could not configure subprocess working directory: \(String(cString: strerror(chdirResult)))")
        }
        let spawnFlags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        guard posix_spawnattr_setflags(&attributes, Int16(spawnFlags)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            return .failure("could not configure subprocess process group")
        }

        guard var argv = duplicatedCStringArray([path] + arguments),
              var environment = duplicatedCStringArray(
                  ProcessInfo.processInfo.environment
                      .merging(environmentOverrides) { _, override in override }
                      .map { "\($0.key)=\($0.value)" }
              ) else {
            return .failure("could not allocate subprocess arguments")
        }
        defer {
            freeCStringArray(&argv)
            freeCStringArray(&environment)
        }
        var pid: pid_t = 0
        let spawnResult = path.withCString { executablePath in
            argv.withUnsafeMutableBufferPointer { argvBuffer in
                environment.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &pid,
                        executablePath,
                        &fileActions,
                        &attributes,
                        argvBuffer.baseAddress!,
                        environmentBuffer.baseAddress!
                    )
                }
            }
        }
        guard spawnResult == 0 else {
            return .failure(String(cString: strerror(spawnResult)))
        }
        return .success(pid)
    }

    private static func duplicatedCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?]? {
        var result: [UnsafeMutablePointer<CChar>?] = []
        result.reserveCapacity(strings.count + 1)
        for string in strings {
            guard let copy = strdup(string) else {
                freeCStringArray(&result)
                return nil
            }
            result.append(copy)
        }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ strings: inout [UnsafeMutablePointer<CChar>?]) {
        for string in strings {
            free(string)
        }
        strings.removeAll()
    }

    private static func terminationStatus(from waitStatus: Int32) -> Int32 {
        let terminatingSignal = waitStatus & 0x7F
        return terminatingSignal == 0 ? (waitStatus >> 8) & 0xFF : terminatingSignal
    }

    private static func closeReadEnds(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
        }
    }

    private static func closeAllEnds(_ pipes: Pipe...) {
        for pipe in pipes {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }

    static func resolvedExecutableURL(
        for executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackDirectories: [String] = fallbackSearchDirectories
    ) -> URL? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            return fileManager.isExecutableFile(atPath: executable) ? URL(fileURLWithPath: executable) : nil
        }

        var directories: [String] = []
        var seen = Set<String>()
        func append(_ path: String?) {
            guard let path else { return }
            for raw in path.split(separator: ":") {
                let directory = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !directory.isEmpty, seen.insert(directory).inserted { directories.append(directory) }
            }
        }
        append(environment["PATH"])
        append(getenv("PATH").map { String(cString: $0) })
        append(Bundle.main.resourceURL?.appendingPathComponent("bin").path)
        fallbackDirectories.forEach { append($0) }
        append("/usr/bin:/bin:/usr/sbin:/sbin")

        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func drain(
        _ handle: FileHandle,
        into collector: BoundedPipeCollector,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { return }
                    collector.consume(chunk)
                } catch {
                    collector.markReadFailed()
                    return
                }
            }
        }
    }
}

// MARK: - Automatic git invocations

extension CanonicalSubprocessRunner {
    /// Options for every git command Programa runs on its own (sidebar polling, review diff,
    /// worktree helpers), placed before the subcommand. The working directory can be any path a
    /// terminal reported (including through OSC 7), so repository config there is untrusted:
    /// `core.fsmonitor` names a command git would run, `safe.bareRepository=explicit` stops a
    /// bare repository committed inside a checkout from being discovered, and
    /// `--no-optional-locks` keeps a background probe from taking `index.lock` while the user
    /// runs git themselves.
    static let automaticGitOptions: [String] = [
        "--no-optional-locks",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "safe.bareRepository=explicit",
    ]

    /// Environment for automatic git commands and for `gh`, which runs git internally where
    /// command-line `-c` cannot reach. `GIT_CONFIG_COUNT` entries apply at command-line scope,
    /// the same as `-c`.
    static let automaticGitEnvironment: [String: String] = [
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_CONFIG_COUNT": "3",
        "GIT_CONFIG_KEY_0": "core.fsmonitor",
        "GIT_CONFIG_VALUE_0": "false",
        "GIT_CONFIG_KEY_1": "core.untrackedCache",
        "GIT_CONFIG_VALUE_1": "false",
        "GIT_CONFIG_KEY_2": "safe.bareRepository",
        "GIT_CONFIG_VALUE_2": "explicit",
    ]

    static func automaticGitArguments(_ arguments: [String]) -> [String] {
        automaticGitOptions + arguments
    }

    /// Runs `git` with `automaticGitOptions` before `arguments` and `automaticGitEnvironment`.
    static func runAutomaticGit(
        arguments: [String],
        currentDirectory: String,
        timeout: TimeInterval?,
        stdoutLimit: Int,
        stderrLimit: Int,
        executableURL: URL? = nil
    ) -> CanonicalSubprocessResult {
        run(
            executable: "git",
            arguments: automaticGitArguments(arguments),
            currentDirectory: currentDirectory,
            timeout: timeout,
            stdoutLimit: stdoutLimit,
            stderrLimit: stderrLimit,
            executableURL: executableURL,
            environmentOverrides: automaticGitEnvironment
        )
    }
}

// MARK: - GitMetadataProber
//
// Stateless git/GitHub CLI probing library: given a working directory, runs `git`/`gh`
// commands and parses their output into workspace sidebar git/PR metadata. TabManager owns
// the stateful scheduling/timers/dedup around these probes, so the probing logic itself has
// no dependency on TabManager instance state and can be tested and reasoned about
// independently. The API surface is static. The one piece of shared state is the
// process-wide pull-request lookup throttle (`PullRequestLookupThrottle`), which limits the
// GitHub `gh` calls while the cheap local git probes keep their own cadence.
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

    // MARK: PR lookup throttle (DECISION D1)
    //
    // The local git probe runs every 5 s for the selected workspace; `gh pr list` and
    // `gh pr checks` are network calls to GitHub, so they run only when the branch of a
    // directory changes or the last answer is older than `pullRequestLookupRefreshInterval`.
    // After a `gh` failure the next attempt waits `pullRequestLookupBackoff(failures:)`.

    nonisolated static let pullRequestLookupRefreshInterval: TimeInterval = 60
    nonisolated static let pullRequestLookupMaxBackoff: TimeInterval = 600
    private nonisolated static let pullRequestLookupInitialBackoff: TimeInterval = 5
    private nonisolated static let pullRequestLookupCacheLimit = 256

    /// Wait before retrying `gh` after `failures` consecutive transient failures:
    /// 5 s, 10 s, 20 s, ... capped at 10 minutes. Starts short so the startup retry burst
    /// (TabManager's initial probe delays) can still recover from one slow first call.
    nonisolated static func pullRequestLookupBackoff(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(pullRequestLookupInitialBackoff * pow(2, exponent), pullRequestLookupMaxBackoff)
    }

    private final class PullRequestLookupThrottle: @unchecked Sendable {
        struct Entry {
            let branch: String
            var snapshot: WorkspacePullRequestSnapshot
            var lastAttemptAt: Date
            var consecutiveFailures: Int
        }

        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        /// The cached answer when a fresh `gh` lookup is not due yet, else nil.
        func cachedSnapshot(directory: String, branch: String, now: Date) -> WorkspacePullRequestSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[directory], entry.branch == branch else { return nil }
            let wait = entry.consecutiveFailures > 0
                ? GitMetadataProber.pullRequestLookupBackoff(failures: entry.consecutiveFailures)
                : GitMetadataProber.pullRequestLookupRefreshInterval
            return now.timeIntervalSince(entry.lastAttemptAt) < wait ? entry.snapshot : nil
        }

        func record(
            _ snapshot: WorkspacePullRequestSnapshot,
            directory: String,
            branch: String,
            now: Date,
            limit: Int
        ) {
            lock.lock()
            defer { lock.unlock() }
            let previous = entries[directory].flatMap { $0.branch == branch ? $0 : nil }
            if case .transientFailure = snapshot {
                // Keep showing the last good answer during the backoff.
                let lastGood = previous.map(\.snapshot).flatMap { cached -> WorkspacePullRequestSnapshot? in
                    if case .transientFailure = cached { return nil }
                    return cached
                }
                entries[directory] = Entry(
                    branch: branch,
                    snapshot: lastGood ?? .transientFailure,
                    lastAttemptAt: now,
                    consecutiveFailures: (previous?.consecutiveFailures ?? 0) + 1
                )
            } else {
                entries[directory] = Entry(branch: branch, snapshot: snapshot, lastAttemptAt: now, consecutiveFailures: 0)
            }
            if entries.count > limit,
               let oldest = entries.min(by: { $0.value.lastAttemptAt < $1.value.lastAttemptAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        }

        func removeAll() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
        }
    }

    private nonisolated static let pullRequestLookupThrottle = PullRequestLookupThrottle()

    nonisolated static func resetPullRequestLookupThrottleForTesting() {
        pullRequestLookupThrottle.removeAll()
    }

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
            arguments: arguments,
            timeout: workspacePullRequestProbeTimeout
        )
    }

    private nonisolated static func workspacePullRequestSnapshot(
        directory: String,
        branch: String
    ) -> WorkspacePullRequestSnapshot {
        guard !shouldSkipWorkspacePullRequestLookup(branch: branch) else {
            return .notFound
        }

        let now = Date()
        if let cached = pullRequestLookupThrottle.cachedSnapshot(directory: directory, branch: branch, now: now) {
            return cached
        }
        let snapshot = uncachedWorkspacePullRequestSnapshot(directory: directory, branch: branch)
        pullRequestLookupThrottle.record(
            snapshot,
            directory: directory,
            branch: branch,
            now: now,
            limit: pullRequestLookupCacheLimit
        )
        return snapshot
    }

    private nonisolated static func uncachedWorkspacePullRequestSnapshot(
        directory: String,
        branch: String
    ) -> WorkspacePullRequestSnapshot {
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
                  isWellFormedHTTPURL(pullRequest.url) else {
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

    /// `URL(string:)` alone is too permissive to catch malformed PR URLs: strings like
    /// "not a url" parse successfully as a relative-path URL with no scheme/host, so a
    /// plain `URL(string:) != nil` check does not reject them. Require an absolute
    /// http(s) URL with a non-empty host.
    private nonisolated static func isWellFormedHTTPURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
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

        guard !result.timedOut,
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

    private nonisolated static let commandStdoutLimit = 4 * 1024 * 1024
    private nonisolated static let commandStderrLimit = 1024 * 1024

    nonisolated static func resolvedCommandPathForTesting(
        executable: String,
        environment: [String: String],
        fallbackDirectories: [String]
    ) -> String? {
        CanonicalSubprocessRunner.resolvedExecutableURL(
            for: executable,
            environment: environment,
            fallbackDirectories: fallbackDirectories
        )?.path
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
        guard result.exitStatus == 0,
              !result.timedOut else {
            return nil
        }
        return result.stdout
    }

    /// Every probe here is automatic, so git gets `automaticGitOptions` and both git and `gh`
    /// get `automaticGitEnvironment`.
    private nonisolated static func runCommandResult(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval? = nil
    ) -> CanonicalSubprocessResult {
        CanonicalSubprocessRunner.run(
            executable: executable,
            arguments: executable == "git"
                ? CanonicalSubprocessRunner.automaticGitArguments(arguments)
                : arguments,
            currentDirectory: directory,
            timeout: timeout,
            stdoutLimit: commandStdoutLimit,
            stderrLimit: commandStderrLimit,
            environmentOverrides: CanonicalSubprocessRunner.automaticGitEnvironment
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
