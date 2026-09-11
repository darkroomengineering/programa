import Foundation

/// Which base the review panel diffs the worktree against.
enum ReviewDiffMode: String, Codable, Equatable, Sendable {
    /// Worktree vs `HEAD`, including uncommitted + untracked changes.
    case uncommitted
    /// `HEAD` vs the merge-base with a base branch (default `origin/main`, falling back to
    /// local `main`/`master` -- see docs/plans/diff-review-panel.md §5 risk 6).
    case branch
}

enum ReviewDiffError: Error, Equatable, Sendable {
    case notGitRepository
    case unknownBaseBranch(String)
    /// A git subprocess needed to build the diff (or its binary/numstat override pass) exited
    /// non-zero, timed out, or otherwise didn't run to completion. Surfaced explicitly instead
    /// of being folded into an empty diff, so a failed probe never reads as "no changes" -- see
    /// M12 in docs/audits/codebase-audit-2026-09-11.md.
    case commandFailed(String)
}

struct ReviewDiffSnapshot: Equatable, Sendable {
    var files: [ReviewFileDiff] = []
    var generatedAt: Date = Date()
    var repositoryRoot: String?
    var resolvedBaseBranch: String?
    var error: ReviewDiffError?

    var diffableFileCount: Int {
        files.filter { $0.notDiffableReason == nil }.count
    }
}

/// Stateless git-subprocess probing for the diff review panel.
struct ReviewDiffProber {
    /// Files whose diff hunk text exceeds this many bytes are treated as "not diffable -- too
    /// large" rather than rendered in full, to keep the SwiftUI diff view responsive.
    static let maxDiffBytesPerFile: Int64 = 400_000

