import Foundation

/// Which base the review panel diffs the worktree against.
enum ReviewDiffMode: String, Codable, Equatable {
    /// Worktree vs `HEAD`, including uncommitted + untracked changes.
    case uncommitted
    /// `HEAD` vs the merge-base with a base branch (default `origin/main`, falling back to
    /// local `main`/`master` -- see docs/plans/diff-review-panel.md §5 risk 6).
    case branch
}

enum ReviewDiffError: Equatable {
    case notGitRepository
    case unknownBaseBranch(String)
}

struct ReviewDiffSnapshot: Equatable {
    var files: [ReviewFileDiff] = []
    var generatedAt: Date = Date()
    var repositoryRoot: String?
    var resolvedBaseBranch: String?
    var error: ReviewDiffError?

    var diffableFileCount: Int {
        files.filter { $0.notDiffableReason == nil }.count
    }
}

/// Stateless git-subprocess probing for the diff review panel. Deliberately a sibling of
/// `GitMetadataProber` (not a modification of it -- that file's header comment scopes it to
/// sidebar git/PR metadata) mirroring its exact process-running shape: `Process` + stdout/stderr
/// `Pipe`s + a `DispatchSemaphore`/`terminationHandler` timeout pattern. See
/// docs/plans/diff-review-panel.md §3.
struct ReviewDiffProber {
    private struct CommandResult {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

    /// Files whose diff hunk text exceeds this many bytes are treated as "not diffable -- too
    /// large" rather than rendered in full, to keep the SwiftUI diff view responsive.
    static let maxDiffBytesPerFile: Int64 = 400_000

    private static let defaultTimeout: TimeInterval = 5.0

    private static let fallbackCommandSearchDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
    ]

    // MARK: - Public entry point

    nonisolated static func diffSnapshot(
        directory: String,
        mode: ReviewDiffMode,
        baseBranch: String
    ) -> ReviewDiffSnapshot {
        guard let repoRoot = repositoryRoot(directory: directory) else {
            return ReviewDiffSnapshot(repositoryRoot: nil, resolvedBaseBranch: nil, error: .notGitRepository)
        }

        switch mode {
        case .uncommitted:
            return uncommittedSnapshot(repoRoot: repoRoot)
        case .branch:
            return branchSnapshot(repoRoot: repoRoot, baseBranch: baseBranch)
        }
    }

