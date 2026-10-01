import XCTest
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Session escrow / WAL fix cluster (SESS-03, 04, 05, 06, 07, 09). SESS-01 lives in
/// `EscrowFDPassingRegressionTests`. SESS-11 needs a live Ghostty surface and has no seam
/// reachable from a unit test, so it is not exercised here.
final class EscrowFixSweepSESSTests: XCTestCase {
    // MARK: SESS-03 drain fault policy

    func testWalAppendFailureKeepsDrainingWithoutCapture() {
        // A full disk must never SIGHUP the escrowed child: nil means "keep draining".
        XCTAssertNil(SessionEscrowHolder.drainOutcome(for: .walAppendFailed))
    }

    func testPollFailureKeepsMasterRetrievable() {
        XCTAssertEqual(SessionEscrowHolder.drainOutcome(for: .pollFailed), .keepMaster)
    }

    func testMasterReadFailureAndEndOfStreamCloseMaster() {
        XCTAssertEqual(SessionEscrowHolder.drainOutcome(for: .readFailed), .closeMaster)
        XCTAssertEqual(SessionEscrowHolder.drainOutcome(for: .endOfStream), .closeMaster)
    }

    // MARK: SESS-04 stale heartbeat

    func testLivePeerPIDDoesNotDrainOnStaleHeartbeat() {
        XCTAssertFalse(SessionEscrowPolicy.shouldDrainOnStaleHeartbeat(peerPID: getpid()))
    }

    func testDeadPeerPIDDrainsOnStaleHeartbeat() {
        XCTAssertTrue(SessionEscrowPolicy.shouldDrainOnStaleHeartbeat(peerPID: 4242) { _ in (-1, ESRCH) })
    }

    func testUnprobeablePeerPIDDoesNotDrainOnStaleHeartbeat() {
        // EPERM: the process exists but belongs to someone else, so it is alive.
        XCTAssertFalse(SessionEscrowPolicy.shouldDrainOnStaleHeartbeat(peerPID: 4242) { _ in (-1, EPERM) })
    }

    func testUnknownPeerPIDDrainsOnStaleHeartbeat() {
        XCTAssertTrue(SessionEscrowPolicy.shouldDrainOnStaleHeartbeat(peerPID: nil) { _ in
            XCTFail("no probe without a pid")
            return (0, 0)
        })
    }

    // MARK: SESS-05 peer credential

    func testPeerIsCurrentUserOnSocketPair() {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { for fd in fds where fd >= 0 { close(fd) } }
        XCTAssertTrue(UnixDomainFDPassing.peerIsCurrentUser(fds[0]))
        XCTAssertTrue(UnixDomainFDPassing.peerIsCurrentUser(fds[1]))
    }

    // MARK: SESS-06 retrieve decision and token comparison

    func testRetrieveDecisionOrder() {
        XCTAssertEqual(HolderRetrieveDecision.decide(sessionExists: false, tokenMatches: true, isDraining: true), .deny(.unknownSession))
        XCTAssertEqual(HolderRetrieveDecision.decide(sessionExists: false, tokenMatches: false, isDraining: false), .deny(.unknownSession))
        XCTAssertEqual(HolderRetrieveDecision.decide(sessionExists: true, tokenMatches: false, isDraining: true), .deny(.tokenMismatch))
        XCTAssertEqual(HolderRetrieveDecision.decide(sessionExists: true, tokenMatches: true, isDraining: false), .deny(.notDraining))
        XCTAssertEqual(HolderRetrieveDecision.decide(sessionExists: true, tokenMatches: true, isDraining: true), .grant)
    }

    func testConstantTimeTokenComparison() {
        let token = [UInt8](repeating: 7, count: 32)
        var other = token
        other[31] ^= 1
        XCTAssertTrue(SessionEscrowHolder.constantTimeTokensEqual(token, token))
        XCTAssertFalse(SessionEscrowHolder.constantTimeTokensEqual(token, other))
        XCTAssertFalse(SessionEscrowHolder.constantTimeTokensEqual(token, Array(token.dropLast())))
        XCTAssertFalse(SessionEscrowHolder.constantTimeTokensEqual([], token))
    }

    // MARK: SESS-07 legacy scan tolerates a corrupt meta.json

    func testLegacySessionsSkipsUnreadableMetaAndReturnsValidOne() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sess07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = "/tmp/programa-sess07-\(UUID().uuidString.prefix(8)).sock"
        let validId = UUID().uuidString
        let garbageId = UUID().uuidString
        let validDir = root.appendingPathComponent(validId, isDirectory: true)
        let garbageDir = root.appendingPathComponent(garbageId, isDirectory: true)
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: garbageDir, withIntermediateDirectories: true)

        var meta = SessionWALMeta(sessionId: validId, lastHeartbeatAt: Date())
        meta.escrowed = true
        meta.escrowSocketPath = socketPath
        meta.escrowToken = String(repeating: "cd", count: 32)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: SessionWALPaths(sessionDirectory: validDir).metaURL)
        try Data("{ not json".utf8).write(to: SessionWALPaths(sessionDirectory: garbageDir).metaURL)

        let found = try SessionEscrowClient.legacySessions(root: root, legacySocketPath: socketPath)
        XCTAssertEqual(found.map(\.sessionId), [validId])
    }

    // MARK: SESS-09 history rotation is scoped to the rotating bundle

    func testRotationPrunesOnlyOwnBundleArchives() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sess09-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("session-com.test.a.json")
        try Data("{\"live\":true}".utf8).write(to: live)
        let history = try XCTUnwrap(SessionPersistenceStore.historyDirectoryURL(fileURL: live))
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)

        let bundleA = "com.test.a"
        let bundleB = "com.test.b-debug"
        // B's archives are the oldest on disk: a global prune would evict them first.
        var bFiles: [String] = []
        for i in 0..<6 {
            let name = String(format: "20200101-0000%02d-%@.json", i, bundleB)
            bFiles.append(name)
            try Data("b\(i)".utf8).write(to: history.appendingPathComponent(name))
        }
        for i in 0..<11 {
            let name = String(format: "20240101-0000%02d-%@.json", i, bundleA)
            try Data("a\(i)".utf8).write(to: history.appendingPathComponent(name))
        }

        XCTAssertTrue(SessionPersistenceStore.rotateIntoHistory(
            fileURL: live, maxHistoryEntries: 10, bundleIdentifier: bundleA
        ))

        for name in bFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: history.appendingPathComponent(name).path),
                "rotation for \(bundleA) deleted \(name) owned by \(bundleB)"
            )
        }
        let owned = SessionPersistenceStore.ownedHistoryFileURLs(fileURL: live, bundleIdentifier: bundleA)
        XCTAssertEqual(owned.count, 10)
        XCTAssertTrue(owned.allSatisfy { $0.lastPathComponent.hasSuffix("-\(bundleA).json") })
        let all = SessionPersistenceStore.historyFileURLs(fileURL: live)
        XCTAssertEqual(all.filter { $0.lastPathComponent.hasSuffix("-\(bundleB).json") }.count, 6)
    }
}
