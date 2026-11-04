import Darwin
import Foundation
import os

// MARK: - WorktreeStorageEntry

/// One linked git worktree with the disk space it takes and the facts that decide whether it
/// can be removed. Probe results that git could not answer are nil, and nil always blocks
/// removal.
struct WorktreeStorageEntry: Equatable, Sendable {
    /// Why a worktree is kept. Raw values are the `blocker` strings of `storage.scan` and
    /// `storage.clean`.
    enum RemovalBlocker: String, Equatable, Sendable {
        /// Outside `worktrees.directory`; only a manual clean with `include_external` may remove it.
        case external
        /// git could not report the dirty or merged state.
        case statusUnknown = "status_unknown"
        case dirty
        /// Ignored `.env*` files, which `git worktree remove` would delete.
        case envFiles = "env_files"
        case notMerged = "not_merged"
        case openInWorkspace = "open_in_workspace"
        case processRunning = "process_running"
        /// Touched within the grace period, or its last use could not be read.
        case recentlyUsed = "recently_used"
    }

    let repoRoot: String
    /// The path as `git worktree list` reports it, which `git worktree remove` matches against.
    let path: String
    let branch: String?
    let headSHA: String?
    let sizeBytes: Int64
    /// The size walk stopped early (time limit or unreadable entries), so `sizeBytes` is a floor.
    let sizePartial: Bool
    /// Newest mtime of the worktree's git `index`, `HEAD` and `logs/HEAD`.
    let lastModified: Date?
    let isProgramaCreated: Bool
    let isDirty: Bool?
    /// Ignored `.env*` files outside `node_modules/`. Always blocks, with no override.
    let hasIgnoredEnvFiles: Bool?
    /// Informational: HEAD holds commits no remote-tracking ref contains. Not a blocker, because
    /// removing a worktree never deletes its branch.
    let hasUnpushedOrUnmergedCommits: Bool?
    let isMerged: Bool?
    let isOpenInWorkspace: Bool
    let isProcessRunningInside: Bool

    /// The first reason to keep this worktree under `policy`, or nil when it may be removed.
    func removalBlocker(policy: WorktreeRemovalPolicy, now: Date) -> RemovalBlocker? {
        if !isProgramaCreated, !policy.includeExternal { return .external }
        guard let isDirty, let hasIgnoredEnvFiles, let isMerged else { return .statusUnknown }
        if isDirty { return .dirty }
        if hasIgnoredEnvFiles { return .envFiles }
        if !isMerged { return .notMerged }
        if isOpenInWorkspace { return .openInWorkspace }
        if isProcessRunningInside { return .processRunning }
        if let gracePeriod = policy.gracePeriod {
            guard let lastModified, now.timeIntervalSince(lastModified) >= gracePeriod else {
                return .recentlyUsed
            }
        }
        return nil
    }
}

/// Which conditions a removal pass waives. The background monitor uses `automatic`; only a
/// manual `storage.clean` can include external worktrees or skip the grace period.
struct WorktreeRemovalPolicy: Equatable, Sendable {
    /// nil skips the recent-use check.
    var gracePeriod: TimeInterval?
    var includeExternal: Bool

    static func automatic(gracePeriodHours: Double) -> WorktreeRemovalPolicy {
        WorktreeRemovalPolicy(gracePeriod: gracePeriodHours * 3600, includeExternal: false)
    }
}

// MARK: - WorktreeStorage

/// Finds linked git worktrees, measures them, and removes the merged, idle ones. Everything
/// here blocks on git and the filesystem; call it off the main thread, except
/// `openWorkspaceDirectories()`.
enum WorktreeStorage {
    /// Why a removal candidate stayed on disk.
    enum KeepReason: Equatable, Sendable {
        case blocker(WorktreeStorageEntry.RemovalBlocker)
        /// `git worktree remove` (never `--force`) refused or failed.
        case gitRefused(message: String)

        var code: String {
            switch self {
            case .blocker(let blocker): blocker.rawValue
            case .gitRefused: "git_refused"
            }
        }
    }

    struct KeptWorktree: Equatable, Sendable {
        let entry: WorktreeStorageEntry
        let reason: KeepReason
    }

    struct CleanOutcome: Equatable, Sendable {
        /// Removed worktrees, or the ones that would be removed when `dryRun`.
        var removed: [WorktreeStorageEntry]
        var kept: [KeptWorktree]
        var dryRun: Bool

        var reclaimedBytes: Int64 { removed.reduce(0) { $0 + $1.sizeBytes } }
    }

    struct Repository: Equatable, Sendable {
        /// The main worktree (first `git worktree list` entry).
        let root: String
        let worktrees: [GitWorktreeManager.WorktreeEntry]
    }

