import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Regression tests for the CONF (config, git, trust) fix cluster. The tests that need only
/// pre-fix APIs live in `ConfigFixSweepRegressionTests`; these exercise the new behavior and
/// helpers (trust digests per config, duplicate-key rejection, settings parse-error handling,
/// confirmation-dialog disclosure, dirty-worktree refusal, PR lookup throttle).
///
/// Every git repository and trust store lives in a test-owned temp directory removed in
/// `tearDown`. Nothing here touches the real repo's config or the user's trust store.
@MainActor
final class ConfigFixSweepCONFTests: XCTestCase {
    private var tempRoot: URL!
    private var originalPATH: String?
    private var ghCountFile: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("conf-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base.resolvingSymlinksInPath()

        // `gh` stub: answers `pr list` with no pull requests and records each such call.
        originalPATH = ProcessInfo.processInfo.environment["PATH"]
        let binDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        ghCountFile = tempRoot.appendingPathComponent("gh-pr-list-calls")
        let script = """
        #!/bin/sh
        if [ "$1 $2" = "pr list" ]; then
          echo x >> "\(ghCountFile.path)"
          echo '[]'
          exit 0
        fi
        exit 1
        """
        let ghStub = binDir.appendingPathComponent("gh")
        try script.write(to: ghStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ghStub.path)
        setenv("PATH", "\(binDir.path):\(originalPATH ?? "/usr/bin:/bin")", 1)
        GitMetadataProber.resetPullRequestLookupThrottleForTesting()
    }

