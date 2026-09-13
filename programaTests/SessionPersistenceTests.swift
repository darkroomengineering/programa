import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class SessionPersistenceTests: XCTestCase {
    @MainActor
    func testWorkspaceSessionSnapshotRestoresPendingReviewComments() throws {
        let workspace = Workspace()
        let sourceID = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.newReviewSplit(from: sourceID, orientation: .horizontal))
        let comment = try panel.addComment(filePath: "App.swift", startLine: 4, endLine: 6, text: "Preserve this review")
        let snapshot = workspace.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.panels.first(where: { $0.id == panel.id })?.review?.comments, [comment])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        let restoredPanel = try XCTUnwrap(restored.panels.values.compactMap { $0 as? ReviewPanel }.first)
        XCTAssertEqual(restoredPanel.comments.first?.id, comment.id)
        XCTAssertEqual(restoredPanel.comments.first?.text, comment.text)
        XCTAssertEqual(restoredPanel.comments.first?.startLine, 4)
        XCTAssertEqual(restoredPanel.comments.first?.endLine, 6)
        XCTAssertNotNil(restored.terminalPanel(for: restoredPanel.sourceSurfaceId), "Source routing must remap with the restored terminal")
        XCTAssertFalse(restored.sendReviewComments(sourceSurfaceId: UUID(), text: "Missing source"))
    }

    @MainActor
    func testSnapshotDecoderRejectsDuplicateAndExcessiveReviewDrafts() throws {
        let workspace = Workspace()
        let panel = try XCTUnwrap(workspace.newReviewSplit(from: try XCTUnwrap(workspace.focusedPanelId), orientation: .horizontal))
        let comment = try panel.addComment(filePath: "App.swift", startLine: 1, text: "Draft")
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0] = workspace.sessionSnapshot(includeScrollback: false)
        let index = try XCTUnwrap(snapshot.windows[0].tabManager.workspaces[0].panels.firstIndex(where: { $0.id == panel.id }))
        XCTAssertNotNil(SessionPersistenceStore.decodeSnapshot(from: try JSONEncoder().encode(snapshot)))
        snapshot.windows[0].tabManager.workspaces[0].panels[index].review?.comments = [comment, comment]
        XCTAssertNil(SessionPersistenceStore.decodeSnapshot(from: try JSONEncoder().encode(snapshot)))
        snapshot.windows[0].tabManager.workspaces[0].panels[index].review?.comments = (0...SessionPersistencePolicy.maxReviewCommentsPerPanel).map { _ in
            ReviewComment(filePath: "App.swift", startLine: 1, text: "Draft")
        }
        XCTAssertNil(SessionPersistenceStore.decodeSnapshot(from: try JSONEncoder().encode(snapshot)))
    }

    private struct LegacyPersistedWindowGeometry: Codable {
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot?
    }

    @MainActor
    func testWorkspaceSessionSnapshotRestoresMarkdownPanel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markdownURL = root.appendingPathComponent("note.md")
        try "# hello\n".write(to: markdownURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let paneId = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(
            workspace.newMarkdownSurface(
                inPane: paneId,
                filePath: markdownURL.path,
                focus: true
            )
        )
        workspace.setCustomTitle("Docs")
        workspace.setPanelCustomTitle(panelId: panel.id, title: "Readme")

        let snapshot = workspace.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.markdownPanel(for: restoredPanelId))
        XCTAssertEqual(restoredPanel.filePath, markdownURL.path)
        XCTAssertEqual(restored.customTitle, "Docs")
        XCTAssertEqual(restored.panelTitle(panelId: restoredPanelId), "Readme")
    }

    @MainActor
    func testWorkspaceSessionSnapshotToleratesDuplicatePanelIDs() throws {
        let workspace = Workspace()
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        let originalPanel = try XCTUnwrap(snapshot.panels.first)
        snapshot.panels.append(originalPanel)

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)

        XCTAssertEqual(restored.panels.count, 1)
        XCTAssertNotNil(restored.panels.values.first)
    }

    func testSaveAndLoadRoundTripWithCustomSnapshotPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        let loaded = SessionPersistenceStore.load(fileURL: snapshotURL)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.version, SessionSnapshotSchema.currentVersion)
        XCTAssertEqual(loaded?.windows.count, 1)
        XCTAssertEqual(loaded?.windows.first?.sidebar.selection, .tabs)
        let frame = try XCTUnwrap(loaded?.windows.first?.frame)
        XCTAssertEqual(frame.x, 10, accuracy: 0.001)
        XCTAssertEqual(frame.y, 20, accuracy: 0.001)
        XCTAssertEqual(frame.width, 900, accuracy: 0.001)
        XCTAssertEqual(frame.height, 700, accuracy: 0.001)
        XCTAssertEqual(loaded?.windows.first?.display?.displayID, 42)
        let visibleFrame = try XCTUnwrap(loaded?.windows.first?.display?.visibleFrame)
        XCTAssertEqual(visibleFrame.y, 25, accuracy: 0.001)
    }

    func testSaveAndLoadRoundTripPreservesWorkspaceCustomColor() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].customColor = "#C0392B"

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        let loaded = SessionPersistenceStore.load(fileURL: snapshotURL)
        XCTAssertEqual(
            loaded?.windows.first?.tabManager.workspaces.first?.customColor,
            "#C0392B"
        )
    }

    func testSaveSkipsRewritingIdenticalSnapshotData() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let firstFileNumber = try fileNumber(for: snapshotURL)

        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        let secondFileNumber = try fileNumber(for: snapshotURL)

        XCTAssertEqual(
            secondFileNumber,
            firstFileNumber,
            "Saving identical session data should not replace the snapshot file"
        )
    }

    func testRotateIntoHistoryCopiesLiveSnapshotIntoHistoryDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL))

        let entries = SessionPersistenceStore.historyFileURLs(fileURL: snapshotURL)
        XCTAssertEqual(entries.count, 1)

        let liveData = try Data(contentsOf: snapshotURL)
        let archivedData = try Data(contentsOf: try XCTUnwrap(entries.first))
        XCTAssertEqual(liveData, archivedData)
    }

    func testRotateIntoHistorySkipsWhenNewestEntryIsIdentical() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL))
        XCTAssertFalse(
            SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL),
            "Rotating unchanged content again should be a no-op"
        )

        XCTAssertEqual(
            SessionPersistenceStore.historyFileURLs(fileURL: snapshotURL).count,
            1,
            "A duplicate rotation should not add a second history entry"
        )
    }

    func testRotateIntoHistoryPrunesToTenNewestEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let historyDirectory = try XCTUnwrap(SessionPersistenceStore.historyDirectoryURL(fileURL: snapshotURL))
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        for index in 0..<12 {
            let filename = "20260101-0000\(String(format: "%02d", index)).json"
            let fileURL = historyDirectory.appendingPathComponent(filename, isDirectory: false)
            try Data("{\"seed\":\(index)}".utf8).write(to: fileURL)
        }

        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        // Force the live file's modification date later than every seeded entry above, so the
        // just-rotated copy is unambiguously the newest and the pruning boundary is deterministic.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let laterDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        try FileManager.default.setAttributes([.modificationDate: laterDate], ofItemAtPath: snapshotURL.path)

        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL, maxHistoryEntries: 10))

        let entries = SessionPersistenceStore.historyFileURLs(fileURL: snapshotURL)
        XCTAssertEqual(entries.count, 10)

        let remainingNames = Set(entries.map { $0.lastPathComponent })
        XCTAssertFalse(remainingNames.contains("20260101-000000.json"), "Oldest seeded entry should be pruned")
        XCTAssertFalse(remainingNames.contains("20260101-000001.json"), "Second-oldest seeded entry should be pruned")
        XCTAssertFalse(remainingNames.contains("20260101-000002.json"), "Third-oldest seeded entry should be pruned")
        XCTAssertTrue(remainingNames.contains("20260101-000011.json"), "Newest seeded entry should survive pruning")
        XCTAssertEqual(
            entries.first?.lastPathComponent.hasPrefix("20260102-"),
            true,
            "The just-rotated entry should sort as the newest"
        )
    }

    func testHistoryScanCapsDirectoryEnumerationBeforeSorting() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-session-history-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let historyDirectory = try XCTUnwrap(SessionPersistenceStore.historyDirectoryURL(fileURL: snapshotURL))
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        for index in 0..<40 {
            let name = "20260101-\(String(format: "%06d", index)).json"
            try Data("{}".utf8).write(to: historyDirectory.appendingPathComponent(name))
        }

        let result = SessionPersistenceStore.historyScan(fileURL: snapshotURL, scanLimit: 8)
        let returnedNames = result.entries.map(\.lastPathComponent)
        let resolvedHistoryDirectory = historyDirectory.resolvingSymlinksInPath()

        XCTAssertEqual(result.inspectedEntryCount, 8)
        XCTAssertEqual(result.entries.count, 8)
        XCTAssertEqual(returnedNames, returnedNames.sorted(by: >))
        XCTAssertTrue(
            result.entries.allSatisfy {
                $0.deletingLastPathComponent().resolvingSymlinksInPath() == resolvedHistoryDirectory
            }
        )
    }

    func testRotateIntoHistoryCapsDuplicateAndPruningScansInHostileDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-session-history-rotation-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let historyDirectory = try XCTUnwrap(SessionPersistenceStore.historyDirectoryURL(fileURL: snapshotURL))
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

        let hostileEntryCount = SessionPersistenceStore.historyDirectoryScanLimit + 44
        for index in 0..<hostileEntryCount {
            let name = "20260101-\(String(format: "%06d", index)).json"
            try Data("{\"seed\":\(index)}".utf8).write(to: historyDirectory.appendingPathComponent(name))
        }

        XCTAssertTrue(
            SessionPersistenceStore.save(
                makeSnapshot(version: SessionSnapshotSchema.currentVersion),
                fileURL: snapshotURL
            )
        )

        var inspectedEntryCounts: [Int] = []
        XCTAssertTrue(
            SessionPersistenceStore.rotateIntoHistory(
                fileURL: snapshotURL,
                maxHistoryEntries: 0,
                historyScanObserver: { inspectedEntryCounts.append($0.inspectedEntryCount) }
            )
        )

        XCTAssertEqual(
            inspectedEntryCounts,
            [
                SessionPersistenceStore.historyDirectoryScanLimit,
                SessionPersistenceStore.historyDirectoryScanLimit,
            ],
            "Duplicate suppression and pruning must each stop at the shared directory scan cap"
        )

        let remainingJSONEntries = try FileManager.default.contentsOfDirectory(
            at: historyDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        XCTAssertEqual(
            remainingJSONEntries.count,
            hostileEntryCount + 1 - SessionPersistenceStore.historyDirectoryScanLimit,
            "One rotation may prune only the entries returned by its bounded maintenance scan"
        )
    }

    func testRotateIntoHistoryReplacesAnArchiveThatLandsOnTheSameFilename() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        // Archive filenames carry the live file's modification date at second resolution, so
        // pinning the same date twice reproduces the collision two quick launches would hit.
        let fixedDate = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 4))
        )

        try Data("{\"seed\":1}".utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: snapshotURL.path)
        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL))

        try Data("{\"seed\":2}".utf8).write(to: snapshotURL)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: snapshotURL.path)
        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL))

        let entries = SessionPersistenceStore.historyFileURLs(fileURL: snapshotURL)
        XCTAssertEqual(entries.count, 1, "A same-filename rotation should replace, not duplicate")
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(entries.first)),
            Data("{\"seed\":2}".utf8),
            "The archive should hold the newer content after the swap"
        )

        let historyDirectory = try XCTUnwrap(SessionPersistenceStore.historyDirectoryURL(fileURL: snapshotURL))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: historyDirectory.path)
            .filter { $0.contains(".staging-") }
        XCTAssertTrue(leftovers.isEmpty, "Staging files should not survive a successful rotation")
    }

    func testWindowsToRestoreClampsToTheStartupWindowCap() throws {
        let base = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let window = try XCTUnwrap(base.windows.first)

        let oversized = AppSessionSnapshot(
            version: base.version,
            createdAt: base.createdAt,
            windows: Array(repeating: window, count: SessionPersistencePolicy.maxWindowsPerSnapshot + 25),
            cleanShutdown: base.cleanShutdown
        )
        XCTAssertEqual(
            SessionPersistenceStore.windowsToRestore(from: oversized).count,
            SessionPersistencePolicy.maxWindowsPerSnapshot,
            "Manual restore should clamp to the same cap startup restore uses"
        )

        XCTAssertEqual(
            SessionPersistenceStore.windowsToRestore(from: base).count,
            1,
            "A snapshot under the cap should restore every window"
        )
        XCTAssertTrue(
            SessionPersistenceStore.windowsToRestore(from: oversized, limit: 0).isEmpty,
            "A zero limit should restore nothing rather than trapping"
        )
    }

    func testDecodeSnapshotDetectsVersionMismatchWithoutRequiringAppKit() throws {
        let mismatched = makeSnapshot(version: SessionSnapshotSchema.currentVersion + 1)
        let data = try JSONEncoder().encode(mismatched)

        let decoded = try XCTUnwrap(SessionPersistenceStore.decodeSnapshot(from: data))
        XCTAssertNotEqual(decoded.version, SessionSnapshotSchema.currentVersion)
    }

    func testDecodeSnapshotReturnsNilForCorruptData() {
        XCTAssertNil(SessionPersistenceStore.decodeSnapshot(from: Data("not json".utf8)))
    }

    func testSnapshotReaderRejectsBytesBeyondLimitBeforeFullAllocation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-session-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json")
        try Data(repeating: 0x41, count: 33).write(to: snapshotURL)

        XCTAssertNil(
            SessionPersistenceStore.boundedSnapshotData(at: snapshotURL, maximumBytes: 32)
        )
    }

    func testDecodeSnapshotRejectsExcessiveJSONNestingBeforeRecursiveDecode() throws {
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let encoded = try JSONEncoder().encode(snapshot)
        var json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let depth = SessionPersistencePolicy.maxJSONNestingDepth + 1
        let nestedValue = String(repeating: "[", count: depth)
            + "0"
            + String(repeating: "]", count: depth)
        json.insert(contentsOf: ",\"unexpectedDeepValue\":\(nestedValue)", at: json.index(before: json.endIndex))

        XCTAssertNil(SessionPersistenceStore.decodeSnapshot(from: Data(json.utf8)))
    }

    func testDecodeSnapshotRejectsWindowCountBeyondReconstructionPolicy() throws {
        let base = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let window = try XCTUnwrap(base.windows.first)
        let oversized = AppSessionSnapshot(
            version: base.version,
            createdAt: base.createdAt,
            windows: Array(
                repeating: window,
                count: SessionPersistencePolicy.maxWindowsPerSnapshot + 1
            ),
            cleanShutdown: base.cleanShutdown
        )

        XCTAssertNil(
            SessionPersistenceStore.decodeSnapshot(from: try JSONEncoder().encode(oversized))
        )
    }

    func testSaveRejectsSnapshotBeyondReconstructionPolicy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-session-save-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let base = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        let window = try XCTUnwrap(base.windows.first)
        let oversized = AppSessionSnapshot(
            version: base.version,
            createdAt: base.createdAt,
            windows: Array(
                repeating: window,
                count: SessionPersistencePolicy.maxWindowsPerSnapshot + 1
            ),
            cleanShutdown: base.cleanShutdown
        )
        let snapshotURL = tempDir.appendingPathComponent("session.json")

        XCTAssertFalse(SessionPersistenceStore.save(oversized, fileURL: snapshotURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }

    func testDecodeSnapshotRejectsOversizedNestedMetadataBeforeRestore() throws {
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].processTitle = String(
            repeating: "x",
            count: SessionPersistencePolicy.maxMetadataStringBytes + 1
        )

        XCTAssertNil(
            SessionPersistenceStore.decodeSnapshot(from: try JSONEncoder().encode(snapshot))
        )
    }

    func testAppSessionSnapshotDecodesLegacyJSONWithoutCleanShutdownField() throws {
        let legacyJSON = Data("""
        {
          "version": \(SessionSnapshotSchema.currentVersion),
          "createdAt": 1700000000,
          "windows": []
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: legacyJSON)
        XCTAssertNil(decoded.cleanShutdown)
    }

    func testAppSessionSnapshotRoundTripsCleanShutdownFlag() throws {
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.cleanShutdown = true
        let data = try JSONEncoder().encode(snapshot)

        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.cleanShutdown, true)
    }

    @MainActor
    func testAutosaveFingerprintChangesWhenPersistedStatusValueChangesWithoutCountChange() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        workspace.statusEntries["build"] = SidebarStatusEntry(
            key: "build",
            value: "queued",
            timestamp: timestamp
        )
        let beforeSnapshot = manager.sessionSnapshot(includeScrollback: false)
        let beforeFingerprint = manager.sessionAutosaveFingerprint()

        workspace.statusEntries["build"] = SidebarStatusEntry(
            key: "build",
            value: "complete",
            timestamp: timestamp
        )
        let afterSnapshot = manager.sessionSnapshot(includeScrollback: false)
        let afterFingerprint = manager.sessionAutosaveFingerprint()

        XCTAssertEqual(
            beforeSnapshot.workspaces.first?.statusEntries.first?.value,
            "queued"
        )
        XCTAssertEqual(
            afterSnapshot.workspaces.first?.statusEntries.first?.value,
            "complete"
        )
        XCTAssertNotEqual(
            beforeFingerprint,
            afterFingerprint,
            "Autosave identity must change whenever persisted status content changes"
        )
    }

    @MainActor
    func testAutosaveFingerprintChangesWhenPersistedPanelTitleChangesWithoutCountChange() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panelID = try XCTUnwrap(workspace.focusedPanelId)

        workspace.setPanelCustomTitle(panelId: panelID, title: "Before")
        let beforeSnapshot = manager.sessionSnapshot(includeScrollback: false)
        let beforeFingerprint = manager.sessionAutosaveFingerprint()

        workspace.setPanelCustomTitle(panelId: panelID, title: "After")
        let afterSnapshot = manager.sessionSnapshot(includeScrollback: false)
        let afterFingerprint = manager.sessionAutosaveFingerprint()

        XCTAssertEqual(
            beforeSnapshot.workspaces.first?.panels.first(where: { $0.id == panelID })?.customTitle,
            "Before"
        )
        XCTAssertEqual(
            afterSnapshot.workspaces.first?.panels.first(where: { $0.id == panelID })?.customTitle,
            "After"
        )
        XCTAssertNotEqual(
            beforeFingerprint,
            afterFingerprint,
            "Autosave identity must change whenever persisted panel content changes"
        )
    }

    func testWorkspaceCustomColorDecodeSupportsMissingLegacyField() throws {
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].customColor = nil

        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"customColor\""))

        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        XCTAssertNil(decoded.windows.first?.tabManager.workspaces.first?.customColor)
    }

    func testLoadRejectsSchemaVersionMismatch() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        XCTAssertTrue(SessionPersistenceStore.save(makeSnapshot(version: SessionSnapshotSchema.currentVersion + 1), fileURL: snapshotURL))

        XCTAssertNil(SessionPersistenceStore.load(fileURL: snapshotURL))
    }

    func testLoadWithHistoryFallbackReturnsHistoryCopyWhenPrimaryIsCorrupt() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].customTitle = "Intact History Copy"
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))

        // Archives the just-saved (intact) snapshot into session-history/ via the store's own
        // rotation seam, exactly like startup does before overwriting the primary file.
        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL))
        XCTAssertEqual(SessionPersistenceStore.historyFileURLs(fileURL: snapshotURL).count, 1)

        // Simulate a crash mid-write / disk corruption: truncate the primary file so it no
        // longer decodes.
        try Data("{\"version\":".utf8).write(to: snapshotURL)
        XCTAssertNil(SessionPersistenceStore.load(fileURL: snapshotURL), "Strict load must stay nil on corrupt primary data")

        let restored = SessionPersistenceStore.loadWithHistoryFallback(fileURL: snapshotURL)
        XCTAssertEqual(
            restored?.windows.first?.tabManager.workspaces.first?.customTitle,
            "Intact History Copy",
            "A corrupt primary snapshot should fall back to the archived history copy"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
            .filter { $0.hasSuffix(".json-quarantine") }
        XCTAssertEqual(quarantined.count, 1, "The corrupt primary should not poison the next launch")
    }

    func testLoadWithHistoryFallbackReturnsHistoryCopyWhenPrimaryVersionMismatches() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        XCTAssertTrue(SessionPersistenceStore.save(snapshot, fileURL: snapshotURL))
        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(fileURL: snapshotURL))

        // A future schema-bumped primary must not shadow the still-current-version archive.
        XCTAssertTrue(
            SessionPersistenceStore.save(makeSnapshot(version: SessionSnapshotSchema.currentVersion + 1), fileURL: snapshotURL)
        )

        let restored = SessionPersistenceStore.loadWithHistoryFallback(fileURL: snapshotURL)
        XCTAssertEqual(restored?.version, SessionSnapshotSchema.currentVersion)
        XCTAssertEqual(restored?.windows.count, 1)
    }

    func testLoadWithHistoryFallbackReturnsNilWhenHistoryIsAlsoUnusable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        // No history/ directory has ever been created for this snapshot path.
        try Data("not json".utf8).write(to: snapshotURL)

        XCTAssertNil(SessionPersistenceStore.loadWithHistoryFallback(fileURL: snapshotURL))
    }

    func testDefaultSnapshotPathSanitizesBundleIdentifier() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-session-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = SessionPersistenceStore.defaultSnapshotFileURL(
            bundleIdentifier: "com.example/unsafe id",
            appSupportDirectory: tempDir
        )

        XCTAssertNotNil(path)
        XCTAssertTrue(path?.path.contains("com.example_unsafe_id") == true)
    }

    func testRestorePolicySkipsWhenLaunchHasExplicitArguments() {
        let shouldRestore = SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "--window", "window:1"],
            environment: [:]
        )

        XCTAssertFalse(shouldRestore)
    }

    func testRestorePolicyAllowsFinderStyleLaunchArgumentsOnly() {
        let shouldRestore = SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux", "-psn_0_12345"],
            environment: [:]
        )

        XCTAssertTrue(shouldRestore)
    }

    func testRestorePolicySkipsWhenRunningUnderXCTest() {
        let shouldRestore = SessionRestorePolicy.shouldAttemptRestore(
            arguments: ["/Applications/cmux.app/Contents/MacOS/cmux"],
            environment: ["XCTestConfigurationFilePath": "/tmp/xctest.xctestconfiguration"]
        )

        XCTAssertFalse(shouldRestore)
    }

    func testSidebarWidthSanitizationClampsToPolicyRange() {
        XCTAssertEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(-20),
            SessionPersistencePolicy.minimumSidebarWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(10_000),
            SessionPersistencePolicy.maximumSidebarWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            SessionPersistencePolicy.sanitizedSidebarWidth(nil),
            SessionPersistencePolicy.defaultSidebarWidth,
            accuracy: 0.001
        )
    }

    func testSessionRectSnapshotEncodesXYWidthHeightKeys() throws {
        let snapshot = SessionRectSnapshot(x: 101.25, y: 202.5, width: 903.75, height: 704.5)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Double])

        XCTAssertEqual(Set(object.keys), Set(["x", "y", "width", "height"]))
        XCTAssertEqual(try XCTUnwrap(object["x"]), 101.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["y"]), 202.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["width"]), 903.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(object["height"]), 704.5, accuracy: 0.001)
    }

    func testSessionBrowserPanelSnapshotHistoryRoundTrip() throws {
        let profileID = try XCTUnwrap(UUID(uuidString: "8F03A658-5A84-428B-AD03-5A6D04692F64"))
        let source = SessionBrowserPanelSnapshot(
            urlString: "https://example.com/current",
            profileID: profileID,
            shouldRenderWebView: true,
            pageZoom: 1.2,
            developerToolsVisible: true,
            backHistoryURLStrings: [
                "https://example.com/a",
                "https://example.com/b"
            ],
            forwardHistoryURLStrings: [
                "https://example.com/d"
            ]
        )

        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: data)
        XCTAssertEqual(decoded.urlString, source.urlString)
        XCTAssertEqual(decoded.profileID, source.profileID)
        XCTAssertEqual(decoded.backHistoryURLStrings, source.backHistoryURLStrings)
        XCTAssertEqual(decoded.forwardHistoryURLStrings, source.forwardHistoryURLStrings)
    }

    func testSessionBrowserPanelSnapshotHistoryDecodesWhenKeysAreMissing() throws {
        let json = """
        {
          "urlString": "https://example.com/current",
          "shouldRenderWebView": true,
          "pageZoom": 1.0,
          "developerToolsVisible": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SessionBrowserPanelSnapshot.self, from: json)
        XCTAssertEqual(decoded.urlString, "https://example.com/current")
        XCTAssertNil(decoded.profileID)
        XCTAssertNil(decoded.backHistoryURLStrings)
        XCTAssertNil(decoded.forwardHistoryURLStrings)
    }

    func testFreshSpawnScrollbackSeedPreparesText() {
        let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: "line one\nline two\n")
        XCTAssertEqual(prepared, "line one\nline two\n")
    }

    func testFreshSpawnScrollbackSeedSkipsWhitespaceOnlyContent() {
        XCTAssertNil(SessionFreshSpawnScrollbackSeed.preparedText(for: " \n\t  "))
        XCTAssertNil(SessionFreshSpawnScrollbackSeed.preparedText(for: nil))
    }

    func testFreshSpawnScrollbackSeedAddsTrailingNewlineWhenMissing() {
        // No trailing newline in the source: the fresh shell's own first
        // prompt must not be concatenated onto the last replayed line.
        let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: "no trailing newline")
        XCTAssertEqual(prepared, "no trailing newline\n")
    }

    func testFreshSpawnScrollbackSeedPreservesANSIColorSequences() {
        let red = "\u{001B}[31m"
        let reset = "\u{001B}[0m"
        let source = "\(red)RED\(reset)\n"
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\(red)RED\(reset)"))
        XCTAssertTrue(prepared.hasPrefix(reset))
        XCTAssertTrue(prepared.hasSuffix(reset + "\n"), "Expected trailing SGR reset + newline")
    }

    /// A program killed by the relaunch never sends the DECRST that balances
    /// its mouse-tracking DECSET, so the saved transcript arms mouse reporting
    /// when it is replayed into the fresh terminal. With nothing left to
    /// consume the reports, the fresh shell's prompt fills with literal
    /// `35;16;54M…` motion reports. The prepared seed text must disarm them.
    func testFreshSpawnScrollbackSeedDisarmsStuckMouseTrackingModes() {
        // An unbalanced enable of any-event motion tracking + SGR encoding,
        // exactly as a TUI killed mid-run leaves it in the WAL tail.
        let source = "\u{001B}[?1003h\u{001B}[?1006hvim session\n"
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        for mode in ["9", "1000", "1001", "1002", "1003", "1005", "1006", "1015", "1016"] {
            XCTAssertTrue(
                prepared.contains("\u{001B}[?\(mode)l"),
                "Prepared seed text must disable mouse mode \(mode)"
            )
        }

        // The sanitizer strips DEC private mode sequences like `ESC[?1003h`
        // at source -- they're CSI, and only meaningful at the grid width
        // they were captured at -- so the replayed enable no longer survives
        // into the output at all. The disable loop above is what actually
        // guarantees the mode can't stay armed, and it fires regardless of
        // whether the enable (or anything else on the line) survived
        // sanitization -- see `forceModeReset` in `preparedText(for:)`.
        XCTAssertFalse(
            prepared.contains("\u{001B}[?1003h"),
            "DEC private mode enables are stripped by the sanitizer at source, not replayed"
        )
    }

    /// A TUI killed by the restart leaves more than the mouse armed. The modes
    /// below are the ones a window resize does NOT clear in ghostty — the
    /// active screen key, the wraparound bit and the charset are all untouched
    /// by `Terminal.resize()` — so a transcript that strands the shell on the
    /// alternate screen, or with autowrap off, stays broken through any number
    /// of resizes unless the prepared seed text disarms them itself.
    func testFreshSpawnScrollbackSeedRestoresLayoutAffectingTerminalState() {
        // A vim-shaped tail: enter alt screen, set a scroll region, turn off
        // autowrap, switch G0 to line drawing -- then die without undoing any.
        let source = "\u{001B}[?1049h\u{001B}[1;40r\u{001B}[?7l\u{001B}(0status line\n"
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        let required: [(String, String)] = [
            ("\u{001B}[?1047l", "leave the alternate screen"),
            ("\u{001B}[?7h", "restore autowrap"),
            ("\u{001B}[r", "reset the scrolling region"),
            ("\u{001B}(B", "restore G0 to ASCII"),
            ("\u{001B}[?1004l", "disable focus reporting"),
        ]
        for (sequence, purpose) in required {
            XCTAssertTrue(prepared.contains(sequence), "Prepared seed text must \(purpose)")
        }

        // 1049l is specifically NOT used: ghostty's 1049-disable path restores
        // the cursor unconditionally, which homes it to (0,0) when nothing was
        // saved -- dropping the fresh shell's prompt on top of the restored
        // output on every restart that never involved an alternate screen.
        XCTAssertFalse(
            prepared.contains("\u{001B}[?1049l"),
            "1049l homes the cursor when no save exists; 1047l is the safe form"
        )
    }

    /// `ESC[r` ends with `setCursorPos(1, 1)`, so the margin reset has to be
    /// bracketed in DECSC/DECRC or the cursor lands at the top of the screen.
    /// The charset and origin resets must precede the DECSC, because DECRC
    /// restores both from the save and would otherwise reinstate the bad ones.
    func testFreshSpawnScrollbackSeedBracketsCursorMovingResets() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}[?7l\u{001B}(0output\n"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        guard let charsetReset = prepared.range(of: "\u{001B}(B")?.lowerBound,
              let save = prepared.range(of: "\u{001B}7")?.lowerBound,
              let marginReset = prepared.range(of: "\u{001B}[r")?.lowerBound,
              let restore = prepared.range(of: "\u{001B}8")?.lowerBound else {
            XCTFail("Expected charset reset, DECSC, margin reset and DECRC")
            return
        }

        XCTAssertLessThan(charsetReset, save, "Charset must be clean before DECSC captures it")
        XCTAssertLessThan(save, marginReset, "DECSC must precede the cursor-homing margin reset")
        XCTAssertLessThan(marginReset, restore, "DECRC must follow the margin reset")
    }

    /// Raw WAL fallback text carries `\r` overwrite runs from progress
    /// spinners. `\r` moves the write column back to 0 without clearing --
    /// a real overwrite, not a line clear -- so a shorter redraw leaves the
    /// tail of the longest previous write in place. Tracing the three
    /// redraws by hand: "working " (8 cols) -> CR -> "working. " (9 cols,
    /// fully overwrites + extends by 1) -> CR -> "working.. " (10 cols,
    /// fully overwrites + extends by 1) -> CR -> "done" (4 cols) only
    /// overwrites columns 0-3 of the 10-column "working.. ", leaving columns
    /// 4-9 ("ing.. ") behind it -- hence "doneing.. ", not "done".
    func testFreshSpawnScrollbackSeedCollapsesCarriageReturnOverwriteRuns() {
        let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "working \rworking. \rworking.. \rdone\n"
        )
        XCTAssertEqual(prepared, "doneing.. \n")
        XCTAssertFalse(prepared?.contains("\r") ?? true, "No carriage return should survive overwrite resolution")
    }

    /// A CR overwrite with no following erase-line leaves the tail of the
    /// longer prior write in place, exactly like a real terminal: "Done"
    /// (4 cols) only overwrites the first 4 columns of "Downloading 100%"
    /// (17 cols), so "loading 100%" survives behind it.
    func testFreshSpawnScrollbackSeedPreservesResidueWhenNoEraseFollowsOverwrite() {
        let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: "Downloading 100%\rDone")
        XCTAssertTrue(prepared?.contains("Doneloading 100%") ?? false)
    }

    /// The realistic spinner shape: CR overwrite immediately followed by
    /// erase-to-end-of-line (`ESC[K`). That erase clears the residual tail
    /// the overwrite alone would have left behind, so no trace of the longer
    /// original line survives. (Asserting `contains`/`!contains` here rather
    /// than exact equality: the source contains an escape, so
    /// `forceModeReset` correctly wraps the output with the mode-reset
    /// preamble/postamble regardless of whether the sanitized text itself
    /// still has any escape left in it -- that wrapping is exercised and
    /// asserted by the mouse-tracking and layout-state tests, not this one.)
    func testFreshSpawnScrollbackSeedTruncatesResidueWhenEraseToEndFollowsOverwrite() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "Downloading 100%\rDone\u{001B}[K"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("Done"))
        XCTAssertFalse(prepared.contains("loading 100%"), "ESC[K must erase the overwrite residue, leaving no trace of it")
    }

    /// `ESC[2K` clears the whole line outright, discarding anything written
    /// before it on that line -- unlike a bare CR overwrite, which only
    /// clobbers as many columns as the new text covers.
    func testFreshSpawnScrollbackSeedEraseEntireLineClearsPriorContent() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "garbage\u{001B}[2Kclean"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("clean"))
        XCTAssertFalse(prepared.contains("garbage"))
    }

    /// A backspace can only ever delete a previously-written plain
    /// character, never a byte belonging to an escape sequence -- escapes
    /// are stripped from the working text before the cell walk sees any
    /// `\b`, so `ESC[31m` cannot be corrupted into the unrelated ECH command
    /// `ESC[31X` the way a naive "delete the raw byte before \b" pass would.
    func testFreshSpawnScrollbackSeedBackspaceNeverCorruptsAnEscapeSequence() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}[31m\u{8}X"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[31m"))
        XCTAssertFalse(prepared.contains("\u{001B}[31X"))
    }

    /// CSI finals the old handwritten allowlist missed (here `L`, insert
    /// line) are still removed, because the generic CSI strip matches any
    /// final byte in `@`-`~` rather than an enumerated list.
    func testFreshSpawnScrollbackSeedRemovesGridMutatingCSIFinalsNotOnAnyAllowlist() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "before\u{001B}[2Lafter"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("beforeafter"))
    }

    /// An OSC 8 hyperlink is removed cleanly -- both the opening sequence
    /// (with its URL payload) and the closing sequence -- without
    /// swallowing the plain text that follows it on the line.
    func testFreshSpawnScrollbackSeedRemovesOSCHyperlinkWithoutSwallowingFollowingText() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}]8;;https://example.com\u{7}link\u{001B}]8;;\u{7} tail"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("link"))
        XCTAssertTrue(prepared.contains("tail"))
        XCTAssertFalse(prepared.contains("\u{7}"))
    }

    /// Absolute cursor-positioning escapes are only valid at the grid width
    /// they were captured at; replaying them into a differently sized grid
    /// scatters text to the wrong columns, so they must be stripped.
    func testFreshSpawnScrollbackSeedStripsAbsoluteCursorPositioning() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}[12;40Hhello"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertFalse(prepared.contains("\u{001B}[12;40H"))
        XCTAssertTrue(prepared.contains("hello"))
    }

    func testFreshSpawnScrollbackSeedKeepsSGRColorSequencesIntact() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}[31mred\u{001B}[0m"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[31m"))
    }

    func testFreshSpawnScrollbackSeedBoundsRepeatedColorReplay() {
        let count = 1_200
        let source = (0..<count).map { "\u{001B}[\($0.isMultiple(of: 2) ? 31 : 34)mx" }.joined()
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertEqual(prepared.filter { $0 == "x" }.count, count)
        XCTAssertLessThan(prepared.utf8.count, source.utf8.count * 4)
    }

    func testFreshSpawnScrollbackSeedKeepsEffectiveStyleAcrossOverwriteAndResets() {
        let source = "\u{001B}[1;38;5;160mAB\u{001B}[22;39m\r\u{001B}[38;2;1;2;3mX"
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[38;2;1;2;3mX\u{001B}[0m\u{001B}[1;38;5;160mB"))
        XCTAssertFalse(prepared.contains("\r"))
    }

    func testFreshSpawnScrollbackSeedReplaysRepeatedColoredProgressOverwrites() throws {
        let source = (0..<20_000).map {
            "\u{001B}[\($0.isMultiple(of: 2) ? 31 : 34)m\r\u{001B}[2Kx"
        }.joined()
        let prepared = try XCTUnwrap(SessionFreshSpawnScrollbackSeed.preparedText(for: source))
        XCTAssertEqual(prepared.filter { $0 == "x" }.count, 1)
        XCTAssertTrue(prepared.contains("\u{001B}[34mx"))
        XCTAssertEqual(prepared, SessionFreshSpawnScrollbackSeed.preparedText(for: "\u{001B}[34mx"))
    }

    func testFreshSpawnScrollbackSeedPreservesBrightAndExtendedColorResets() {
        let source = "\u{001B}[94;48;2;10;20;30;58;5;18mA\u{001B}[39;49;59mB"
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[94;48;2;10;20;30;58;5;18mA\u{001B}[0mB"))
    }

    func testFreshSpawnScrollbackSeedTracksColonUnderlineAndColor() {
        let source = "\u{001B}[4:3;38:2::1:2:3mA\u{001B}[24;39mB"
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: source) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[4:3;38;2;1;2;3mA\u{001B}[0mB"))
    }

    func testFreshSpawnScrollbackSeedParsesSGRAfterUnsupportedExtendedColor() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}[38;3;31mA"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[3;31mA"))
    }

    func testFreshSpawnScrollbackSeedSplitsStylesWithinTerminalParameterLimit() throws {
        let source = "\u{001B}[1;2;3;4:3;5;7;8;9;53m"
            + "\u{001B}[38;2;1;2;3m\u{001B}[48;2;4;5;6m\u{001B}[58;2;7;8;9mA"
        let prepared = try XCTUnwrap(SessionFreshSpawnScrollbackSeed.preparedText(for: source))
        let regex = try NSRegularExpression(pattern: "\u{001B}\\[([0-9;:]*)m")
        let text = prepared as NSString
        for match in regex.matches(in: prepared, range: NSRange(location: 0, length: text.length)) {
            let parameters = text.substring(with: match.range(at: 1))
            XCTAssertLessThanOrEqual(1 + parameters.filter { $0 == ";" || $0 == ":" }.count, 24)
        }
        XCTAssertTrue(prepared.contains("4:3"))
        XCTAssertTrue(prepared.contains("38;2;1;2;3"))
        XCTAssertTrue(prepared.contains("48;2;4;5;6"))
        XCTAssertTrue(prepared.contains("\u{001B}[58;2;7;8;9mA"))
    }

    /// An SGR sequence set immediately before a `\r` overwrite must be
    /// carried onto the kept segment, or color state set just before a
    /// spinner update would be silently dropped.
    func testFreshSpawnScrollbackSeedCarriesSGRAcrossCarriageReturnOverwrite() {
        guard let prepared = SessionFreshSpawnScrollbackSeed.preparedText(
            for: "\u{001B}[32mspin\rdone"
        ) else {
            XCTFail("Expected prepared seed text")
            return
        }

        XCTAssertTrue(prepared.contains("\u{001B}[32m"))
        XCTAssertTrue(prepared.contains("done"))
    }

    /// Already-rendered plain text (the clean-quit snapshot path) has no
    /// escapes or carriage returns, so the positioning sanitizer must be a
    /// no-op beyond the existing trailing-newline guarantee.
    func testFreshSpawnScrollbackSeedPassesThroughPlainTextUnchanged() {
        let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: "already rendered\nplain text\n")
        XCTAssertEqual(prepared, "already rendered\nplain text\n")
    }

    func testTruncatedScrollbackAvoidsLeadingPartialANSICSISequence() {
        let maxChars = SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        let source = "\u{001B}[31m"
            + String(repeating: "X", count: maxChars - 7)
            + "\u{001B}[0m"

        guard let truncated = SessionPersistencePolicy.truncatedScrollback(source) else {
            XCTFail("Expected truncated scrollback")
            return
        }

        XCTAssertFalse(truncated.hasPrefix("31m"))
        XCTAssertFalse(truncated.hasPrefix("[31m"))
        XCTAssertFalse(truncated.hasPrefix("m"))
    }

    func testNormalizedExportedScreenPathAcceptsAbsoluteAndFileURL() {
        XCTAssertEqual(
            TerminalController.normalizedExportedScreenPath("/tmp/programa-screen.txt"),
            "/tmp/programa-screen.txt"
        )
        XCTAssertEqual(
            TerminalController.normalizedExportedScreenPath(" file:///tmp/programa-screen.txt "),
            "/tmp/programa-screen.txt"
        )
    }

    func testNormalizedExportedScreenPathRejectsRelativeAndWhitespace() {
        XCTAssertNil(TerminalController.normalizedExportedScreenPath("relative/path.txt"))
        XCTAssertNil(TerminalController.normalizedExportedScreenPath("   "))
        XCTAssertNil(TerminalController.normalizedExportedScreenPath(nil))
    }

    func testShouldRemoveExportedScreenDirectoryOnlyWithinTemporaryRoot() {
        let tempRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("cmux-export-tests-\(UUID().uuidString)", isDirectory: true)
        let tempFile = tempRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("screen.txt", isDirectory: false)
        let outsideFile = URL(fileURLWithPath: "/Users/example/screen.txt")

        XCTAssertTrue(
            TerminalController.shouldRemoveExportedScreenDirectory(
                fileURL: tempFile,
                temporaryDirectory: tempRoot
            )
        )
        XCTAssertFalse(
            TerminalController.shouldRemoveExportedScreenDirectory(
                fileURL: outsideFile,
                temporaryDirectory: tempRoot
            )
        )
    }

    func testShouldRemoveExportedScreenFileOnlyWithinTemporaryRoot() {
        let tempRoot = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("cmux-export-tests-\(UUID().uuidString)", isDirectory: true)
        let tempFile = tempRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("screen.txt", isDirectory: false)
        let outsideFile = URL(fileURLWithPath: "/Users/example/screen.txt")

        XCTAssertTrue(
            TerminalController.shouldRemoveExportedScreenFile(
                fileURL: tempFile,
                temporaryDirectory: tempRoot
            )
        )
        XCTAssertFalse(
            TerminalController.shouldRemoveExportedScreenFile(
                fileURL: outsideFile,
                temporaryDirectory: tempRoot
            )
        )
    }

    func testWindowUnregisterSnapshotPersistencePolicy() {
        XCTAssertTrue(
            AppDelegate.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: false)
        )
        XCTAssertFalse(
            AppDelegate.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: true)
        )
        XCTAssertTrue(
            AppDelegate.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(isTerminatingApp: false)
        )
        XCTAssertFalse(
            AppDelegate.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(isTerminatingApp: true)
        )
    }

    func testShouldSkipSessionSaveDuringStartupRestorePolicy() {
        XCTAssertTrue(
            AppDelegate.shouldSkipSessionSaveDuringStartupRestore(
                isApplyingStartupSessionRestore: true,
                includeScrollback: false
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionSaveDuringStartupRestore(
                isApplyingStartupSessionRestore: true,
                includeScrollback: true
            )
        )
        XCTAssertFalse(
            AppDelegate.shouldSkipSessionSaveDuringStartupRestore(
                isApplyingStartupSessionRestore: false,
                includeScrollback: false
            )
        )
    }

    func testSessionAutosaveTickPolicySkipsWhenTerminating() {
        XCTAssertTrue(
            SessionAutosaveCoordinator.shouldRunSessionAutosaveTick(isTerminatingApp: false)
        )
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldRunSessionAutosaveTick(isTerminatingApp: true)
        )
    }

    func testSessionSnapshotSynchronousWritePolicy() {
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: false,
                includeScrollback: false
            )
        )
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: false,
                includeScrollback: true
            )
        )
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: true,
                includeScrollback: false
            )
        )
        XCTAssertTrue(
            SessionAutosaveCoordinator.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: true,
                includeScrollback: true
            )
        )
    }

    func testUnchangedAutosaveFingerprintSkipsWithinStalenessWindow() {
        let now = Date()
        XCTAssertTrue(
            SessionAutosaveCoordinator.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-5),
                now: now,
                maximumAutosaveSkippableInterval: 60
            )
        )
    }

    func testUnchangedAutosaveFingerprintDoesNotSkipAfterStalenessWindow() {
        let now = Date()
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-120),
                now: now,
                maximumAutosaveSkippableInterval: 60
            )
        )
    }

    func testUnchangedAutosaveFingerprintNeverSkipsTerminatingOrScrollbackWrites() {
        let now = Date()
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: true,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        XCTAssertFalse(
            SessionAutosaveCoordinator.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: true,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    func testResolvedWindowFramePrefersSavedDisplayIdentity() {
        let savedFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: nil,
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        // Display 1 and 2 swapped horizontal positions between snapshot and restore.
        let display1 = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: nil,
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )
        let display2 = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [display1, display2],
            fallbackDisplay: display1
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(display2.visibleFrame.intersects(restored))
        XCTAssertFalse(display1.visibleFrame.intersects(restored))
        XCTAssertEqual(restored.width, 600, accuracy: 0.001)
        XCTAssertEqual(restored.height, 400, accuracy: 0.001)
        XCTAssertEqual(restored.minX, 200, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 100, accuracy: 0.001)
    }

    func testStableDisplayIdentityWinsWhenDisplayIDIsReassigned() {
        let savedFrame = SessionRectSnapshot(x: 1_200, y: 100, width: 600, height: 400)
        // Simulates a monitor unplug/replug: the OS reassigned displayID 999 to
        // what used to be displayA's screen, so the snapshot's displayID now
        // spuriously matches displayA. The snapshot's stableID still correctly
        // identifies the original monitor (displayB).
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 999,
            stableID: "stable-B",
            frame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: SessionRectSnapshot(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        let displayA = AppDelegate.SessionDisplayGeometry(
            displayID: 999,
            stableID: "stable-A",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let displayB = AppDelegate.SessionDisplayGeometry(
            displayID: 555,
            stableID: "stable-B",
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [displayA, displayB],
            fallbackDisplay: displayA
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(displayB.visibleFrame.intersects(restored))
        XCTAssertFalse(displayA.visibleFrame.intersects(restored))
        XCTAssertEqual(restored.width, 600, accuracy: 0.001)
        XCTAssertEqual(restored.height, 400, accuracy: 0.001)
        XCTAssertEqual(restored.minX, 1_200, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 100, accuracy: 0.001)
    }

    func testDisplayIDFallbackWhenNoStableID() {
        let savedFrame = SessionRectSnapshot(x: 1_303, y: -90, width: 1_280, height: 1_410)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: nil,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            stableID: "stable-2",
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_410)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 1_303, accuracy: 0.001)
        XCTAssertEqual(restored.minY, -90, accuracy: 0.001)
        XCTAssertEqual(restored.width, 1_280, accuracy: 0.001)
        XCTAssertEqual(restored.height, 1_410, accuracy: 0.001)
    }

    func testResolvedWindowFrameKeepsIntersectingFrameWithoutDisplayMetadata() {
        let savedFrame = SessionRectSnapshot(x: 120, y: 80, width: 500, height: 350)
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 120, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 80, accuracy: 0.001)
        XCTAssertEqual(restored.width, 500, accuracy: 0.001)
        XCTAssertEqual(restored.height, 350, accuracy: 0.001)
    }

    func testResolvedStartupPrimaryWindowFrameFallsBackToPersistedGeometryWhenPrimaryMissing() {
        let fallbackFrame = SessionRectSnapshot(x: 180, y: 140, width: 900, height: 640)
        let fallbackDisplay = SessionDisplaySnapshot(
            displayID: 1,
            stableID: nil,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )

        let restored = AppDelegate.resolvedStartupPrimaryWindowFrame(
            primarySnapshot: nil,
            fallbackFrame: fallbackFrame,
            fallbackDisplaySnapshot: fallbackDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 180, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 140, accuracy: 0.001)
        XCTAssertEqual(restored.width, 900, accuracy: 0.001)
        XCTAssertEqual(restored.height, 640, accuracy: 0.001)
    }

    func testResolvedStartupPrimaryWindowFramePrefersPrimarySnapshotOverFallback() {
        let primarySnapshot = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 1,
                stableID: nil,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
            ),
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: nil, workspaces: []),
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 220)
        )
        let fallbackFrame = SessionRectSnapshot(x: 40, y: 30, width: 700, height: 500)
        let fallbackDisplay = SessionDisplaySnapshot(
            displayID: 1,
            stableID: nil,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_600, height: 1_000)
        )

        let restored = AppDelegate.resolvedStartupPrimaryWindowFrame(
            primarySnapshot: primarySnapshot,
            fallbackFrame: fallbackFrame,
            fallbackDisplaySnapshot: fallbackDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 220, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 160, accuracy: 0.001)
        XCTAssertEqual(restored.width, 980, accuracy: 0.001)
        XCTAssertEqual(restored.height, 700, accuracy: 0.001)
    }

    func testDecodedPersistedWindowGeometryDataAcceptsCurrentSchema() throws {
        let data = try JSONEncoder().encode(
            AppDelegate.PersistedWindowGeometry(
                version: AppDelegate.persistedWindowGeometrySchemaVersion,
                frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
                display: SessionDisplaySnapshot(
                    displayID: 1,
                    stableID: nil,
                    frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
                )
            )
        )

        let decoded = try XCTUnwrap(AppDelegate.decodedPersistedWindowGeometryData(data))
        XCTAssertEqual(decoded.version, AppDelegate.persistedWindowGeometrySchemaVersion)
        XCTAssertEqual(decoded.frame.x, 220, accuracy: 0.001)
        XCTAssertEqual(decoded.frame.y, 160, accuracy: 0.001)
        XCTAssertEqual(decoded.frame.width, 980, accuracy: 0.001)
        XCTAssertEqual(decoded.frame.height, 700, accuracy: 0.001)
        XCTAssertEqual(decoded.display?.displayID, 1)
    }

    func testDecodedPersistedWindowGeometryDataRejectsLegacyUnversionedPayload() throws {
        let data = try JSONEncoder().encode(
            LegacyPersistedWindowGeometry(
                frame: SessionRectSnapshot(x: 180, y: 140, width: 900, height: 640),
                display: SessionDisplaySnapshot(
                    displayID: 1,
                    stableID: nil,
                    frame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000),
                    visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 1_600, height: 1_000)
                )
            )
        )

        XCTAssertNil(AppDelegate.decodedPersistedWindowGeometryData(data))
    }

    func testDecodedPersistedWindowGeometryDataRejectsDifferentSchemaVersion() throws {
        let data = try JSONEncoder().encode(
            AppDelegate.PersistedWindowGeometry(
                version: AppDelegate.persistedWindowGeometrySchemaVersion + 1,
                frame: SessionRectSnapshot(x: 220, y: 160, width: 980, height: 700),
                display: nil
            )
        )

        XCTAssertNil(AppDelegate.decodedPersistedWindowGeometryData(data))
    }

    func testResolvedWindowFrameCentersInFallbackDisplayWhenOffscreen() {
        let savedFrame = SessionRectSnapshot(x: 4_000, y: 4_000, width: 900, height: 700)
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 1,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: nil,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(display.visibleFrame.contains(restored))
        XCTAssertEqual(restored.minX, 50, accuracy: 0.001)
        XCTAssertEqual(restored.minY, 50, accuracy: 0.001)
        XCTAssertEqual(restored.width, 900, accuracy: 0.001)
        XCTAssertEqual(restored.height, 700, accuracy: 0.001)
    }

    func testResolvedWindowFramePreservesExactGeometryWhenDisplayIsUnchanged() {
        let savedFrame = SessionRectSnapshot(x: 1_303, y: -90, width: 1_280, height: 1_410)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: nil,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let display = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2_560, height: 1_410)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [display],
            fallbackDisplay: display
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 1_303, accuracy: 0.001)
        XCTAssertEqual(restored.minY, -90, accuracy: 0.001)
        XCTAssertEqual(restored.width, 1_280, accuracy: 0.001)
        XCTAssertEqual(restored.height, 1_410, accuracy: 0.001)
    }

    func testResolvedWindowFramePreservesExactGeometryWhenDisplayChangesButWindowRemainsAccessible() {
        let savedFrame = SessionRectSnapshot(x: 1_100, y: -20, width: 1_280, height: 1_000)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: nil,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let adjustedDisplay = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: CGRect(x: 0, y: 40, width: 2_560, height: 1_360)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [adjustedDisplay],
            fallbackDisplay: adjustedDisplay
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertEqual(restored.minX, 1_100, accuracy: 0.001)
        XCTAssertEqual(restored.minY, -20, accuracy: 0.001)
        XCTAssertEqual(restored.width, 1_280, accuracy: 0.001)
        XCTAssertEqual(restored.height, 1_000, accuracy: 0.001)
    }

    func testResolvedWindowFrameClampsWhenDisplayGeometryChangesEvenWithSameDisplayID() {
        let savedFrame = SessionRectSnapshot(x: 1_303, y: -90, width: 1_280, height: 1_410)
        let savedDisplay = SessionDisplaySnapshot(
            displayID: 2,
            stableID: nil,
            frame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_440),
            visibleFrame: SessionRectSnapshot(x: 0, y: 0, width: 2_560, height: 1_410)
        )
        let resizedDisplay = AppDelegate.SessionDisplayGeometry(
            displayID: 2,
            stableID: nil,
            frame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_050)
        )

        let restored = AppDelegate.resolvedWindowFrame(
            from: savedFrame,
            display: savedDisplay,
            availableDisplays: [resizedDisplay],
            fallbackDisplay: resizedDisplay
        )

        XCTAssertNotNil(restored)
        guard let restored else { return }
        XCTAssertTrue(resizedDisplay.visibleFrame.contains(restored))
        XCTAssertNotEqual(restored.minX, 1_303, "Changed display geometry should clamp/remap frame")
        XCTAssertNotEqual(restored.minY, -90, "Changed display geometry should clamp/remap frame")
    }

    func testResolvedSnapshotTerminalScrollbackPrefersCaptured() {
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: "captured-value",
            fallbackScrollback: "fallback-value"
        )

        XCTAssertEqual(resolved, "captured-value")
    }

    func testResolvedSnapshotTerminalScrollbackFallsBackWhenCaptureMissing() {
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback-value"
        )

        XCTAssertEqual(resolved, "fallback-value")
    }

    func testResolvedSnapshotTerminalScrollbackTruncatesFallback() {
        let oversizedFallback = String(
            repeating: "x",
            count: SessionPersistencePolicy.maxScrollbackCharactersPerTerminal + 37
        )
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: oversizedFallback
        )

        XCTAssertEqual(
            resolved?.count,
            SessionPersistencePolicy.maxScrollbackCharactersPerTerminal
        )
    }

    func testResolvedSnapshotTerminalScrollbackSkipsFallbackWhenRestoreIsUnsafe() {
        let resolved = Workspace.resolvedSnapshotTerminalScrollback(
            capturedScrollback: nil,
            fallbackScrollback: "fallback-value",
            allowFallbackScrollback: false
        )

        XCTAssertNil(resolved)
    }

    func testWorktreeFolderMetadataRoundTrips() throws {
        let folderId = UUID()
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].worktreeFolderId = folderId
        snapshot.windows[0].tabManager.workspaces[0].worktreeFolderRepoRoot = "/repo"
        snapshot.windows[0].tabManager.workspaces[0].isWorktreeFolder = true
        snapshot.windows[0].tabManager.workspaces[0].isWorktreeFolderCollapsed = true
        snapshot.windows[0].tabManager.workspaces[0].worktreeBranch = "feature/sidebar"

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(AppSessionSnapshot.self, from: data)
        let workspace = try XCTUnwrap(decoded.windows.first?.tabManager.workspaces.first)

        XCTAssertEqual(workspace.worktreeFolderId, folderId)
        XCTAssertEqual(workspace.worktreeFolderRepoRoot, "/repo")
        XCTAssertEqual(workspace.isWorktreeFolder, true)
        XCTAssertEqual(workspace.isWorktreeFolderCollapsed, true)
        XCTAssertEqual(workspace.worktreeBranch, "feature/sidebar")
    }

    func testSnapshotOwnershipProtectsExpiredSessionsAndDefersOnCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session-own.json")
        let ownedID = UUID()
        let abandonedID = UUID()
        let now = Date()
        let expiredAt = now.addingTimeInterval(-SessionEscrowPolicy.unclaimedSessionTTL - 1)
        func expires(_ id: UUID, draining: Bool = true, since: Date? = nil) -> Bool {
            SessionEscrowPolicy.shouldExpireSession(
                sessionID: id.uuidString, isDraining: draining,
                drainingStartedAt: since ?? expiredAt, now: now,
                ownedSessionIDs: SessionPersistenceStore.ownedTerminalSessionIDs(fileURL: file)
            )
        }
        XCTAssertEqual(SessionPersistenceStore.ownedTerminalSessionIDs(fileURL: file), [])
        XCTAssertTrue(expires(abandonedID))
        XCTAssertTrue(SessionPersistenceStore.save(makeOwnershipSnapshot(ownedID), fileURL: file))
        XCTAssertEqual(SessionPersistenceStore.ownedTerminalSessionIDs(fileURL: file), [ownedID.uuidString])
        XCTAssertFalse(expires(ownedID))
        XCTAssertTrue(expires(abandonedID))
        XCTAssertFalse(expires(abandonedID, draining: false))
        XCTAssertFalse(expires(abandonedID, since: now))
        try Data("invalid snapshot".utf8).write(to: file)
        XCTAssertNil(SessionPersistenceStore.ownedTerminalSessionIDs(fileURL: file))
        XCTAssertFalse(expires(abandonedID))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertNil(SessionPersistenceStore.ownedTerminalSessionIDs(fileURL: file))
        XCTAssertFalse(expires(abandonedID))
    }

    func testNewEscrowRegistrationsUseVersionedBundleScopedHolderPaths() {
        XCTAssertEqual(
            SessionEscrowClient.escrowSocketPath(controlSocketPath: "/tmp/programa.sock"),
            "/tmp/programa-escrow-v2.sock"
        )
        XCTAssertEqual(
            SessionEscrowClient.escrowSocketPath(controlSocketPath: "/tmp/programa-debug-review.sock"),
            "/tmp/programa-debug-review-escrow-v2.sock"
        )
    }

    func testOrphanSweepPreservesAllBundlesAndDefersWhenOwnershipIsUnknown() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownID = UUID(), otherID = UUID(), abandonedID = UUID(), registeredID = UUID()
        let now = Date()
        for id in [ownID, otherID, abandonedID, registeredID] {
            let directory = sessions.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-SessionWALPolicy.orphanDirectoryMaxAge - 1)],
                ofItemAtPath: directory.path
            )
        }
        let ownFile = try XCTUnwrap(SessionPersistenceStore.defaultSnapshotFileURL(
            bundleIdentifier: "dev.own", appSupportDirectory: root
        )).lastPathComponent
        let otherFile = root.appendingPathComponent("session-production.json")
        XCTAssertTrue(SessionPersistenceStore.save(makeOwnershipSnapshot(ownID), fileURL: root.appendingPathComponent(ownFile)))
        XCTAssertTrue(SessionPersistenceStore.save(makeOwnershipSnapshot(otherID), fileURL: otherFile))
        XCTAssertEqual(SessionPersistenceStore.allOwnedTerminalSessionIDs(in: root), [ownID.uuidString, otherID.uuidString])
        try Data("corrupt".utf8).write(to: otherFile)
        SessionWALStore.sweepOrphanedSessionDirectories(at: sessions, registeredSessionIDs: [], now: now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent(abandonedID.uuidString).path))
        XCTAssertTrue(SessionPersistenceStore.save(makeOwnershipSnapshot(otherID), fileURL: otherFile))
        SessionWALStore.sweepOrphanedSessionDirectories(at: sessions, registeredSessionIDs: [registeredID.uuidString], now: now)
        for id in [ownID, otherID, registeredID] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: sessions.appendingPathComponent(id.uuidString).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.appendingPathComponent(abandonedID.uuidString).path))
    }

    private func makeOwnershipSnapshot(_ id: UUID) -> AppSessionSnapshot {
        var snapshot = makeSnapshot(version: SessionSnapshotSchema.currentVersion)
        snapshot.windows[0].tabManager.workspaces[0].panels = [SessionPanelSnapshot(
            id: id, type: .terminal, title: nil, customTitle: nil, directory: nil,
            isPinned: false, isManuallyUnread: false, gitBranch: nil, listeningPorts: [], ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(workingDirectory: nil, scrollback: nil),
            browser: nil, markdown: nil, review: nil
        )]
        return snapshot
    }

    private func makeSnapshot(version: Int) -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )

        let tabManager = SessionTabManagerSnapshot(
            selectedWorkspaceIndex: 0,
            workspaces: [workspace]
        )

        let window = SessionWindowSnapshot(
            frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
            display: SessionDisplaySnapshot(
                displayID: 42,
                stableID: nil,
                frame: SessionRectSnapshot(x: 0, y: 0, width: 1920, height: 1200),
                visibleFrame: SessionRectSnapshot(x: 0, y: 25, width: 1920, height: 1175)
            ),
            tabManager: tabManager,
            sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
        )

        return AppSessionSnapshot(
            version: version,
            createdAt: Date().timeIntervalSince1970,
            windows: [window],
            cleanShutdown: false
        )
    }

    private func fileNumber(for fileURL: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? Int)
    }
}

