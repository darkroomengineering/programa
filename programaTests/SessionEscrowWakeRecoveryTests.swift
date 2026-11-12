import XCTest

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// Regression coverage for the sleep/wake escrow bug: the holder used to
/// measure heartbeat staleness with `Date()` (wall clock), so any system
/// sleep longer than `SessionEscrowPolicy.heartbeatStaleAfter` made it
/// declare every escrowed PTY dead the instant the Mac woke back up -- the
/// app was suspended too, so no heartbeat could possibly have arrived
/// during the sleep window either. The fix moved the comparison onto
/// `ProcessInfo.systemUptime` (pauses across sleep). These tests exercise
/// the factored-out comparison directly (an executable seam,
/// `SessionEscrowPolicy.isConnectionStale`), not the real socket read loop,
/// which needs a live holder process to drive.
final class SessionEscrowWakeRecoveryTests: XCTestCase {
    func testDisconnectedNonProductionHolderExpiresAtIdleLimit() {
        let limit = SessionEscrowPolicy.nonProductionDisconnectedExitAfter
        XCTAssertFalse(SessionEscrowPolicy.shouldExitDisconnectedHolder(
            disconnectedFor: limit - 0.01, isNonProduction: true
        ))
        XCTAssertTrue(SessionEscrowPolicy.shouldExitDisconnectedHolder(
            disconnectedFor: limit, isNonProduction: true
        ))
        XCTAssertFalse(SessionEscrowPolicy.shouldExitDisconnectedHolder(
            disconnectedFor: limit * 100, isNonProduction: false
        ))
    }

    func testHolderBuildKindUsesDebugBuildOrTaggedSmokeSocket() {
        XCTAssertTrue(SessionEscrowPolicy.isNonProductionHolder(
            isDebugBuild: true, socketPath: "/tmp/programa-escrow-v2.sock"
        ))
        for name in ["programa-debug-escrow-v2.sock", "programa-debug-inc-830-a-escrow-v2.sock", "programa-smoke-ci-escrow-v2.sock"] {
            XCTAssertTrue(SessionEscrowPolicy.isNonProductionHolder(
                isDebugBuild: false, socketPath: "/private/tmp/\(name)"
            ))
        }
        for name in ["programa-escrow-v2.sock", "programa-501-escrow-v2.sock", "programa-staging-escrow-v2.sock"] {
            XCTAssertFalse(SessionEscrowPolicy.isNonProductionHolder(
                isDebugBuild: false, socketPath: "/private/tmp/\(name)"
            ))
        }
    }

    /// A long *wall-clock* gap that only reflects elapsed sleep time must
    /// NOT be seen as staleness once measured on the sleep-pausing clock:
    /// the two systemUptime readings here are only 1s apart, standing in
    /// for "the machine was asleep for hours, but awake for only 1s since
    /// the last heartbeat."
    func testGapThatOnlyReflectsSleepIsNotStale() {
        let lastActivity: TimeInterval = 1_000
        let now: TimeInterval = 1_001 // 1s of *awake* time elapsed.
        XCTAssertFalse(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now),
            "a 1s awake gap must never be treated as a dead connection"
        )
    }

    /// A genuine gap while the machine stayed awake (no heartbeat arrived,
    /// nothing to blame on sleep) must still be caught -- this is the
    /// backstop `heartbeatStaleAfter` exists for in the first place, and
    /// the fix must not have weakened it.
    func testGenuineAwakeGapIsStillStale() {
        let lastActivity: TimeInterval = 1_000
        let now: TimeInterval = 1_000 + SessionEscrowPolicy.heartbeatStaleAfter + 1
        XCTAssertTrue(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now),
            "a genuine awake gap past heartbeatStaleAfter must still be detected as dead"
        )
    }

    func testExactBoundaryIsStale() {
        let lastActivity: TimeInterval = 500
        let now: TimeInterval = 500 + SessionEscrowPolicy.heartbeatStaleAfter
        XCTAssertTrue(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now)
        )
    }

    func testJustBelowBoundaryIsNotStale() {
        let lastActivity: TimeInterval = 500
        let now: TimeInterval = 500 + SessionEscrowPolicy.heartbeatStaleAfter - 0.01
        XCTAssertFalse(
            SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now)
        )
    }
}

/// INC-1031: when the escrow holder dies while the app keeps running, a
/// replacement holder must receive every still-open pane's pty master again.
/// Driven through an injected transport: each "holder" is the far end of a
/// socketpair that the test reads and answers.
final class SessionEscrowHolderLossResendTests: XCTestCase {
    private final class Harness {
        private let lock = NSLock()
        private var pendingClientFDs: [Int32]
        private var resendRequests: [Set<String>] = []
        weak var client: SessionEscrowClient?
        var liveMasterFDs: [String: Int32] = [:]
        var resentCompletion: ((SessionEscrowClient.Result?) -> Void)?

        init(clientFDs: [Int32]) { pendingClientFDs = clientFDs }

        func nextClientFD() -> Int32? {
            lock.lock(); defer { lock.unlock() }
            return pendingClientFDs.isEmpty ? nil : pendingClientFDs.removeFirst()
        }

        func closeUnusedClientFDs() {
            lock.lock(); defer { lock.unlock() }
            pendingClientFDs.forEach { close($0) }
            pendingClientFDs.removeAll()
        }

        var requests: [Set<String>] {
            lock.lock(); defer { lock.unlock() }
            return resendRequests
        }

