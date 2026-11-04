import Foundation
import Darwin
import Security
import Bonsplit

// MARK: - Raw Unix domain socket + SCM_RIGHTS primitives

/// Low-level `AF_UNIX` connect/listen helpers, plus `SCM_RIGHTS` fd passing
/// delegated to `session_escrow_shim.c` (declared in
/// `session_escrow_shim.h`, wired into this target via
/// `programa-Bridging-Header.h`).
///
/// Darwin's `<sys/socket.h>` `CMSG_*` macros are C preprocessor macros and aren't
/// importable into Swift, so marshalling `msghdr`/`cmsghdr` by hand across several
/// nested `withUnsafe...` closures is easy to get subtly wrong (a hand-rolled
/// `sendmsg` failed with `EINVAL` despite byte offsets matching the macros on
/// paper) and hard to diagnose without a debugger on the actual kernel call.
/// `session_escrow_shim.c` does the same job in
/// ~30 lines of plain C using the real `CMSG_*` macros, which is strictly
/// more reliable for this one piece; everything else (framing, session
/// bookkeeping, heartbeats, retry/backoff) stays in Swift.
enum UnixDomainFDPassing {
    enum ConnectionProbeResult {
        case live(Int32)
        case stale
        case missing
        case indeterminate(Int32)
    }

    enum ChunkResult {
        case data(Data, Int32?)
        case eof
        case timeout
        case error
    }

