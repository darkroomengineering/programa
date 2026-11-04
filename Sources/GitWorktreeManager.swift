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
        case worktreePathExists
        case gitCommandFailed(message: String)
    }

    enum RemoveOutcome {
        case success
        case worktreeNotFound
        case worktreeDirty(message: String)
        case gitCommandFailed(message: String)
    }

    private static let defaultTimeout: TimeInterval = 15.0
    private static let commandStdoutLimit = 4 * 1024 * 1024
    private static let commandStderrLimit = 1024 * 1024

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

    /// nil when git could not answer (refused, timed out, or failed for another reason than the
    /// ref being absent). Callers must treat nil as "unknown", never as "absent": acting on a
    /// false "absent" can delete a branch the user created.
    nonisolated static func branchExistsLocally(_ branch: String, repoRoot: String) -> Bool? {
        guard let result = runGitCommand(
            directory: repoRoot,
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]
        ), !result.timedOut else { return nil }
        switch result.exitStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
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

        // `--` ends option parsing, so a caller-supplied path or base such as `--detach` is
        // read as a path or ref name, never as an option. `-b <branch>` is an option value and
        // is safe before it.
        var arguments = ["worktree", "add"]
        guard let branchExisted = branchExistsLocally(branch, repoRoot: repoRoot) else {
            return .gitCommandFailed(message: "Could not determine whether branch '\(branch)' already exists")
        }
        if branchExisted {
            arguments.append(contentsOf: ["--", path, branch])
        } else {
            arguments.append(contentsOf: ["-b", branch, "--", path, base ?? "HEAD"])
        }

        let result = runGitCommand(directory: repoRoot, arguments: arguments)
        guard let result else {
            return .gitCommandFailed(message: "Failed to run git")
        }
        guard !result.timedOut, result.exitStatus == 0 else {
            if !branchExisted {
                deleteBranchIfUnused(branch, repoRoot: repoRoot)
            }
            if result.timedOut {
                return .gitCommandFailed(message: "git worktree add timed out")
            }
            let message = (result.stderr ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return .gitCommandFailed(message: message.isEmpty ? "git worktree add failed" : message)
        }

        guard let entry = worktreeEntry(atPath: path, repoRoot: repoRoot) else {
            return .gitCommandFailed(message: "git worktree add succeeded but the new worktree could not be found")
        }
        return .success(entry)
    }

    /// Deletes local branch `branch` when no worktree has it checked out. Used to undo a
    /// branch that this process created with `worktree add -b` when the add (or the caller's
    /// follow-up) failed. Callers must only pass a branch they created: this does not check
    /// whether the branch holds commits. Returns whether the branch is gone afterwards; false
    /// without touching anything when git cannot say whether the branch exists.
    @discardableResult
    nonisolated static func deleteBranchIfUnused(_ branch: String, repoRoot: String) -> Bool {
        guard let exists = branchExistsLocally(branch, repoRoot: repoRoot) else { return false }
        guard exists else { return true }
        guard worktreeEntry(forBranch: branch, repoRoot: repoRoot) == nil else { return false }
        let result = runGitCommand(
            directory: repoRoot,
            arguments: ["update-ref", "-d", "refs/heads/\(branch)"]
        )
        return result?.exitStatus == 0 && result?.timedOut == false
    }

    // MARK: - Remove

    /// Removes the worktree at `path`. With `force: false`, git refuses a worktree with
    /// modified or untracked files and that refusal surfaces as `.worktreeDirty`, so the caller
    /// can ask for an explicit second confirmation instead of discarding uncommitted work.
    /// With `force: true`, `--force` is passed to git and a dirty worktree is removed. This
    /// function never deletes the underlying branch.
    nonisolated static func remove(repoRoot: String, path: String, force: Bool) -> RemoveOutcome {
        guard worktreeEntry(atPath: path, repoRoot: repoRoot) != nil else {
            return .worktreeNotFound
        }

        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments.append(contentsOf: ["--", path])

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

    // MARK: - Storage queries (WorktreeStorage)
    //
    // Local-only: none of these fetch. A nil return means git could not answer, which callers
    // must treat as "unknown" and keep the worktree.

    /// The remote default branch ref: `refs/remotes/origin/HEAD`'s target, else `origin/main`,
    /// else `origin/master`. nil when the repo has none of them.
    nonisolated static func defaultRemoteBranch(repoRoot: String) -> String? {
        if let result = runGitCommand(
            directory: repoRoot,
            arguments: ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]
        ), result.exitStatus == 0, !result.timedOut,
           let ref = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            return ref
        }
        for candidate in ["refs/remotes/origin/main", "refs/remotes/origin/master"] {
            let result = runGitCommand(directory: repoRoot, arguments: ["show-ref", "--verify", "--quiet", candidate])
            if result?.exitStatus == 0, result?.timedOut == false {
                return candidate
            }
        }
        return nil
    }

    /// Whether `commit` is reachable from `ref` (`git merge-base --is-ancestor`). nil when git
    /// fails for any reason other than a plain "no".
    nonisolated static func isAncestor(_ commit: String, of ref: String, repoRoot: String) -> Bool? {
        guard let result = runGitCommand(
            directory: repoRoot,
            arguments: ["merge-base", "--is-ancestor", commit, ref]
        ), !result.timedOut else { return nil }
        switch result.exitStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// Whether local `branch` has an upstream configured that no longer exists (`[gone]`),
    /// which is what a squash-merged and deleted remote branch looks like after a prune.
    nonisolated static func upstreamIsGone(branch: String, repoRoot: String) -> Bool? {
        guard let result = runGitCommand(
            directory: repoRoot,
            arguments: ["for-each-ref", "--format=%(upstream:track)", "refs/heads/\(branch)"]
        ), result.exitStatus == 0, !result.timedOut, let stdout = result.stdout else { return nil }
        return stdout.contains("[gone]")
    }

    /// Whether `commit` has commits that no remote-tracking ref contains. nil when git fails.
    nonisolated static func hasCommitsMissingFromRemotes(_ commit: String, repoRoot: String) -> Bool? {
        guard let result = runGitCommand(
            directory: repoRoot,
            arguments: ["rev-list", "--count", commit, "--not", "--remotes"]
        ), result.exitStatus == 0, !result.timedOut,
              let count = Int(result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else {
            return nil
        }
        return count > 0
    }

    /// Whether the worktree at `path` has modified or untracked (not ignored) files. nil when
    /// git could not answer; output over the stdout limit counts as dirty.
    nonisolated static func workingTreeIsDirty(path: String) -> Bool? {
        guard let result = runGitCommand(
            directory: path,
            arguments: ["status", "--porcelain", "--untracked-files=normal"]
        ) else { return nil }
        if result.outcome == .stdoutLimitExceeded { return true }
        guard result.outcome == .exited, result.exitStatus == 0, let stdout = result.stdout else { return nil }
        return !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the worktree at `path` holds ignored `.env*` files outside `node_modules/`.
    /// `git worktree remove` deletes ignored files, and these are often the only copy of local
    /// secrets. Lists files one by one, so a `.env` inside a fully ignored folder (`build/.env`)
    /// counts. nil when git could not answer.
    nonisolated static func ignoredEnvFiles(path: String) -> Bool? {
        guard let result = runGitCommand(
            directory: path,
            arguments: [
                "ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--",
                ":(glob)**/.env*", ":(exclude,glob)**/node_modules/**",
            ]
        ), result.outcome == .exited, result.exitStatus == 0, let stdout = result.stdout else { return nil }
        return !stdout.isEmpty
    }

    // MARK: - Process plumbing

    private nonisolated static func runGitCommand(
        directory: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) -> CanonicalSubprocessResult? {
        CanonicalSubprocessRunner.runAutomaticGit(
            arguments: arguments,
            currentDirectory: directory,
            timeout: timeout,
            stdoutLimit: commandStdoutLimit,
            stderrLimit: commandStderrLimit,
            executableURL: resolvedGitExecutablePath().map { URL(fileURLWithPath: $0) }
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

    static let defaultAutoRemoveMerged = true
    static let defaultAutoRemoveAfterHours: Double = 24
    static let minimumAutoRemoveAfterHours: Double = 1

    /// `worktrees.autoRemoveMerged`: whether the background monitor removes merged, idle
    /// Programa-created worktrees.
    static func autoRemoveMerged() -> Bool {
        (readSettingsRoot()?["worktrees"] as? [String: Any])?["autoRemoveMerged"] as? Bool ?? defaultAutoRemoveMerged
    }

    /// `worktrees.autoRemoveAfterHours`, clamped to at least one hour.
    static func autoRemoveAfterHours() -> Double {
        guard let section = readSettingsRoot()?["worktrees"] as? [String: Any],
              let number = section["autoRemoveAfterHours"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else {
            return defaultAutoRemoveAfterHours
        }
        return max(minimumAutoRemoveAfterHours, number.doubleValue)
    }

    private static func readSettingsRoot() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (home as NSString).appendingPathComponent(".config/programa/settings.json")
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return nil }
        guard let sanitized = try? JSONCParser.preprocess(data: data),
              let object = try? JSONSerialization.jsonObject(with: sanitized, options: []) else {
            return nil
        }
        return object as? [String: Any]
    }
}
