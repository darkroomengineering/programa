import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class StorageCategoriesTests: XCTestCase {
    private var home: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3600

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-categories-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        home = URL(fileURLWithPath: WorktreeStorage.resolvedPath(home.path), isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let home { try FileManager.default.removeItem(at: home) }
        home = nil
        try super.tearDownWithError()
    }

    private func context(
        processes: @escaping () -> [String]? = { [] },
        projects: [String] = []
    ) -> StorageCacheContext {
        StorageCacheContext(
            home: home.path,
            environment: [:],
            processes: processes,
            command: { executable, arguments, directory, _ in
                guard URL(fileURLWithPath: executable).lastPathComponent == "git" else { return nil }
                return try? configFixtureGit(arguments, in: URL(fileURLWithPath: directory))
            },
            tools: [:],
            projectDirectories: projects,
            now: now
        )
    }

    @discardableResult
    private func directory(_ relative: String, age: TimeInterval = 0) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let artifact = url.appendingPathComponent("artifact")
        try Data("rebuildable".utf8).write(to: artifact)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: artifact.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return url
    }

    private func item(_ url: URL, in items: [StorageCacheItem]) throws -> StorageCacheItem {
        try XCTUnwrap(items.first { $0.path.map(WorktreeStorage.resolvedPath) == url.path })
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testDerivedDataRequiresFourteenDaysAndUsesNewerInfoPlistDate() throws {
        let old = try directory("Library/Developer/Xcode/DerivedData/Old-abcd", age: 14 * day)
        let recent = try directory("Library/Developer/Xcode/DerivedData/Recent-abcd", age: 14 * day - 1)
        let refreshed = try directory("Library/Developer/Xcode/DerivedData/Refreshed-abcd", age: 30 * day)
        let info = refreshed.appendingPathComponent("info.plist")
        try Data().write(to: info)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-day)], ofItemAtPath: info.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: refreshed.path)

        let items = StorageCategories.scan(categories: [.xcode], context: context())

        XCTAssertTrue(try item(old, in: items).autoCleanable)
        XCTAssertFalse(try item(recent, in: items).autoCleanable)
        let refreshedItem = try item(refreshed, in: items)
        XCTAssertFalse(refreshedItem.autoCleanable)
        XCTAssertEqual(refreshedItem.lastUsed, now.addingTimeInterval(-day))
    }

    func testNewestDeviceSupportPerPlatformIsNeverOffered() throws {
        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let old = try directory("Library/Developer/Xcode/\(platform) DeviceSupport/9.0", age: 60 * day)
            let newest = try directory("Library/Developer/Xcode/\(platform) DeviceSupport/10.0", age: 90 * day)
            let items = StorageCategories.scan(categories: [.xcode], context: context())
            XCTAssertFalse(try item(old, in: items).autoCleanable, platform)
            XCTAssertFalse(items.contains { $0.path == newest.path }, platform)
        }
    }

    func testDerivedDataWithRecentDescendantActivityRequiresManualCleanup() throws {
        let derivedData = try directory("Library/Developer/Xcode/DerivedData/Active-abcd", age: 30 * day)
        let nested = try directory("Library/Developer/Xcode/DerivedData/Active-abcd/Build/Products", age: day)
        let info = derivedData.appendingPathComponent("info.plist")
        try Data().write(to: info)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: info.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: nested.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: nested.deletingLastPathComponent().path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * day)], ofItemAtPath: derivedData.path)

        let scanned = try item(derivedData, in: StorageCategories.scan(categories: [.xcode], context: context()))

        XCTAssertFalse(scanned.autoCleanable)
        XCTAssertEqual(scanned.lastUsed, now.addingTimeInterval(-day))
    }

    func testBootedSimulatorBlocksSimulatorCleanupWithoutBlockingDerivedData() throws {
        let derivedData = try directory("Library/Developer/Xcode/DerivedData/App-abcd", age: 30 * day)
        let simulatorCache = try directory("Library/Developer/CoreSimulator/Caches")
        let unavailableID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let availableID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let unavailable = try directory("Library/Developer/CoreSimulator/Devices/\(unavailableID)")
        let available = try directory("Library/Developer/CoreSimulator/Devices/\(availableID)")
        var fixture = context()
        fixture.command = { _, arguments, _, _ in
            guard arguments.prefix(3) == ["simctl", "list", "devices"] else { return nil }
            if arguments.contains("unavailable") {
                return "{\"devices\":{\"runtime\":[{\"udid\":\"\(unavailableID)\",\"isAvailable\":false,\"state\":\"Shutdown\"}]}}"
            }
            return "{\"devices\":{\"runtime\":[{\"udid\":\"\(availableID)\",\"isAvailable\":true,\"state\":\"Booted\"}]}}"
        }

        let items = StorageCategories.scan(categories: [.xcode], context: fixture)

        XCTAssertNil(try item(derivedData, in: items).blocker)
        XCTAssertEqual(try item(simulatorCache, in: items).blocker, "xcode_running")
        let unavailableItem = try XCTUnwrap(items.first { $0.path == nil })
        XCTAssertTrue(unavailableItem.autoCleanable)
        XCTAssertEqual(unavailableItem.blocker, "xcode_running")
        XCTAssertEqual(unavailableItem.sizeBytes, WorktreeStorage.directorySize(atPath: unavailable.path, timeout: 20).bytes)
        XCTAssertFalse(items.contains { $0.path == available.path })
        XCTAssertTrue(exists(available))
    }

    func testGradleCacheAgeAndNewestDistributionExclusion() throws {
        let oldBuild = try directory(".gradle/caches/build-cache-1", age: 14 * day)
        let recentTransforms = try directory(".gradle/caches/transforms-4", age: day)
        let modules = try directory(".gradle/caches/modules-2", age: 60 * day)
        let oldDist = try directory(".gradle/wrapper/dists/gradle-8.9-bin", age: day)
        let newestDist = try directory(".gradle/wrapper/dists/gradle-8.10-bin", age: 30 * day)

        let items = StorageCategories.scan(categories: [.android], context: context())

        XCTAssertTrue(try item(oldBuild, in: items).autoCleanable)
        XCTAssertFalse(try item(recentTransforms, in: items).autoCleanable)
        XCTAssertFalse(items.contains { $0.path == newestDist.path })
        XCTAssertFalse(try item(oldDist, in: items).autoCleanable)
        XCTAssertTrue(items.contains { candidate in
            guard let path = candidate.path else { return false }
            return !candidate.autoCleanable && WorktreeStorage.isPath(modules.path, equalToOrInside: path, caseInsensitive: false)
        }, "the remaining Gradle caches require manual cleanup")
    }

    func testReferencedAndroidSystemImageIsKeptWhileUnusedImageIsOffered() throws {
        let referenced = try directory("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a")
        let unused = try directory("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
        let avd = home.appendingPathComponent(".android/avd/Pixel.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avd, withIntermediateDirectories: true)
        try "image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n"
            .write(to: avd.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)

        let items = StorageCategories.scan(categories: [.android], context: context())

        XCTAssertFalse(items.contains { $0.path == referenced.path })
        XCTAssertFalse(try item(unused, in: items).autoCleanable)
        XCTAssertFalse(items.contains { $0.path == avd.path }, "AVDs themselves are never cleanup candidates")
    }

    func testUnknownAVDConfigurationKeepsSystemImages() throws {
        let image = try directory("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a")
        XCTAssertFalse(try item(image, in: StorageCategories.scan(categories: [.android], context: context())).autoCleanable)
        let avd = home.appendingPathComponent(".android/avd/Unknown.avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avd, withIntermediateDirectories: true)

        let items = StorageCategories.scan(categories: [.android], context: context())

        XCTAssertFalse(items.contains { $0.path == image.path }, "missing config leaves the image reference unknown")
    }

    func testRegisteredExternalAVDsKeepTheirSystemImagesForDefaultAndCustomAVDHomes() throws {
        let unused = try directory("Library/Android/sdk/system-images/android-34/google_apis/arm64-v8a")
        for root in [".android/avd", "custom/android/avd"] {
            let imagePath = "system-images/android-\(root == ".android/avd" ? "35" : "36")/google_apis/arm64-v8a"
            let referenced = try directory("Library/Android/sdk/\(imagePath)")
            let avdRoot = home.appendingPathComponent(root, isDirectory: true)
            try FileManager.default.createDirectory(at: avdRoot, withIntermediateDirectories: true)
            let external = try directory("elsewhere/\(root == ".android/avd" ? "Default" : "Custom").avd")
            try "image.sysdir.1=\(imagePath)/\n"
                .write(to: external.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
            var fixture = context()
            if root != ".android/avd" { fixture.environment["ANDROID_AVD_HOME"] = avdRoot.path }
            for registration in ["path=\(external.path)\n", "path.rel=\(root == ".android/avd" ? "../" : "../../")elsewhere/\(external.lastPathComponent)\n"] {
                try registration.write(to: avdRoot.appendingPathComponent("Pixel.ini"), atomically: true, encoding: .utf8)

                let items = StorageCategories.scan(categories: [.android], context: fixture)

                XCTAssertFalse(items.contains { $0.path == referenced.path }, "\(root): \(registration)")
                XCTAssertNotNil(try item(unused, in: items).path, "valid registrations must still allow unused image cleanup")
            }
        }
    }

    func testUnknownAVDRegistrationKeepsEverySystemImage() throws {
        let image = try directory("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a")
        let avdRoot = home.appendingPathComponent(".android/avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avdRoot, withIntermediateDirectories: true)
        let registration = avdRoot.appendingPathComponent("Unknown.ini")
        for contents in ["avd.ini.encoding=UTF-8\n", "path=\(home.appendingPathComponent("missing.avd").path)\n"] {
            try contents.write(to: registration, atomically: true, encoding: .utf8)

            let items = StorageCategories.scan(categories: [.android], context: context())

            XCTAssertFalse(items.contains { $0.path == image.path }, contents)
        }
        try FileManager.default.removeItem(at: registration)
        try FileManager.default.createDirectory(at: registration, withIntermediateDirectories: true)
        XCTAssertFalse(StorageCategories.scan(categories: [.android], context: context()).contains { $0.path == image.path })
    }

    func testSymlinkedAVDKeepsSystemImagesWhenItsReferenceCannotBeSafelyDiscovered() throws {
        let image = try directory("Library/Android/sdk/system-images/android-35/google_apis/arm64-v8a")
        XCTAssertFalse(try item(image, in: StorageCategories.scan(categories: [.android], context: context())).autoCleanable)
        let external = try directory("elsewhere/Linked.avd")
        try "image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n"
            .write(to: external.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let avdRoot = home.appendingPathComponent(".android/avd", isDirectory: true)
        try FileManager.default.createDirectory(at: avdRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: avdRoot.appendingPathComponent("Linked.avd"), withDestinationURL: external)

        let items = StorageCategories.scan(categories: [.android], context: context())

        XCTAssertFalse(items.contains { $0.path == image.path }, "silently skipping an AVD symlink can delete its image")
    }

    func testProjectBuildWithTrackedFilesIsSkipped() throws {
        let repo = try directory("repo")
        try configFixtureGit(["init", "-b", "main"], in: repo)
        try "plugins {}\n".write(to: repo.appendingPathComponent("build.gradle.kts"), atomically: true, encoding: .utf8)
        let tracked = try directory("repo/build")
        try configFixtureGit(["add", "build/artifact"], in: repo)
        let disposable = try directory("repo/module/build")
        try "plugins {}\n".write(to: repo.appendingPathComponent("module/build.gradle"), atomically: true, encoding: .utf8)

        let items = StorageCategories.scan(categories: [.android], context: context(projects: [repo.path]))

        XCTAssertFalse(items.contains { $0.path == tracked.path })
        XCTAssertFalse(try item(disposable, in: items).autoCleanable)
    }

    func testProjectBuildWithEnvironmentFileIsSkipped() throws {
        let repo = try directory("repo")
        try configFixtureGit(["init", "-b", "main"], in: repo)
        try "plugins {}\n".write(to: repo.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        let protected = try directory("repo/build")
        try Data().write(to: protected.appendingPathComponent(".env.local"))
        let disposable = try directory("repo/module/build")
        try "plugins {}\n".write(to: repo.appendingPathComponent("module/build.gradle.kts"), atomically: true, encoding: .utf8)

        let items = StorageCategories.scan(categories: [.android], context: context(projects: [repo.path]))

        XCTAssertFalse(items.contains { $0.path == protected.path })
        XCTAssertFalse(try item(disposable, in: items).autoCleanable)
        XCTAssertTrue(exists(protected.appendingPathComponent(".env.local")))
    }

    func testRunningToolsBlockOnlyTheirCacheCategory() throws {
        let xcode = try directory("Library/Developer/Xcode/DerivedData/App-abcd", age: 30 * day)
        let gradle = try directory(".gradle/caches/build-cache-1", age: 30 * day)
        let bun = try directory(".bun/install/cache", age: 30 * day)
        let cases: [(String, URL, String)] = [
            ("/Applications/Xcode.app/Contents/MacOS/Xcode", xcode, "xcode_running"),
            ("/usr/bin/xcodebuild -project App.xcodeproj", xcode, "xcode_running"),
            ("/usr/bin/java org.gradle.launcher.daemon.bootstrap.GradleDaemon", gradle, "gradle_running"),
            ("/Applications/Android Studio.app/Contents/MacOS/studio", gradle, "gradle_running"),
            ("/opt/homebrew/bin/bun install", bun, "install_running"),
        ]
        for (process, blockedPath, reason) in cases {
            let items = StorageCategories.scan(context: context(processes: { [process] }))
            XCTAssertEqual(try item(blockedPath, in: items).blocker, reason, process)
            for unaffected in [xcode, gradle, bun] where unaffected != blockedPath {
                XCTAssertNil(try item(unaffected, in: items).blocker, process)
            }
        }
        let editor = StorageCategories.scan(context: context(processes: { ["/Applications/Visual Studio Code.app/Contents/MacOS/Electron"] }))
        for path in [xcode, gradle, bun] {
            XCTAssertNil(try item(path, in: editor).blocker)
        }
    }

    func testPackageCachesHonorAgeAndInstallAliases() throws {
        let bun = try directory(".bun/install/cache", age: 14 * day)
        let npm = try directory(".npm/_cacache", age: 14 * day - 1)
        let idle = StorageCategories.scan(categories: [.packages], context: context())
        XCTAssertTrue(try item(bun, in: idle).autoCleanable)
        XCTAssertFalse(try item(npm, in: idle).autoCleanable)

        for alias in ["install", "add", "i", "ci"] {
            let busy = StorageCategories.scan(categories: [.packages], context: context(processes: {
                ["/opt/homebrew/bin/bun \(alias)"]
            }))
            XCTAssertEqual(try item(bun, in: busy).blocker, "install_running", alias)
            XCTAssertNil(try item(npm, in: busy).blocker, "a Bun install must not block npm cleanup")
        }
    }

    func testAutomaticCleanupKeepsManualItemsAndDryRunPreservesDisposableData() throws {
        let manual = try directory("Library/Developer/Xcode/DerivedData/Recent-abcd", age: day)
        let disposable = try directory("Library/Developer/Xcode/DerivedData/Old-abcd", age: 30 * day)
        let fixture = context()
        let items = StorageCategories.scan(categories: [.xcode], context: fixture)

        let preview = StorageCategories.clean(items: items, automaticOnly: true, dryRun: true, now: now, context: fixture)

        XCTAssertEqual(preview.kept.first { $0.item.path == manual.path }?.reason, "manual_only")
        XCTAssertEqual(preview.removed.map(\.path), [disposable.path])
        XCTAssertTrue(exists(manual))
        XCTAssertTrue(exists(disposable))

        let outcome = StorageCategories.clean(items: items, automaticOnly: true, dryRun: false, now: now, context: fixture)
        XCTAssertEqual(outcome.kept.first { $0.item.path == manual.path }?.reason, "manual_only")
        XCTAssertEqual(outcome.removed.map(\.path), [disposable.path])
        XCTAssertTrue(exists(manual))
        XCTAssertFalse(exists(disposable))
    }

    func testYarnWithoutSubcommandBlocksCleanupButCacheQueriesDoNot() throws {
        let yarn = try directory("Library/Caches/Yarn", age: 30 * day)
        var fixture = context()
        fixture.tools = ["yarn": "/fixture/bin/yarn"]
        fixture.command = { executable, arguments, _, _ in
            guard executable == "/fixture/bin/yarn", arguments == ["cache", "dir"] else { return nil }
            return yarn.path + "\n"
        }
        for process in ["/opt/homebrew/bin/yarn", "node /usr/local/lib/node_modules/yarn/bin/yarn.js --frozen-lockfile"] {
            fixture.processes = { [process] }
            let items = StorageCategories.scan(categories: [.packages], context: fixture)
            XCTAssertEqual(try item(yarn, in: items).blocker, "install_running", process)
        }
        fixture.processes = { ["yarn cache dir"] }
        let items = StorageCategories.scan(categories: [.packages], context: fixture)
        XCTAssertNil(try item(yarn, in: items).blocker)
    }

    func testDryRunReportsTheCombinedSizeOfRemovableItems() throws {
        let first = try directory("Library/Developer/Xcode/DerivedData/First-abcd", age: 30 * day)
        let second = try directory("Library/Developer/Xcode/DerivedData/Second-abcd", age: 30 * day)
        let manual = try directory("Library/Developer/Xcode/DerivedData/Recent-abcd", age: day)
        let fixture = context()
        let items = StorageCategories.scan(categories: [.xcode], context: fixture)
        let expectedBytes = try item(first, in: items).sizeBytes + item(second, in: items).sizeBytes

        let preview = StorageCategories.clean(items: items, automaticOnly: true, dryRun: true, now: now, context: fixture)

        XCTAssertEqual(Set(preview.removed.compactMap(\.path)), Set([first.path, second.path]))
        XCTAssertGreaterThan(expectedBytes, 0)
        XCTAssertEqual(preview.reclaimedBytes, expectedBytes)
        for path in [first, second, manual] { XCTAssertTrue(exists(path.appendingPathComponent("artifact"))) }
    }

    func testCleanRechecksProcessesAfterScan() throws {
        let cache = try directory("Library/Developer/Xcode/DerivedData/App-abcd", age: 30 * day)
        var processes: [String] = []
        let fixture = context(processes: { processes })
        let items = StorageCategories.scan(categories: [.xcode], context: fixture)
        XCTAssertNil(try item(cache, in: items).blocker)
        processes = ["/usr/bin/xcodebuild -project App.xcodeproj"]

        let outcome = StorageCategories.clean(items: items, automaticOnly: false, dryRun: false, now: now, context: fixture)

        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.kept.first { $0.item.path == cache.path }?.reason, "xcode_running")
        XCTAssertTrue(exists(cache))
    }

    func testCustomPackageCacheRootsCannotSelectHomeSharedCachesOrProjects() throws {
        let safe = try directory("custom/cache", age: 30 * day)
        let shared = try directory(".cache", age: 30 * day)
        let repo = try directory("repo")
        try configFixtureGit(["init", "-b", "main"], in: repo)
        let projectCache = try directory("repo/cache", age: 30 * day)
        let ordinary = try directory("documents", age: 30 * day)
        var fixture = context(projects: [repo.path])
        fixture.environment["BUN_INSTALL_CACHE_DIR"] = safe.path
        let safeItems = StorageCategories.scan(categories: [.packages], context: fixture)
        XCTAssertTrue(try item(safe, in: safeItems).autoCleanable)

        for dangerous in [home!, shared, repo, projectCache, ordinary] {
            fixture.environment["BUN_INSTALL_CACHE_DIR"] = dangerous.path
            let items = StorageCategories.scan(categories: [.packages], context: fixture)
            XCTAssertFalse(items.contains { $0.path == dangerous.path }, dangerous.path)

            let outcome = StorageCategories.clean(
                items: safeItems, automaticOnly: false, dryRun: false, now: now, context: fixture
            )
            XCTAssertTrue(outcome.removed.isEmpty, "configuration changes cannot authorize a broader cache root")
            XCTAssertTrue(exists(dangerous))
            XCTAssertTrue(exists(safe.appendingPathComponent("artifact")))
        }
    }

    func testUnknownProcessListKeepsAllCacheCategories() throws {
        let xcode = try directory("Library/Developer/Xcode/DerivedData/App-abcd", age: 30 * day)
        let gradle = try directory(".gradle/caches/build-cache-1", age: 30 * day)
        let bun = try directory(".bun/install/cache", age: 30 * day)
        let fixture = context(processes: { nil })

        let items = StorageCategories.scan(context: fixture)
        let outcome = StorageCategories.clean(
            items: items, automaticOnly: false, dryRun: false, now: now, context: fixture
        )

        XCTAssertEqual(try item(xcode, in: items).blocker, "xcode_running")
        XCTAssertEqual(try item(gradle, in: items).blocker, "gradle_running")
        XCTAssertEqual(try item(bun, in: items).blocker, "install_running")
        XCTAssertTrue(outcome.removed.isEmpty)
        for path in [xcode, gradle, bun] { XCTAssertTrue(exists(path.appendingPathComponent("artifact"))) }
    }

    func testProjectBuildCleanupRemovesUntrackedOutputAndRechecksNewlyTrackedFiles() throws {
        let repo = try directory("repo")
        try configFixtureGit(["init", "-b", "main"], in: repo)
        try "plugins {}\n".write(to: repo.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        let disposable = try directory("repo/build")
        let trackedLater = try directory("repo/module/build")
        try "plugins {}\n".write(to: repo.appendingPathComponent("module/build.gradle.kts"), atomically: true, encoding: .utf8)
        let fixture = context(projects: [repo.path])
        let items = StorageCategories.scan(categories: [.android], context: fixture)
        XCTAssertFalse(try item(disposable, in: items).autoCleanable)
        XCTAssertFalse(try item(trackedLater, in: items).autoCleanable)
        try configFixtureGit(["add", "module/build/artifact"], in: repo)

        let outcome = StorageCategories.clean(
            items: items, automaticOnly: false, dryRun: false, now: now, context: fixture
        )

        XCTAssertEqual(outcome.removed.map(\.path), [disposable.path])
        XCTAssertFalse(exists(disposable))
        XCTAssertTrue(exists(trackedLater.appendingPathComponent("artifact")))
        XCTAssertEqual(outcome.kept.first { $0.item.path == trackedLater.path }?.reason, "no_longer_eligible")
        XCTAssertTrue(exists(repo.appendingPathComponent("build.gradle")), "cleanup preserves the project definition")
    }

    func testPnpmPruneIsAutomaticForRecentStoreAndPreservesReferencedPackages() throws {
        let store = try directory("Library/pnpm/store")
        let referenced = store.appendingPathComponent("artifact")
        let orphan = store.appendingPathComponent("orphan")
        try Data("unreferenced package".utf8).write(to: orphan)
        var fixture = context()
        fixture.tools = ["pnpm": "/fixture/bin/pnpm"]
        fixture.command = { executable, arguments, _, _ in
            guard executable == "/fixture/bin/pnpm" else { return nil }
            if arguments == ["store", "path"] { return store.path + "\n" }
            guard arguments == ["store", "prune"] else { return nil }
            do {
                try FileManager.default.removeItem(at: orphan)
                return ""
            } catch { return nil }
        }
        let items = StorageCategories.scan(categories: [.packages], context: fixture)
        let scanned = try item(store, in: items)
        XCTAssertTrue(scanned.autoCleanable, "pnpm prunes unreferenced packages even when its store is recent")
        XCTAssertNotNil(scanned.lastUsed)

        let outcome = StorageCategories.clean(
            items: items, automaticOnly: true, dryRun: false, now: now, context: fixture
        )

        XCTAssertEqual(outcome.removed.map(\.path), [store.path])
        XCTAssertTrue(exists(store))
        XCTAssertTrue(exists(referenced), "the tool retains packages still in use")
        XCTAssertFalse(exists(orphan))
    }

    func testCleaningSeveralItemsOfOneCategoryScansThatCategoryOnce() throws {
        let caches = try ["First", "Second", "Third"].map {
            try directory("Library/Developer/Xcode/DerivedData/\($0)-abcd", age: 30 * day)
        }
        var deviceQueries = 0
        var fixture = context()
        fixture.command = { executable, arguments, _, _ in
            if executable == "xcrun", arguments.starts(with: ["simctl", "list"]) { deviceQueries += 1 }
            return nil
        }
        let items = StorageCategories.scan(categories: [.xcode], context: fixture)
        let queriesPerScan = deviceQueries
        XCTAssertGreaterThan(queriesPerScan, 0)

        deviceQueries = 0
        let preview = StorageCategories.clean(items: items, automaticOnly: false, dryRun: true, now: now, context: fixture)
        XCTAssertEqual(preview.removed.count, caches.count)
        XCTAssertEqual(deviceQueries, queriesPerScan, "a dry run scans the category once, not once per item")

        deviceQueries = 0
        let outcome = StorageCategories.clean(items: items, automaticOnly: false, dryRun: false, now: now, context: fixture)
        XCTAssertEqual(Set(outcome.removed.compactMap(\.path)), Set(caches.map(\.path)))
        XCTAssertEqual(deviceQueries, queriesPerScan, "removal scans the category once, not once per item")
        for cache in caches { XCTAssertFalse(exists(cache)) }
    }

    func testProjectBuildGitCheckRunsWithAutomaticGitHardening() throws {
        let log = home.appendingPathComponent("git-invocations.log")
        let git = try directory("bin").appendingPathComponent("git")
        try """
        #!/bin/sh
        { printf '%s\\n' "$@"; env | grep '^GIT_CONFIG_' | sort; echo '@@end'; } >> '\(log.path)'
        exit 0
        """.write(to: git, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        let repo = try directory("repo")
        try "plugins {}\n".write(to: repo.appendingPathComponent("build.gradle"), atomically: true, encoding: .utf8)
        let build = try directory("repo/build")
        var fixture = context(projects: [repo.path])
        fixture.tools = ["git": git.path]
        fixture.command = StorageCacheContext.liveCommand(environment: [:])

        let items = StorageCategories.scan(categories: [.android], context: fixture)

        XCTAssertNotNil(try? item(build, in: items), "the fake git reports no tracked files")
        let invocations = try String(contentsOf: log, encoding: .utf8)
            .components(separatedBy: "@@end\n").filter { !$0.isEmpty }
            .map { $0.split(separator: "\n").map(String.init) }
        let listFiles = try XCTUnwrap(invocations.first { $0.contains("ls-files") })
        let options = CanonicalSubprocessRunner.automaticGitOptions
        XCTAssertTrue(options.contains("core.fsmonitor=false"))
        XCTAssertEqual(Array(listFiles.prefix(options.count + 3)), options + ["ls-files", "-z", "--"])
        XCTAssertEqual(listFiles.count > options.count + 3 ? WorktreeStorage.resolvedPath(listFiles[options.count + 3]) : nil, build.path)
        let fsmonitorKey = try XCTUnwrap(listFiles.first { $0.hasPrefix("GIT_CONFIG_KEY_") && $0.hasSuffix("=core.fsmonitor") })
        let index = fsmonitorKey.dropFirst("GIT_CONFIG_KEY_".count).prefix { $0 != "=" }
        XCTAssertTrue(listFiles.contains("GIT_CONFIG_VALUE_\(index)=false"))
    }
}
