import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

@MainActor
final class ReviewPanelRowPlannerTests: XCTestCase {
    func testCommentAdmissionRejectsInvalidAndOversizedDraftsWithoutMutation() throws {
        let panel = ReviewPanel(workspaceId: UUID(), sourceSurfaceId: UUID(), directory: "/tmp", mode: .uncommitted, baseBranch: "main")
        let valid = try panel.addComment(filePath: "App.swift", startLine: 0, text: "Deletion anchor")
        XCTAssertThrowsError(try panel.addComment(filePath: "", startLine: 1, text: "Draft"))
        XCTAssertThrowsError(try panel.addComment(filePath: "App.swift", startLine: -1, text: "Draft"))
        XCTAssertThrowsError(try panel.addComment(filePath: "App.swift", startLine: 3, endLine: 2, text: "Draft"))
        XCTAssertThrowsError(try panel.addComment(filePath: "App.swift", startLine: 1, text: "  "))
        XCTAssertThrowsError(try panel.addComment(filePath: String(repeating: "a", count: SessionPersistencePolicy.maxPathStringBytes + 1), startLine: 1, text: "Draft"))
        XCTAssertThrowsError(try panel.addComment(filePath: "App.swift", startLine: 1, text: String(repeating: "é", count: SessionPersistencePolicy.maxMetadataStringBytes / 2 + 1)))
        XCTAssertEqual(panel.comments, [valid])
        let boundary = try panel.addComment(filePath: "App.swift", startLine: 1, text: String(repeating: "a", count: SessionPersistencePolicy.maxMetadataStringBytes))
        XCTAssertTrue(boundary.isValidForPersistence)
    }

    func testCommentAdmissionRejectsAtCountLimitAndAllowsRetryAfterRemoval() throws {
        let panel = ReviewPanel(workspaceId: UUID(), sourceSurfaceId: UUID(), directory: "/tmp", mode: .uncommitted, baseBranch: "main")
        for _ in 0..<SessionPersistencePolicy.maxReviewCommentsPerPanel {
            try panel.addComment(filePath: "App.swift", startLine: 1, text: "Draft")
        }
        XCTAssertThrowsError(try panel.addComment(filePath: "App.swift", startLine: 1, text: "Retry later"))
        XCTAssertEqual(panel.comments.count, SessionPersistencePolicy.maxReviewCommentsPerPanel)
        panel.removeComment(id: try XCTUnwrap(panel.comments.first).id)
        XCTAssertNoThrow(try panel.addComment(filePath: "App.swift", startLine: 1, text: "Retry later"))
    }

    func testFailedCommentDispatchRetainsDraftsAndCanBeRetried() throws {
        let panel = ReviewPanel(workspaceId: UUID(), sourceSurfaceId: UUID(), directory: "/tmp", mode: .uncommitted, baseBranch: "main")
        let comment = try panel.addComment(filePath: "App.swift", startLine: 1, text: "Please fix this")

        XCTAssertNil(panel.sendPendingComments(), "A missing callback must not discard comments")
        XCTAssertEqual(panel.comments, [comment])
        XCTAssertTrue(panel.commentDeliveryFailed)
        panel.sendToSourceSurface = { _ in false }
        XCTAssertNil(panel.sendPendingComments())
        XCTAssertEqual(panel.comments, [comment])

        var dispatchedText = ""
        panel.sendToSourceSurface = { text in
            dispatchedText = text
            return true
        }
        XCTAssertEqual(panel.sendPendingComments(), 1)
        XCTAssertTrue(dispatchedText.contains(comment.text))
        XCTAssertTrue(panel.comments.isEmpty)
        XCTAssertFalse(panel.commentDeliveryFailed)
        panel.sendToSourceSurface = nil
        XCTAssertEqual(panel.sendPendingComments(), 0, "Empty review remains a successful no-op")
    }

