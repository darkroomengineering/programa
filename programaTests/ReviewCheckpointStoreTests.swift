import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class ReviewCheckpointStoreTests: XCTestCase {
    private let workspaceId = UUID()
    private let surfaceId = UUID()
    private var directories: [String] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(atPath: directory)
        }
        directories.removeAll()
        super.tearDown()
    }

    func testRestoreRevertsModifiedRestoresDeletedAndRemovesNewFiles() throws {
        let repo = try makeCommittedRepo(files: ["edited.txt": "original\n", "deleted.txt": "keep me\n"])
        let ref = try XCTUnwrap(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))

        try write("agent edit\n", to: "edited.txt", in: repo)
        try FileManager.default.removeItem(atPath: path("deleted.txt", in: repo))
        try write("new\n", to: "created/new.txt", in: repo)

        let result = ReviewCheckpointStore.restore(ref: ref, directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)
        XCTAssertEqual(try resultError(result), nil)

        XCTAssertEqual(try read("edited.txt", in: repo), "original\n")
        XCTAssertEqual(try read("deleted.txt", in: repo), "keep me\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("created/new.txt", in: repo)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("created", in: repo)))
    }

    func testRevertCanBeUndoneThroughThePreRevertCheckpoint() throws {
        let repo = try makeCommittedRepo(files: ["file.txt": "before\n"])
        let turnStart = try XCTUnwrap(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))
        try write("after\n", to: "file.txt", in: repo)
        try write("untracked\n", to: "agent.txt", in: repo)

        XCTAssertEqual(try resultError(ReviewCheckpointStore.restore(ref: turnStart, directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)), nil)
        let newest = try XCTUnwrap(ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).first)
        XCTAssertEqual(newest.kind, .beforeRevert)

        XCTAssertEqual(try resultError(ReviewCheckpointStore.restore(ref: newest.ref, directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)), nil)
        XCTAssertEqual(try read("file.txt", in: repo), "after\n")
        XCTAssertEqual(try read("agent.txt", in: repo), "untracked\n")
        XCTAssertEqual(ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).first?.kind, .turnStart)
    }

    func testSaveAndRestoreLeaveRealIndexAndHeadUntouched() throws {
        let repo = try makeCommittedRepo(files: ["staged.txt": "one\n", "plain.txt": "one\n"])
        try write("two\n", to: "staged.txt", in: repo)
        try runGit(["add", "staged.txt"], in: repo)
        let indexPath = try realIndexPath(repo: repo)
        let indexBefore = try Data(contentsOf: URL(fileURLWithPath: indexPath))
        let indexDateBefore = try modificationDate(indexPath)
        let cachedBefore = try runGit(["--no-optional-locks", "diff", "--cached", "--name-only"], in: repo)
        let headBefore = try runGit(["--no-optional-locks", "rev-parse", "HEAD"], in: repo)

        let ref = try XCTUnwrap(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))
        try write("agent\n", to: "plain.txt", in: repo)
        try write("agent\n", to: "added.txt", in: repo)
        XCTAssertEqual(try resultError(ReviewCheckpointStore.restore(ref: ref, directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)), nil)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: indexPath)), indexBefore)
        XCTAssertEqual(try modificationDate(indexPath), indexDateBefore)
        XCTAssertEqual(try runGit(["--no-optional-locks", "diff", "--cached", "--name-only"], in: repo), cachedBefore)
        XCTAssertEqual(try runGit(["--no-optional-locks", "rev-parse", "HEAD"], in: repo), headBefore)
        XCTAssertEqual(try read("plain.txt", in: repo), "one\n")
        XCTAssertEqual(try read("staged.txt", in: repo), "two\n")
    }

    func testUnbornHeadRepoSavesAndRestores() throws {
        let repo = try makeRepo()
        try write("first\n", to: "draft.txt", in: repo)
        let ref = try XCTUnwrap(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))

        try write("changed\n", to: "draft.txt", in: repo)
        try write("extra\n", to: "extra.txt", in: repo)
        XCTAssertEqual(try resultError(ReviewCheckpointStore.restore(ref: ref, directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)), nil)

        XCTAssertEqual(try read("draft.txt", in: repo), "first\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("extra.txt", in: repo)))
        XCTAssertThrowsError(try runGit(["--no-optional-locks", "rev-parse", "--verify", "--quiet", "HEAD"], in: repo))
    }

    func testUnchangedTreeReusesNewestCheckpoint() throws {
        let repo = try makeCommittedRepo(files: ["file.txt": "same\n"])
        let first = ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)
        let second = ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).count, 1)
    }

    func testSaveKeepsOnlyTheNewestTwentyCheckpoints() throws {
        let repo = try makeCommittedRepo(files: ["counter.txt": "0\n"])
        var refs: [String] = []
        for step in 1...(ReviewCheckpointStore.keepCount + 2) {
            try write("\(step)\n", to: "counter.txt", in: repo)
            refs.append(try XCTUnwrap(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId)))
        }

        let listed = ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).map(\.ref)
        XCTAssertEqual(listed, Array(refs.suffix(ReviewCheckpointStore.keepCount).reversed()))
    }

    func testSaveSkipsWhenTooManyFilesChanged() throws {
        let repo = try makeCommittedRepo(files: ["file.txt": "x\n"])
        for index in 0...ReviewCheckpointStore.maxChangedPaths {
            try write("\(index)\n", to: "many/file-\(index).txt", in: repo)
        }
        XCTAssertNil(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertTrue(ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).isEmpty)
    }

    func testSaveSkipsWhenAnUntrackedFileIsTooLarge() throws {
        let repo = try makeCommittedRepo(files: ["file.txt": "x\n"])
        let large = Data(count: Int(ReviewCheckpointStore.maxUntrackedFileBytes) + 1)
        try large.write(to: URL(fileURLWithPath: path("large.bin", in: repo)))
        XCTAssertNil(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertTrue(ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).isEmpty)
    }

    func testDeleteAllRemovesOnlyThatWorkspacesCheckpoints() throws {
        let repo = try makeCommittedRepo(files: ["file.txt": "x\n"])
        let otherWorkspace = UUID()
        XCTAssertNotNil(ReviewCheckpointStore.save(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertNotNil(ReviewCheckpointStore.save(directory: repo, workspaceId: otherWorkspace, surfaceId: surfaceId))

        ReviewCheckpointStore.deleteAll(workspaceId: workspaceId, directory: repo)

        XCTAssertTrue(ReviewCheckpointStore.list(directory: repo, workspaceId: workspaceId, surfaceId: surfaceId).isEmpty)
        XCTAssertEqual(ReviewCheckpointStore.list(directory: repo, workspaceId: otherWorkspace, surfaceId: surfaceId).count, 1)
    }

    // MARK: - Helpers

    private func resultError(_ result: Result<Void, ReviewCheckpointError>) throws -> ReviewCheckpointError? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private func makeRepo() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-checkpoint-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url.path)
        try runGit(["init", "-q", "-b", "main"], in: url.path)
        return url.path
    }

    private func makeCommittedRepo(files: [String: String]) throws -> String {
        let repo = try makeRepo()
        for (name, contents) in files {
            try write(contents, to: name, in: repo)
        }
        try runGit(["add", "-A"], in: repo)
        try runGit(["-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "initial"], in: repo)
        return repo
    }

    private func path(_ relative: String, in repo: String) -> String {
        (repo as NSString).appendingPathComponent(relative)
    }

    private func write(_ contents: String, to relative: String, in repo: String) throws {
        let fullPath = path(relative, in: repo)
        try FileManager.default.createDirectory(
            atPath: (fullPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try contents.write(toFile: fullPath, atomically: false, encoding: .utf8)
    }

    private func read(_ relative: String, in repo: String) throws -> String {
        try String(contentsOfFile: path(relative, in: repo), encoding: .utf8)
    }

    private func realIndexPath(repo: String) throws -> String {
        let output = try runGit(["--no-optional-locks", "rev-parse", "--git-path", "index"], in: repo)
            .trimmingCharacters(in: .newlines)
        return output.hasPrefix("/") ? output : path(output, in: repo)
    }

    private func modificationDate(_ path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
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
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw NSError(
                domain: "ReviewCheckpointStoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}
