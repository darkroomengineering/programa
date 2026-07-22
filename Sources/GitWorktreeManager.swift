import Foundation

// MARK: - GitWorktreeManager
//
// Stateless git worktree lifecycle helper: given a repo root, shells out to `git worktree
// add/list/remove` and parses the results. Mirrors `Sources/GitMetadataProber.swift`'s
// Process+Pipe+semaphore-timeout `runCommandResult` pattern so this stays independently
// testable and has no dependency on TabManager/TerminalController state. All git I/O here
// is synchronous/blocking by construction -- callers (TerminalController+Worktree.swift)
// are responsible for keeping it off the main thread.
struct GitWorktreeManager {
    struct WorktreeEntry: Equatable {
        let path: String
        let headSHA: String?
        let branch: String?
        let isBare: Bool
        let isDetached: Bool
    }

    enum AddOutcome {
        case success(WorktreeEntry)
        case notAGitRepo
        case branchCheckedOut(existing: WorktreeEntry)
        case worktreePathExists
        case gitCommandFailed(message: String)
    }

    enum RemoveOutcome {
        case success
        case notAGitRepo
        case worktreeNotFound
        case worktreeDirty(message: String)
        case gitCommandFailed(message: String)
    }

    private struct CommandResult {
        let stdout: String?
        let stderr: String?
        let exitStatus: Int32?
        let timedOut: Bool
        let executionError: String?
    }

    private static let defaultTimeout: TimeInterval = 15.0

    // MARK: - Repo resolution

    /// Resolves the top-level directory of the git repository containing `directory`, via
    /// `git rev-parse --show-toplevel`. Returns nil if `directory` is not inside a git repo
    /// (or `git` itself could not be run).
    nonisolated static func resolveRepoRoot(from directory: String) -> String? {
        let result = runGitCommand(directory: directory, arguments: ["rev-parse", "--show-toplevel"])
        guard let result, result.exitStatus == 0, !result.timedOut,
              let stdout = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stdout.isEmpty else {
            return nil
        }
        return stdout
    }

    nonisolated static func repoName(forRepoRoot repoRoot: String) -> String {
        (repoRoot as NSString).lastPathComponent
    }

    /// Filesystem-safe slug for a branch name, used to derive the default worktree directory
    /// name (`feature/foo` -> `feature-foo`).
    nonisolated static func branchSlug(_ branch: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = branch.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let slug = String(mapped)
        return slug.isEmpty ? "worktree" : slug
    }

    // MARK: - Listing

    /// Parses `git worktree list --porcelain` for `repoRoot`.
    nonisolated static func listWorktrees(repoRoot: String) -> [WorktreeEntry]? {
        let result = runGitCommand(directory: repoRoot, arguments: ["worktree", "list", "--porcelain"])
        guard let result, result.exitStatus == 0, !result.timedOut, let stdout = result.stdout else {
            return nil
        }
        return parsePorcelainWorktreeList(stdout)
    }