final class SocketListenerAcceptPolicyTests: XCTestCase {
    func testAcceptErrorClassificationBucketsExpectedErrnos() {
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EINTR),
            "immediate_retry"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: ECONNABORTED),
            "immediate_retry"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EMFILE),
            "resource_pressure"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: ENOMEM),
            "resource_pressure"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EBADF),
            "fatal"
        )
        XCTAssertEqual(
            TerminalController.acceptErrorClassification(errnoCode: EINVAL),
            "fatal"
        )
    }

    func testAcceptErrorPolicySignalsRearmOnlyForFatalErrors() {
        XCTAssertTrue(TerminalController.shouldRearmListenerForAcceptError(errnoCode: EBADF))
        XCTAssertTrue(TerminalController.shouldRearmListenerForAcceptError(errnoCode: ENOTSOCK))
        XCTAssertFalse(TerminalController.shouldRearmListenerForAcceptError(errnoCode: EMFILE))
        XCTAssertFalse(TerminalController.shouldRearmListenerForAcceptError(errnoCode: EINTR))
    }

    func testAcceptErrorPolicyRearmsAfterPersistentFailures() {
        XCTAssertFalse(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 0))
        XCTAssertFalse(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 49))
        XCTAssertTrue(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 50))
        XCTAssertTrue(TerminalController.shouldRearmForConsecutiveAcceptFailures(consecutiveFailures: 120))
    }

    func testAcceptFailureBackoffIsExponentialAndCapped() {
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 0),
            0
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 1),
            10
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 2),
            20
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 6),
            320
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 12),
            5_000
        )
        XCTAssertEqual(
            TerminalController.acceptFailureBackoffMilliseconds(consecutiveFailures: 50),
            5_000
        )
    }

    func testAcceptFailureRearmDelayAppliesMinimumThrottle() {
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 0),
            100
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 1),
            100
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 2),
            100
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 6),
            320
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRearmDelayMilliseconds(consecutiveFailures: 12),
            5_000
        )
    }

    func testAcceptFailureRecoveryActionResumesAfterDelayForTransientErrors() {
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EPROTO,
                consecutiveFailures: 1
            ),
            .resumeAfterDelay(delayMs: 10)
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EMFILE,
                consecutiveFailures: 3
            ),
            .resumeAfterDelay(delayMs: 40)
        )
    }

    func testAcceptFailureRecoveryActionRearmsForFatalAndPersistentFailures() {
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EBADF,
                consecutiveFailures: 1
            ),
            .rearmAfterDelay(delayMs: 100)
        )
        XCTAssertEqual(
            TerminalController.acceptFailureRecoveryAction(
                errnoCode: EPROTO,
                consecutiveFailures: 50
            ),
            .rearmAfterDelay(delayMs: 5_000)
        )
    }

    func testAcceptLoopCleanupUnlinkPolicySkipsDuringListenerStartup() {
        XCTAssertFalse(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: true
            )
        )
        XCTAssertFalse(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: false,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: false
            )
        )
        XCTAssertFalse(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: true,
                activeGeneration: 7,
                listenerStartInProgress: false
            )
        )
        XCTAssertTrue(
            TerminalController.shouldUnlinkSocketPathAfterAcceptLoopCleanup(
                pathMatches: true,
                isRunning: false,
                activeGeneration: 0,
                listenerStartInProgress: false
            )
        )
    }
}