    private static let defaultTimeout: TimeInterval = 5.0
    private static let commandStdoutLimit = 32 * 1024 * 1024
    private static let commandStderrLimit = 1024 * 1024

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
        // `HEAD` doesn't resolve on an unborn branch (a repo with commits never made yet). Diff
        // against the empty tree in that case so staged files before the first commit still show
        // up as added, instead of `git diff HEAD` failing and (previously) reading as clean.
        let diffRangeArgs = headDiffRangeArgs(repoRoot: repoRoot)
        switch diffAndOverrides(repoRoot: repoRoot, diffRangeArgs: diffRangeArgs) {
        case .failure(let error):
            // A failed diff must never look clean: skip the untracked-file merge and surface the
            // error instead of returning a partial (or empty) file list.
            return ReviewDiffSnapshot(files: [], repositoryRoot: repoRoot, resolvedBaseBranch: nil, error: error)
        case .success(var files):
            files.append(contentsOf: untrackedFileDiffs(repoRoot: repoRoot))
            return ReviewDiffSnapshot(files: files, repositoryRoot: repoRoot, resolvedBaseBranch: nil, error: nil)
        }
    }

    private nonisolated static func branchSnapshot(repoRoot: String, baseBranch: String) -> ReviewDiffSnapshot {
        for candidate in candidateBaseBranches(preferred: baseBranch) {
            let mergeBaseOutput = runCommand(directory: repoRoot, executable: "git", arguments: ["merge-base", "HEAD", candidate])
            guard let mergeBase = mergeBaseOutput?.trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty else {
                continue
            }
            switch diffAndOverrides(repoRoot: repoRoot, diffRangeArgs: ["\(mergeBase)..HEAD"]) {
            case .failure(let error):
                return ReviewDiffSnapshot(files: [], repositoryRoot: repoRoot, resolvedBaseBranch: candidate, error: error)
            case .success(let files):
                return ReviewDiffSnapshot(files: files, repositoryRoot: repoRoot, resolvedBaseBranch: candidate, error: nil)
            }
        }
        return ReviewDiffSnapshot(repositoryRoot: repoRoot, resolvedBaseBranch: nil, error: .unknownBaseBranch(baseBranch))
    }

    /// `["HEAD"]` normally. On an unborn branch (`git rev-parse --verify --quiet HEAD` fails --
    /// no commits yet) returns `[<empty-tree-id>]` instead, so a diff against it still enumerates
    /// staged files. Falls back to `["HEAD"]` if the empty-tree id can't be obtained, matching
    /// prior behavior (the subsequent diff will then fail and surface `.commandFailed`).
    private nonisolated static func headDiffRangeArgs(repoRoot: String) -> [String] {
        let verify = CanonicalSubprocessRunner.run(
            executable: "git",
            arguments: ["rev-parse", "--verify", "--quiet", "HEAD"],
            currentDirectory: repoRoot,
            timeout: defaultTimeout,
            stdoutLimit: commandStdoutLimit,
            stderrLimit: commandStderrLimit
        )
        if verify.exitStatus == 0, verify.outcome == .exited {
            return ["HEAD"]
        }
        guard let emptyTreeOutput = runCommand(directory: repoRoot, executable: "git", arguments: ["hash-object", "-t", "tree", "/dev/null"]) else {
            return ["HEAD"]
        }
        let emptyTree = emptyTreeOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return emptyTree.isEmpty ? ["HEAD"] : [emptyTree]
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

    private nonisolated static func diffAndOverrides(repoRoot: String, diffRangeArgs: [String]) -> Result<[ReviewFileDiff], ReviewDiffError> {
        switch runCommandResult(
            directory: repoRoot,
            executable: "git",
            arguments: ["diff", "--no-color", "--find-renames"] + diffRangeArgs
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let diffText):
            var files = ReviewDiffParser.parse(diffText)
            switch binaryFilePaths(repoRoot: repoRoot, diffRangeArgs: diffRangeArgs) {
            case .failure(let error):
                return .failure(error)
            case .success(let binaryPaths):
                applyOverrides(files: &files, binaryPaths: binaryPaths)
                return .success(files)
            }
        }
    }

    /// `git diff --numstat` reports `-\t-\t<path>` for binary files -- a cheap single extra
    /// invocation used to build a binary-file set before the unified-diff parse, per
    /// docs/plans/diff-review-panel.md §3 point 4.
    private nonisolated static func binaryFilePaths(repoRoot: String, diffRangeArgs: [String]) -> Result<Set<String>, ReviewDiffError> {
        switch runCommandResult(
            directory: repoRoot,
            executable: "git",
            arguments: ["diff", "--numstat", "--find-renames"] + diffRangeArgs
        ) {
        case .failure(let error):
            return .failure(error)
        case .success(let output):
            var paths: Set<String> = []
            for line in output.split(separator: "\n") {
                let columns = line.split(separator: "\t")
                guard columns.count >= 3, columns[0] == "-", columns[1] == "-" else { continue }
                paths.insert(String(columns[2]))
            }
            return .success(paths)
        }
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

    // MARK: - Process plumbing

    private nonisolated static func runCommand(directory: String, executable: String, arguments: [String]) -> String? {
        let result = CanonicalSubprocessRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            timeout: defaultTimeout,
            stdoutLimit: commandStdoutLimit,
            stderrLimit: commandStderrLimit
        )
        guard result.exitStatus == 0, result.outcome == .exited else {
            return nil
        }
        return result.stdout
    }

    /// Like `runCommand`, but surfaces failure as `.commandFailed` instead of substituting an
    /// empty string -- used everywhere a command failure must not be silently read as "no
    /// changes". See M12 in docs/audits/codebase-audit-2026-09-11.md.
    private nonisolated static func runCommandResult(directory: String, executable: String, arguments: [String]) -> Result<String, ReviewDiffError> {
        let result = CanonicalSubprocessRunner.run(
            executable: executable,
            arguments: arguments,
            currentDirectory: directory,
            timeout: defaultTimeout,
            stdoutLimit: commandStdoutLimit,
            stderrLimit: commandStderrLimit
        )
        guard result.exitStatus == 0, result.outcome == .exited else {
            let stderrText = (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let commandDescription = ([executable] + arguments).joined(separator: " ")
            let detail = stderrText.isEmpty ? "exit status \(result.exitStatus), outcome \(result.outcome)" : stderrText
            return .failure(.commandFailed("\(commandDescription): \(detail)"))
        }
        return .success(result.stdout ?? "")
    }
}
