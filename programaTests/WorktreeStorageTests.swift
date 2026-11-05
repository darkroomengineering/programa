import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Behavior tests for merged-worktree cleanup. Every case runs real git against a temp bare
/// remote, a clone of it, and linked worktrees inside a test-owned directory that stands in
/// for `worktrees.directory`. Open directories and process cwds are injected, so nothing reads
/// the running app, real processes, `~/.programa` or the user's settings.
final class WorktreeStorageTests: XCTestCase {
    private var tempRoot: URL!
    private var repo: URL!
    private var programaDir: URL!
    private var savedEnvironment: [String: String?] = [:]

    /// Far enough past the worktrees' creation that the 24-hour grace period has elapsed.
    private let later = Date().addingTimeInterval(48 * 3600)
    private let automatic = WorktreeRemovalPolicy.automatic(gracePeriodHours: 24)
    private let noGrace = WorktreeRemovalPolicy(gracePeriod: nil, includeExternal: false)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The production probes inherit the process environment; keep the user's global and
        // system git config (excludesFile, hooks, signing) out of their answers.
        for key in ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"] {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
            setenv(key, "/dev/null", 1)
        }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // realpath gives /private/var, matching the scanner. resolvingSymlinksInPath would strip
        // /private instead.
        tempRoot = URL(fileURLWithPath: WorktreeStorage.resolvedPath(base.path), isDirectory: true)

        try configFixtureGit(["init", "--bare", "-b", "main", "remote.git"], in: tempRoot)
        let seed = tempRoot.appendingPathComponent("seed", isDirectory: true)
        try configFixtureGit(["init", "-b", "main", "seed"], in: tempRoot)
        try write(".env*\nbuild/\nnode_modules/\n.dev.vars\nscratch/\n", to: seed.appendingPathComponent(".gitignore"))
        try write("hello\n", to: seed.appendingPathComponent("README.md"))
        try configFixtureGit(["add", "."], in: seed)
        try configFixtureGit(["commit", "-m", "initial"], in: seed)
        try configFixtureGit(["remote", "add", "origin", tempRoot.appendingPathComponent("remote.git").path], in: seed)
        try configFixtureGit(["push", "origin", "main"], in: seed)

        try configFixtureGit(["clone", tempRoot.appendingPathComponent("remote.git").path, "repo"], in: tempRoot)
        repo = tempRoot.appendingPathComponent("repo", isDirectory: true)
        programaDir = tempRoot.appendingPathComponent("programa-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(
            at: programaDir.appendingPathComponent("repo", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        savedEnvironment = [:]
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A linked worktree on new branch `slug` at `origin/main`, under the Programa directory
    /// (`<programaDir>/repo/<slug>`) unless `parent` says otherwise.
    @discardableResult
    private func addWorktree(_ slug: String, parent: URL? = nil) throws -> URL {
        let directory = parent ?? programaDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(slug, isDirectory: true)
        try configFixtureGit(["worktree", "add", "-b", slug, path.path, "origin/main"], in: repo)
        return path
    }

    private func commit(_ fileName: String, in worktree: URL) throws {
        try write("\(fileName)\n", to: worktree.appendingPathComponent(fileName))
        try configFixtureGit(["add", fileName], in: worktree)
        try configFixtureGit(["commit", "-m", "add \(fileName)"], in: worktree)
    }

    /// Discovery plus scan, the way `scanAll` composes them, with injected open state.
    private func scanEntries(
        openDirectories: [String] = [],
        processCwds: Set<String> = [],
        removalFilter: WorktreeStorage.RemovalFilter? = nil
    ) -> [WorktreeStorageEntry] {
        let candidates = [repo.path] + WorktreeStorage.programaWorktreeCandidates(in: programaDir.path)
        let repositories = WorktreeStorage.discoverRepositories(candidateDirectories: candidates)
        XCTAssertEqual(repositories.count, 1, "the repo and all its worktrees group into one repository")
        return WorktreeStorage.scan(
            repositories: repositories,
            programaDirectory: programaDir.path,
            openDirectories: openDirectories,
            processCwds: processCwds,
            removalFilter: removalFilter
        )
    }

    /// A clean, merged Programa worktree last used long ago, with every probe answered.
    private func probedEntry(
        isDirty: Bool? = false,
        hasIgnoredEnvFiles: Bool? = false,
        isMerged: Bool? = true,
        hasIgnoredFiles: Bool? = false
    ) -> WorktreeStorageEntry {
        WorktreeStorageEntry(
            repoRoot: "/fixtures/repo", path: "/fixtures/worktrees/repo/feature", branch: "feature",
            headSHA: "abc123", sizeBytes: 10, sizePartial: false, lastModified: Date(timeIntervalSince1970: 0),
            isProgramaCreated: true, isDirty: isDirty, hasIgnoredEnvFiles: hasIgnoredEnvFiles,
            hasUnpushedOrUnmergedCommits: false, isMerged: isMerged, isOpenInWorkspace: false,
            isProcessRunningInside: false, hasIgnoredFiles: hasIgnoredFiles
        )
    }

    private func resolved(_ path: String) -> String {
        WorktreeStorage.resolvedPath(path)
    }

    private func entry(_ worktree: URL, in entries: [WorktreeStorageEntry]) throws -> WorktreeStorageEntry {
        try XCTUnwrap(
            entries.first { resolved($0.path) == resolved(worktree.path) },
            "scan did not report \(worktree.path)"
        )
    }

    private func clean(
        _ entries: [WorktreeStorageEntry],
        policy: WorktreeRemovalPolicy,
        now: Date,
        dryRun: Bool = false,
        openDirectories: @escaping () -> [String] = { [] },
        processCwds: @escaping () -> Set<String> = { [] }
    ) -> WorktreeStorage.CleanOutcome {
        WorktreeStorage.clean(
            entries: entries,
            policy: policy,
            now: now,
            dryRun: dryRun,
            openDirectories: openDirectories,
            processCwds: processCwds
        )
    }

    private func keptReason(_ worktree: URL, in outcome: WorktreeStorage.CleanOutcome) -> WorktreeStorage.KeepReason? {
        outcome.kept.first { resolved($0.entry.path) == resolved(worktree.path) }?.reason
    }

    private func removedPaths(_ outcome: WorktreeStorage.CleanOutcome) -> [String] {
        outcome.removed.map { resolved($0.path) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func isListed(_ worktree: URL) -> Bool {
        (GitWorktreeManager.listWorktrees(repoRoot: repo.path) ?? [])
            .contains { resolved($0.path) == resolved(worktree.path) }
    }

    private func branchExists(_ branch: String) -> Bool {
        (try? configFixtureGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo)) != nil
    }

    // MARK: - Removable worktrees

    /// The core promise: a merged, clean, idle worktree is reclaimed, and the branch survives
    /// so no commit is ever lost by cleanup.
    func testMergedCleanIdleWorktreeIsRemovedAndBranchIsKept() throws {
        let worktree = try addWorktree("merged")
        let entries = scanEntries()

        XCTAssertFalse(
            entries.contains { resolved($0.path) == resolved(repo.path) },
            "the main worktree is never a removal candidate"
        )
        let scanned = try entry(worktree, in: entries)
        XCTAssertTrue(scanned.isProgramaCreated)
        XCTAssertEqual(scanned.isMerged, true)
        XCTAssertEqual(scanned.isDirty, false)
        XCTAssertEqual(scanned.hasIgnoredEnvFiles, false)
        XCTAssertGreaterThan(scanned.sizeBytes, 0)
        XCTAssertNil(scanned.removalBlocker(policy: automatic, now: later))

        let outcome = clean(entries, policy: automatic, now: later)

        XCTAssertEqual(removedPaths(outcome), [resolved(worktree.path)])
        XCTAssertTrue(outcome.kept.isEmpty, "unexpected kept: \(outcome.kept)")
        XCTAssertFalse(exists(worktree), "the worktree directory is deleted")
        XCTAssertFalse(isListed(worktree), "git no longer lists the worktree")
        XCTAssertTrue(branchExists("merged"), "cleanup never deletes the branch")
    }

    /// Ignored dependency folders are disposable; a `.env` a package ships inside
    /// `node_modules/` must not pin the worktree forever.
    func testEnvFileInsideNodeModulesDoesNotBlockRemoval() throws {
        let worktree = try addWorktree("deps")
        try write("TOKEN=pkg\n", to: worktree.appendingPathComponent("node_modules/pkg/.env"))

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.isDirty, false)
        XCTAssertEqual(scanned.hasIgnoredEnvFiles, false)
        XCTAssertNil(scanned.removalBlocker(policy: automatic, now: later))

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(removedPaths(outcome), [resolved(worktree.path)])
        XCTAssertFalse(exists(worktree))
    }

    /// A squash-merged PR leaves HEAD off the default branch; a `[gone]` upstream is the signal
    /// that the branch landed.
    func testCleanWorktreeWhoseUpstreamIsGoneCountsAsMerged() throws {
        let worktree = try addWorktree("squashed")
        try commit("feature.txt", in: worktree)
        try configFixtureGit(["push", "-u", "origin", "squashed"], in: worktree)
        try configFixtureGit(["push", "origin", "--delete", "squashed"], in: repo)

        let scanned = try entry(worktree, in: scanEntries())
        XCTAssertEqual(
            scanned.hasUnpushedOrUnmergedCommits, true,
            "HEAD is not on any remote ref, so only the gone upstream can make it merged"
        )
        XCTAssertEqual(scanned.isMerged, true)
        XCTAssertNil(scanned.removalBlocker(policy: automatic, now: later))
    }

    // MARK: - Blockers found by scan

    func testUnmergedCommitKeepsWorktree() throws {
        let worktree = try addWorktree("unmerged")
        try commit("work.txt", in: worktree)

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.isMerged, false)
        XCTAssertEqual(scanned.hasUnpushedOrUnmergedCommits, true)
        XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .notMerged)

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.notMerged))
        XCTAssertEqual(keptReason(worktree, in: outcome)?.code, "not_merged")
        XCTAssertTrue(exists(worktree))
    }

    func testUntrackedFileKeepsWorktreeAsDirty() throws {
        let worktree = try addWorktree("untracked")
        try write("draft\n", to: worktree.appendingPathComponent("notes.txt"))

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.isDirty, true)
        XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .dirty)

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.dirty))
        XCTAssertTrue(exists(worktree.appendingPathComponent("notes.txt")))
    }

    /// `git worktree remove` deletes ignored files, and `.env` files are often the only copy
    /// of local secrets. Each location is a separate worktree so every detection path must
    /// work on its own.
    func testIgnoredEnvFilesKeepWorktreeAndSurviveClean() throws {
        let rootEnv = try addWorktree("env-root")
        try write("SECRET=1\n", to: rootEnv.appendingPathComponent(".env"))
        let nestedEnv = try addWorktree("env-nested")
        try write("SECRET=2\n", to: nestedEnv.appendingPathComponent("apps/web/.env.local"))
        let buildEnv = try addWorktree("env-build")
        try write("SECRET=3\n", to: buildEnv.appendingPathComponent("build/.env"))
        let envFiles = [
            rootEnv.appendingPathComponent(".env"),
            nestedEnv.appendingPathComponent("apps/web/.env.local"),
            buildEnv.appendingPathComponent("build/.env"),
        ]

        let entries = scanEntries()
        for worktree in [rootEnv, nestedEnv, buildEnv] {
            let scanned = try entry(worktree, in: entries)
            XCTAssertEqual(scanned.isDirty, false, "\(worktree.lastPathComponent): ignored files are not dirt")
            XCTAssertEqual(scanned.hasIgnoredEnvFiles, true, worktree.lastPathComponent)
            XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .envFiles, worktree.lastPathComponent)
        }

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertTrue(outcome.removed.isEmpty, "removed: \(outcome.removed.map(\.path))")
        for worktree in [rootEnv, nestedEnv, buildEnv] {
            XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.envFiles), worktree.lastPathComponent)
        }
        for file in envFiles {
            XCTAssertTrue(exists(file), "\(file.path) survives clean")
        }
    }

    /// Worktrees the user made outside `worktrees.directory` are never touched automatically;
    /// only a manual clean that opts in may remove them.
    func testExternalWorktreeIsRemovableOnlyWithIncludeExternal() throws {
        let worktree = try addWorktree("outside", parent: tempRoot.appendingPathComponent("external", isDirectory: true))

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertFalse(scanned.isProgramaCreated)
        XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .external)
        let manual = WorktreeRemovalPolicy(gracePeriod: 24 * 3600, includeExternal: true)
        XCTAssertNil(scanned.removalBlocker(policy: manual, now: later))

        let automaticOutcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(keptReason(worktree, in: automaticOutcome), .blocker(.external))
        XCTAssertTrue(exists(worktree))

        let manualOutcome = clean(entries, policy: manual, now: later)
        XCTAssertEqual(removedPaths(manualOutcome), [resolved(worktree.path)])
        XCTAssertFalse(exists(worktree))
    }

    /// A worktree in use is kept. The check is "the open directory or cwd is inside the
    /// worktree": an open parent directory or a cwd in a sibling with a shared name prefix
    /// must not block it.
    func testOpenWorkspaceAndRunningProcessKeepWorktree() throws {
        let opened = try addWorktree("opened")
        let idle = try addWorktree("feat")
        let busy = try addWorktree("feat-2")
        let busySubdirectory = busy.appendingPathComponent("src/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: busySubdirectory, withIntermediateDirectories: true)

        let entries = scanEntries(
            openDirectories: [opened.path, programaDir.path],
            processCwds: [busySubdirectory.path]
        )

        let openedEntry = try entry(opened, in: entries)
        XCTAssertTrue(openedEntry.isOpenInWorkspace)
        XCTAssertEqual(openedEntry.removalBlocker(policy: automatic, now: later), .openInWorkspace)

        let busyEntry = try entry(busy, in: entries)
        XCTAssertFalse(busyEntry.isOpenInWorkspace, "an open parent directory does not mark its children open")
        XCTAssertTrue(busyEntry.isProcessRunningInside, "a cwd in a subdirectory counts")
        XCTAssertEqual(busyEntry.removalBlocker(policy: automatic, now: later), .processRunning)

        let idleEntry = try entry(idle, in: entries)
        XCTAssertFalse(idleEntry.isOpenInWorkspace)
        XCTAssertFalse(idleEntry.isProcessRunningInside, "feat-2's cwd is not inside feat")
        XCTAssertNil(idleEntry.removalBlocker(policy: automatic, now: later))

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(keptReason(opened, in: outcome)?.code, "open_in_workspace")
        XCTAssertEqual(keptReason(busy, in: outcome)?.code, "process_running")
        XCTAssertEqual(removedPaths(outcome), [resolved(idle.path)])
        XCTAssertTrue(exists(opened))
        XCTAssertTrue(exists(busy))
    }

    /// A worktree touched within the grace period is kept by the background pass; a manual
    /// clean without a grace period removes it.
    func testGracePeriodKeepsRecentlyUsedWorktree() throws {
        let worktree = try addWorktree("recent")
        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)

        let lastModified = try XCTUnwrap(scanned.lastModified, "the git index/HEAD mtime must be readable")
        XCTAssertLessThan(abs(lastModified.timeIntervalSinceNow), 3600)
        XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: Date()), .recentlyUsed)
        XCTAssertNil(scanned.removalBlocker(policy: noGrace, now: Date()))

        let outcome = clean(entries, policy: automatic, now: Date())
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.recentlyUsed))
        XCTAssertTrue(exists(worktree))
    }

    // MARK: - Clean-time re-checks

    /// A scan can be minutes old by the time clean runs; a workspace opened or a process
    /// started in that window must still save the worktree.
    func testCleanRechecksOpenDirectoriesAndProcessesBeforeRemoving() throws {
        let openedLater = try addWorktree("opened-later")
        let busyLater = try addWorktree("busy-later")
        let busySubdirectory = busyLater.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: busySubdirectory, withIntermediateDirectories: true)

        let entries = scanEntries()
        for worktree in [openedLater, busyLater] {
            XCTAssertNil(try entry(worktree, in: entries).removalBlocker(policy: automatic, now: later))
        }

        let outcome = clean(
            entries,
            policy: automatic,
            now: later,
            openDirectories: { [openedLater.path] },
            processCwds: { [busySubdirectory.path] }
        )

        XCTAssertTrue(outcome.removed.isEmpty, "removed: \(outcome.removed.map(\.path))")
        XCTAssertEqual(keptReason(openedLater, in: outcome), .blocker(.openInWorkspace))
        XCTAssertEqual(keptReason(busyLater, in: outcome), .blocker(.processRunning))
        XCTAssertTrue(exists(openedLater))
        XCTAssertTrue(exists(busyLater))
        XCTAssertTrue(isListed(openedLater))
        XCTAssertTrue(isListed(busyLater))
    }

    /// A `.env` created after the scan must not be deleted by `git worktree remove`, which
    /// removes ignored files even without `--force`.
    func testCleanRechecksIgnoredEnvFilesBeforeRemoving() throws {
        let worktree = try addWorktree("env-later")
        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.hasIgnoredEnvFiles, false)
        XCTAssertNil(scanned.removalBlocker(policy: noGrace, now: Date()))

        let envFile = worktree.appendingPathComponent(".env")
        try write("SECRET=late\n", to: envFile)

        let outcome = clean(entries, policy: noGrace, now: Date())

        XCTAssertTrue(outcome.removed.isEmpty, "removed: \(outcome.removed.map(\.path))")
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.envFiles))
        XCTAssertTrue(exists(worktree))
        XCTAssertTrue(exists(envFile), "the late .env survives")
        XCTAssertTrue(isListed(worktree))
        XCTAssertTrue(branchExists("env-later"))
    }

    func testDryRunReportsRemovalsWithoutDeletingAnything() throws {
        let worktree = try addWorktree("preview")
        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)

        let outcome = clean(entries, policy: automatic, now: later, dryRun: true)

        XCTAssertTrue(outcome.dryRun)
        XCTAssertEqual(removedPaths(outcome), [resolved(worktree.path)])
        XCTAssertEqual(outcome.reclaimedBytes, scanned.sizeBytes)
        XCTAssertTrue(exists(worktree), "dry run leaves the directory")
        XCTAssertTrue(isListed(worktree), "dry run leaves git's worktree list")
    }

    // MARK: - Ignored files outside build directories

    /// Build output and dependency folders are rebuilt on demand, so they never pin a
    /// worktree, even when a dependency is a git checkout of its own.
    func testOnlyRebuildableIgnoredDirectoriesDoNotBlockAutomaticRemoval() throws {
        let worktree = try addWorktree("rebuildable")
        try write("module.exports = 1\n", to: worktree.appendingPathComponent("node_modules/pkg/index.js"))
        try write("obj\n", to: worktree.appendingPathComponent("build/out/main.o"))
        let checkout = worktree.appendingPathComponent("node_modules/git-dep", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try configFixtureGit(["init", "-q"], in: checkout)

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.isDirty, false)
        XCTAssertEqual(scanned.hasIgnoredFiles, false)
        XCTAssertNil(scanned.removalBlocker(policy: automatic, now: later))

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(removedPaths(outcome), [resolved(worktree.path)])
        XCTAssertFalse(exists(worktree))
    }

    /// The background pass deletes without asking, so any ignored file a build would not
    /// recreate (here a Cloudflare `.dev.vars`) keeps the worktree. A manual clean, which
    /// previews and confirms, is not held back.
    func testIgnoredLocalFileKeepsWorktreeFromAutomaticRemovalOnly() throws {
        let worktree = try addWorktree("dev-vars")
        let secrets = worktree.appendingPathComponent(".dev.vars")
        try write("API_TOKEN=local\n", to: secrets)

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.isDirty, false, "ignored files are not dirt")
        XCTAssertEqual(scanned.hasIgnoredEnvFiles, false, ".dev.vars is not a .env* file")
        XCTAssertEqual(scanned.hasIgnoredFiles, true)
        XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .ignoredFiles)
        XCTAssertNil(scanned.removalBlocker(policy: noGrace, now: later))

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertTrue(outcome.removed.isEmpty, "removed: \(outcome.removed.map(\.path))")
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.ignoredFiles))
        XCTAssertEqual(keptReason(worktree, in: outcome)?.code, "ignored_files")
        XCTAssertTrue(exists(secrets), ".dev.vars survives the background pass")
    }

    /// A clone inside an ignored folder can hold commits that exist nowhere else.
    func testIgnoredNestedRepositoryKeepsWorktree() throws {
        let worktree = try addWorktree("nested-clone")
        let clone = worktree.appendingPathComponent("scratch/clone", isDirectory: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        try configFixtureGit(["init", "-q", "-b", "main"], in: clone)
        try write("local work\n", to: clone.appendingPathComponent("notes.txt"))
        try configFixtureGit(["add", "notes.txt"], in: clone)
        try configFixtureGit(["commit", "-q", "-m", "unpushed"], in: clone)

        let entries = scanEntries()
        let scanned = try entry(worktree, in: entries)
        XCTAssertEqual(scanned.isDirty, false)
        XCTAssertEqual(scanned.hasIgnoredFiles, true)
        XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .ignoredFiles)

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.ignoredFiles))
        XCTAssertTrue(exists(clone.appendingPathComponent(".git")), "the nested repository survives")
    }

    /// An ignored file created after the scan must still stop the background removal.
    func testCleanRechecksIgnoredFilesBeforeAutomaticRemoval() throws {
        let worktree = try addWorktree("dev-vars-later")
        let entries = scanEntries()
        XCTAssertNil(try entry(worktree, in: entries).removalBlocker(policy: automatic, now: later))

        let secrets = worktree.appendingPathComponent(".dev.vars")
        try write("API_TOKEN=late\n", to: secrets)

        let outcome = clean(entries, policy: automatic, now: later)
        XCTAssertTrue(outcome.removed.isEmpty, "removed: \(outcome.removed.map(\.path))")
        XCTAssertEqual(keptReason(worktree, in: outcome), .blocker(.ignoredFiles))
        XCTAssertTrue(exists(secrets))
        XCTAssertTrue(isListed(worktree))
    }

    // MARK: - Unanswered probes

    /// A probe git could not answer must never read as "safe to delete".
    func testUnansweredProbeBlocksAsStatusUnknown() {
        XCTAssertNil(probedEntry().removalBlocker(policy: automatic, now: later))
        for (label, scanned) in [
            ("dirty", probedEntry(isDirty: nil)),
            ("env files", probedEntry(hasIgnoredEnvFiles: nil)),
            ("merged", probedEntry(isMerged: nil)),
        ] {
            XCTAssertEqual(scanned.removalBlocker(policy: automatic, now: later), .statusUnknown, label)
            XCTAssertEqual(scanned.removalBlocker(policy: noGrace, now: later), .statusUnknown, label)
        }

        let ignoredUnknown = probedEntry(hasIgnoredFiles: nil)
        XCTAssertEqual(ignoredUnknown.removalBlocker(policy: automatic, now: later), .statusUnknown)
        XCTAssertNil(
            ignoredUnknown.removalBlocker(policy: noGrace, now: later),
            "a manual clean does not apply the ignored-file rule, so its probe does not matter"
        )
    }

    // MARK: - Removal-only scan

    /// The background pass skips git and the size walk for worktrees a cheap check already
    /// keeps, and still removes exactly what a full scan would.
    func testRemovalFilterSkipsWorktreesBlockedWithoutProbesAndRemovesTheSameSet() throws {
        let opened = try addWorktree("filter-open")
        let idle = try addWorktree("filter-idle")
        let external = try addWorktree("filter-outside", parent: tempRoot.appendingPathComponent("external", isDirectory: true))
        let dirty = try addWorktree("filter-dirty")
        try write("draft\n", to: dirty.appendingPathComponent("notes.txt"))

        let full = scanEntries(openDirectories: [opened.path])
        let filtered = scanEntries(
            openDirectories: [opened.path],
            removalFilter: WorktreeStorage.RemovalFilter(policy: automatic, now: later)
        )

        XCTAssertEqual(
            Set(filtered.map { resolved($0.path) }),
            [resolved(idle.path), resolved(dirty.path)],
            "open and external worktrees are left out; the dirty one needs git to be judged"
        )
        XCTAssertEqual(try entry(dirty, in: filtered).removalBlocker(policy: automatic, now: later), .dirty)
        XCTAssertEqual(try entry(external, in: full).removalBlocker(policy: automatic, now: later), .external)
        XCTAssertTrue(
            scanEntries(removalFilter: WorktreeStorage.RemovalFilter(policy: automatic, now: Date())).isEmpty,
            "every worktree was just created, so none is past the grace period"
        )

        let preview = clean(full, policy: automatic, now: later, dryRun: true)
        let outcome = clean(filtered, policy: automatic, now: later, openDirectories: { [opened.path] })
        XCTAssertEqual(removedPaths(outcome), removedPaths(preview))
        XCTAssertEqual(removedPaths(outcome), [resolved(idle.path)])
    }

    // MARK: - Path containment

    /// Containment decides whether a cwd or open directory protects a worktree. A prefix match
    /// on a sibling name would protect the wrong worktree and leave the right one exposed.
    func testIsPathEqualToOrInsideRespectsComponentBoundaries() {
        XCTAssertTrue(WorktreeStorage.isPath("/a/foo", equalToOrInside: "/a/foo", caseInsensitive: false))
        XCTAssertTrue(WorktreeStorage.isPath("/a/foo/bar", equalToOrInside: "/a/foo", caseInsensitive: false))
        XCTAssertFalse(WorktreeStorage.isPath("/a/foobar", equalToOrInside: "/a/foo", caseInsensitive: false))
        XCTAssertFalse(WorktreeStorage.isPath("/a/foobar/x", equalToOrInside: "/a/foo", caseInsensitive: false))
        XCTAssertFalse(WorktreeStorage.isPath("/a", equalToOrInside: "/a/foo", caseInsensitive: false))
        XCTAssertTrue(WorktreeStorage.isPath("/a/foo/bar", equalToOrInside: "/a/foo/", caseInsensitive: false))
        XCTAssertTrue(WorktreeStorage.isPath("/a/foo", equalToOrInside: "/a/foo//", caseInsensitive: false))
        XCTAssertTrue(WorktreeStorage.isPath("/anything", equalToOrInside: "/", caseInsensitive: false))
        XCTAssertFalse(WorktreeStorage.isPath("/a/foo", equalToOrInside: "", caseInsensitive: false))
        XCTAssertFalse(WorktreeStorage.isPath("/A/Foo/bar", equalToOrInside: "/a/foo", caseInsensitive: false))
        XCTAssertTrue(WorktreeStorage.isPath("/A/Foo/bar", equalToOrInside: "/a/foo", caseInsensitive: true))
        XCTAssertFalse(WorktreeStorage.isPath("/A/FooBar", equalToOrInside: "/a/foo", caseInsensitive: true))
    }
}

