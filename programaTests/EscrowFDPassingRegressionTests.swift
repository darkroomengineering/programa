import XCTest
import Darwin

#if canImport(Programa_DEV)
@testable import Programa_DEV
#elseif canImport(Programa)
@testable import Programa
#endif

/// SESS-01: a PTY master fd received over the escrow socket, or duplicated from the retained
/// registry, must be close-on-exec (a concurrent fork/exec must not inherit the master), and a
/// peer that attaches several fds must not leak the extras into this process.
///
/// Every test closes every fd it opens. The sender side of a socketpair stays open until the
/// receive has completed (closing it right after sendmsg can hand the receiver a defunct fd
/// under load).
final class EscrowFDPassingRegressionTests: XCTestCase {
    private var openedFDs: [Int32] = []

    override func tearDown() {
        for fd in openedFDs where fcntl(fd, F_GETFD) != -1 { close(fd) }
        openedFDs.removeAll()
        super.tearDown()
    }

    private func track(_ fd: Int32) -> Int32 {
        openedFDs.append(fd)
        return fd
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        guard fds[0] >= 0, fds[1] >= 0 else { throw XCTSkip("socketpair unavailable") }
        return (track(fds[0]), track(fds[1]))
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        guard fds[0] >= 0, fds[1] >= 0 else { throw XCTSkip("pipe unavailable") }
        return (track(fds[0]), track(fds[1]))
    }

    /// Bounded probe, never lsof.
    private func openFDCount(limit: Int32 = 1024) -> Int {
        (0..<limit).filter { fcntl($0, F_GETFD) != -1 }.count
    }

    private func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags != -1 && (flags & FD_CLOEXEC) != 0
    }

    /// One sendmsg carrying every fd in `fds` as a single SCM_RIGHTS message.
    private func sendRaw(fds: [Int32], payload: [UInt8], over socketFD: Int32) -> Bool {
        var payload = payload
        return payload.withUnsafeMutableBytes { raw -> Bool in
            var iov = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            let space = CMSG_SPACE_COMPAT(fds.count * MemoryLayout<Int32>.size)
            var control = [UInt8](repeating: 0, count: space)
            return control.withUnsafeMutableBytes { controlRaw -> Bool in
                var msg = msghdr()
                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                msg.msg_iovlen = 1
                msg.msg_control = controlRaw.baseAddress
                msg.msg_controllen = socklen_t(space)
                let cmsg = controlRaw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                cmsg.pointee.cmsg_level = SOL_SOCKET
                cmsg.pointee.cmsg_type = SCM_RIGHTS
                cmsg.pointee.cmsg_len = socklen_t(CMSG_LEN_COMPAT(fds.count * MemoryLayout<Int32>.size))
                let dataPtr = controlRaw.baseAddress!.advanced(by: CMSG_LEN_COMPAT(0))
                fds.withUnsafeBytes { dataPtr.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                return sendmsg(socketFD, &msg, 0) == raw.count
            }
        }
    }

    private func CMSG_LEN_COMPAT(_ length: Int) -> Int { 12 + length }
    private func CMSG_SPACE_COMPAT(_ length: Int) -> Int { 12 + ((length + 3) & ~3) }

    func testReceivedDescriptorIsCloseOnExec() throws {
        let (sender, receiver) = try makeSocketPair()
        let pipeEnds = try makePipe()
        XCTAssertTrue(UnixDomainFDPassing.send(fd: pipeEnds.read, payload: Data([0x01]), over: sender))
        guard case .data(let bytes, let received?) = UnixDomainFDPassing.receiveChunk(maxBytes: 8, from: receiver) else {
            return XCTFail("expected one byte with an attached fd")
        }
        _ = track(received)
        XCTAssertEqual(bytes, Data([0x01]))
        XCTAssertTrue(isCloseOnExec(received), "a received PTY master must not be inherited by a concurrent exec")
    }

    func testRetainedDescriptorDuplicateIsCloseOnExec() throws {
        let pipeEnds = try makePipe()
        // Ownership of the read end moves to the registry; releaseAfterOwnershipTransfer closes it.
        let master = fcntl(pipeEnds.read, F_DUPFD, 0)
        XCTAssertGreaterThanOrEqual(master, 0)
        let owner = SessionEscrowRetainedDescriptor.retain(
            sessionId: UUID().uuidString, masterFD: master, childPID: 0,
            tokenHex: String(repeating: "ab", count: 32), socketPath: "/tmp/programa-sess01-unused.sock",
            recoveryPending: false
        )
        defer { owner.releaseAfterOwnershipTransfer() }
        guard let copy = owner.duplicate() else { return XCTFail("duplicate returned nil") }
        _ = track(copy)
        XCTAssertNotEqual(copy, master)
        XCTAssertTrue(isCloseOnExec(copy), "the duplicate handed to a holder must not leak into spawned children")
    }

    func testPeerAttachingTwoDescriptorsLeaksNeitherExtra() throws {
        let (sender, receiver) = try makeSocketPair()
        let a = try makePipe()
        let b = try makePipe()
        XCTAssertTrue(sendRaw(fds: [a.read, b.read], payload: [0x02], over: sender))

        let before = openFDCount()
        let result = UnixDomainFDPassing.receiveChunk(maxBytes: 8, from: receiver)
        let after = openFDCount()

        guard case .data(_, let received?) = result else {
            // A refused frame is also acceptable, but nothing may have leaked.
            XCTAssertEqual(after, before, "a rejected two-fd message must not leave fds installed")
            return
        }
        _ = track(received)
        XCTAssertEqual(after - before, 1, "exactly one received fd may remain open")
        XCTAssertTrue(isCloseOnExec(received))
    }
}
