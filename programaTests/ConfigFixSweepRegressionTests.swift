import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@discardableResult
func configFixtureGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    environment["GIT_AUTHOR_NAME"] = "Conf Test"
    environment["GIT_AUTHOR_EMAIL"] = "conf@example.invalid"
    environment["GIT_COMMITTER_NAME"] = "Conf Test"
    environment["GIT_COMMITTER_EMAIL"] = "conf@example.invalid"
    process.environment = environment
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: outData, as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "ConfigFixSweepFixtures",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey:
                "git \(arguments.joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self))"]
        )
    }
    return output
}

/// Regression tests for the CONF (config, git, trust) fix cluster that only use APIs that
/// existed before the fixes, so they can be committed first and fail on the unfixed code.
///
/// Every git repository lives in a test-owned temp directory that is removed in `tearDown`.
/// Repository config is only ever written inside those temp repos, never the real checkout.
final class ConfigFixSweepRegressionTests: XCTestCase {
    private var tempRoot: URL!
    private var originalPATH: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("conf-regression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so paths compare equal to what git prints.
        tempRoot = base.resolvingSymlinksInPath()

        // Keep the probes network-free: a `gh` that answers `pr list` with no pull requests.
        originalPATH = ProcessInfo.processInfo.environment["PATH"]
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let ghStub = binDir.appendingPathComponent("gh")
        try "#!/bin/sh\necho '[]'\nexit 0\n".write(to: ghStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghStub.path)
        setenv("PATH", "\(binDir.path):\(originalPATH ?? "/usr/bin:/bin")", 1)
    }

    override func tearDownWithError() throws {
        if let originalPATH { setenv("PATH", originalPATH, 1) }
        originalPATH = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture helpers

    /// A repo on `branch` with one commit containing `fileName`.
    private func makeRepo(branch: String, fileName: String = "README.md", contents: String = "one\n") throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try configFixtureGit(["init", "-q", "-b", branch], in: repo)
        try contents.write(to: repo.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        try configFixtureGit(["add", "."], in: repo)
        try configFixtureGit(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    // MARK: - CONF-01: repository config is untrusted input to automatic git probes

    /// A repository's `core.fsmonitor` names a command git runs on `status`. The sidebar probe
    /// runs on whatever directory a terminal reports, so opening a hostile checkout must never
    /// execute that command.
    func testInitialGitMetadataProbeNeverRunsRepositoryFsmonitorCommand() throws {
        let repo = try makeRepo(branch: "feature-x")
        let marker = tempRoot.appendingPathComponent("fsmonitor-ran-probe")
        // Configure last so none of the fixture's own git commands trip the hook.
        try configFixtureGit(["config", "core.fsmonitor", "touch \(marker.path)"], in: repo)

        // Positive control: plain git does run the hook, so an absent marker below really means
        // the probe neutralized it rather than that this git never runs it.
        try configFixtureGit(["status", "--porcelain"], in: repo)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "control: plain `git status` should execute the hostile core.fsmonitor command"
        )
        try FileManager.default.removeItem(at: marker)

        let snapshot = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: repo.path)

        XCTAssertEqual(snapshot.branch, "feature-x")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "the sidebar git probe executed the repository's core.fsmonitor command"
        )
    }

    func testWorktreeListingNeverRunsRepositoryFsmonitorCommand() throws {
        let repo = try makeRepo(branch: "feature-x")
        let marker = tempRoot.appendingPathComponent("fsmonitor-ran-worktrees")
        try configFixtureGit(["config", "core.fsmonitor", "touch \(marker.path)"], in: repo)

        let entries = GitWorktreeManager.listWorktrees(repoRoot: repo.path)

        // git reports the realpath (/private/var/...); the temp URL may still be the /var symlink.
        XCTAssertEqual(
            entries?.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
            repo.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(entries?.first?.branch, "feature-x")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "worktree listing executed the repository's core.fsmonitor command"
        )
    }

    // MARK: - Filter drivers are repository-controlled commands