    func testRestoredCommentsSurviveFreshDiffAndRevalidateAnchors() throws {
        let comment = ReviewComment(filePath: "App.swift", startLine: 1, text: "Keep this draft")
        let snapshot = SessionReviewPanelSnapshot(sourceSurfaceId: UUID(), mode: "uncommitted", baseBranch: "main", comments: [comment])
        let restored = try JSONDecoder().decode(SessionReviewPanelSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored.comments, [comment])
        let panel = ReviewPanel(workspaceId: UUID(), sourceSurfaceId: restored.sourceSurfaceId, directory: "/tmp", mode: .uncommitted, baseBranch: restored.baseBranch)
        panel.restoreComments(try XCTUnwrap(restored.comments))
        XCTAssertTrue(try XCTUnwrap(panel.comments.first).isStale)
        panel.apply(snapshot: ReviewDiffSnapshot(files: [makeFile(path: "App.swift", lineText: "changed")], generatedAt: Date()))
        XCTAssertEqual(panel.comments, [comment])
        panel.apply(snapshot: ReviewDiffSnapshot(files: [], generatedAt: Date()))
        XCTAssertEqual(panel.comments.first?.text, comment.text)
        XCTAssertTrue(try XCTUnwrap(panel.comments.first).isStale)
    }

    func testLegacyReviewSnapshotRestoresWithoutComments() throws {
        let data = Data("{\"sourceSurfaceId\":\"00000000-0000-0000-0000-000000000001\",\"mode\":\"uncommitted\",\"baseBranch\":\"main\"}".utf8)
        let snapshot = try JSONDecoder().decode(SessionReviewPanelSnapshot.self, from: data)
        XCTAssertNil(snapshot.comments)
    }

    func testRepeatedIdenticalInputReusesRowsWithoutRebuilding() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let files = [makeFile(path: "Sources/App.swift", lineText: "first")]

