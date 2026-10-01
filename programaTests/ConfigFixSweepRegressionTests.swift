import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

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

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
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
                domain: "ConfigFixSweepRegressionTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "git \(arguments.joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self))"]
            )
        }
        return output
    }

    /// A repo on `branch` with one commit containing `fileName`.
    private func makeRepo(branch: String, fileName: String = "README.md", contents: String = "one\n") throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", branch], in: repo)
        try contents.write(to: repo.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
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
        try git(["config", "core.fsmonitor", "touch \(marker.path)"], in: repo)

        // Positive control: plain git does run the hook, so an absent marker below really means
        // the probe neutralized it rather than that this git never runs it.
        try git(["status", "--porcelain"], in: repo)
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
        try git(["config", "core.fsmonitor", "touch \(marker.path)"], in: repo)

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

    // MARK: - CONF-02: review diff survives hostile or surprising git config and non-ASCII paths

    /// `diff.external` would replace git's diff output with a program's, and `diff.noprefix`
    /// changes the path prefixes the parser expects. Non-ASCII names must come back verbatim,
    /// not as git's quoted octal form.
    func testReviewDiffIgnoresDiffConfigAndKeepsNonASCIIPaths() throws {
        let repo = try makeRepo(branch: "main", fileName: "café.md")
        try "one\ntwo\n".write(to: repo.appendingPathComponent("café.md"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: repo.appendingPathComponent("naïve.txt"), atomically: true, encoding: .utf8)
        try git(["config", "diff.external", "/bin/false"], in: repo)
        try git(["config", "diff.noprefix", "true"], in: repo)

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
        XCTAssertFalse(GitWorktreeManager.branchExistsLocally("x", repoRoot: repo.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }
}