    static let defaultSizeWalkTimeout: TimeInterval = 30

    /// Serializes removal passes across the background monitor and `storage.clean`.
    static let passLock = NSLock()

    // MARK: Scan

    /// Scans every repo reachable from `openDirectories` or `worktrees.directory`.
    static func scanAll(
        openDirectories: [String],
        programaDirectory: String = ProgramaWorktreeSettings.resolvedDirectory(),
        sizeWalkTimeout: TimeInterval = defaultSizeWalkTimeout
    ) -> [WorktreeStorageEntry] {
        let processCwds = processWorkingDirectories()
        let candidates = openDirectories + programaWorktreeCandidates(in: programaDirectory)
        return scan(
            repositories: discoverRepositories(candidateDirectories: candidates),
            programaDirectory: programaDirectory,
            openDirectories: openDirectories,
            processCwds: processCwds,
            sizeWalkTimeout: sizeWalkTimeout
        )
    }

    /// Classifies every linked worktree of `repositories`. The main worktree, bare entries and
    /// worktrees whose directory is gone are skipped.
    static func scan(
        repositories: [Repository],
        programaDirectory: String,
        openDirectories: [String],
        processCwds: Set<String>,
        sizeWalkTimeout: TimeInterval = defaultSizeWalkTimeout
    ) -> [WorktreeStorageEntry] {
        let programaRoot = resolvedPath(programaDirectory)
        let resolvedOpenDirectories = openDirectories.map(resolvedPath)
        var entries: [WorktreeStorageEntry] = []
        for repository in repositories {
            let linked = repository.worktrees.dropFirst().filter { entry in
                var isDirectory: ObjCBool = false
                return !entry.isBare
                    && FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            guard !linked.isEmpty else { continue }
            let defaultBranch = GitWorktreeManager.defaultRemoteBranch(repoRoot: repository.root)
            for worktree in linked {
                entries.append(classify(
                    worktree,
                    repoRoot: repository.root,
                    defaultBranch: defaultBranch,
                    programaRoot: programaRoot,
                    openDirectories: resolvedOpenDirectories,
                    processCwds: processCwds,
                    sizeWalkTimeout: sizeWalkTimeout
                ))
            }
        }
        return entries
    }

    private static func classify(
        _ worktree: GitWorktreeManager.WorktreeEntry,
        repoRoot: String,
        defaultBranch: String?,
        programaRoot: String,
        openDirectories: [String],
        processCwds: Set<String>,
        sizeWalkTimeout: TimeInterval
    ) -> WorktreeStorageEntry {
        let path = worktree.path
        let resolved = resolvedPath(path)
        // Read before any git call in the worktree so our own probes cannot refresh it.
        let modified = Self.lastModified(worktreePath: path)
        let isDirty = GitWorktreeManager.workingTreeIsDirty(path: path)
        let hasIgnoredEnvFiles = GitWorktreeManager.ignoredEnvFiles(path: path)

        var isMerged: Bool? = false
        if let head = worktree.headSHA, let defaultBranch {
            isMerged = GitWorktreeManager.isAncestor(head, of: defaultBranch, repoRoot: repoRoot)
        }
        if isMerged != true, isDirty == false, let branch = worktree.branch,
           GitWorktreeManager.upstreamIsGone(branch: branch, repoRoot: repoRoot) == true {
            isMerged = true
        }
        let hasUnpushed = worktree.headSHA.flatMap {
            GitWorktreeManager.hasCommitsMissingFromRemotes($0, repoRoot: repoRoot)
        }
        let size = directorySize(atPath: path, timeout: sizeWalkTimeout)

        return WorktreeStorageEntry(
            repoRoot: repoRoot,
            path: path,
            branch: worktree.branch,
            headSHA: worktree.headSHA,
            sizeBytes: size.bytes,
            sizePartial: size.partial,
            lastModified: modified,
            isProgramaCreated: isPath(resolved, equalToOrInside: programaRoot, caseInsensitive: false)
                && resolved != programaRoot,
            isDirty: isDirty,
            hasIgnoredEnvFiles: hasIgnoredEnvFiles,
            hasUnpushedOrUnmergedCommits: hasUnpushed,
            isMerged: isMerged,
            isOpenInWorkspace: openDirectories.contains {
                isPath($0, equalToOrInside: resolved, caseInsensitive: true)
            },
            isProcessRunningInside: processCwds.contains {
                isPath($0, equalToOrInside: resolved, caseInsensitive: true)
            }
        )
    }

    // MARK: Clean

    /// Removes every entry `policy` allows, via `git worktree remove` without `--force`.
    /// Before removing, the open-workspace and process checks are re-run against fresh
    /// snapshots, since a size walk can take long enough for a user to start working there.
    /// Branches are never deleted. Hold `passLock` around the scan and this call.
    static func clean(
        entries: [WorktreeStorageEntry],
        policy: WorktreeRemovalPolicy,
        now: Date,
        dryRun: Bool,
        openDirectories: () -> [String],
        processCwds: () -> Set<String>
    ) -> CleanOutcome {
        var outcome = CleanOutcome(removed: [], kept: [], dryRun: dryRun)
        var candidates: [WorktreeStorageEntry] = []
        for entry in entries {
            if let blocker = entry.removalBlocker(policy: policy, now: now) {
                outcome.kept.append(KeptWorktree(entry: entry, reason: .blocker(blocker)))
            } else {
                candidates.append(entry)
            }
        }
        if dryRun {
            outcome.removed = candidates
            return outcome
        }
        guard !candidates.isEmpty else { return outcome }

        let freshOpenDirectories = openDirectories().map(resolvedPath)
        let freshCwds = processCwds()
        for entry in candidates {
            let resolved = resolvedPath(entry.path)
            if freshOpenDirectories.contains(where: { isPath($0, equalToOrInside: resolved, caseInsensitive: true) }) {
                outcome.kept.append(KeptWorktree(entry: entry, reason: .blocker(.openInWorkspace)))
                continue
            }
            if freshCwds.contains(where: { isPath($0, equalToOrInside: resolved, caseInsensitive: true) }) {
                outcome.kept.append(KeptWorktree(entry: entry, reason: .blocker(.processRunning)))
                continue
            }
            // `git worktree remove` without --force still deletes ignored files, and the scan
            // can be minutes old, so a `.env` created since then must be caught here.
            guard GitWorktreeManager.ignoredEnvFiles(path: entry.path) == false else {
                outcome.kept.append(KeptWorktree(entry: entry, reason: .blocker(.envFiles)))
                continue
            }
            switch GitWorktreeManager.remove(repoRoot: entry.repoRoot, path: entry.path, force: false) {
            case .success:
                outcome.removed.append(entry)
            case .worktreeNotFound:
                outcome.kept.append(KeptWorktree(entry: entry, reason: .gitRefused(message: "git no longer lists this worktree")))
            case .worktreeDirty(let message), .gitCommandFailed(let message):
                outcome.kept.append(KeptWorktree(entry: entry, reason: .gitRefused(message: message)))
            }
        }
        return outcome
    }

    // MARK: Discovery

    /// Groups `candidateDirectories` by repository, keyed on the main worktree, with one
    /// `git worktree list` per distinct directory. Directories outside git are dropped.
    static func discoverRepositories(candidateDirectories: [String]) -> [Repository] {
        var repositories: [Repository] = []
        var seen = Set<String>()
        for raw in candidateDirectories {
            let directory = resolvedPath(raw)
            guard !directory.isEmpty, seen.insert(directory).inserted else { continue }
            guard FileManager.default.fileExists(atPath: directory),
                  let worktrees = GitWorktreeManager.listWorktrees(repoRoot: directory),
                  let main = worktrees.first else { continue }
            let root = resolvedPath(main.path)
            guard !repositories.contains(where: { $0.root == root }) else { continue }
            repositories.append(Repository(root: root, worktrees: worktrees))
        }
        return repositories
    }

    /// Linked worktrees directly under `directory` or one level deeper
    /// (`<directory>/<repo-name>/<branch-slug>`): directories whose `.git` is a file.
    static func programaWorktreeCandidates(in directory: String) -> [String] {
        let fileManager = FileManager.default
        func children(_ path: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: path)) ?? [])
                .map { (path as NSString).appendingPathComponent($0) }
        }
        func hasGitFile(_ path: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"), isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        var result: [String] = []
        for child in children(directory) {
            if hasGitFile(child) {
                result.append(child)
                continue
            }
            result.append(contentsOf: children(child).filter(hasGitFile))
        }
        return result
    }

    /// Every directory open in a Programa window: each workspace's current directory and its
    /// panels' directories.
    @MainActor
    static func openWorkspaceDirectories() -> [String] {
        guard let appDelegate = AppDelegate.shared else { return [] }
        var directories: [String] = []
        for context in appDelegate.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                directories.append(workspace.currentDirectory)
                directories.append(contentsOf: workspace.panelDirectories.values)
            }
        }
        return directories.filter { !$0.isEmpty }
    }

    // MARK: Probes

    /// Allocated bytes of the regular files under `path`, not following symlinks. Stops at
    /// `timeout` and reports `partial`; unreadable entries also mark the result partial.
    static func directorySize(atPath path: String, timeout: TimeInterval) -> (bytes: Int64, partial: Bool) {
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let keySet = Set(keys)
        final class ErrorFlag { var raised = false }
        let errorFlag = ErrorFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in
                errorFlag.raised = true
                return true
            }
        ) else {
            return (0, true)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var total: Int64 = 0
        var visited = 0
        var timedOut = false
        while let item = enumerator.nextObject() {
            visited += 1
            if visited % 512 == 0, ProcessInfo.processInfo.systemUptime >= deadline {
                timedOut = true
                break
            }
            guard let url = item as? URL, let values = try? url.resourceValues(forKeys: keySet) else { continue }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return (total, timedOut || errorFlag.raised)
    }

    /// The worktree's private git directory, from the `gitdir:` line of its `.git` file.
    static func gitDirectory(forWorktree path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        guard let contents = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        for line in contents.split(whereSeparator: \.isNewline) where line.hasPrefix("gitdir:") {
            let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { return nil }
            let absolute = raw.hasPrefix("/") ? raw : (path as NSString).appendingPathComponent(raw)
            return (absolute as NSString).standardizingPath
        }
        return nil
    }

    /// Newest mtime of the worktree's git `index`, `HEAD` and `logs/HEAD`; nil when none can
    /// be read. No tree walk.
    static func lastModified(worktreePath: String) -> Date? {
        guard let gitDir = Self.gitDirectory(forWorktree: worktreePath) else { return nil }
        return ["index", "HEAD", "logs/HEAD"]
            .map { (gitDir as NSString).appendingPathComponent($0) }
            .compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            .max()
    }

    /// The current directory of every process this user may inspect.
    static func processWorkingDirectories() -> Set<String> {
        var directories = Set<String>()
        let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        for pid in allPids() where pid > 0 {
            var info = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, expectedSize) == expectedSize else { continue }
            let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty {
                directories.insert(path)
            }
        }
        return directories
    }

    private static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes spawned between the sizing call and the read.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    // MARK: Paths

    /// `realpath(3)` of `path` after `~` expansion, so `/var` and `/private/var` compare equal
    /// (the kernel reports cwds with `/private`). Falls back to the standardized path when the
    /// path does not exist.
    static func resolvedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        guard let resolved = realpath(expanded, nil) else {
            return (expanded as NSString).standardizingPath
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether `path` is `root` or inside it. Both must already be resolved.
    static func isPath(_ path: String, equalToOrInside root: String, caseInsensitive: Bool) -> Bool {
        let candidate = caseInsensitive ? path.lowercased() : path
        var base = caseInsensitive ? root.lowercased() : root
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return false }
        if candidate == base { return true }
        return candidate.hasPrefix(base == "/" ? base : base + "/")
    }
}