        /// Stands in for the app's surface registry: re-escrows a fresh dup of
        /// each still-live master, as a real surface would.
        func resend(_ surfaceIds: Set<String>) {
            lock.lock()
            resendRequests.append(surfaceIds)
            let masters = liveMasterFDs
            lock.unlock()
            for surfaceId in surfaceIds.sorted() {
                guard let master = masters[surfaceId], let client else { continue }
                client.escrow(surfaceId: surfaceId, dupedMasterFD: dup(master), childPID: getpid()) { [weak self] result in
                    self?.resentCompletion?(result)
                }
            }
        }
    }

    private var testOwnedFDs: [Int32] = []

    override func tearDown() {
        testOwnedFDs.forEach { close($0) }
        testOwnedFDs.removeAll()
        super.tearDown()
    }

    private func makeSocketPair() throws -> (client: Int32, holder: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw XCTSkip("socketpair unavailable") }
        fds.forEach { UnixDomainFDPassing.suppressSigPipe(on: $0) }
        return (fds[0], fds[1])
    }

    /// Reads one whole frame from the fake holder's end and closes any fd it
    /// carried. Nil on timeout or EOF.
    private func readFrame(from fd: Int32, timeout: TimeInterval) -> (frame: EscrowWireFormat.Decoded, carriedFD: Bool)? {
        let whole = timeout.rounded(.down)
        var receiveTimeout = timeval(tv_sec: Int(whole), tv_usec: suseconds_t((timeout - whole) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var collected = Data()
        var carriedFD = false
        while collected.count < EscrowWireFormat.frameSize {
            guard case .data(let chunk, let received) = UnixDomainFDPassing.receiveChunk(
                maxBytes: EscrowWireFormat.frameSize - collected.count, from: fd
            ) else { return nil }
            if let received { close(received); carriedFD = true }
            guard !chunk.isEmpty else { return nil }
            collected.append(chunk)
        }
        guard let decoded = EscrowWireFormat.decode(collected) else { return nil }
        return (decoded, carriedFD)
    }

    private func acknowledge(_ sessionId: String, over fd: Int32) throws {
        var reply = try XCTUnwrap(EscrowWireFormat.encodeRetrieveResponseFrame(sessionId: sessionId, granted: true))
        reply[0] = EscrowWireFormat.escrowAcknowledgementType
        XCTAssertTrue(UnixDomainFDPassing.send(fd: nil, payload: reply, over: fd))
    }

    /// Escrows one session and answers it from the fake holder, as a live
    /// holder would.
    private func escrowAndAcknowledge(
        _ client: SessionEscrowClient, surfaceId: String, master: Int32, holder: Int32
    ) throws {
        let done = expectation(description: "escrow \(surfaceId.prefix(8))")
        var result: SessionEscrowClient.Result?
        client.escrow(surfaceId: surfaceId, dupedMasterFD: dup(master), childPID: getpid()) {
            result = $0
            done.fulfill()
        }
        let received = try XCTUnwrap(readFrame(from: holder, timeout: 2))
        XCTAssertEqual(received.frame.sessionId, surfaceId)
        XCTAssertTrue(received.carriedFD)
        try acknowledge(surfaceId, over: holder)
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(result)
    }

    func testReplacementHolderReceivesLiveMastersButNotReleasedOnes() throws {
        let first = try makeSocketPair()
        let second = try makeSocketPair()
        testOwnedFDs += [first.holder, second.holder]
        var master: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&master), 0)
        testOwnedFDs += master

        let harness = Harness(clientFDs: [first.client, second.client])
        defer { harness.closeUnusedClientFDs() }
        let client = SessionEscrowClient(
            isEnabled: true,
            heartbeatInterval: 3600,
            socketPath: { "/nonexistent/inc-1031-escrow.sock" },
            connectToHolder: { _ in harness.nextClientFD() },
            resendLiveSessions: { harness.resend($0) }
        )
        harness.client = client

        let livePane = UUID().uuidString
        let closedPane = UUID().uuidString
        harness.liveMasterFDs = [livePane: master[0], closedPane: master[0]]
        try escrowAndAcknowledge(client, surfaceId: livePane, master: master[0], holder: first.holder)
        try escrowAndAcknowledge(client, surfaceId: closedPane, master: master[0], holder: first.holder)

        client.release(surfaceId: closedPane)
        let release = try XCTUnwrap(readFrame(from: first.holder, timeout: 2))
        XCTAssertEqual(release.frame.type, EscrowWireFormat.releaseType)
        XCTAssertEqual(release.frame.sessionId, closedPane)

        // The holder dies; the heartbeat a wake forces finds it gone.
        close(first.holder)
        testOwnedFDs.removeAll { $0 == first.holder }
        let resent = expectation(description: "live pane re-escrowed")
        var resentResult: SessionEscrowClient.Result?
        harness.resentCompletion = {
            resentResult = $0
            resent.fulfill()
        }
        client.notifySystemDidWake()

        let received = try XCTUnwrap(
            readFrame(from: second.holder, timeout: 2),
            "A replacement holder must receive the still-open pane's master"
        )
        XCTAssertEqual(received.frame.sessionId, livePane)
        XCTAssertTrue(received.carriedFD)
        try acknowledge(livePane, over: second.holder)
        wait(for: [resent], timeout: 5)
        XCTAssertNotNil(resentResult)

        XCTAssertEqual(harness.requests, [[livePane]], "A pane released before the loss must not be re-escrowed")
        XCTAssertNil(readFrame(from: second.holder, timeout: 0.2), "Nothing else may reach the replacement holder")
    }
}