/// The settings that turn on unattended deletion. A flipped default, or a zero or boolean grace
/// period slipping through, would remove worktrees merged minutes ago.
final class WorktreeAutoRemoveSettingsTests: XCTestCase {
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("worktree-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent())
        settingsURL = nil
        try super.tearDownWithError()
    }

    private func writeSettings(_ contents: String) throws {
        try contents.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    func testMissingOrUnusableSettingsFallBackToDefaults() throws {
        XCTAssertTrue(ProgramaWorktreeSettings.autoRemoveMerged(settingsURL: settingsURL))
        XCTAssertEqual(ProgramaWorktreeSettings.autoRemoveAfterHours(settingsURL: settingsURL), 24)
        XCTAssertTrue(ProgramaStorageSettings.autoCleanCaches(settingsURL: settingsURL))

        for contents in [
            "", "not JSON", "[]", "{}", "{\"worktrees\":{},\"storage\":{}}",
            "{\"worktrees\":{\"autoRemoveMerged\":\"false\",\"autoRemoveAfterHours\":\"48\"},"
                + "\"storage\":{\"autoCleanCaches\":\"false\"}}",
            "{\"worktrees\":{\"autoRemoveMerged\":null,\"autoRemoveAfterHours\":null},\"storage\":{\"autoCleanCaches\":null}}",
        ] {
            try writeSettings(contents)
            XCTAssertTrue(ProgramaWorktreeSettings.autoRemoveMerged(settingsURL: settingsURL), contents)
            XCTAssertEqual(ProgramaWorktreeSettings.autoRemoveAfterHours(settingsURL: settingsURL), 24, contents)
            XCTAssertTrue(ProgramaStorageSettings.autoCleanCaches(settingsURL: settingsURL), contents)
        }
    }

    func testExplicitFalseTurnsAutomaticCleanupOffInJSONC() throws {
        try writeSettings("""
        {
          // keep everything
          "worktrees": { "autoRemoveMerged": false, },
          "storage": { "autoCleanCaches": false },
        }
        """)
        XCTAssertFalse(ProgramaWorktreeSettings.autoRemoveMerged(settingsURL: settingsURL))
        XCTAssertFalse(ProgramaStorageSettings.autoCleanCaches(settingsURL: settingsURL))
    }

    func testGracePeriodIsClampedToAtLeastOneHour() throws {
        let cases: [(json: String, hours: Double)] = [
            ("0", 1), ("0.5", 1), ("-12", 1), ("1", 1), ("1.5", 1.5), ("48", 48),
            ("true", 24), ("false", 24), ("1e999", 24),
        ]
        for (json, hours) in cases {
            try writeSettings("{\"worktrees\":{\"autoRemoveAfterHours\":\(json)}}")
            XCTAssertEqual(ProgramaWorktreeSettings.autoRemoveAfterHours(settingsURL: settingsURL), hours, json)
        }
    }
}