    /// Cheap standalone "is this a git repo" check, used by `review.open` to fail fast with an
    /// `unavailable` error before creating a split (see docs/plans/diff-review-panel.md §2).
    nonisolated static func repositoryRoot(directory: String) -> String? {
        guard let output = runCommand(directory: directory, executable: "git", arguments: ["rev-parse", "--show-toplevel"]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Snapshot modes

    private nonisolated static func uncommittedSnapshot(repoRoot: String) -> ReviewDiffSnapshot {
        var files = diffAndOverrides(repoRoot: repoRoot, diffRangeArgs: ["HEAD"])
        files.append(contentsOf: untrackedFileDiffs(repoRoot: repoRoot))
        return ReviewDiffSnapshot(files: files, repositoryRoot: repoRoot, resolvedBaseBranch: nil, error: nil)
    }

    private nonisolated static func branchSnapshot(repoRoot: String, baseBranch: String) -> ReviewDiffSnapshot {
        for candidate in candidateBaseBranches(preferred: baseBranch) {
            let mergeBaseOutput = runCommand(directory: repoRoot, executable: "git", arguments: ["merge-base", "HEAD", candidate])
            guard let mergeBase = mergeBaseOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty else {
                continue
            }
            let files = diffAndOverrides(repoRoot: repoRoot, diffRangeArgs: ["\(mergeBase)..HEAD"])
            return ReviewDiffSnapshot(files: files, repositoryRoot: repoRoot, resolvedBaseBranch: candidate, error: nil)
        }
        return ReviewDiffSnapshot(repositoryRoot: repoRoot, resolvedBaseBranch: nil, error: .unknownBaseBranch(baseBranch))
    }

    /// Fallback chain for the "branch" mode base ref: the caller's requested base first, then
    /// local `main`, then `master`. See docs/plans/diff-review-panel.md §5 risk 6.
    private nonisolated static func candidateBaseBranches(preferred: String) -> [String] {
        var candidates = [preferred]
        if preferred != "main" { candidates.append("main") }
        if preferred != "master" { candidates.append("master") }
        return candidates
    }

    // MARK: - Diff + binary/size overrides

    private nonisolated static func diffAndOverrides(repoRoot: String, diffRangeArgs: [String]) -> [ReviewFileDiff] {
        let diffText = runCommand(
            directory: repoRoot,
            executable: "git",
            arguments: ["diff", "--no-color", "--find-renames"] + diffRangeArgs
        ) ?? ""
        var files = ReviewDiffParser.parse(diffText)
        let binaryPaths = binaryFilePaths(repoRoot: repoRoot, diffRangeArgs: diffRangeArgs)
        applyOverrides(files: &files, binaryPaths: binaryPaths)
        return files
    }

    /// `git diff --numstat` reports `-\t-\t<path>` for binary files -- a cheap single extra
    /// invocation used to build a binary-file set before the unified-diff parse, per
    /// docs/plans/diff-review-panel.md §3 point 4.
    private nonisolated static func binaryFilePaths(repoRoot: String, diffRangeArgs: [String]) -> Set<String> {
        guard let output = runCommand(
            directory: repoRoot,
            executable: "git",
            arguments: ["diff", "--numstat", "--find-renames"] + diffRangeArgs
        ) else {
            return []
        }
        var paths: Set<String> = []
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            guard columns.count >= 3, columns[0] == "-", columns[1] == "-" else { continue }
            paths.insert(String(columns[2]))
        }
        return paths
    }

    private nonisolated static func applyOverrides(files: inout [ReviewFileDiff], binaryPaths: Set<String>) {
        for index in files.indices {
            let path = files[index].newPath ?? files[index].oldPath
            if let path, binaryPaths.contains(path) {
                files[index].notDiffableReason = .binary
                files[index].hunks = []
                continue
            }
            let hunkByteCount = files[index].hunks.reduce(0) { total, hunk in
                total + hunk.lines.reduce(0) { $0 + $1.text.utf8.count }
            }
            if Int64(hunkByteCount) > maxDiffBytesPerFile {
                files[index].notDiffableReason = .tooLarge(sizeBytes: Int64(hunkByteCount))
                files[index].hunks = []
            }
        }
    }

    // MARK: - Untracked files

    private nonisolated static func untrackedFileDiffs(repoRoot: String) -> [ReviewFileDiff] {
        guard let output = runCommand(directory: repoRoot, executable: "git", arguments: ["ls-files", "--others", "--exclude-standard"]) else {
            return []
        }
        let paths = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return paths.map { untrackedFileDiff(repoRoot: repoRoot, path: $0) }
    }

    private nonisolated static func untrackedFileDiff(repoRoot: String, path: String) -> ReviewFileDiff {
        let fullPath = (repoRoot as NSString).appendingPathComponent(path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: fullPath)
        let size: Int64
        if let number = attributes?[.size] as? NSNumber {
            size = number.int64Value
        } else {
            size = 0
        }

        if size > maxDiffBytesPerFile {
            return ReviewFileDiff(oldPath: nil, newPath: path, status: .added, hunks: [], notDiffableReason: .tooLarge(sizeBytes: size))
        }
        if isLikelyBinary(fullPath: fullPath) {
            return ReviewFileDiff(oldPath: nil, newPath: path, status: .added, hunks: [], notDiffableReason: .binary)
        }
        return ReviewFileDiff(oldPath: nil, newPath: path, status: .added, hunks: [], notDiffableReason: .newUntrackedFile)
    }

    private nonisolated static func isLikelyBinary(fullPath: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: fullPath) else { return false }
        defer { handle.closeFile() }
        let sample = handle.readData(ofLength: 8000)
        return sample.contains(0)
    }

    // MARK: - Process plumbing (copied from GitMetadataProber's shape -- see file header)

    private nonisolated static func runCommand(directory: String, executable: String, arguments: [String]) -> String? {
        let result = runCommandResult(directory: directory, executable: executable, arguments: arguments, timeout: defaultTimeout)
        guard let result, result.exitStatus == 0, !result.timedOut else {
            return nil
        }
        return result.stdout
    }

    private nonisolated static func runCommandResult(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
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
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: false, executionError: String(describing: error))
        }

        if let timeout, completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil)
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
                guard !component.isEmpty, seenDirectories.insert(component).inserted else { continue }
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
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