    /// A repo whose tracked `a.txt` is modified and whose `.gitattributes` routes `*.txt` to
    /// the filter driver `driver`. The driver is configured last so the fixture's own commands
    /// never run it; `configure` receives the repo to set the driver up.
    private func makeFilterRepo(driver: String, configure: (URL) throws -> Void) throws -> URL {
        let repo = try makeRepo(branch: "feature-x", fileName: "a.txt")
        try "*.txt filter=\(driver)\n".write(
            to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "one\nchanged\n".write(
            to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try configure(repo)
        return repo
    }

    func testProbesNeverRunRepositoryLocalFilterDriver() throws {
        let marker = tempRoot.appendingPathComponent("filter-ran")
        let repo = try makeFilterRepo(driver: "evil") { repo in
            try configFixtureGit(["config", "filter.evil.clean", "touch \(marker.path); cat"], in: repo)
        }

        // Positive control: plain git runs the clean filter for the modified file.
        try configFixtureGit(["status", "--porcelain"], in: repo)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "control: plain `git status` should execute the repository's clean filter"
        )
        try FileManager.default.removeItem(at: marker)

        let snapshot = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: repo.path)
        let review = ReviewDiffProber.diffSnapshot(directory: repo.path, mode: .uncommitted, baseBranch: "main")

        XCTAssertEqual(snapshot.branch, "feature-x")
        XCTAssertTrue(snapshot.isDirty)
        XCTAssertNil(review.error)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a background git probe executed the repository's filter driver"
        )
    }

    /// Git LFS is configured in the user's global config; its filter must keep working or every
    /// LFS file would read as modified.
    func testProbesKeepFilterDriverDefinedOnlyInGlobalConfig() throws {
        let marker = tempRoot.appendingPathComponent("global-filter-ran")
        let globalConfig = tempRoot.appendingPathComponent("global-gitconfig")
        try "[filter \"trusted\"]\n\tclean = touch \(marker.path); cat\n"
            .write(to: globalConfig, atomically: true, encoding: .utf8)
        let originalGlobal = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        setenv("GIT_CONFIG_GLOBAL", globalConfig.path, 1)
        defer {
            if let originalGlobal { setenv("GIT_CONFIG_GLOBAL", originalGlobal, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
        }
        let repo = try makeFilterRepo(driver: "trusted") { _ in }

        _ = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: repo.path)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "a filter driver defined only by the user's global config must still run"
        )
    }

    func testFilterOverridesCoverOnlyDriversRepositoryConfigDefinesOrChanges() {
        let output = [
            "global", "filter.lfs.clean\ngit-lfs clean -- %f",
            "global", "filter.lfs.required\ntrue",
            "global", "filter.same.clean\ncat",
            "local", "filter.same.clean\ncat",
            "global", "filter.hijacked.clean\ncat",
            "local", "filter.hijacked.clean\ntouch x",
            "local", "filter.dotted.name.process\ntouch y",
            "local", "filter.a=b.smudge\ncat",
            "command", "filter.lfs.clean\ngit-lfs clean -- %f",
        ].joined(separator: "\0") + "\0"

        let keys = CanonicalSubprocessRunner.untrustedFilterDriverConfig(fromShowScopeOutput: output)
            .map { "\($0.key)=\($0.value)" }

        XCTAssertEqual(keys, [
            "filter.hijacked.clean=", "filter.hijacked.smudge=", "filter.hijacked.process=", "filter.hijacked.required=false",
            "filter.dotted.name.clean=", "filter.dotted.name.smudge=", "filter.dotted.name.process=", "filter.dotted.name.required=false",
            "filter.a=b.clean=", "filter.a=b.smudge=", "filter.a=b.process=", "filter.a=b.required=false",
        ])
    }

    /// Git LFS runs `lfs.extension.<name>.clean` from the repository's own config inside the
    /// `filter.lfs` driver, so a repository-local extension makes the trusted global driver a
    /// command runner for that repository.
    func testRepositoryLocalLFSExtensionNeutralizesTheGlobalLFSFilter() {
        let output = [
            "global", "filter.lfs.clean\ngit-lfs clean -- %f",
            "global", "filter.lfs.required\ntrue",
            "local", "lfs.extension.x.clean\ntouch x",
        ].joined(separator: "\0") + "\0"

        let keys = CanonicalSubprocessRunner.untrustedFilterDriverConfig(fromShowScopeOutput: output)
            .map { "\($0.key)=\($0.value)" }

        XCTAssertEqual(keys, [
            "filter.lfs.clean=", "filter.lfs.smudge=", "filter.lfs.process=", "filter.lfs.required=false",
        ])
    }

    func testLFSExtensionNeutralizesFilterLFSEvenWhenNoFilterKeyIsListed() {
        let output = ["worktree", "lfs.extension.x.clean\ntouch x"].joined(separator: "\0") + "\0"

        let keys = CanonicalSubprocessRunner.untrustedFilterDriverConfig(fromShowScopeOutput: output)
            .map(\.key)

        XCTAssertEqual(keys, ["filter.lfs.clean", "filter.lfs.smudge", "filter.lfs.process", "filter.lfs.required"])
    }

    func testMixedCaseLFSExtensionStillNeutralizesFilterLFS() {
        let output = ["local", "lfs.Extension.x.clean\ntouch x"].joined(separator: "\0") + "\0"

        let keys = CanonicalSubprocessRunner.untrustedFilterDriverConfig(fromShowScopeOutput: output)
            .map(\.key)

        XCTAssertEqual(keys, ["filter.lfs.clean", "filter.lfs.smudge", "filter.lfs.process", "filter.lfs.required"])
    }

    /// A non-repository directory's cached "no filters" answer must not outlive a repository
    /// appearing in it, or the next probe runs git there without the filter overrides.
    func testRepositoryConfigFingerprintChangesWhenARepositoryAppears() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-\(UUID().uuidString)")
        let directory = parent.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let before = CanonicalSubprocessRunner.repositoryConfigFingerprint(directory: directory.path)
        XCTAssertEqual(before, CanonicalSubprocessRunner.repositoryConfigFingerprint(directory: directory.path))

        try configFixtureGit(["init", "-q"], in: directory)
        let afterInit = CanonicalSubprocessRunner.repositoryConfigFingerprint(directory: directory.path)
        XCTAssertNotEqual(before, afterInit)

        try configFixtureGit(["config", "filter.x.clean", "cat"], in: directory)
        XCTAssertNotEqual(afterInit, CanonicalSubprocessRunner.repositoryConfigFingerprint(directory: directory.path))
    }

    func testGlobalLFSExtensionLeavesTheGlobalLFSFilterAlone() {
        let output = [
            "global", "filter.lfs.clean\ngit-lfs clean -- %f",
            "global", "lfs.extension.x.clean\ntrusted-tool",
            "local", "lfs.repositoryformatversion\n0",
        ].joined(separator: "\0") + "\0"

        XCTAssertTrue(CanonicalSubprocessRunner.untrustedFilterDriverConfig(fromShowScopeOutput: output).isEmpty)
    }

    func testProbesNeverRunGlobalLFSFilterForRepositoryWithLocalLFSExtension() throws {
        let marker = tempRoot.appendingPathComponent("lfs-filter-ran")
        let globalConfig = tempRoot.appendingPathComponent("global-lfs-gitconfig")
        try "[filter \"lfs\"]\n\tclean = touch \(marker.path); cat\n"
            .write(to: globalConfig, atomically: true, encoding: .utf8)
        let originalGlobal = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]
        setenv("GIT_CONFIG_GLOBAL", globalConfig.path, 1)
        defer {
            if let originalGlobal { setenv("GIT_CONFIG_GLOBAL", originalGlobal, 1) } else { unsetenv("GIT_CONFIG_GLOBAL") }
        }
        let repo = try makeFilterRepo(driver: "lfs") { repo in
            try configFixtureGit(["config", "lfs.extension.x.clean", "touch \(marker.path); cat"], in: repo)
        }

        let snapshot = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: repo.path)

        XCTAssertEqual(snapshot.branch, "feature-x")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a repository-local lfs.extension reached the trusted global filter.lfs driver"
        )
    }

    // MARK: - Submodules are probed without their own config

    /// `git status` and `git diff` spawn a child `git status` inside each populated submodule,
    /// which reads the submodule's own config and does not inherit the parent's overrides.
    func testProbesNeverRunFilterDriverConfiguredInASubmodule() throws {
        let marker = tempRoot.appendingPathComponent("submodule-filter-ran")
        let upstream = try makeRepo(branch: "main", fileName: "a.txt", contents: "a\n")
        let parent = try makeRepo(branch: "feature-x")
        try configFixtureGit(["-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream.path, "sub"], in: parent)
        try configFixtureGit(["commit", "-q", "-m", "add submodule"], in: parent)
        let checkout = parent.appendingPathComponent("sub", isDirectory: true)
        try "*.txt filter=evil\n".write(
            to: checkout.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        // Same size, new mtime: git has to run the clean filter to learn whether it changed.
        try "b\n".write(to: checkout.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try configFixtureGit(["config", "filter.evil.clean", "touch \(marker.path); cat"], in: checkout)

        try configFixtureGit(["status", "--porcelain", "-uno"], in: parent)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path),
            "control: plain `git status` should run the submodule's clean filter"
        )
        try FileManager.default.removeItem(at: marker)

        let snapshot = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: parent.path)
        let review = ReviewDiffProber.diffSnapshot(directory: parent.path, mode: .uncommitted, baseBranch: "main")

        XCTAssertNil(review.error)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "a background git probe executed a filter driver configured in a submodule"
        )

        // Only the submodule's working tree was ignored: a moved gitlink commit still counts.
        XCTAssertFalse(snapshot.isDirty)
        try configFixtureGit(["commit", "-q", "-a", "-m", "move"], in: checkout)
        XCTAssertTrue(GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: parent.path).isDirty)
    }

    func testAutomaticGitEnvironmentCarriesFilterOverridesVerbatim() {
        let environment = CanonicalSubprocessRunner.gitConfigEnvironment([
            ("core.fsmonitor", "false"),
            ("filter.a=b.clean", ""),
        ])

        XCTAssertEqual(environment["GIT_CONFIG_COUNT"], "2")
        XCTAssertEqual(environment["GIT_CONFIG_KEY_1"], "filter.a=b.clean")
        XCTAssertEqual(environment["GIT_CONFIG_VALUE_1"], "")
    }

    // MARK: - Filter overrides are not cached for "not a repository" or "no filters"

    private func configKeys(in environment: [String: String]?) -> Set<String> {
        Set((environment ?? [:]).filter { $0.key.hasPrefix("GIT_CONFIG_KEY_") }.values)
    }

    func testFilterOverridesAreReadAgainOnceADirectoryBecomesARepository() throws {
        let directory = tempRoot.appendingPathComponent("extracted-later", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let before = CanonicalSubprocessRunner.automaticGitEnvironment(directory: directory.path)
        XCTAssertNotNil(before, "a directory that is not a repository is not a config read failure")
        XCTAssertFalse(configKeys(in: before).contains("filter.evil.clean"))

        try configFixtureGit(["init", "-q", "-b", "main"], in: directory)
        try configFixtureGit(["config", "filter.evil.clean", "touch x; cat"], in: directory)

        XCTAssertTrue(
            configKeys(in: CanonicalSubprocessRunner.automaticGitEnvironment(directory: directory.path))
                .contains("filter.evil.clean"),
            "the empty answer for a non-repository was cached and reused for the repository that appeared"
        )
    }

    func testFilterOverridesAreReadAgainWhenARepositoryGainsFilterConfig() throws {
        let repo = try makeRepo(branch: "main")

        XCTAssertFalse(
            configKeys(in: CanonicalSubprocessRunner.automaticGitEnvironment(directory: repo.path))
                .contains("filter.evil.clean")
        )
        try configFixtureGit(["config", "filter.evil.clean", "touch x; cat"], in: repo)

        XCTAssertTrue(
            configKeys(in: CanonicalSubprocessRunner.automaticGitEnvironment(directory: repo.path))
                .contains("filter.evil.clean"),
            "the empty answer for a repository without filters was cached and reused"
        )
    }

    // MARK: - CONF-02: review diff survives hostile or surprising git config and non-ASCII paths

    /// `diff.external` would replace git's diff output with a program's, and `diff.noprefix`
    /// changes the path prefixes the parser expects. Non-ASCII names must come back verbatim,
    /// not as git's quoted octal form.
    func testReviewDiffIgnoresDiffConfigAndKeepsNonASCIIPaths() throws {
        let repo = try makeRepo(branch: "main", fileName: "café.md")
        try "one\ntwo\n".write(to: repo.appendingPathComponent("café.md"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: repo.appendingPathComponent("naïve.txt"), atomically: true, encoding: .utf8)
        try configFixtureGit(["config", "diff.external", "/bin/false"], in: repo)
        try configFixtureGit(["config", "diff.noprefix", "true"], in: repo)

        let snapshot = ReviewDiffProber.diffSnapshot(directory: repo.path, mode: .uncommitted, baseBranch: "main")

        XCTAssertNil(snapshot.error)
        let tracked = snapshot.files.filter { $0.newPath == "café.md" }
        XCTAssertEqual(tracked.count, 1, "files: \(snapshot.files.map(\.displayPath))")
        XCTAssertGreaterThanOrEqual(tracked.first?.hunks.count ?? 0, 1)
        XCTAssertTrue(
            snapshot.files.contains { $0.displayPath == "naïve.txt" },
            "untracked non-ASCII file missing: \(snapshot.files.map(\.displayPath))"
        )
    }

    // MARK: - CONF-03: trailing newline is not a context line

    func testDiffParserDoesNotTurnTrailingNewlineIntoContextLine() throws {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 1111111..2222222 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,2 +1,2 @@
         a
        -b
        +c

        """
        XCTAssertTrue(diff.hasSuffix("\n"))

        let files = ReviewDiffParser.parse(diff)

        let hunk = try XCTUnwrap(files.first?.hunks.last)
        XCTAssertEqual(hunk.lines.count, 3)
        let last = try XCTUnwrap(hunk.lines.last)
        XCTAssertEqual(last.kind, .addition)
        XCTAssertEqual(last.text, "c")
    }

    // MARK: - CONF-06: JSONC comments end at any line terminator

    private func parsedJSONC(_ source: String) throws -> [String: Int]? {
        let data = try JSONCParser.preprocess(data: Data(source.utf8))
        return try JSONSerialization.jsonObject(with: data) as? [String: Int]
    }

    func testJSONCLineCommentEndsAtCRLF() throws {
        XCTAssertEqual(try parsedJSONC("{\r\n // c\r\n \"a\": 1\r\n}"), ["a": 1])
    }

    func testJSONCLineCommentEndsAtBareCR() throws {
        XCTAssertEqual(try parsedJSONC("{\r // c\r \"a\": 1\r}"), ["a": 1])
    }

    func testJSONCBlockCommentSpanningCRLF() throws {
        XCTAssertEqual(try parsedJSONC("{\r\n /* one\r\n two */ \"a\": 1\r\n}"), ["a": 1])
    }

    // MARK: - CONF-14: a hostile base never leaves a worktree or branch behind

    func testWorktreeAddWithOptionLikeBaseFailsAndLeavesNothingBehind() throws {
        let repo = try makeRepo(branch: "main")
        let worktreePath = tempRoot.appendingPathComponent("wt-x").path

        let outcome = GitWorktreeManager.add(repoRoot: repo.path, branch: "x", base: "--detach", path: worktreePath)

        guard case .gitCommandFailed = outcome else {
            return XCTFail("expected .gitCommandFailed for base \"--detach\", got \(outcome)")
        }
        XCTAssertEqual(GitWorktreeManager.branchExistsLocally("x", repoRoot: repo.path), false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }

    // MARK: - An unknown branch state never leads to a deleted branch

    func testBranchExistsLocallyReportsPresentAbsentAndUnknown() throws {
        let repo = try makeRepo(branch: "main")
        let notARepository = tempRoot.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepository, withIntermediateDirectories: true)

        XCTAssertEqual(GitWorktreeManager.branchExistsLocally("main", repoRoot: repo.path), true)
        XCTAssertEqual(GitWorktreeManager.branchExistsLocally("nope", repoRoot: repo.path), false)
        XCTAssertNil(GitWorktreeManager.branchExistsLocally("main", repoRoot: notARepository.path))
    }

    /// A config git cannot parse makes every probe fail, so whether the branch exists is
    /// unknown. The user's branch must survive both the add and the cleanup helper.
    func testWorktreeAddRefusesAndKeepsBranchWhenBranchExistenceIsUnknown() throws {
        let repo = try makeRepo(branch: "main")
        try configFixtureGit(["branch", "keep"], in: repo)
        let configURL = repo.appendingPathComponent(".git/config")
        let goodConfig = try String(contentsOf: configURL, encoding: .utf8)
        let worktreePath = tempRoot.appendingPathComponent("wt-keep").path
        try (goodConfig + "[broken\n").write(to: configURL, atomically: true, encoding: .utf8)
        var configRestored = false
        defer {
            if !configRestored { try? goodConfig.write(to: configURL, atomically: true, encoding: .utf8) }
        }

        XCTAssertNil(GitWorktreeManager.branchExistsLocally("keep", repoRoot: repo.path))
        let outcome = GitWorktreeManager.add(repoRoot: repo.path, branch: "keep", base: nil, path: worktreePath)
        guard case .gitCommandFailed = outcome else {
            return XCTFail("expected .gitCommandFailed when branch existence is unknown, got \(outcome)")
        }
        XCTAssertFalse(GitWorktreeManager.deleteBranchIfUnused("keep", repoRoot: repo.path))

        try goodConfig.write(to: configURL, atomically: true, encoding: .utf8)
        configRestored = true
        XCTAssertEqual(GitWorktreeManager.branchExistsLocally("keep", repoRoot: repo.path), true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }
}