        let first = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: files
        )
        let second = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: files
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(planner.rebuildCount, 1, "An unchanged review should reuse its existing row topology")
    }

    func testSnapshotRevisionInvalidatesCacheAndReflectsChangedRows() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let initialFiles = [makeFile(path: "Sources/App.swift", lineText: "before")]
        let changedFiles = [makeFile(path: "Sources/App.swift", lineText: "after")]

        let initialRows = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: initialFiles
        )
        let changedRows = planner.rows(
            panelID: panelID,
            filesRevision: 2,
            collapsedFilePaths: [],
            composer: nil,
            files: changedFiles
        )

        XCTAssertEqual(lineTexts(in: initialRows), ["before"])
        XCTAssertEqual(lineTexts(in: changedRows), ["after"])
        XCTAssertEqual(planner.rebuildCount, 2, "A new snapshot revision must invalidate cached review rows")
    }

    func testCollapseHidesDiffAndComposerRowsAndExpandRestoresThem() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let path = "Sources/App.swift"
        let files = [makeFile(path: path, lineText: "changed", newLineNumber: 12)]
        let composer = makeComposer(path: path, endLine: 12)

        let expanded = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: composer,
            files: files
        )
        let collapsed = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [path],
            composer: composer,
            files: files
        )
        let restored = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: composer,
            files: files
        )

        XCTAssertEqual(rowKinds(in: expanded), ["file", "hunk", "line", "composer", "spacing"])
        XCTAssertEqual(rowKinds(in: collapsed), ["file", "spacing"])
        XCTAssertEqual(restored.map(\.id), expanded.map(\.id), "Expanding should restore the same stable row identities")
    }

    func testComposerPlacementFollowsAnchorWhileTextAndRangeStartReuseTopology() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let path = "Sources/App.swift"
        let file = ReviewFileDiff(
            oldPath: path,
            newPath: path,
            status: .modified,
            hunks: [
                ReviewHunk(
                    header: "@@ -9,2 +9,2 @@",
                    lines: [
                        ReviewDiffLine(kind: .context, oldLineNumber: 9, newLineNumber: 9, text: "before"),
                        ReviewDiffLine(kind: .addition, oldLineNumber: nil, newLineNumber: 10, text: "target"),
                    ]
                )
            ],
            notDiffableReason: nil
        )

        let initial = makeComposer(path: path, anchorLine: 10, startLine: 10, endLine: 10, text: "draft")
        let initialRows = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: initial,
            files: [file]
        )
        let edited = makeComposer(path: path, anchorLine: 10, startLine: 9, endLine: 10, text: "edited draft")
        let editedRows = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: edited,
            files: [file]
        )

        XCTAssertEqual(rowKinds(in: initialRows), ["file", "hunk", "line", "line", "composer", "spacing"])
        XCTAssertEqual(initialRows.map(\.id), editedRows.map(\.id))
        XCTAssertEqual(planner.rebuildCount, 1, "Composer text and range-start edits should not rebuild row topology")
    }

    func testDuplicateFilePathsProduceDistinctStableRowIDs() {
        let planner = ReviewPanelRowPlanner()
        let panelID = UUID()
        let duplicateFiles = [
            makeFile(path: "Sources/App.swift", lineText: "first"),
            makeFile(path: "Sources/App.swift", lineText: "second"),
        ]

        let firstRevision = planner.rows(
            panelID: panelID,
            filesRevision: 1,
            collapsedFilePaths: [],
            composer: nil,
            files: duplicateFiles
        )
        let secondRevision = planner.rows(
            panelID: panelID,
            filesRevision: 2,
            collapsedFilePaths: [],
            composer: nil,
            files: duplicateFiles
        )
        let firstIDs = firstRevision.map(\.id)

        XCTAssertEqual(Set(firstIDs).count, firstIDs.count, "Duplicate paths must not collide in SwiftUI row identity")
        XCTAssertEqual(secondRevision.map(\.id), firstIDs, "Snapshot refreshes should preserve row identity for unchanged files")
    }

    // MARK: - M12: stale probe generations / unborn HEAD

    func testUncommittedProbeSeesStagedFileBeforeFirstCommit() throws {
        let repoRoot = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let filePath = (repoRoot as NSString).appendingPathComponent("staged.txt")
        try "hello".write(toFile: filePath, atomically: true, encoding: .utf8)
        try runGit(["add", "staged.txt"], in: repoRoot)

        let snapshot = ReviewDiffProber.diffSnapshot(directory: repoRoot, mode: .uncommitted, baseBranch: "main")

        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.files.count, 1)
        XCTAssertEqual(snapshot.files.first?.newPath, "staged.txt")
        XCTAssertEqual(snapshot.files.first?.status, .added)
    }

    func testNonGitDirectoryReportsNotGitRepository() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let snapshot = ReviewDiffProber.diffSnapshot(directory: directory, mode: .uncommitted, baseBranch: "main")

        XCTAssertEqual(snapshot.error, .notGitRepository)
    }

    func testUnresolvableBaseBranchReportsUnknownBaseBranch() throws {
        let repoRoot = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let filePath = (repoRoot as NSString).appendingPathComponent("committed.txt")
        try "hello".write(toFile: filePath, atomically: true, encoding: .utf8)
        try runGit(["add", "committed.txt"], in: repoRoot)
        try runGit(["-c", "user.email=test@example.com", "-c", "user.name=Test", "commit", "-m", "initial"], in: repoRoot)

        let snapshot = ReviewDiffProber.diffSnapshot(directory: repoRoot, mode: .branch, baseBranch: "no-such-branch-zzz")

        XCTAssertEqual(snapshot.error, .unknownBaseBranch("no-such-branch-zzz"))
    }

    func testOutOfOrderRefreshCompletionsDoNotOverwriteNewerState() throws {
        let repoRoot = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(atPath: repoRoot) }
        let panel = ReviewPanel(workspaceId: UUID(), sourceSurfaceId: UUID(), directory: repoRoot, mode: .uncommitted, baseBranch: "main")

        panel.refresh()
        panel.refresh()

        let deadline = Date().addingTimeInterval(10)
        while panel.isRefreshing, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertFalse(panel.isRefreshing)
        XCTAssertEqual(panel.refreshGeneration, 2)
    }

    func testStaleGenerationApplyIsDiscardedWithoutMutatingState() throws {
        let panel = ReviewPanel(workspaceId: UUID(), sourceSurfaceId: UUID(), directory: "/tmp", mode: .uncommitted, baseBranch: "main")
        let currentFile = makeFile(path: "Sources/Current.swift", lineText: "current")
        let staleFile = makeFile(path: "Sources/Stale.swift", lineText: "stale")

        // Bumps refreshGeneration to 1 and applies.
        panel.apply(snapshot: ReviewDiffSnapshot(files: [currentFile], generatedAt: Date()))
        XCTAssertEqual(panel.refreshGeneration, 1)
        XCTAssertEqual(panel.files, [currentFile])
        let revisionAfterCurrent = panel.filesRevision

        // A completion issued under a stale (already-superseded) generation must be dropped.
        panel.apply(snapshot: ReviewDiffSnapshot(files: [staleFile], generatedAt: Date()), generation: 0)

        XCTAssertEqual(panel.files, [currentFile])
        XCTAssertEqual(panel.filesRevision, revisionAfterCurrent)
    }

    private func makeTempDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-panel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func makeTempGitRepo() throws -> String {
        let directory = try makeTempDirectory()
        try runGit(["init", "-q"], in: directory)
        return directory
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "ReviewPanelViewTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }

    func testApplyingSnapshotsAdvancesFilesRevision() {
        let panel = ReviewPanel(
            workspaceId: UUID(),
            sourceSurfaceId: UUID(),
            directory: "/tmp",
            mode: .uncommitted,
            baseBranch: "origin/main"
        )
        let firstFile = makeFile(path: "Sources/App.swift", lineText: "first")
        let secondFile = makeFile(path: "Sources/App.swift", lineText: "second")

        panel.apply(snapshot: ReviewDiffSnapshot(files: [firstFile], generatedAt: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(panel.filesRevision, 1)
        XCTAssertEqual(panel.files, [firstFile])

        panel.apply(snapshot: ReviewDiffSnapshot(files: [secondFile], generatedAt: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(panel.filesRevision, 2)
        XCTAssertEqual(panel.files, [secondFile])
    }

    private func makeFile(
        path: String,
        lineText: String,
        newLineNumber: Int = 1
    ) -> ReviewFileDiff {
        ReviewFileDiff(
            oldPath: path,
            newPath: path,
            status: .modified,
            hunks: [
                ReviewHunk(
                    header: "@@ -1 +1 @@",
                    lines: [
                        ReviewDiffLine(
                            kind: .addition,
                            oldLineNumber: nil,
                            newLineNumber: newLineNumber,
                            text: lineText
                        )
                    ]
                )
            ],
            notDiffableReason: nil
        )
    }

    private func makeComposer(
        path: String,
        anchorLine: Int = 1,
        startLine: Int = 1,
        endLine: Int,
        text: String = "comment"
    ) -> ReviewPanelComposerTopology {
        ReviewPanelComposerTopology(
            filePath: path,
            anchorLine: anchorLine,
            startLine: startLine,
            endLine: endLine,
            text: text
        )
    }

    private func lineTexts(in rows: [ReviewPanelRow]) -> [String] {
        rows.compactMap { row in
            guard case .line(_, _, _, let annotated, _) = row else { return nil }
            return annotated.line.text
        }
    }

    private func rowKinds(in rows: [ReviewPanelRow]) -> [String] {
        rows.map { row in
            switch row {
            case .fileHeader: return "file"
            case .notDiffable: return "notDiffable"
            case .hunkHeader: return "hunk"
            case .line: return "line"
            case .composer: return "composer"
            case .fileSpacing: return "spacing"
            }
        }
    }
}
