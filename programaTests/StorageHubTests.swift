import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class StorageHubTests: XCTestCase {
    func testLowDiskWarningFiresOnceUntilSpaceExceedsRearmMargin() {
        var state = StorageLowDiskWarningState()
        var notificationCount = 0
        let notify = { notificationCount += 1 }

        state.check(availableBytes: 20_000_000_000, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 0, "The threshold itself is not low space")
        state.check(availableBytes: 19_999_999_999, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 1)
        state.check(availableBytes: 1_000_000_000, thresholdGB: 20, notify: notify)
        state.check(availableBytes: 24_999_999_999, thresholdGB: 20, notify: notify)
        state.check(availableBytes: 19_000_000_000, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 1, "Remaining low or recovering within the margin must not repeat the warning")

        state.check(availableBytes: 25_000_000_000, thresholdGB: 20, notify: notify)
        state.check(availableBytes: 19_000_000_000, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 1, "Space must rise above the full rearm margin")
        state.check(availableBytes: 25_000_000_001, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 1, "Recovery rearms without posting a warning")
        state.check(availableBytes: 19_000_000_000, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 2, "A new crossing after recovery produces one new warning")
    }

    func testDisabledWarningAndUnavailableCapacityDoNotConsumeNextCrossing() {
        var state = StorageLowDiskWarningState()
        var notificationCount = 0
        let notify = { notificationCount += 1 }

        state.check(availableBytes: 0, thresholdGB: 0, notify: notify)
        state.check(availableBytes: -1, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 0)
        state.check(availableBytes: 0, thresholdGB: 20, notify: notify)
        XCTAssertEqual(notificationCount, 1, "Enabling the warning must still notify for the first valid low reading")
    }

    func testLowDiskSettingDefaultsForMissingMalformedAndInvalidValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")

        XCTAssertEqual(ProgramaStorageSettings.lowDiskWarningGB(settingsURL: settingsURL), 20)
        for contents in [
            "", "not JSON", "[]", "{}", "{\"storage\":{}}",
            "{\"storage\":{\"lowDiskWarningGB\":true}}",
            "{\"storage\":{\"lowDiskWarningGB\":\"10\"}}",
            "{\"storage\":{\"lowDiskWarningGB\":-1}}",
            "{\"storage\":{\"lowDiskWarningGB\":1e999}}"
        ] {
            try contents.write(to: settingsURL, atomically: true, encoding: .utf8)
            XCTAssertEqual(ProgramaStorageSettings.lowDiskWarningGB(settingsURL: settingsURL), 20, contents)
        }
    }

    func testLowDiskSettingHonorsDisableAndFractionalThresholdInJSONC() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")

        try "{\"storage\":{\"lowDiskWarningGB\":0}}".write(to: settingsURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProgramaStorageSettings.lowDiskWarningGB(settingsURL: settingsURL), 0)
        try "{ /* custom threshold */ \"storage\": {\"lowDiskWarningGB\": 12.5,},}".write(
            to: settingsURL, atomically: true, encoding: .utf8
        )
        XCTAssertEqual(ProgramaStorageSettings.lowDiskWarningGB(settingsURL: settingsURL), 12.5)
    }

    func testConfirmationListsOnlyDryRunRemovalCandidatesAndTheirCombinedSize() {
        let removableWorktree = worktree(path: "/fixtures/merged", branch: "merged-branch", bytes: 120)
        let keptWorktree = worktree(path: "/fixtures/dirty", branch: "dirty-branch", bytes: 900)
        let removableCache = cache(id: "xcode.derived_data/project", title: "Project build cache", bytes: 340)
        let keptCache = cache(id: "xcode.derived_data/running", title: "Running project", bytes: 800)
        let worktreeOutcome = WorktreeStorage.CleanOutcome(
            removed: [removableWorktree],
            kept: [WorktreeStorage.KeptWorktree(entry: keptWorktree, reason: .blocker(.dirty))],
            dryRun: true
        )
        let cacheOutcome = StorageCacheCleanOutcome(
            removed: [removableCache],
            kept: [StorageCacheCleanOutcome.Kept(item: keptCache, reason: "xcode_running")],
            reclaimedBytes: 340
        )

        let summary = StorageConfirmationSummary(worktreeOutcome: worktreeOutcome, cacheOutcome: cacheOutcome)

        XCTAssertEqual(summary.items, [
            StorageConfirmationItem(name: "merged-branch", path: "/fixtures/merged", sizeBytes: 120),
            StorageConfirmationItem(name: "Project build cache", path: "/fixtures/xcode.derived_data/project", sizeBytes: 340)
        ])
        XCTAssertEqual(summary.totalBytes, 460, "Kept worktrees and caches must not inflate the confirmed removal total")
    }

    func testConfirmationHandlesNoCandidatesAndDetachedWorktreeNames() {
        let empty = StorageConfirmationSummary(
            worktreeOutcome: WorktreeStorage.CleanOutcome(removed: [], kept: [], dryRun: true),
            cacheOutcome: StorageCacheCleanOutcome()
        )
        XCTAssertEqual(empty.items, [])
        XCTAssertEqual(empty.totalBytes, 0)

        let summary = StorageConfirmationSummary(
            worktreeOutcome: WorktreeStorage.CleanOutcome(
                removed: [worktree(path: "/fixtures/detached", branch: nil, bytes: 75)], kept: [], dryRun: true
            ),
            cacheOutcome: StorageCacheCleanOutcome()
        )
        XCTAssertEqual(summary.items, [StorageConfirmationItem(name: "detached", path: "/fixtures/detached", sizeBytes: 75)])
        XCTAssertEqual(summary.totalBytes, 75)
    }

    func testLiveSessionsMergeDirectoryAliasesAndExcludeHomeRootAndEmptyPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = directory.appendingPathComponent("home", isDirectory: true)
        let project = home.appendingPathComponent("project", isDirectory: true)
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectAlias = directory.appendingPathComponent("project-alias")
        let homeAlias = directory.appendingPathComponent("home-alias")
        try FileManager.default.createSymbolicLink(at: projectAlias, withDestinationURL: project)
        try FileManager.default.createSymbolicLink(at: homeAlias, withDestinationURL: home)

        let sessions = StorageLiveSessions.sessions(from: [
            (title: "Editor", path: project.path),
            (title: "Shell", path: projectAlias.path),
            (title: "Other", path: other.path),
            (title: "Home", path: home.path),
            (title: "Home alias", path: homeAlias.path),
            (title: "Root", path: "/"),
            (title: "Empty", path: "")
        ], homePath: home.path)

        XCTAssertEqual(sessions.count, 2, "Aliases share one disk measurement and broad directories are excluded")
        let resolvedProject = project.resolvingSymlinksInPath().path
        let merged = try XCTUnwrap(sessions.first { $0.id == resolvedProject })
        XCTAssertEqual(merged.path, resolvedProject)
        XCTAssertEqual(merged.title, "Editor, Shell", "Both workspaces remain identifiable after merging their disk usage")
        XCTAssertEqual(sessions.first { $0.path == other.resolvingSymlinksInPath().path }?.title, "Other")
    }

    func testLiveSessionHeavyFoldersFilterDirectDirectoriesAndSortByAllocatedSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["node_modules", ".build", "build", "unrelated", "nested/target"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true
            )
        }
        let largeContents = Data((0..<262_144).map { _ in UInt8.random(in: .min ... .max) })
        let smallContents = Data(largeContents.prefix(16_384))
        try largeContents.write(to: directory.appendingPathComponent("node_modules/dependency"))
        try smallContents.write(to: directory.appendingPathComponent(".build/object"))
        try largeContents.write(to: directory.appendingPathComponent("unrelated/data"))
        try largeContents.write(to: directory.appendingPathComponent("nested/target/artifact"))
        try largeContents.write(to: directory.appendingPathComponent("dist"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("Pods"),
            withDestinationURL: directory.appendingPathComponent("node_modules")
        )

        let folders = StorageLiveSessions.heavyFolders(in: directory.path, minimumBytes: 1)

        XCTAssertEqual(folders.map(\.name), ["node_modules", ".build"],
                       "Only large, direct, recognized directories contribute heavy-folder rows")
        let largest = try XCTUnwrap(folders.first)
        let smaller = try XCTUnwrap(folders.last)
        XCTAssertGreaterThan(largest.bytes, smaller.bytes, "Rows rank actual allocated disk usage")
        XCTAssertGreaterThanOrEqual(smaller.bytes, 1)
        XCTAssertTrue(StorageLiveSessions.heavyFolders(in: directory.path, minimumBytes: Int64.max).isEmpty,
                      "Directories below the display threshold stay out of the list")
    }

    private func worktree(path: String, branch: String?, bytes: Int64) -> WorktreeStorageEntry {
        WorktreeStorageEntry(
            repoRoot: "/fixtures/repository", path: path, branch: branch, headSHA: nil,
            sizeBytes: bytes, sizePartial: false, lastModified: nil, isProgramaCreated: true,
            isDirty: false, hasIgnoredEnvFiles: false, hasUnpushedOrUnmergedCommits: false,
            isMerged: true, isOpenInWorkspace: false, isProcessRunningInside: false
        )
    }

    private func cache(id: String, title: String, bytes: Int64) -> StorageCacheItem {
        StorageCacheItem(
            id: id, category: .xcode, title: title, path: "/fixtures/\(id)", sizeBytes: bytes,
            sizePartial: false, lastUsed: nil, autoCleanable: false, blocker: nil
        )
    }
}