// SidebarDragFailsafePolicy tests moved to SidebarOrderingTests.swift
// (SidebarDragFailsafePolicyTests), where the rest of the sidebar drag
// coverage lives.

// MARK: - Escrow reattach race regressions (2026-08-10 mass-drain incident)
//
// A Sparkle-update relaunch raced the holder's death detection and lost
// every terminal: the old app's escrow connection fd had leaked into its
// shell children (no FD_CLOEXEC), so the holder saw no EOF when the app
// exited and had to wait out `heartbeatStaleAfter`; the new instance's
// one-shot retrieve landed inside that blind window, was denied
// `not_draining`, and fell back to fresh shells; four seconds later the
// holder declared the connection stale and drained all six sessions. The
// fallback restore then deleted each session's `meta.json` — the only copy
// of the retrieval token — foreclosing recovery of children that were
// still alive in the holder. One test per fix below.
final class SessionEscrowReattachRegressionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SessionEscrowClient.resetCircuitBreakerForTesting()
    }

    /// AF_UNIX socket paths are capped at 104 bytes on Darwin;
    /// `FileManager.temporaryDirectory` paths are too long, so these live
    /// directly under /tmp.
    private func makeShortSocketPath() -> String {
        "/tmp/programa-escrow-test-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
    }

    // Fix 1: an escrow control socket inherited by a spawned shell child
    // keeps the holder's connection open after the app dies, suppressing
    // EOF death detection and opening the stale-heartbeat blind window the
    // incident's retrieve raced into.
    func testEscrowSocketFDsAreCloseOnExec() throws {
        let socketPath = makeShortSocketPath()
        let listenFD = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
        defer {
            close(listenFD)
            unlink(socketPath)
        }
        let connectionFD = try XCTUnwrap(UnixDomainFDPassing.connect(to: socketPath))
        defer { close(connectionFD) }

        XCTAssertNotEqual(
            fcntl(connectionFD, F_GETFD) & FD_CLOEXEC, 0,
            "escrow client connection fd must be close-on-exec: an inherited fd suppresses the holder's EOF death detection"
        )
        XCTAssertNotEqual(
            fcntl(listenFD, F_GETFD) & FD_CLOEXEC, 0,
            "escrow listening fd must be close-on-exec"
        )
    }

    func testSecondEscrowListenerCannotReplaceLiveSocket() throws {
        let socketPath = makeShortSocketPath()
        let firstFD = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
        defer {
            close(firstFD)
            unlink(socketPath)
            unlink(socketPath + ".election")
        }

        XCTAssertNil(
            UnixDomainFDPassing.bindListening(socketPath: socketPath),
            "A losing holder must not unlink and replace the live winner's socket"
        )
        let clientFD = try XCTUnwrap(UnixDomainFDPassing.connect(to: socketPath))
        close(clientFD)
    }

    func testEscrowListenerProbeOnlyUnlinksDefinitelyStaleSocket() throws {
        func makeStaleSocket() throws -> String {
            let socketPath = makeShortSocketPath()
            let listener = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
            close(listener)
            return socketPath
        }

        let livePath = try makeStaleSocket()
        defer {
            unlink(livePath)
            unlink(livePath + ".election")
        }
        let probeFD = dup(STDIN_FILENO)
        XCTAssertGreaterThanOrEqual(probeFD, 0)
        XCTAssertNil(
            UnixDomainFDPassing.bindListening(
                socketPath: livePath,
                connectionProbe: { _ in .live(probeFD) }
            )
        )
        XCTAssertEqual(access(livePath, F_OK), 0, "a live probe must preserve the incumbent socket")

        let indeterminatePath = try makeStaleSocket()
        defer {
            unlink(indeterminatePath)
            unlink(indeterminatePath + ".election")
        }
        XCTAssertNil(
            UnixDomainFDPassing.bindListening(
                socketPath: indeterminatePath,
                connectionProbe: { _ in .indeterminate(EMFILE) }
            )
        )
        XCTAssertEqual(
            access(indeterminatePath, F_OK),
            0,
            "an indeterminate connect or setup failure must preserve the incumbent socket"
        )
        XCTAssertNil(
            UnixDomainFDPassing.bindListening(
                socketPath: indeterminatePath,
                connectionProbe: { _ in .indeterminate(EBADF) }
            )
        )
        XCTAssertEqual(access(indeterminatePath, F_OK), 0, "an indeterminate fcntl failure must preserve the socket")

        let stalePath = try makeStaleSocket()
        let replacementFD = try XCTUnwrap(
            UnixDomainFDPassing.bindListening(
                socketPath: stalePath,
                connectionProbe: { _ in .stale }
            )
        )
        defer {
            close(replacementFD)
            unlink(stalePath)
            unlink(stalePath + ".election")
        }
        XCTAssertEqual(access(stalePath, F_OK), 0, "a definitely stale socket should be replaced")
    }

    func testEscrowListenerReclaimsVerifiedStaleOwnedSocket() throws {
        let socketPath = makeShortSocketPath()
        let staleFD = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
        close(staleFD)

        let replacementFD = try XCTUnwrap(
            UnixDomainFDPassing.bindListening(socketPath: socketPath),
            "A closed, user-owned socket inode should be reclaimed under the election lock"
        )
        defer {
            close(replacementFD)
            unlink(socketPath)
            unlink(socketPath + ".election")
        }
    }

    // Fix 2: a valid-token retrieve that arrives before the holder has
    // detected the previous app's death is denied `not_draining`. That
    // denial must be retried within a bounded window, not treated as a
    // permanent fallback — the holder resolves the race on its own within
    // `heartbeatStaleAfter`. The fake holder below replays the incident:
    // deny `not_draining` once, then (drain now underway) grant.
    func testRetrieveSurvivesDenyWhileHolderHasNotYetNoticedAppDeath() throws {
        let socketPath = makeShortSocketPath()
        let listenFD = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
        defer {
            close(listenFD)
            unlink(socketPath)
        }
        // Join the server thread BEFORE the defer above closes listenFD
        // (defers run LIFO): a server thread that outlives its test can
        // block in accept on a closed-and-REUSED fd number and steal or
        // close a later test's sockets. The wake connect unblocks a server
        // still sitting in accept on the failure path.
        let serverExited = DispatchSemaphore(value: 0)
        let stopServing = ManagedAtomic()
        defer {
            stopServing.increment()
            if let wake = UnixDomainFDPassing.connect(to: socketPath) { close(wake) }
            _ = serverExited.wait(timeout: .now() + 2.0)
        }

        let sessionId = UUID().uuidString
        let tokenBytes = [UInt8](repeating: 0xAB, count: EscrowWireFormat.tokenSize)
        let tokenHex = tokenBytes.map { String(format: "%02x", $0) }.joined()

        // Hand-rolled response frames pin the wire layout: 1-byte type,
        // 36-byte session id, 32 bytes of padding whose FIRST byte is the
        // deny reason (0x03 = not_draining; zero-padded by pre-reason
        // holders), then the granted flag.
        func responseFrame(granted: Bool, denyReasonByte: UInt8) -> Data {
            var frame = Data(count: EscrowWireFormat.frameSize)
            frame[0] = 0x04 // retrieveResponseType
            frame.replaceSubrange(1..<(1 + EscrowWireFormat.sessionIdSize), with: Array(sessionId.utf8))
            frame[1 + EscrowWireFormat.sessionIdSize] = denyReasonByte
            frame[1 + EscrowWireFormat.sessionIdSize + EscrowWireFormat.tokenSize] = granted ? 1 : 0
            return frame
        }

        let serverReady = DispatchSemaphore(value: 0)
        let expectedSessionIdBytes = Array(sessionId.utf8)
        let matchedRequests = ManagedAtomic()
        Thread.detachNewThread {
            defer { serverExited.signal() }
            serverReady.signal()
            var round = 0
            while round < 2 {
                let conn = accept(listenFD, nil, nil)
                guard conn >= 0 else { return }
                guard stopServing.value == 0 else {
                    close(conn)
                    return
                }
                var request = Data()
                while request.count < EscrowWireFormat.frameSize {
                    var buffer = [UInt8](repeating: 0, count: EscrowWireFormat.frameSize - request.count)
                    let n = read(conn, &buffer, buffer.count)
                    guard n > 0 else { break }
                    request.append(contentsOf: buffer.prefix(n))
                }
                // Only frames carrying THIS test's session id consume a
                // round -- anything else (a stray wake poke, a connection
                // from an unrelated fd mixup) is dropped without advancing
                // the deny/grant sequence.
                guard request.count == EscrowWireFormat.frameSize,
                      Array(request[1..<(1 + EscrowWireFormat.sessionIdSize)]) == expectedSessionIdBytes else {
                    close(conn)
                    continue
                }
                matchedRequests.increment()
                if round == 0 {
                    let deny = responseFrame(granted: false, denyReasonByte: 0x03)
                    _ = deny.withUnsafeBytes { raw -> Int in
                        write(conn, raw.baseAddress, raw.count)
                    }
                } else {
                    var grantPair: [Int32] = [-1, -1]
                    if socketpair(AF_UNIX, SOCK_STREAM, 0, &grantPair) == 0 {
                        _ = UnixDomainFDPassing.send(
                            fd: grantPair[0],
                            payload: responseFrame(granted: true, denyReasonByte: 0),
                            over: conn
                        )
                        // Mirror the production holder's "never close the
                        // escrowed fd" grant path: closing the sender's
                        // copy right after sendmsg races the receiver's
                        // recvmsg externalization of the in-flight
                        // SCM_RIGHTS fd on loaded hosts (observed as a
                        // defunct/EOF-empty fd at the client in CI).
                        // Waiting for the client to close the control
                        // connection guarantees its recvmsg completed.
                        var drainBuffer = [UInt8](repeating: 0, count: 16)
                        while read(conn, &drainBuffer, drainBuffer.count) > 0 {}
                        close(grantPair[0])
                        close(grantPair[1])
                    }
                }
                close(conn)
                round += 1
            }
        }
        serverReady.wait()

        let retrievedFD = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: 2.0
        )
        let unwrappedFD = try XCTUnwrap(
            retrievedFD,
            "a rightful-successor retrieve denied only because the holder has not yet detected app death must be retried, not permanently abandoned"
        )
        defer { close(unwrappedFD) }

        // The retry semantics are the regression under test: the client
        // must have presented its request twice (once denied not_draining,
        // once granted) and ended up holding a real, open fd. Content-level
        // proof that a granted fd carries the escrowed bytes lives in
        // testRetrieveGrantDeliversTheEscrowedFDBytes -- deliberately a
        // separate, retry-free test, so a same-process fd-delivery hiccup
        // there can never masquerade as a retry-logic regression here.
        XCTAssertEqual(matchedRequests.value, 2, "the holder must have seen the request twice: the not_draining denial and the post-drain grant")
        XCTAssertGreaterThanOrEqual(fcntl(unwrappedFD, F_GETFD), 0, "the granted fd must be a live, open descriptor")
    }

    // Deterministic single-shot companion to the retry test above: the
    // holder grants immediately, and the granted fd must deliver exactly
    // the bytes that were buffered into it before it was sent (both
    // original socketpair ends are closed pre-send, so the kernel buffer
    // is the only possible source -- no liveness dependency on any other
    // fd in this process).
    func testRetrieveGrantDeliversTheEscrowedFDBytes() throws {
        let socketPath = makeShortSocketPath()
        let listenFD = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
        defer {
            close(listenFD)
            unlink(socketPath)
        }
        let serverExited = DispatchSemaphore(value: 0)
        defer {
            if let wake = UnixDomainFDPassing.connect(to: socketPath) { close(wake) }
            _ = serverExited.wait(timeout: .now() + 2.0)
        }

        let sessionId = UUID().uuidString
        let tokenHex = String(repeating: "ab", count: EscrowWireFormat.tokenSize)

        Thread.detachNewThread {
            defer { serverExited.signal() }
            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else { return }
            var request = Data()
            while request.count < EscrowWireFormat.frameSize {
                var buffer = [UInt8](repeating: 0, count: EscrowWireFormat.frameSize - request.count)
                let n = read(conn, &buffer, buffer.count)
                guard n > 0 else { break }
                request.append(contentsOf: buffer.prefix(n))
            }
            var frame = Data(count: EscrowWireFormat.frameSize)
            frame[0] = 0x04 // retrieveResponseType
            frame.replaceSubrange(1..<(1 + EscrowWireFormat.sessionIdSize), with: Array(sessionId.utf8))
            frame[1 + EscrowWireFormat.sessionIdSize + EscrowWireFormat.tokenSize] = 1 // granted
            var grantPair: [Int32] = [-1, -1]
            if socketpair(AF_UNIX, SOCK_STREAM, 0, &grantPair) == 0 {
                let ping = Data("ping".utf8)
                _ = ping.withUnsafeBytes { raw -> Int in
                    write(grantPair[1], raw.baseAddress, raw.count)
                }
                close(grantPair[1])
                _ = UnixDomainFDPassing.send(fd: grantPair[0], payload: frame, over: conn)
                // Mirror the production holder's "never close the escrowed
                // fd" grant path -- see the race test's grant branch for
                // the full rationale. The client closes the control
                // connection only after its recvmsg completed, so waiting
                // for conn EOF removes the sender-close vs receiver-
                // externalization race entirely.
                var drainBuffer = [UInt8](repeating: 0, count: 16)
                while read(conn, &drainBuffer, drainBuffer.count) > 0 {}
                close(grantPair[0])
            }
            close(conn)
        }

        let retrievedFD = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: 2.0
        )
        let unwrappedFD = try XCTUnwrap(retrievedFD, "an immediate grant must succeed on the first attempt")
        defer { close(unwrappedFD) }

        var received = [UInt8](repeating: 0, count: 8)
        var collected = Data()
        while collected.count < 4 {
            let n = read(unwrappedFD, &received, received.count)
            guard n > 0 else { break }
            collected.append(contentsOf: received.prefix(n))
        }
        XCTAssertEqual(String(data: collected, encoding: .utf8), "ping", "the granted fd must be the one the holder escrowed -- its kernel buffer carries the bytes written before the send")
        XCTAssertEqual(read(unwrappedFD, &received, received.count), 0, "after the buffered ping, EOF: both original pair ends were closed before the send")
    }

    // The deny reason travels in the first byte of the response frame's
    // otherwise-unused token padding, so pre-reason holders (zero padding)
    // must decode as .unspecified and reason-carrying frames must survive a
    // round trip. The holder outlives the app across updates, so
    // mixed-version frames are the normal update path, not an edge case.
    func testRetrieveResponseFrameDenyReasonRoundTripAndLegacyCompatibility() throws {
        let sessionId = UUID().uuidString

        for reason: EscrowWireFormat.RetrieveDenyReason in [.unknownSession, .tokenMismatch, .notDraining, .drainStopTimeout] {
            let frame = try XCTUnwrap(EscrowWireFormat.encodeRetrieveResponseFrame(
                sessionId: sessionId,
                granted: false,
                denyReason: reason
            ))
            let decoded = try XCTUnwrap(EscrowWireFormat.decode(frame))
            XCTAssertEqual(decoded.retrieveGranted, false)
            XCTAssertEqual(decoded.retrieveDenyReason, reason)
        }

        // A granted frame never carries a deny reason byte.
        let granted = try XCTUnwrap(EscrowWireFormat.encodeRetrieveResponseFrame(
            sessionId: sessionId,
            granted: true,
            denyReason: .notDraining
        ))
        XCTAssertEqual(granted[EscrowWireFormat.retrieveDenyReasonOffset], 0)

        // A legacy (pre-reason) holder's deny frame: zero token padding.
        var legacy = Data(count: EscrowWireFormat.frameSize)
        legacy[0] = 0x04
        legacy.replaceSubrange(1..<(1 + EscrowWireFormat.sessionIdSize), with: Array(sessionId.utf8))
        let decodedLegacy = try XCTUnwrap(EscrowWireFormat.decode(legacy))
        XCTAssertEqual(decodedLegacy.retrieveGranted, false)
        XCTAssertEqual(decodedLegacy.retrieveDenyReason, .unspecified)
    }

    // The retry is bounded: a holder that keeps answering not_draining
    // past the deadline (e.g. the old app really is still alive) ends in
    // the fallback, after more than one attempt.
    func testRetrieveGivesUpOnPersistentNotDrainingDenialAtDeadline() throws {
        let socketPath = makeShortSocketPath()
        let listenFD = try XCTUnwrap(UnixDomainFDPassing.bindListening(socketPath: socketPath))
        defer {
            close(listenFD)
            unlink(socketPath)
        }

        let sessionId = UUID().uuidString
        let tokenHex = String(repeating: "ab", count: EscrowWireFormat.tokenSize)
        let requestCount = ManagedAtomic()
        let stopRequested = ManagedAtomic()
        let serverExited = DispatchSemaphore(value: 0)
        // Deterministic teardown: close(listenFD) does NOT reliably wake a
        // thread blocked in accept(2) on macOS, and a zombie server blocked
        // on a closed (and later REUSED) fd number steals or closes the
        // next test's sockets. The defer below sets the stop flag, pokes
        // the server awake with one throwaway connect, and JOINS the
        // thread so none of its code runs concurrently with a later test.
        defer {
            stopRequested.increment()
            if let wake = UnixDomainFDPassing.connect(to: socketPath) { close(wake) }
            _ = serverExited.wait(timeout: .now() + 2.0)
        }

        Thread.detachNewThread {
            defer { serverExited.signal() }
            while true {
                let conn = accept(listenFD, nil, nil)
                guard conn >= 0 else { return }
                guard stopRequested.value == 0 else {
                    close(conn)
                    return
                }
                var request = Data()
                while request.count < EscrowWireFormat.frameSize {
                    var buffer = [UInt8](repeating: 0, count: EscrowWireFormat.frameSize - request.count)
                    let n = read(conn, &buffer, buffer.count)
                    guard n > 0 else { break }
                    request.append(contentsOf: buffer.prefix(n))
                }
                requestCount.increment()
                if let deny = EscrowWireFormat.encodeRetrieveResponseFrame(
                    sessionId: sessionId,
                    granted: false,
                    denyReason: .notDraining
                ) {
                    _ = UnixDomainFDPassing.send(fd: nil, payload: deny, over: conn)
                }
                close(conn)
            }
        }

        // Generous timing on purpose: a loaded CI runner can stretch one
        // attempt toward its recv timeout, and this test asserts the retry
        // COUNT, so the deadline must fit several worst-case attempts.
        let startedAt = Date()
        let retrievedFD = SessionEscrowClient.retrieve(
            sessionId: sessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            recvTimeout: 1.0,
            retryDeadline: .now() + 3.0
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertNil(retrievedFD, "a denial that persists past the retry deadline must fall back")
        XCTAssertGreaterThanOrEqual(requestCount.value, 2, "the not_draining denial must be retried at least once before falling back")
        XCTAssertLessThan(elapsed, 15.0, "the retry loop must respect its deadline")
    }

    private final class ManagedAtomic {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // Fix 3: the fallback restore path must not delete a session directory
    // whose escrow claim may still be live — `meta.json` holds the only
    // copy of the retrieval token, and the holder keeps the child alive
    // for `unclaimedSessionTTL` after a drain begins.
    func testDiscardOrphanedSessionPreservesDirectoryWithLiveEscrowClaim() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-escrow-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let sessionId = UUID().uuidString
        let paths = try XCTUnwrap(SessionWALPaths.make(sessionId: sessionId, appSupportDirectory: appSupport))
        try FileManager.default.createDirectory(at: paths.sessionDirectory, withIntermediateDirectories: true)
        let meta = SessionWALMeta(
            sessionId: sessionId,
            childPID: 123,
            ptyPath: nil,
            workingDirectory: nil,
            lastHeartbeatAt: Date(),
            walGeneration: 0,
            escrowed: true,
            escrowSocketPath: "/tmp/example-holder.sock",
            escrowToken: String(repeating: "ab", count: EscrowWireFormat.tokenSize)
        )
        _ = try SessionWALCore.persistMeta(meta, to: paths)

        let discarded = expectation(description: "discard completed")
        SessionWALStore.shared.discardOrphanedSession(
            sessionId: sessionId,
            appSupportDirectory: appSupport
        ) {
            discarded.fulfill()
        }
        wait(for: [discarded], timeout: 5.0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: paths.metaURL.path),
            "a live escrow claim's meta.json is the only copy of the retrieval token — deleting it forecloses reattach while the holder still has the child alive"
        )
    }

    // The preservation is deliberately claim-based, not freshness-based:
    // the holder expires sessions from `drainingStartedAt` on its own
    // reaper cadence, and a client-side heartbeat-age check would race that
    // clock near the TTL boundary and delete a live child's token. So the
    // ONLY things still deleted here are directories with no escrow claim
    // at all -- and consumed claims, via the revive path's `force`.
    func testDiscardOrphanedSessionStillDeletesUnescrowedDirectories() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-escrow-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let sessionId = UUID().uuidString
        let paths = try XCTUnwrap(SessionWALPaths.make(sessionId: sessionId, appSupportDirectory: appSupport))
        try FileManager.default.createDirectory(at: paths.sessionDirectory, withIntermediateDirectories: true)
        let meta = SessionWALMeta(
            sessionId: sessionId,
            childPID: 123,
            ptyPath: nil,
            workingDirectory: nil,
            lastHeartbeatAt: Date(),
            walGeneration: 0,
            escrowed: nil,
            escrowSocketPath: nil,
            escrowToken: nil
        )
        _ = try SessionWALCore.persistMeta(meta, to: paths)

        let discarded = expectation(description: "discard completed")
        SessionWALStore.shared.discardOrphanedSession(
            sessionId: sessionId,
            appSupportDirectory: appSupport
        ) {
            discarded.fulfill()
        }
        wait(for: [discarded], timeout: 5.0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.sessionDirectory.path),
            "a directory with no escrow claim has nothing to preserve and must be cleaned up by the fallback restore"
        )
    }

    func testDiscardOrphanedSessionForceDeletesConsumedEscrowClaim() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-escrow-discard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }

        let sessionId = UUID().uuidString
        let paths = try XCTUnwrap(SessionWALPaths.make(sessionId: sessionId, appSupportDirectory: appSupport))
        try FileManager.default.createDirectory(at: paths.sessionDirectory, withIntermediateDirectories: true)
        let meta = SessionWALMeta(
            sessionId: sessionId,
            childPID: 123,
            ptyPath: nil,
            workingDirectory: nil,
            lastHeartbeatAt: Date(),
            walGeneration: 0,
            escrowed: true,
            escrowSocketPath: "/tmp/example-holder.sock",
            escrowToken: String(repeating: "ab", count: EscrowWireFormat.tokenSize)
        )
        _ = try SessionWALCore.persistMeta(meta, to: paths)

        let discarded = expectation(description: "discard completed")
        SessionWALStore.shared.discardOrphanedSession(
            sessionId: sessionId,
            appSupportDirectory: appSupport,
            force: true
        ) {
            discarded.fulfill()
        }
        wait(for: [discarded], timeout: 5.0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.sessionDirectory.path),
            "the revive-success path consumed the claim (holder registry entry is gone) and must be able to clean up despite live-looking escrow fields"
        )
    }

    // MARK: - Escrow release on genuine close

    func testReleaseFrameRoundTripsThroughDecode() throws {
        let sessionId = UUID().uuidString
        let token = (0..<EscrowWireFormat.tokenSize).map { UInt8($0 % 251) }

        let frame = try XCTUnwrap(
            EscrowWireFormat.encodeReleaseFrame(sessionId: sessionId, token: token)
        )
        XCTAssertEqual(
            frame.count,
            EscrowWireFormat.frameSize,
            "release must use the same fixed frame size as every other type, or the read side desynchronizes"
        )

        let decoded = try XCTUnwrap(EscrowWireFormat.decode(frame))
        XCTAssertEqual(decoded.type, EscrowWireFormat.releaseType)
        XCTAssertEqual(decoded.sessionId, sessionId)
        XCTAssertEqual(decoded.token, token, "the holder authenticates a release by token; it must survive the round trip")
        XCTAssertNil(decoded.childPID, "release carries no child pid")
    }

    func testReleaseFrameRejectsMalformedInput() {
        let token = [UInt8](repeating: 0x11, count: EscrowWireFormat.tokenSize)
        XCTAssertNil(
            EscrowWireFormat.encodeReleaseFrame(sessionId: "too-short", token: token),
            "a session id that is not a UUID string would shift every later field"
        )
        XCTAssertNil(
            EscrowWireFormat.encodeReleaseFrame(sessionId: UUID().uuidString, token: [0x01, 0x02]),
            "a short token would leave the frame undersized"
        )
    }

    /// A session open when the app quits MUST stay escrowed — reattaching it
    /// on the next launch is what escrow is for, and releasing on quit would
    /// kill every running agent on every app update.
    func testEscrowIsReleasedOnlyForAUserCloseWhileTheAppIsRunning() {
        XCTAssertTrue(
            TerminalSurface.shouldReleaseEscrowOnTeardown(reason: "teardown", isApplicationTerminating: false),
            "a finalized user close is the one case that must release"
        )
        XCTAssertFalse(
            TerminalSurface.shouldReleaseEscrowOnTeardown(reason: "teardown", isApplicationTerminating: true),
            "quitting must leave sessions escrowed for the next launch to reattach"
        )
        XCTAssertFalse(
            TerminalSurface.shouldReleaseEscrowOnTeardown(reason: "deinit", isApplicationTerminating: false),
            "deallocation is not necessarily a user-visible close"
        )
        XCTAssertFalse(
            TerminalSurface.shouldReleaseEscrowOnTeardown(reason: "deinit", isApplicationTerminating: true)
        )
    }
}

