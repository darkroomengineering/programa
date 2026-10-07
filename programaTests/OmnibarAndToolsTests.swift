import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

final class FinderServicePathResolverTests: XCTestCase {
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "programa-finder-service-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    func testOrderedUniqueDirectoriesUsesParentForFilesAndDedupes() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/programa-services/project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/programa-services/project/README.md", isDirectory: false),
            URL(fileURLWithPath: "/tmp/programa-services/other/../project", isDirectory: true),
            URL(fileURLWithPath: "/tmp/programa-services/other", isDirectory: true),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/programa-services/project",
                "/tmp/programa-services/other",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesFirstSeenOrder() {
        let input: [URL] = [
            URL(fileURLWithPath: "/tmp/programa-services/b", isDirectory: true),
            URL(fileURLWithPath: "/tmp/programa-services/a/file.txt", isDirectory: false),
            URL(fileURLWithPath: "/tmp/programa-services/a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/programa-services/b/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(from: input)
        XCTAssertEqual(
            directories,
            [
                "/tmp/programa-services/b",
                "/tmp/programa-services/a",
            ]
        )
    }

    func testOrderedUniqueDirectoriesSkipsBundleAndEmbeddedPathsWhenExcludingBundleRoot() {
        let bundleURL = URL(fileURLWithPath: "/Applications/Tools/../programa.app", isDirectory: true)
        let input: [URL] = [
            bundleURL,
            URL(fileURLWithPath: "/Applications/programa.app/Contents/MacOS/programa", isDirectory: false),
            URL(fileURLWithPath: "/Applications/programa.app/Contents/Resources/bin/programa", isDirectory: false),
            URL(fileURLWithPath: "/Users/tester/Projects/programa", isDirectory: true),
            URL(fileURLWithPath: "/Users/tester/Projects/programa/README.md", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(
            from: input,
            excludingDescendantsOf: [bundleURL]
        )

        XCTAssertEqual(
            directories,
            [
                "/Users/tester/Projects/programa",
            ]
        )
    }

    func testOrderedUniqueDirectoriesExclusionDoesNotFilterSiblingPaths() {
        let bundleURL = URL(fileURLWithPath: "/Applications/programa.app", isDirectory: true)
        let input: [URL] = [
            URL(fileURLWithPath: "/Applications/programa.app backup/project", isDirectory: true),
            URL(fileURLWithPath: "/Applications/programa.app.beta/project/file.txt", isDirectory: false),
        ]

        let directories = FinderServicePathResolver.orderedUniqueDirectories(
            from: input,
            excludingDescendantsOf: [bundleURL]
        )

        XCTAssertEqual(
            directories,
            [
                "/Applications/programa.app backup/project",
                "/Applications/programa.app.beta/project",
            ]
        )
    }

    func testOrderedUniqueDirectoriesPreservesSymlinkAliasPaths() throws {
        try withTemporaryDirectory { root in
            let actualDirectory = root.appendingPathComponent("actual/project", isDirectory: true)
            let aliasDirectory = root.appendingPathComponent("alias-project", isDirectory: true)
            let actualFile = actualDirectory.appendingPathComponent("README.md", isDirectory: false)
            let aliasFile = aliasDirectory.appendingPathComponent("README.md", isDirectory: false)

            try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: actualFile.path, contents: Data())
            try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: actualDirectory)

            let directories = FinderServicePathResolver.orderedUniqueDirectories(
                from: [aliasDirectory, aliasFile]
            )

            XCTAssertEqual(directories, [aliasDirectory.standardizedFileURL.path])
            XCTAssertNotEqual(directories, [actualDirectory.standardizedFileURL.path])
        }
    }

    func testOrderedUniqueDirectoriesResolvesSymlinksOnlyForExcludedRootComparison() throws {
        try withTemporaryDirectory { root in
            let applicationsDirectory = root.appendingPathComponent("Applications", isDirectory: true)
            let actualBundle = applicationsDirectory.appendingPathComponent("programa.app", isDirectory: true)
            let actualBinary = actualBundle.appendingPathComponent("Contents/MacOS/programa", isDirectory: false)
            let aliasApplications = root.appendingPathComponent("Launcher", isDirectory: true)
            let aliasWorkspace = aliasApplications.appendingPathComponent("workspace", isDirectory: true)

            try FileManager.default.createDirectory(at: actualBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: actualBinary.path, contents: Data())
            try FileManager.default.createDirectory(
                at: applicationsDirectory.appendingPathComponent("workspace", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(at: aliasApplications, withDestinationURL: applicationsDirectory)

            let directories = FinderServicePathResolver.orderedUniqueDirectories(
                from: [
                    aliasApplications.appendingPathComponent("programa.app", isDirectory: true),
                    aliasApplications.appendingPathComponent("programa.app/Contents/MacOS/programa", isDirectory: false),
                    aliasWorkspace,
                ],
                excludingDescendantsOf: [actualBundle]
            )

            XCTAssertEqual(directories, [aliasWorkspace.standardizedFileURL.path])
        }
    }
}


final class CanonicalSubprocessRunnerTests: XCTestCase {
    func testSeparatelyCapturesBoundedStandardOutputAndError() {
        let result = CanonicalSubprocessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf output; printf error >&2"],
            currentDirectory: FileManager.default.temporaryDirectory.path,
            timeout: 1,
            stdoutLimit: 64,
            stderrLimit: 64
        )

        XCTAssertEqual(result.outcome, .exited)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdout, "output")
        XCTAssertEqual(result.stderr, "error")
    }

    func testLargeChildOutputFailsClosedWithoutPipeDeadlock() {
        let result = CanonicalSubprocessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 131072 /dev/zero"],
            currentDirectory: FileManager.default.temporaryDirectory.path,
            timeout: 2,
            stdoutLimit: 1_024,
            stderrLimit: 1_024
        )

        XCTAssertEqual(result.outcome, .stdoutLimitExceeded)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertNil(result.stdout, "Truncated child output must never be returned as successful output")
    }

    func testTimeoutIsDistinctFromExitAndOutputLimitFailures() {
        let result = CanonicalSubprocessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 2"],
            currentDirectory: FileManager.default.temporaryDirectory.path,
            timeout: 0.01,
            stdoutLimit: 64,
            stderrLimit: 64
        )

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.exitStatus)
    }

    func testTimeoutDoesNotWaitForDescendantHoldingOutputPipes() {
        let descendantPIDFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("programa-runner-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: descendantPIDFile) }
        let startedAt = ContinuousClock.now
        let result = CanonicalSubprocessRunner.run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "(sleep 5; printf descendant; printf descendant-error >&2) & child=$!; printf %d \"$child\" > \"$1\"; wait",
                "programa-runner-test",
                descendantPIDFile.path,
            ],
            currentDirectory: FileManager.default.temporaryDirectory.path,
            timeout: 0.5,
            stdoutLimit: 64,
            stderrLimit: 64
        )
        let elapsed = ContinuousClock.now - startedAt

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertLessThan(
            elapsed,
            .seconds(2),
            "timeout cleanup must terminate the owned process group and bound pipe-reader shutdown"
        )
        let pidText = try? String(contentsOf: descendantPIDFile, encoding: .utf8)
        let descendantPID = pidText.flatMap { pid_t($0) }
        XCTAssertNotNil(descendantPID)
        if let descendantPID {
            let goneDeadline = Date().addingTimeInterval(1)
            var descendantExists = true
            repeat {
                errno = 0
                descendantExists = kill(descendantPID, 0) == 0 || errno != ESRCH
                if descendantExists { usleep(10_000) }
            } while descendantExists && Date() < goneDeadline
            XCTAssertFalse(descendantExists, "the timed-out descendant must not survive process-group cleanup")
        }
    }
}