    /// Probes `socketPath` without collapsing a definitely stale listener
    /// into setup failures that must preserve the incumbent socket inode.
    static func probeConnection(to socketPath: String) -> ConnectionProbeResult {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .indeterminate(errno) }
        guard setCloseOnExec(on: fd) else {
            let probeErrno = errno
            close(fd)
            return .indeterminate(probeErrno)
        }
        suppressSigPipe(on: fd)
        guard var addr = makeSockaddr(path: socketPath) else {
            close(fd)
            return .indeterminate(ENAMETOOLONG)
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let connectErrno = errno
            close(fd)
            switch connectErrno {
            case ECONNREFUSED:
                return .stale
            case ENOENT:
                return .missing
            default:
                return .indeterminate(connectErrno)
            }
        }
        // A listener owned by another uid (a planted socket in a shared
        // directory) must never receive a PTY master or a retrieve token.
        guard peerIsCurrentUser(fd) else {
            close(fd)
            return .indeterminate(EPERM)
        }
        return .live(fd)
    }

    /// Whether the process on the other end of the connected `fd` runs as
    /// this process's effective uid. False when `getpeereid` fails.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }

    /// The peer's pid (`LOCAL_PEERPID`) captured at connect time, or nil
    /// when the kernel does not report one.
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return nil }
        return pid
    }

    /// Compatibility wrapper for callers that only need a connected fd.
    static func connect(to socketPath: String) -> Int32? {
        guard case .live(let fd) = probeConnection(to: socketPath) else { return nil }
        return fd
    }

    /// Sets `SO_NOSIGPIPE` on `fd` so a write/send to a peer that has
    /// already hung up returns `EPIPE` instead of raising `SIGPIPE` on this
    /// process. Belt-and-suspenders alongside the holder's process-wide
    /// `signal(SIGPIPE, SIG_IGN)` (see `SessionEscrowHolder.run`'s doc
    /// comment) -- applied here, at every socket's creation, so it covers
    /// the app-side client sockets too (which do not install a process-wide
    /// ignore) and so it is never accidentally missed on one fd while a
    /// future change adds another socket path. Best-effort: failure here
    /// just means the process-wide ignore (holder side) or the caller's own
    /// error handling (client side, which already treats a failed `send` as
    /// an ordinary degrade-and-retry case) is what protects against SIGPIPE
    /// instead. Mirrors the established pattern in
    /// `TerminalController.probeSocketCommand`.
    /// Marks `fd` close-on-exec so children spawned by this process never
    /// inherit an escrow control socket. This is load-bearing for death
    /// detection, not hygiene: ghostty's shell children outlive the app by
    /// design, so an inherited connection fd keeps the holder's read loop
    /// from ever seeing EOF after the app exits, silently degrading death
    /// detection from "immediate" to the `heartbeatStaleAfter` backstop.
    /// That blind window is exactly what the 2026-08-10 mass-drain's
    /// relaunch raced into (retrieve denied `not_draining`, all sessions
    /// drained 4s later). Darwin has no SOCK_CLOEXEC, so the flag is set
    /// immediately after `socket()` -- the theoretical fork-between-the-two
    /// window is accepted and unavoidable on this platform. Returns false
    /// on `fcntl` failure (EBADF-class, should never happen on a fresh
    /// socket) so callers can refuse to use the fd rather than silently
    /// reintroduce the leaked-fd race this flag exists to close.
    static func setCloseOnExec(on fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0
    }

    static func suppressSigPipe(on fd: Int32) {
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    /// Binds and listens on `socketPath` under a cross-process election lock. A live listener
    /// is never unlinked: on `EADDRINUSE`, the winner is probed while the lock is held, and only
    /// a socket inode owned by this user that no longer accepts connections is removed.
    static func bindListening(
        socketPath: String,
        connectionProbe: (String) -> ConnectionProbeResult = probeConnection(to:)
    ) -> Int32? {
        let electionPath = socketPath + ".election"
        let electionFD = electionPath.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard electionFD >= 0 else { return nil }
        defer { close(electionFD) }

        var electionStat = stat()
        guard fstat(electionFD, &electionStat) == 0,
              electionStat.st_uid == geteuid(),
              (electionStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              flock(electionFD, LOCK_EX) == 0 else {
            return nil
        }
        defer { _ = flock(electionFD, LOCK_UN) }
        _ = fchmod(electionFD, S_IRUSR | S_IWUSR)

        if let fd = bindListeningWithoutUnlink(socketPath: socketPath) {
            return fd
        }
        guard errno == EADDRINUSE else { return nil }

        switch connectionProbe(socketPath) {
        case .live(let existingFD):
            close(existingFD)
            return nil
        case .stale:
            guard removeStaleSocketOwnedByCurrentUser(socketPath) else { return nil }
        case .missing:
            break
        case .indeterminate:
            return nil
        }
        return bindListeningWithoutUnlink(socketPath: socketPath)
    }

    private static func bindListeningWithoutUnlink(socketPath: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard setCloseOnExec(on: fd) else {
            close(fd)
            return nil
        }
        suppressSigPipe(on: fd)
        guard var addr = makeSockaddr(path: socketPath) else {
            close(fd)
            return nil
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let bindErrno = errno
            close(fd)
            errno = bindErrno
            return nil
        }
        guard listen(fd, 16) == 0 else {
            let listenErrno = errno
            close(fd)
            unlink(socketPath)
            errno = listenErrno
            return nil
        }
        guard chmod(socketPath, 0o600) == 0 else {
            close(fd)
            unlink(socketPath)
            return nil
        }
        return fd
    }

    private static func removeStaleSocketOwnedByCurrentUser(_ socketPath: String) -> Bool {
        var socketStat = stat()
        guard lstat(socketPath, &socketStat) == 0 else {
            return errno == ENOENT
        }
        guard socketStat.st_uid == geteuid(),
              (socketStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            return false
        }
        return unlink(socketPath) == 0 || errno == ENOENT
    }

    private static func makeSockaddr(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxPathLen else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPath in
            guard let base = rawPath.baseAddress else { return }
            memset(base, 0, rawPath.count)
            _ = path.withCString { cstr in
                memcpy(base, cstr, path.utf8.count)
            }
        }
        return addr
    }

    /// Sends exactly `payload.count` bytes in one `sendmsg` call (via the
    /// C shim), with `fd` attached as `SCM_RIGHTS` ancillary data if
    /// non-nil. Returns false on any short write or error; never
    /// partial-writes silently.
    static func send(fd: Int32?, payload: Data, over socketFD: Int32) -> Bool {
        var mutablePayload = payload
        return mutablePayload.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let base = rawBuffer.baseAddress else { return false }
            let sent = session_escrow_send(socketFD, fd ?? -1, base, rawBuffer.count)
            return sent == rawBuffer.count
        }
    }

    /// Receives up to `maxBytes` in one `recvmsg` call (via the C shim;
    /// may be a short read -- callers that need exactly N bytes must loop,
    /// see `SessionEscrowHolder.readFrame`). Distinguishes EOF, a
    /// `SO_RCVTIMEO` timeout, and a hard error so callers can bound their
    /// own retry/dead-man logic.
    static func receiveChunk(maxBytes: Int, from socketFD: Int32) -> ChunkResult {
        guard maxBytes > 0 else { return .data(Data(), nil) }
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        var receivedFD: Int32 = -1
        var savedErrno: Int32 = 0
        let n = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return -1 }
            let result = session_escrow_recv(socketFD, base, rawBuffer.count, &receivedFD)
            savedErrno = errno
            return result
        }
        if n < 0 {
            return (savedErrno == EAGAIN || savedErrno == EWOULDBLOCK) ? .timeout : .error
        }
        if n == 0 { return .eof }
        return .data(Data(buffer.prefix(n)), receivedFD >= 0 ? receivedFD : nil)
    }
}