/// Regression coverage for the 0.4.231 revive-replay main-thread deadlock.
///
/// `TerminalSurface.replayRevivedScrollback` feeds a revived session's
/// scrollback to `ghostty_surface_process_output` in chunks. Every OSC
/// sequence in that transcript that produces an apprt surface message (title
/// set OSC 0/2, pwd report OSC 7 — shells emit these on every prompt) is
/// pushed into ghostty's app mailbox (`BlockingQueue(Message, 64)`,
/// ghostty/src/App.zig:662), which blocks with a `.forever` policy once full
/// (ghostty/src/termio/stream_handler.zig:126-137). The ONLY drainer of that
/// mailbox is `ghostty_app_tick`, which Programa runs on the main thread
/// (`GhosttyApp.swift`). When the replay itself also runs on the main thread,
/// a transcript with more than 64 surface-message-producing sequences
/// self-deadlocks: the 65th push parks the main thread forever, and the tick
/// that would drain it can never run.
///
/// The #285 fix (chunking `process_output` calls, see the comment on
/// `replayRevivedScrollback`) only unblocks ghostty's *renderer* mailbox,
/// which has an independent drainer thread. It cannot unblock the app
/// mailbox, whose only drainer is the very thread running the replay.
///
/// This test asserts every replay chunk lands off the main thread. It is
/// expected to be RED before the fix lands (chunks currently run on main via
/// the `DispatchQueue.main.async` hop in `seedRevivedScrollbackIfPending`)
/// and GREEN once the replay loop is moved to a background serial queue.
/// CI is expected red on this commit per the repo's two-commit regression
/// test policy.
///
/// The transcript here is intentionally tiny (10 OSC-prefixed lines, far
/// below the 64-message mailbox capacity) — a transcript large enough to
/// actually fill the mailbox would genuinely deadlock the main thread on the
/// unfixed code and hang the CI job instead of failing this assertion.
@MainActor
final class ReviveReplayMainThreadRegressionTests: XCTestCase {
    func testReviveReplayNeverFeedsGhosttyOnTheMainThread() {
        _ = NSApplication.shared

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            TerminalSurface.reviveReplayChunkObserverForTesting = nil
            window.orderOut(nil)
        }

        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        // CRITICAL: 10 OSC sequences, far below the app mailbox's 64-message
        // capacity. A larger transcript would genuinely deadlock the unfixed
        // code and hang CI instead of failing the assertion below.
        let transcript = String(repeating: "\u{1B}]0;t\u{07}hello\r\n", count: 10)