// MARK: - WorktreeStorageMonitor

/// Removes merged, idle Programa-created worktrees in the background: 120 s after launch,
/// then every 6 hours, when `worktrees.autoRemoveMerged` is on.
final class WorktreeStorageMonitor: @unchecked Sendable {
    static let shared = WorktreeStorageMonitor()

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.darkroom.programa",
        category: "worktree-storage"
    )

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 120, repeating: 6 * 60 * 60, leeway: .seconds(600))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard WorktreeStorage.passLock.try() else {
            logger.info("Skipped worktree cleanup: the previous pass is still running")
            return
        }
        defer { WorktreeStorage.passLock.unlock() }
        guard ProgramaWorktreeSettings.autoRemoveMerged() else { return }

        let policy = WorktreeRemovalPolicy.automatic(gracePeriodHours: ProgramaWorktreeSettings.autoRemoveAfterHours())
        let entries = WorktreeStorage.scanAll(openDirectories: Self.openDirectoriesFromMain())
        let outcome = WorktreeStorage.clean(
            entries: entries,
            policy: policy,
            now: Date(),
            dryRun: false,
            openDirectories: Self.openDirectoriesFromMain,
            processCwds: WorktreeStorage.processWorkingDirectories
        )
        for entry in outcome.removed {
            logger.info("Removed merged worktree \(entry.path, privacy: .private) (\(entry.sizeBytes, privacy: .public) bytes)")
        }
        for kept in outcome.kept {
            if case .gitRefused(let message) = kept.reason {
                logger.error("git refused to remove \(kept.entry.path, privacy: .private): \(message, privacy: .private)")
            }
        }
        logger.info("Worktree cleanup scanned \(entries.count, privacy: .public), removed \(outcome.removed.count, privacy: .public), reclaimed \(outcome.reclaimedBytes, privacy: .public) bytes")
    }

    private static func openDirectoriesFromMain() -> [String] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { WorktreeStorage.openWorkspaceDirectories() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { WorktreeStorage.openWorkspaceDirectories() }
        }
    }
}