    nonisolated static func parsePorcelainWorktreeList(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var path: String?
        var headSHA: String?
        var branch: String?
        var isBare = false
        var isDetached = false

        func flush() {
            guard let path else { return }
            entries.append(WorktreeEntry(path: path, headSHA: headSHA, branch: branch, isBare: isBare, isDetached: isDetached))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                path = nil
                headSHA = nil
                branch = nil
                isBare = false
                isDetached = false
                continue
            }
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                headSHA = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            }
        }
        flush()
        return entries
    }

    /// Finds the worktree entry (if any) whose branch matches `branch` exactly, excluding
    /// bare repo entries. Used for the pre-`git worktree add` "branch already checked out"
    /// check -- must run before calling `add`, not inferred from git's own error text.
    nonisolated static func worktreeCheckedOut(branch: String, repoRoot: String) -> WorktreeEntry? {
        listWorktrees(repoRoot: repoRoot)?.first { $0.branch == branch && !$0.isBare }
    }

    nonisolated static func worktreeEntry(atPath path: String, repoRoot: String) -> WorktreeEntry? {
        let standardizedTarget = (path as NSString).standardizingPath
        return listWorktrees(repoRoot: repoRoot)?.first {
            ($0.path as NSString).standardizingPath == standardizedTarget
        }
    }

    nonisolated static func worktreeEntry(forBranch branch: String, repoRoot: String) -> WorktreeEntry? {
        listWorktrees(repoRoot: repoRoot)?.first { $0.branch == branch }
    }

    nonisolated static func branchExistsLocally(_ branch: String, repoRoot: String) -> Bool {
        let result = runGitCommand(
            directory: repoRoot,
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]
        )
        return result?.exitStatus == 0
    }

    // MARK: - Add

    /// Adds a worktree at `path` for `branch`. If `branch` already exists locally, checks it
    /// out (`git worktree add <path> <branch>`); otherwise creates it from `base` (default
    /// `HEAD`) via `git worktree add -b <branch> <path> <base>`. Callers must have already
    /// checked `worktreeCheckedOut` themselves if they want a `branch_checked_out` error --
    /// this method does not re-derive that check so it can be unit-tested against a plain
    /// "does this succeed" contract.
    nonisolated static func add(
        repoRoot: String,
        branch: String,
        base: String?,
        path: String
    ) -> AddOutcome {
        if FileManager.default.fileExists(atPath: path) {
            return .worktreePathExists
        }

        var arguments = ["worktree", "add"]
        if branchExistsLocally(branch, repoRoot: repoRoot) {
            arguments.append(path)
            arguments.append(branch)
        } else {
            arguments.append(contentsOf: ["-b", branch])
            arguments.append(path)
            arguments.append(base ?? "HEAD")
        }

        let result = runGitCommand(directory: repoRoot, arguments: arguments)
        guard let result else {
            return .gitCommandFailed(message: "Failed to run git")
        }
        if result.timedOut {
            return .gitCommandFailed(message: "git worktree add timed out")
        }
        guard result.exitStatus == 0 else {
            let message = (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .gitCommandFailed(message: message.isEmpty ? "git worktree add failed" : message)
        }

        guard let entry = worktreeEntry(atPath: path, repoRoot: repoRoot) else {
            return .gitCommandFailed(message: "git worktree add succeeded but the new worktree could not be found")
        }
        return .success(entry)
    }

    // MARK: - Remove

    /// Removes the worktree at `path`. Never passes `--force` to git regardless of caller
    /// intent for dirty-state override -- `force` here only controls whether we retry with
    /// `--force` after confirming the worktree is *not* dirty for some other git-refusal
    /// reason (e.g. locked). A dirty worktree always surfaces as `.worktreeDirty` so the
    /// caller can require an explicit second confirmation instead of silently discarding
    /// uncommitted work. This function never deletes the underlying branch.
    nonisolated static func remove(repoRoot: String, path: String, force: Bool) -> RemoveOutcome {
        guard worktreeEntry(atPath: path, repoRoot: repoRoot) != nil else {
            return .worktreeNotFound
        }

        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments.append(path)

        let result = runGitCommand(directory: repoRoot, arguments: arguments)
        guard let result else {
            return .gitCommandFailed(message: "Failed to run git")
        }
        if result.timedOut {
            return .gitCommandFailed(message: "git worktree remove timed out")
        }
        guard result.exitStatus == 0 else {
            let message = (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !force, isDirtyWorktreeRefusal(message) {
                return .worktreeDirty(message: message)
            }
            return .gitCommandFailed(message: message.isEmpty ? "git worktree remove failed" : message)
        }
        return .success
    }

    nonisolated static func isDirtyWorktreeRefusal(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("contains modified or untracked files")
            || lowered.contains("is dirty")
            || lowered.contains("use --force")
    }

    // MARK: - Process plumbing (mirrors GitMetadataProber.runCommandResult)

    private nonisolated static func runGitCommand(
        directory: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> CommandResult? {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        if let gitPath = resolvedGitExecutablePath() {
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
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

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + 0.2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.2)
            }
            return CommandResult(stdout: nil, stderr: nil, exitStatus: nil, timedOut: true, executionError: nil)
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

    private nonisolated static func resolvedGitExecutablePath() -> String? {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - ProgramaWorktreeSettings
//
// Reads `worktrees.directory` (Resources/settings.schema.json) directly from settings.json
// rather than through `ProgramaSettingsFileStore`'s full managed-UserDefaults pipeline: that
// pipeline exists to map settings onto live-reactive feature toggles (appearance, shortcuts,
// etc.), which `worktrees.directory` is not -- it is read once per `worktree.create` call to
// compute a default path, with no UI surface that needs to react to it changing live. A
// direct, self-contained read keeps this addition isolated to the new worktree subsystem
// instead of touching ProgramaSettingsFileStore.swift's many existing call sites.
enum ProgramaWorktreeSettings {
    static let defaultDirectory: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".programa/worktrees")
    }()

    /// Resolves the configured `worktrees.directory`, expanding `~` and falling back to
    /// `defaultDirectory` when unset, blank, or the settings file can't be read/parsed.
    static func resolvedDirectory() -> String {
        guard let root = readSettingsRoot(),
              let worktreesSection = root["worktrees"] as? [String: Any],
              let raw = worktreesSection["directory"] as? String else {
            return defaultDirectory
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultDirectory }
        if trimmed.hasPrefix("~/") || trimmed == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return trimmed == "~" ? home : (home as NSString).appendingPathComponent(String(trimmed.dropFirst(2)))
        }
        return trimmed
    }

    private static func readSettingsRoot() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let newPath = (home as NSString).appendingPathComponent(".config/programa/settings.json")
        let legacyPath = (home as NSString).appendingPathComponent(".config/cmux/settings.json")
        let fm = FileManager.default
        let path = fm.fileExists(atPath: newPath) ? newPath : legacyPath
        guard let data = fm.contents(atPath: path), !data.isEmpty else { return nil }
        guard let sanitized = try? JSONCParser.preprocess(data: data),
              let object = try? JSONSerialization.jsonObject(with: sanitized, options: []) else {
            return nil
        }
        return object as? [String: Any]
    }
}