        var observedMainThreadFlags: [Bool] = []
        TerminalSurface.reviveReplayChunkObserverForTesting = { isMainThread in
            observedMainThreadFlags.append(isMainThread)
        }

        let expectation = expectation(description: "revive replay completes")
        surface.replayRevivedScrollbackForTesting(text: transcript) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 30)

        XCTAssertFalse(
            observedMainThreadFlags.isEmpty,
            "Expected at least one replay chunk to be observed"
        )
        XCTAssertFalse(
            observedMainThreadFlags.contains(true),
            "Revive replay must feed ghostty off the main thread — the app mailbox " +
            "(BlockingQueue(Message, 64)) is drained only by ghostty_app_tick on the " +
            "main thread, so replaying on main can self-deadlock past 64 OSC messages " +
            "(shipped in 0.4.231)"
        )
    }
}

// 2026-08-20 update-reset report: WAL rotation and ring overruns cut the byte
// stream mid-escape-sequence, leaving an orphaned parameter tail ("38;114m")
// with no ESC byte at the head of the replay — plain text to every sanitizer,
// rendered literally. The head repair must strip it without eating legitimate
// prose that merely looks parameter-ish.
final class ScrollbackSeedOrphanedHeadTests: XCTestCase {
    func testOrphanedSGRTailAtHeadIsStripped() {
        let corrupt = "38;114mreturn }\nnext line"
        XCTAssertEqual(
            SessionFreshSpawnScrollbackSeed.strippedOrphanedSequenceHead(corrupt),
            "return }\nnext line"
        )
    }

    func testOrphanedPrivateModeTailAtHeadIsStripped() {
        let corrupt = "?1003hprompt$ "
        XCTAssertEqual(
            SessionFreshSpawnScrollbackSeed.strippedOrphanedSequenceHead(corrupt),
            "prompt$ "
        )
    }

    func testLegitimateProseHeadsAreUntouched() {
        for text in ["1m 30s elapsed\n", "42x42 grid\n", "2026-08-20 log line\n", "500 OK\n", "plain text"] {
            XCTAssertEqual(
                SessionFreshSpawnScrollbackSeed.strippedOrphanedSequenceHead(text),
                text,
                "must not strip: \(text)"
            )
        }
    }

    func testPreparedTextRepairsCorruptHeadEndToEnd() {
        let prepared = SessionFreshSpawnScrollbackSeed.preparedText(for: "38;114mreturn }\nnext line\n")
        XCTAssertNotNil(prepared)
        XCTAssertFalse(
            prepared?.contains("38;114m") ?? true,
            "the orphaned fragment must not survive into the seeded replay"
        )
    }
}