    override func tearDownWithError() throws {
        GitMetadataProber.resetPullRequestLookupThrottleForTesting()
        if let originalPATH { setenv("PATH", originalPATH, 1) }
        originalPATH = nil
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        ghCountFile = nil
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
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ConfigFixSweepCONFTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey:
                    "git \(arguments.joined(separator: " ")) failed: \(String(decoding: errData, as: UTF8.self))"]
            )
        }
        return String(decoding: outData, as: UTF8.self)
    }

    private func makeRepo(branch: String) throws -> URL {
        let repo = tempRoot.appendingPathComponent("repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", branch], in: repo)
        try "one\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return repo
    }

    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let globalConfigPath = "/dev/null/global-programa.json"

    private func decodeConfig(_ json: String) throws -> ProgramaConfigFile {
        try JSONDecoder().decode(ProgramaConfigFile.self, from: Data(json.utf8))
    }

    // MARK: - CONF-04: replaceAll keeps digests of roots that stay

    private final class NotificationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testReplaceAllKeepsDigestOfRootsThatStayAndPostsNothingWhenUnchanged() throws {
        let configURL = try makeDirectory("trust04/x").appendingPathComponent("programa.json")
        try write(#"{"commands":[{"name":"Build","command":"make build"}]}"#, to: configURL)
        let store = ProgramaDirectoryTrust(storePath: tempRoot.appendingPathComponent("trust04.json").path)
        store.trust(configPath: configURL.path)
        XCTAssertEqual(store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath), .trusted)

        let root = ProgramaDirectoryTrust.trustKey(for: configURL.path)
        store.replaceAll(with: [root, "/tmp/conf-sweep-other-root"])

        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .trusted,
            "a root that stays in the set must keep its recorded digest"
        )

        try write(#"{"commands":[{"name":"Build","command":"rm -rf /"}]}"#, to: configURL)
        XCTAssertEqual(
            store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath),
            .changed
        )

        let counter = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: ProgramaDirectoryTrust.didChangeNotification, object: nil, queue: nil
        ) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.replaceAll(with: [root, "/tmp/conf-sweep-other-root"])
        XCTAssertEqual(counter.count, 0, "replacing the trusted set with itself must not post a change")
    }

    // MARK: - CONF-05: one digest per config file under a root

    func testTwoConfigsUnderOneRootAreTrustedIndependentlyAndLegacyStoresPromptOnce() throws {
        let root = try makeDirectory("trust05")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        let configA = root.appendingPathComponent("programa.json")
        let configB = root.appendingPathComponent("packages/b/programa.json")
        try write(#"{"commands":[{"name":"A","command":"echo a"}]}"#, to: configA)
        try write(#"{"commands":[{"name":"B","command":"echo b"}]}"#, to: configB)

        let store = ProgramaDirectoryTrust(storePath: tempRoot.appendingPathComponent("trust05.json").path)
        store.trust(configPath: configA.path)
        store.trust(configPath: configB.path)
        XCTAssertEqual(store.trustState(configPath: configA.path, globalConfigPath: Self.globalConfigPath), .trusted)
        XCTAssertEqual(store.trustState(configPath: configB.path, globalConfigPath: Self.globalConfigPath), .trusted)

        // A version-2 store recorded one digest per root, for the root's own programa.json.
        let rootKey = ProgramaDirectoryTrust.trustKey(for: configA.path)
        let digestA = try XCTUnwrap(ProgramaDirectoryTrust.executableDigest(forConfigAt: configA.path))
        let v2 = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "directories": [rootKey: digestA],
        ])
        let v2URL = tempRoot.appendingPathComponent("trust05-v2.json")
        try v2.write(to: v2URL)
        let migrated = ProgramaDirectoryTrust(storePath: v2URL.path)
        XCTAssertEqual(migrated.trustState(configPath: configA.path, globalConfigPath: Self.globalConfigPath), .trusted)
        XCTAssertEqual(migrated.trustState(configPath: configB.path, globalConfigPath: Self.globalConfigPath), .changed)

        // A flat legacy array has no digests: prompt, and keep prompting until the user trusts.
        let legacyURL = tempRoot.appendingPathComponent("trust05-legacy.json")
        try JSONSerialization.data(withJSONObject: [rootKey]).write(to: legacyURL)
        let legacy = ProgramaDirectoryTrust(storePath: legacyURL.path)
        XCTAssertEqual(legacy.trustState(configPath: configA.path, globalConfigPath: Self.globalConfigPath), .changed)
        XCTAssertEqual(legacy.trustState(configPath: configA.path, globalConfigPath: Self.globalConfigPath), .changed)
    }

    // MARK: - CONF-07: a half-saved settings.json keeps the last good settings

    func testSettingsFileParseErrorKeepsPreviousManagedSettings() throws {
        let defaults = UserDefaults.standard
        let backupsKey = "programa.settingsFile.backups.v1"
        let quitKey = QuitWarningSettings.warnBeforeQuitKey
        let previousBackups = defaults.data(forKey: backupsKey)
        let previousQuit = defaults.object(forKey: quitKey)
        defer {
            if let previousBackups { defaults.set(previousBackups, forKey: backupsKey) } else { defaults.removeObject(forKey: backupsKey) }
            if let previousQuit { defaults.set(previousQuit, forKey: quitKey) } else { defaults.removeObject(forKey: quitKey) }
        }
        defaults.removeObject(forKey: backupsKey)
        defaults.removeObject(forKey: quitKey)

        let directory = try makeDirectory("settings07")
        let settingsURL = directory.appendingPathComponent("settings.json")
        let themeConfig = directory.appendingPathComponent("config.ghostty")
        let themeStore = TerminalThemeStore(
            fileManager: .default, managedConfigURL: themeConfig, configSearchURLs: [themeConfig]
        )
        try write(#"{ "app": { "warnBeforeQuit": false } }"#, to: settingsURL)

        let center = NotificationCenter()
        let reloads = NotificationCounter()
        let observer = center.addObserver(
            forName: ProgramaSettingsFileStore.didReloadNotification, object: nil, queue: nil
        ) { _ in reloads.increment() }
        defer { center.removeObserver(observer) }

        let store = ProgramaSettingsFileStore(
            primaryPath: settingsURL.path,
            fallbackPath: nil,
            fileManager: .default,
            notificationCenter: center,
            terminalThemeStore: themeStore,
            terminalThemeReloadHandler: {},
            startWatching: false
        )
        XCTAssertEqual(defaults.object(forKey: quitKey) as? Bool, false)
        XCTAssertTrue(store.isManagedByFile(defaultsKey: quitKey))
        XCTAssertNil(store.currentParseError())

        let reloadsBefore = reloads.count
        try write(#"{ "app": {"#, to: settingsURL)
        store.reload()

        XCTAssertEqual(defaults.object(forKey: quitKey) as? Bool, false, "last good value must stay applied")
        XCTAssertTrue(store.isManagedByFile(defaultsKey: quitKey))
        XCTAssertNotNil(store.currentParseError())
        XCTAssertEqual(reloads.count, reloadsBefore + 1, "a failed reload still announces itself")

        try write(#"{ "app": { "warnBeforeQuit": false } }"#, to: settingsURL)
        store.reload()
        XCTAssertNil(store.currentParseError())
    }

    // MARK: - CONF-09: pull request lookup backoff and throttle

    func testPullRequestLookupBackoffDoublesAndCaps() {
        XCTAssertEqual(GitMetadataProber.pullRequestLookupBackoff(failures: 0), 0)
        XCTAssertEqual(GitMetadataProber.pullRequestLookupBackoff(failures: 1), 5)
        XCTAssertEqual(GitMetadataProber.pullRequestLookupBackoff(failures: 2), 10)
        XCTAssertEqual(GitMetadataProber.pullRequestLookupBackoff(failures: 3), 20)
        XCTAssertEqual(GitMetadataProber.pullRequestLookupBackoff(failures: 50), 600)
    }

    func testRepeatedProbesWithinRefreshWindowCallGhOnce() throws {
        let repo = try makeRepo(branch: "feature-y")
        try git(["remote", "add", "origin", "https://github.com/acme/widget.git"], in: repo)

        _ = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: repo.path)
        _ = GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for: repo.path)

        let calls = (try? String(contentsOf: ghCountFile, encoding: .utf8))?
            .split(separator: "\n").count ?? 0
        XCTAssertEqual(calls, 1, "`gh pr list` should run once per directory and branch per refresh window")
    }

    // MARK: - CONF-10: a hung subprocess is cut off

    /// `PortScanner` runs `ps` and `lsof` through `CanonicalSubprocessRunner` with a timeout and
    /// treats anything but a normal exit as "skip this cycle". It exposes no injectable runner,
    /// so this pins the runner contract it relies on.
    func testSubprocessRunnerTimesOutHungToolInsteadOfBlocking() {
        let started = Date()
        let result = CanonicalSubprocessRunner.run(
            executable: "/bin/sleep",
            arguments: ["10"],
            currentDirectory: "/",
            timeout: 0.2,
            stdoutLimit: 1024,
            stderrLimit: 1024,
            executableURL: URL(fileURLWithPath: "/bin/sleep")
        )
        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }

    // MARK: - CONF-11: dialog discloses cwd and refused browser URLs

    private static let browserWorkspaceJSON = """
    {"commands":[{"name":"x","workspace":{"name":"dev","cwd":"/tmp/x","layout":{"direction":"horizontal","children":[
    {"pane":{"surfaces":[{"type":"browser","url":"file:///etc/passwd"}]}},
    {"pane":{"surfaces":[{"type":"browser","url":"https://example.com"}]}}]}}}]}
    """

    func testConfirmationDescribesCwdAndMarksRefusedBrowserURL() throws {
        let command = try XCTUnwrap(decodeConfig(Self.browserWorkspaceJSON).commands.first)

        let text = ProgramaConfigExecutor.describeForConfirmation(command)

        XCTAssertTrue(text.contains("/tmp/x"), text)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("url=https://example.com"), text)
        let fileLine = try XCTUnwrap(lines.first { $0.contains("file:///etc/passwd") }, text)
        XCTAssertNotEqual(fileLine, "url=file:///etc/passwd", "a refused URL must say it is not opened")
        XCTAssertTrue(fileLine.hasPrefix("url=file:///etc/passwd"), fileLine)
    }

    func testLayoutRefusingNonHTTPBrowserURLsClearsFileKeepsHTTPS() throws {
        let command = try XCTUnwrap(decodeConfig(Self.browserWorkspaceJSON).commands.first)
        let layout = try XCTUnwrap(command.workspace?.layout)

        let filtered = ProgramaConfigExecutor.layoutRefusingNonHTTPBrowserURLs(layout)

        guard case let .split(split) = filtered,
              case let .pane(first) = split.children[0],
              case let .pane(second) = split.children[1] else {
            return XCTFail("layout shape changed")
        }
        XCTAssertNil(first.surfaces[0].url)
        XCTAssertEqual(second.surfaces[0].url, "https://example.com")
    }

    // MARK: - CONF-12: control characters cannot hide in a command

    func testControlCharacterDetection() {
        XCTAssertTrue(ProgramaConfigExecutor.containsDisallowedControlCharacters("echo \u{1b}[2J"))
        XCTAssertTrue(ProgramaConfigExecutor.containsDisallowedControlCharacters("a\tb"))
        XCTAssertTrue(ProgramaConfigExecutor.containsDisallowedControlCharacters("\u{7f}"))
        XCTAssertTrue(ProgramaConfigExecutor.containsDisallowedControlCharacters("\u{85}"))
        XCTAssertFalse(ProgramaConfigExecutor.containsDisallowedControlCharacters("a\nb"))
    }

    func testCommandTextsIncludesEveryNestedLayoutSurfaceCommand() throws {
        let json = """
        {"commands":[{"name":"x","workspace":{"name":"dev","layout":{"direction":"horizontal","children":[
        {"pane":{"surfaces":[{"type":"terminal","command":"first-thing"}]}},
        {"direction":"vertical","children":[
        {"pane":{"surfaces":[{"type":"terminal","command":"second-thing"}]}},
        {"pane":{"surfaces":[{"type":"terminal","command":"third-thing"}]}}]}]}}}]}
        """
        let command = try XCTUnwrap(decodeConfig(json).commands.first)

        XCTAssertEqual(
            ProgramaConfigExecutor.commandTexts(of: command, resolvedCommand: nil),
            ["first-thing", "second-thing", "third-thing"]
        )
    }

    func testConfirmationShowsNewlinesAsVisibleMarkers() {
        let command = ProgramaCommandDefinition(name: "x", command: "a\nb")

        let text = ProgramaConfigExecutor.describeForConfirmation(command)

        XCTAssertTrue(text.contains("⏎"), text)
        XCTAssertFalse(text.contains("\n"), text)
    }

    // MARK: - CONF-15: dirty-worktree refusal

    func testDirtyWorktreeRefusalRecognizesGitWordings() {
        XCTAssertTrue(GitWorktreeManager.isDirtyWorktreeRefusal(
            "fatal: '/p' contains modified or untracked files, use --force to delete it"
        ))
        XCTAssertTrue(GitWorktreeManager.isDirtyWorktreeRefusal("fatal: '/p' is dirty, use --force to delete it"))
        XCTAssertFalse(GitWorktreeManager.isDirtyWorktreeRefusal("fatal: '/p' is not a working tree"))
    }

    func testRemovingDirtyWorktreeNeedsForceAndKeepsUserFileUntilThen() throws {
        let repo = try makeRepo(branch: "main")
        let worktreePath = tempRoot.appendingPathComponent("wt-dirty").path
        guard case .success = GitWorktreeManager.add(repoRoot: repo.path, branch: "feat", base: nil, path: worktreePath) else {
            return XCTFail("fixture worktree could not be added")
        }
        let userFile = URL(fileURLWithPath: worktreePath).appendingPathComponent("notes.txt")
        try "unsaved\n".write(to: userFile, atomically: true, encoding: .utf8)

        let refused = GitWorktreeManager.remove(repoRoot: repo.path, path: worktreePath, force: false)
        guard case .worktreeDirty = refused else {
            return XCTFail("expected .worktreeDirty, got \(refused)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))

        let forced = GitWorktreeManager.remove(repoRoot: repo.path, path: worktreePath, force: true)
        guard case .success = forced else {
            return XCTFail("expected .success, got \(forced)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreePath))
    }

    // MARK: - CONF-20: duplicate keys can never be trusted

    func testConfigWithDuplicateKeysHasNoDigestAndCannotBeTrusted() throws {
        let configURL = try makeDirectory("trust20").appendingPathComponent("programa.json")
        try write(#"{"commands":[{"name":"a","command":"echo a"}],"commands":[]}"#, to: configURL)
        let store = ProgramaDirectoryTrust(storePath: tempRoot.appendingPathComponent("trust20.json").path)

        XCTAssertNil(ProgramaDirectoryTrust.executableDigest(forConfigAt: configURL.path))
        XCTAssertEqual(store.trustState(configPath: configURL.path, globalConfigPath: Self.globalConfigPath), .untrusted)
        store.trust(configPath: configURL.path)
        XCTAssertTrue(store.allTrustedPaths.isEmpty, "trusting an undigestable config must not create an entry")
    }

    func testDuplicateObjectKeyDetection() {
        XCTAssertTrue(JSONCParser.containsDuplicateObjectKeys(Data(#"{"a":1,"a":2}"#.utf8)))
        XCTAssertFalse(JSONCParser.containsDuplicateObjectKeys(Data(#"[{"a":1},{"a":2}]"#.utf8)))
        XCTAssertFalse(JSONCParser.containsDuplicateObjectKeys(Data(#"{"x":"a\":","a":1}"#.utf8)))
    }
}
