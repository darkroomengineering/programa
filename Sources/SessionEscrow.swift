import Foundation
import Darwin
import Security
import Bonsplit

/// Issue #182 slice 1: escrow the PTY master fd dup to a small detached
/// "holder" process so terminal children survive Programa quitting or
/// crashing. See `docs/plans/detached-sessions.md` section 0 for the full
/// design ("escrow the dup, don't move the custody"). This file implements
/// ONLY the escrow half: dup+send the master fd once per surface, hold it
/// open in a process that outlives the app, and drain PTY output into the
/// session's existing WAL (`SessionWALStore`/`SessionWALPaths`) once app
/// death is detected. Issue #182 slice 2 adds the retrieval half on top of
/// this: a token-gated RPC (`EscrowWireFormat.retrieveRequestType`
/// /`retrieveResponseType`) that stops a session's drain thread, hands the
/// fd back to a NEW app instance over `SCM_RIGHTS`, and removes it from the
/// holder's registry so it can never be issued twice. See "Retrieval
/// protocol" and "Drain/retrieve coordination" below.
///
/// ## Holder process choice
/// Nothing is always-running in the normal desktop case --
/// `daemon/remote/cmd/programad-remote` only bootstraps for the SSH remote
/// workflow, it is not resident otherwise. Rather than add a second Xcode
/// target/binary (a new `PBXNativeTarget`, code signing, and an
/// embed-helper build phase -- out of scope for one slice), the holder is
/// the SAME app binary launched in a hidden mode:
/// `SessionEscrowHolder.runIfRequested()` is called at the very top of
/// `programaApp.init()`, before any AppKit/SwiftUI setup, mirroring the
/// existing `terminateForMissingLaunchTag()` early-exit precedent in that
/// same file. If the hidden-mode launch argument is present it runs the
/// holder server loop and never returns into SwiftUI. `SessionEscrowClient`
/// spawns this hidden-mode process detached (`posix_spawn` +
/// `POSIX_SPAWN_SETSID`) so it is reparented away from the app rather than
/// dying with it, the same way a classic double-forked daemon would be.
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` is set too: without it, `posix_spawn`
/// inherits every open fd (including every live surface's pty master)
/// into the holder by ordinary fd-inheritance the instant it's spawned --
/// which can accidentally keep a child alive with no session bookkeeping
/// on the holder side at all, masking whether the deliberate `SCM_RIGHTS`
/// protocol below ever actually completes. See
/// `SessionEscrowClient.spawnHolderIfNeeded`'s doc comment for the full
/// story (found via a real repro: the child survived a kill but `wal.log`
/// never grew and `meta.json` never got escrow fields -- exactly the
/// signature of an accidentally-inherited fd nobody is draining).
///
/// ## Escrow point
/// `TerminalSurface.attemptSessionEscrow(surface:surfaceId:childPID:)`
/// (called from `resolveSessionWALIdentity`, the same bounded retry loop
/// that already resolves `childPID`/`ptyPath` for `SessionWALStore`) reads
/// `ghostty_surface_pty_master_fd(surface)` and `dup()`s it once the child
/// PID is known -- both on the main actor, matching the existing sibling
/// accessor calls' cost class. The dup and the actual socket send are
/// deliberately split: only the cheap `dup()` syscall happens on main; the
/// send (which can block on socket I/O) is handed to
/// `SessionEscrowClient`'s own background queue immediately after.
///
/// ## Protocol
/// One persistent stream connection per app instance, opened lazily by
/// `SessionEscrowClient` on the first surface's escrow attempt and reused
/// for every later surface in the same run. Every message on the wire is a
/// fixed `EscrowWireFormat.frameSize` byte frame (a 1-byte type tag plus a
/// zero-padded fixed payload), sent via `sendmsg`/`recvmsg` (through the
/// `session_escrow_shim.c` C shim -- see `UnixDomainFDPassing`'s doc
/// comment for why) so an escrow frame's `SCM_RIGHTS` ancillary fd is
/// delivered atomically with it:
/// - Heartbeat frame: sent every `SessionEscrowPolicy.heartbeatInterval`,
///   no ancillary fd.
/// - Escrow frame: session id + random token + child pid, exactly one
///   ancillary fd (the dup'd master).
///
/// ## Death detection + drain
/// The holder's one read loop per connection sets `SO_RCVTIMEO`
/// (`SessionEscrowPolicy.recvTimeoutSeconds`) so it never blocks past that
/// bound. `recvmsg` returning EOF (fires as soon as the kernel closes every
/// fd the app process held -- essentially immediate on quit/crash) is
/// treated as app death immediately; a run of timeouts past
/// `SessionEscrowPolicy.heartbeatStaleAfter` since the last successfully
/// read frame is the backstop for the (harder to hit) case where the
/// process is wedged rather than exited. Both bounds are small constants,
/// satisfying "bound the detection". On death, every session escrowed on
/// that connection starts being drained on its own dedicated thread doing
/// blocking `read()` calls straight onto that session's `wal.log`, reusing
/// `SessionWALPaths`/`SessionWALPolicy` so the file and its rotation/cap
/// behavior are identical regardless of which process (app or holder)
/// wrote which byte range. Before death is detected the holder never reads
/// the escrowed fd at all -- ghostty is the only reader while the app is
/// alive, so escrow cannot race the terminal's own output or steal bytes
/// meant for the live display.
///
/// ## Token scheme
/// `SessionEscrowClient` generates one random 32-byte token per surface
/// (`SecRandomCopyBytes`) at escrow time and sends it to the holder
/// alongside the fd. The holder records it (keyed by session id, in
/// `SessionEscrowHolder.HeldSession.token`) and, since slice 2, checks it
/// (constant-time compare) on every retrieval request -- the fd is only
/// ever handed back over a connection that presents the exact token issued
/// at escrow time. The token is also written into the session's
/// `meta.json` (`SessionWALMeta.escrowToken`, via
/// `SessionWALStore.markEscrowed`) so the reattach path
/// (`Workspace+Persistence.swift`'s `createPanel(from:inPane:)`) has it to
/// present back to the holder.
///
/// ## Retrieval protocol (issue #182 slice 2)
/// One-shot, not part of the persistent heartbeat connection: the previous
/// app instance's connection died along with it, so `SessionEscrowClient
/// .retrieve(sessionId:tokenHex:socketPath:)` opens a brand new connection,
/// sends one `retrieveRequestType` frame (session id + token, same fixed
/// frame size as every other message on this wire), and reads back one
/// `retrieveResponseType` frame. On success that response frame carries the
/// live master fd as its `SCM_RIGHTS` ancillary data, same delivery
/// mechanism as the original escrow frame; on denial (unknown session,
/// token mismatch, or the child already exited) there is no ancillary fd
/// and the caller falls back to spawning a fresh shell. The holder removes
/// a session from its registry the instant it grants a retrieval, before it
/// even finishes sending the response, so two concurrent/retried requests
/// for the same session id can never both receive a live fd.
///
/// ## Drain/retrieve coordination
/// The risk retrieval has to close is a byte-offset race: the drain thread
/// (see "Death detection + drain" above) is mid-`read()` on the exact fd a
/// retrieval wants back, and closing or handing off that fd out from under
/// an in-flight read would either duplicate or drop bytes relative to what
/// the app's own frame+WAL-delta replay (`SessionWALStore
/// .readFrameAndDeltaScrollbackText`) believes it has already seen. Each
/// `HeldSession` carries a `stopRequested` flag (mutated only under
/// `SessionEscrowHolder.registryLock`) and a `DispatchSemaphore` the drain
/// thread signals exactly once, right after it stops. The drain loop itself
/// no longer blocks in a bare `read()`: it `poll()`s the fd first (bounded,
/// `SessionEscrowPolicy.drainPollIntervalMilliseconds`) so it can notice
/// `stopRequested` promptly even while the child is producing no output at
/// all, and only calls the actual (now effectively non-blocking, since
/// `poll` already confirmed readability) `read()` once data is pending --
/// this is the "bounded by one `drainReadBufferSize` read" a retrieval
/// waits out. A retrieval request sets `stopRequested`, blocks on the
/// semaphore (bounded by `SessionEscrowPolicy.retrieveDrainStopTimeout`),
/// and only sends the fd back once the drain thread has actually stopped
/// and flushed its last chunk to `wal.log` -- guaranteeing the app's replay
/// picks up at a byte offset with no gap and no duplicate. Per the
/// "Never close the escrowed fd" constraint, the fd itself is never closed
/// on this path: `HeldSession.markHandedOff()` just flags it as
/// transferred so `deinit`'s safety-net close never fires for it.
///
/// ## Degradation
/// Every step -- connect, spawn-if-missing, handshake send -- is
/// best-effort with bounded retries on a background queue. Any failure
/// just skips escrow for that one surface; it never throws into
/// `TerminalSurface.createSurface()`, never blocks opening a terminal, and
/// never surfaces a user-visible error. `SessionEscrowClient.escrow` always
/// closes the dup'd fd it was handed, on every exit path, so a failed
/// escrow never leaks the fd either.
enum SessionEscrowPolicy {
    static let heartbeatInterval: TimeInterval = 2.0
    static let heartbeatStaleAfter: TimeInterval = 6.0
    static let recvTimeoutSeconds: Int = 3
    /// The holder is a cold-launched copy of the full app binary (AppKit +
    /// SwiftUI + GhosttyKit all linked in), so dyld/Swift-runtime startup
    /// before it reaches `accept()` can comfortably take longer than a
    /// couple hundred milliseconds on a cold page cache. 24 attempts * 0.25s
    /// gives a ~6s total budget, generous enough to cover that without
    /// blocking anything user-facing (this loop runs entirely on
    /// `SessionEscrowClient`'s own background queue).
    static let connectRetryCount = 24
    static let connectRetryDelay: TimeInterval = 0.25
    static let drainReadBufferSize = 16 * 1024
    /// Issue #182 slice 2: how long `poll()` waits for the drain fd to
    /// become readable before looping back to re-check `stopRequested`.
    /// Bounds how quickly a retrieval's stop request is noticed when the
    /// child is producing no output at all -- see the file-level
    /// "Drain/retrieve coordination" doc comment.
    static let drainPollIntervalMilliseconds: Int32 = 250
    /// How long a retrieval request blocks waiting for the target session's
    /// drain thread to acknowledge `stopRequested` before giving up. Should
    /// comfortably exceed `drainPollIntervalMilliseconds` plus one bounded
    /// read; generous here just means a slow/rare case degrades to "treat
    /// as failed retrieval" rather than ever risking handing back an fd a
    /// drain thread might still be touching.
    static let retrieveDrainStopTimeout: TimeInterval = 3.0
    /// Bounds the app-side `SessionEscrowClient.retrieve` round trip
    /// end-to-end (connect is effectively immediate for local `AF_UNIX`,
    /// this mostly covers the holder's own `retrieveDrainStopTimeout`
    /// budget plus normal scheduling slop). Any timeout is treated as a
    /// plain retrieval failure -- the reattach path falls back to spawning
    /// fresh, never blocks restore indefinitely.
    static let retrieveRecvTimeoutSeconds: Int = 5
}

// MARK: - Wire format

/// Fixed-size frame format shared by every message on the escrow control
/// connection. Always exactly `frameSize` bytes so the read side never
/// needs to peek a length prefix -- see the file-level "Protocol" doc
/// comment.
enum EscrowWireFormat {
    static let sessionIdSize = 36 // UUID string, e.g. TerminalSurface.id.uuidString
    static let tokenSize = 32
    static let childPIDSize = 4
    static let payloadSize = sessionIdSize + tokenSize + childPIDSize
    static let frameSize = 1 + payloadSize

    static let heartbeatType: UInt8 = 0x01
    static let escrowType: UInt8 = 0x02
    /// Issue #182 slice 2: app -> holder, session id + token, no ancillary
    /// fd. See the file-level "Retrieval protocol" doc comment.
    static let retrieveRequestType: UInt8 = 0x03
    /// Issue #182 slice 2: holder -> app, session id + a one-byte
    /// granted/denied flag (packed into the childPID field's bytes, unused
    /// otherwise by this type). Carries the live master fd as `SCM_RIGHTS`
    /// ancillary data iff granted.
    static let retrieveResponseType: UInt8 = 0x04

    struct Decoded {
        let type: UInt8
        let sessionId: String?
        let token: [UInt8]?
        let childPID: Int32?
        /// Only meaningful when `type == retrieveResponseType`: whether the
        /// holder granted the retrieval. Unknown session, token mismatch,
        /// child already exited, and "not yet detected as dead" all decode
        /// to `false` here -- the wire deliberately never distinguishes
        /// why, only whether an fd follows.
        let retrieveGranted: Bool?
    }

    static func heartbeatFrame() -> Data {
        var data = Data(count: frameSize)
        data[0] = heartbeatType
        return data
    }

    static func encodeEscrowFrame(sessionId: String, token: [UInt8], childPID: Int32) -> Data? {
        guard sessionId.utf8.count == sessionIdSize, token.count == tokenSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(escrowType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(contentsOf: token)
        withUnsafeBytes(of: childPID.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func encodeRetrieveRequestFrame(sessionId: String, token: [UInt8]) -> Data? {
        guard sessionId.utf8.count == sessionIdSize, token.count == tokenSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(retrieveRequestType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(contentsOf: token)
        data.append(Data(count: childPIDSize)) // unused padding for this type
        return data
    }

    static func encodeRetrieveResponseFrame(sessionId: String, granted: Bool) -> Data? {
        guard sessionId.utf8.count == sessionIdSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(retrieveResponseType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(Data(count: tokenSize)) // unused padding for this type
        data.append(contentsOf: [granted ? 1 : 0, 0, 0, 0])
        return data
    }

    static func decode(_ data: Data) -> Decoded? {
        guard data.count == frameSize else { return nil }
        let bytes = [UInt8](data)
        let type = bytes[0]
        switch type {
        case escrowType, retrieveRequestType:
            var offset = 1
            let sessionIdBytes = Array(bytes[offset..<(offset + sessionIdSize)])
            offset += sessionIdSize
            let tokenBytes = Array(bytes[offset..<(offset + tokenSize)])
            offset += tokenSize
            let pidBytes = Array(bytes[offset..<(offset + childPIDSize)])
            guard let sessionId = String(bytes: sessionIdBytes, encoding: .utf8) else { return nil }
            let rawPID = pidBytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            let childPID: Int32? = type == escrowType ? Int32(littleEndian: rawPID) : nil
            return Decoded(type: type, sessionId: sessionId, token: tokenBytes, childPID: childPID, retrieveGranted: nil)
        case retrieveResponseType:
            let offset = 1 + sessionIdSize + tokenSize
            let sessionIdBytes = Array(bytes[1..<(1 + sessionIdSize)])
            guard let sessionId = String(bytes: sessionIdBytes, encoding: .utf8) else { return nil }
            let grantedByte = bytes[offset]
            return Decoded(type: type, sessionId: sessionId, token: nil, childPID: nil, retrieveGranted: grantedByte == 1)
        default:
            return Decoded(type: type, sessionId: nil, token: nil, childPID: nil, retrieveGranted: nil)
        }
    }
}

// MARK: - Raw Unix domain socket + SCM_RIGHTS primitives

/// Low-level `AF_UNIX` connect/listen helpers, plus `SCM_RIGHTS` fd passing
/// delegated to `session_escrow_shim.c` (declared in
/// `session_escrow_shim.h`, wired into this target via
/// `programa-Bridging-Header.h`).
///
/// The fd-passing send/receive used to be hand-rolled here in Swift,
/// manually computing the `cmsghdr` control-message layout since Darwin's
/// `<sys/socket.h>` `CMSG_*` macros are C preprocessor macros and aren't
/// importable into Swift. That version's `sendmsg` failed with `EINVAL` in
/// a real repro despite the byte-offset arithmetic matching the macros on
/// paper -- marshalling `msghdr`/`cmsghdr` by hand across several nested
/// `withUnsafe...` closures is exactly the kind of detail that's easy to
/// get subtly wrong in a way that's hard to diagnose without a debugger on
/// the actual kernel call. `session_escrow_shim.c` does the same job in
/// ~30 lines of plain C using the real `CMSG_*` macros, which is strictly
/// more reliable for this one piece; everything else (framing, session
/// bookkeeping, heartbeats, retry/backoff) stays in Swift.
enum UnixDomainFDPassing {
    enum ChunkResult {
        case data(Data, Int32?)
        case eof
        case timeout
        case error
    }

    /// Connects to `socketPath`, blocking (local `AF_UNIX` connects do not
    /// hang the way TCP connects can -- they fail immediately if nothing is
    /// listening, so no async/timeout machinery is needed here). Returns
    /// nil on any failure.
    static func connect(to socketPath: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = makeSockaddr(path: socketPath) else {
            close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Binds and listens on `socketPath`. Removes a stale socket file first
    /// (the caller is expected to have already confirmed nothing is
    /// listening there via a `connect` probe). Returns nil on any failure.
    static func bindListening(socketPath: String) -> Int32? {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var addr = makeSockaddr(path: socketPath) else {
            close(fd)
            return nil
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        chmod(socketPath, 0o600)
        return fd
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
            path.withCString { cstr in
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

// MARK: - App-side client

/// App-side singleton: owns the one persistent connection to the holder
/// for this app instance, lazily connecting (and spawning the holder if
/// nothing answers) on the first surface's escrow attempt. All socket I/O
/// is confined to `queue`, off-main. See the file-level doc comment for
/// the full protocol/degradation contract.
final class SessionEscrowClient {
    static let shared = SessionEscrowClient()

    /// Returned to the caller on a successful escrow so it can be recorded
    /// in `meta.json` (`SessionWALStore.markEscrowed`).
    struct Result {
        let tokenHex: String
        let socketPath: String
    }

    private let queue = DispatchQueue(label: "com.darkroom.programa.session-escrow-client", qos: .utility)
    private var connectionFD: Int32?
    private var heartbeatTimer: DispatchSourceTimer?
    private var escrowedSurfaceIds = Set<String>()
    private lazy var socketPath = Self.escrowSocketPath()

    private init() {}

    /// Escrows one surface's already-dup'd master fd. `dupedMasterFD` is
    /// ALWAYS closed by this method (success or failure) -- callers must
    /// not close it themselves and must not reuse it afterward. Calls
    /// `completion` with a `Result` on success, or nil on any failure
    /// (holder unreachable, spawn failed, send failed, etc). Never throws;
    /// always safe to call speculatively.
    func escrow(
        surfaceId: String,
        dupedMasterFD: Int32,
        childPID: Int32,
        completion: @escaping (Result?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                close(dupedMasterFD)
                completion(nil)
                return
            }
            defer { close(dupedMasterFD) }

            guard !self.escrowedSurfaceIds.contains(surfaceId) else {
                #if DEBUG
                dlog("session.escrow.client.skip surface=\(surfaceId.prefix(8)) reason=already_escrowed")
                #endif
                completion(nil)
                return
            }
            guard let fd = self.ensureConnection() else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=no_connection")
                #endif
                completion(nil)
                return
            }

            var token = [UInt8](repeating: 0, count: EscrowWireFormat.tokenSize)
            let randomStatus = token.withUnsafeMutableBytes { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return errSecParam }
                return SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
            }
            guard randomStatus == errSecSuccess,
                  let frame = EscrowWireFormat.encodeEscrowFrame(sessionId: surfaceId, token: token, childPID: childPID) else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=encode_or_random status=\(randomStatus)")
                #endif
                completion(nil)
                return
            }

            guard UnixDomainFDPassing.send(fd: dupedMasterFD, payload: frame, over: fd) else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=send errno=\(errno)")
                #endif
                self.teardownConnection()
                completion(nil)
                return
            }

            self.escrowedSurfaceIds.insert(surfaceId)
            let tokenHex = token.map { String(format: "%02x", $0) }.joined()
            #if DEBUG
            dlog("session.escrow.client.sent surface=\(surfaceId.prefix(8)) childPID=\(childPID) connFD=\(fd) masterFD=\(dupedMasterFD)")
            #endif
            completion(Result(tokenHex: tokenHex, socketPath: self.socketPath))
        }
    }

    /// `queue`-confined. Returns the existing connection if live, otherwise
    /// attempts to connect, spawning the holder once (on the first failed
    /// attempt only) if nothing answers. Bounded by
    /// `SessionEscrowPolicy.connectRetryCount` short retries; never
    /// blocks indefinitely.
    private func ensureConnection() -> Int32? {
        if let connectionFD { return connectionFD }
        var spawnedHolder = false
        for attempt in 0..<SessionEscrowPolicy.connectRetryCount {
            if let fd = UnixDomainFDPassing.connect(to: socketPath) {
                connectionFD = fd
                startHeartbeat(fd: fd)
                #if DEBUG
                dlog("session.escrow.client.connected attempt=\(attempt) socket=\(socketPath)")
                #endif
                return fd
            }
            if !spawnedHolder {
                spawnedHolder = true
                Self.spawnHolderIfNeeded(socketPath: socketPath)
            }
            if attempt < SessionEscrowPolicy.connectRetryCount - 1 {
                Thread.sleep(forTimeInterval: SessionEscrowPolicy.connectRetryDelay)
            }
        }
        #if DEBUG
        dlog("session.escrow.client.connect.exhausted attempts=\(SessionEscrowPolicy.connectRetryCount) socket=\(socketPath)")
        #endif
        return nil
    }

    private func startHeartbeat(fd: Int32) {
        heartbeatTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + SessionEscrowPolicy.heartbeatInterval,
            repeating: SessionEscrowPolicy.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self, let fd = self.connectionFD else { return }
            if !UnixDomainFDPassing.send(fd: nil, payload: EscrowWireFormat.heartbeatFrame(), over: fd) {
                self.teardownConnection()
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func teardownConnection() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if let connectionFD {
            close(connectionFD)
        }
        connectionFD = nil
        escrowedSurfaceIds.removeAll()
    }

    /// Derived from the app's own control-socket path
    /// (`SocketControlSettings.socketPath()`), which is already
    /// bundle-id/tag-scoped and already lives under `/tmp` specifically to
    /// stay well under `sockaddr_un.sun_path`'s ~104-byte limit -- see
    /// `SocketControlSettings.taggedDebugSocketPath`. Reusing that scoping
    /// means a tagged debug build and the production app (or two different
    /// tags) always get distinct holder sockets, matching the isolation
    /// the rest of the socket-path machinery already guarantees.
    private static func escrowSocketPath() -> String {
        let base = SocketControlSettings.socketPath()
        let baseURL = URL(fileURLWithPath: base)
        let name = baseURL.deletingPathExtension().lastPathComponent + "-escrow"
        return baseURL.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension("sock")
            .path
    }

    /// Spawns the holder detached (`posix_spawn` + `POSIX_SPAWN_SETSID`) so
    /// it is reparented away from this app process rather than dying with
    /// it -- the equivalent of a classic double-fork daemonize, but safe to
    /// call from a Cocoa app since `posix_spawn` avoids `fork()`'s
    /// multi-threaded-process hazards. Best-effort: any failure here just
    /// means `ensureConnection`'s remaining retries (and eventually the
    /// caller's degrade-silently path) run out.
    ///
    /// `argv` deliberately contains neither the socket path nor anything
    /// derived from the app's tag/bundle id/display name -- only
    /// `posix_spawn`'s `path` parameter (never shown by `ps`/`pkill -f`,
    /// which display argv, not the exec path) points at the real
    /// executable. This is a real, disclosed gap, not a full fix: the
    /// holder is still the identical on-disk binary, so a bare `pkill
    /// <processname>` (which matches the kernel's `p_comm`, derived from
    /// the executable file's own basename, not argv[0]) can still catch
    /// it. A name/pattern-based kill of "the app" should target the
    /// specific app PID rather than a broad name match if this matters --
    /// see this slice's hand-off notes.
    ///
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT` is load-bearing, not decoration:
    /// `posix_spawn` inherits every open fd from the caller into the child
    /// by default unless a fd is marked close-on-exec. Without this flag,
    /// the holder would accidentally inherit a raw, untracked copy of
    /// every open surface's pty master fd (and anything else this process
    /// has open) the instant it's spawned -- which would keep a child
    /// alive by sheer accident, completely bypassing the token-gated
    /// `SCM_RIGHTS` escrow protocol this file exists to implement, and
    /// with no session bookkeeping on the holder side to ever drain that
    /// accidental fd. This flag makes fd inheritance opt-in (nothing
    /// inherited unless explicitly added via `posix_spawn_file_actions_t`,
    /// which we only use for `/dev/null` on 0/1/2 below), forcing the
    /// escrow send to be the only way the holder ever gets a session's fd.
    private static func spawnHolderIfNeeded(socketPath: String) {
        guard let executablePath = Bundle.main.executablePath else { return }
        let argv = ["session-escrow-holder", SessionEscrowHolder.launchModeArgument]
        var environment = ProcessInfo.processInfo.environment
        environment[SessionEscrowHolder.socketPathEnvironmentKey] = socketPath
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        // With CLOEXEC_DEFAULT, fds 0/1/2 are closed too unless explicitly
        // reopened here -- standard daemonize hygiene, and cheap insurance
        // against any startup code path that assumes stdio exists.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 2, "/dev/null", O_WRONLY, 0)

        let spawnResult = withCStringArgv(argv) { argvPtr in
            withCStringArgv(envp) { envpPtr in
                executablePath.withCString { cPath in
                    posix_spawn(&pid, cPath, &fileActions, &attr, argvPtr, envpPtr)
                }
            }
        }
        #if DEBUG
        dlog("session.escrow.holder.spawn result=\(spawnResult) pid=\(pid)")
        #endif
    }

    /// Builds a NULL-terminated `char**` for `posix_spawn` from Swift
    /// strings, `strdup`-ing each entry and freeing them all after `body`
    /// returns. `body` must not retain the pointer past its own call.
    private static func withCStringArgv<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> R) -> R {
        var cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        cStrings.append(nil)
        defer {
            for pointer in cStrings where pointer != nil {
                free(pointer)
            }
        }
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress)
        }
    }
}

// MARK: - App-side retrieval (issue #182 slice 2)

extension SessionEscrowClient {
    /// One-shot fd retrieval for the reattach path
    /// (`Workspace+Persistence.swift`'s `createPanel(from:inPane:)`). Opens
    /// a FRESH connection to the holder's socket -- the previous app
    /// instance's persistent heartbeat connection died along with that
    /// instance, so `SessionEscrowClient.shared`'s connection state is
    /// irrelevant here; this never touches `shared` at all, and is safe to
    /// call before/without ever having escrowed anything from this process.
    /// Synchronous and launch-time only, matching `SessionWALStore
    /// .readFallbackScrollbackText`'s contract -- never call this from a
    /// keystroke-hot path. Bounded by `SessionEscrowPolicy
    /// .retrieveRecvTimeoutSeconds`; any failure (holder unreachable,
    /// unknown session, token mismatch, child already exited, timeout)
    /// returns nil so the caller can fall through to its existing
    /// spawn-fresh path unchanged.
    static func retrieve(sessionId: String, tokenHex: String, socketPath: String) -> Int32? {
        guard let token = decodeHexToken(tokenHex) else { return nil }
        guard let connectionFD = UnixDomainFDPassing.connect(to: socketPath) else {
            #if DEBUG
            dlog("session.escrow.retrieve.fail session=\(sessionId.prefix(8)) reason=no_connection")
            #endif
            return nil
        }
        defer { close(connectionFD) }

        var timeout = timeval(tv_sec: SessionEscrowPolicy.retrieveRecvTimeoutSeconds, tv_usec: 0)
        setsockopt(connectionFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let requestFrame = EscrowWireFormat.encodeRetrieveRequestFrame(sessionId: sessionId, token: token),
              UnixDomainFDPassing.send(fd: nil, payload: requestFrame, over: connectionFD) else {
            #if DEBUG
            dlog("session.escrow.retrieve.fail session=\(sessionId.prefix(8)) reason=send errno=\(errno)")
            #endif
            return nil
        }

        var collected = Data()
        var receivedFD: Int32?
        while collected.count < EscrowWireFormat.frameSize {
            switch UnixDomainFDPassing.receiveChunk(maxBytes: EscrowWireFormat.frameSize - collected.count, from: connectionFD) {
            case .data(let chunk, let chunkFD):
                guard !chunk.isEmpty else {
                    if let chunkFD { close(chunkFD) }
                    #if DEBUG
                    dlog("session.escrow.retrieve.fail session=\(sessionId.prefix(8)) reason=empty_chunk")
                    #endif
                    return nil
                }
                collected.append(chunk)
                if receivedFD == nil { receivedFD = chunkFD }
            case .eof, .error, .timeout:
                if let receivedFD { close(receivedFD) }
                #if DEBUG
                dlog("session.escrow.retrieve.fail session=\(sessionId.prefix(8)) reason=recv")
                #endif
                return nil
            }
        }

        guard let decoded = EscrowWireFormat.decode(collected),
              decoded.type == EscrowWireFormat.retrieveResponseType,
              decoded.sessionId == sessionId,
              decoded.retrieveGranted == true,
              let receivedFD else {
            if let receivedFD { close(receivedFD) }
            #if DEBUG
            dlog("session.escrow.retrieve.denied session=\(sessionId.prefix(8))")
            #endif
            return nil
        }
        #if DEBUG
        dlog("session.escrow.retrieve.granted session=\(sessionId.prefix(8)) fd=\(receivedFD)")
        #endif
        return receivedFD
    }

    private static func decodeHexToken(_ hex: String) -> [UInt8]? {
        guard hex.count == EscrowWireFormat.tokenSize * 2 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(EscrowWireFormat.tokenSize)
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

// MARK: - Holder process

/// The escrow holder server loop, run in-process when the app binary is
/// relaunched with `launchModeArgument`. See the file-level "Holder
/// process choice" doc comment for why this is the same binary rather than
/// a separate target.
enum SessionEscrowHolder {
    static let launchModeArgument = "--session-escrow-holder"
    /// The socket path travels via environment variable, not argv -- see
    /// `SessionEscrowClient.spawnHolderIfNeeded`'s doc comment for why
    /// (keeps the holder's `ps`/`pkill -f`-visible command line free of
    /// any tag/bundle-id/socket-path substring).
    static let socketPathEnvironmentKey = "PROGRAMA_SESSION_ESCROW_HOLDER_SOCKET"

    /// Process-wide record of one escrowed session's fd + capability token,
    /// kept alive independent of which connection registered it. This MUST
    /// be global (not scoped to one `serve(connectionFD:)` call, as it was
    /// pre-slice-2): a retrieval always arrives on a brand new connection
    /// opened by a NEW app instance, after the connection that originally
    /// escrowed the session has already died -- so a connection-local dict
    /// would simply never see it. See the file-level "Retrieval protocol"
    /// doc comment.
    private final class HeldSession {
        let sessionId: String
        let fd: Int32
        let token: [UInt8]
        let childPID: Int32
        /// True once a drain thread has been started for this session
        /// (app death detected). A retrieval is only ever granted for a
        /// session that is actively draining -- if this is still false the
        /// escrowing app might still be alive, and handing back the fd
        /// would risk two readers on the same pty master.
        var isDraining = false
        /// Set (under `SessionEscrowHolder.registryLock`) to ask an active
        /// drain thread to stop after its next bounded read/poll cycle.
        var stopRequested = false
        /// Signaled by the drain thread exactly once, right after it has
        /// actually stopped and flushed its last chunk. A retrieval blocks
        /// on this (bounded by `SessionEscrowPolicy.retrieveDrainStopTimeout`)
        /// before it is safe to hand the fd back.
        let drainStoppedSemaphore = DispatchSemaphore(value: 0)
        private var closed = false

        init(sessionId: String, fd: Int32, token: [UInt8], childPID: Int32) {
            self.sessionId = sessionId
            self.fd = fd
            self.token = token
            self.childPID = childPID
        }

        /// Closes `fd` exactly once, however this session's life ends
        /// (dedup replacement, genuine end-of-stream, or the `deinit`
        /// safety net below). Callers other than `deinit` must hold
        /// `SessionEscrowHolder.registryLock`.
        func markClosedIfNeeded() {
            guard !closed else { return }
            closed = true
            close(fd)
        }

        /// Marks the fd as handed off to a caller (sent via `SCM_RIGHTS`)
        /// so `deinit`'s safety net never double-closes it. Callers must
        /// hold `SessionEscrowHolder.registryLock`.
        func markHandedOff() {
            closed = true
        }

        deinit {
            // Last-resort safety net only -- every normal exit path above
            // already calls `markClosedIfNeeded()`/`markHandedOff()`
            // explicitly. `close` on an fd this object no longer considers
            // open is a fd-reuse hazard, hence the `closed` guard.
            if !closed {
                close(fd)
            }
        }
    }

    /// Guards `registry` and every `HeldSession`'s mutable fields
    /// (`isDraining`, `stopRequested`, `closed`). Held only very briefly
    /// (dictionary lookups/mutations, flag flips) -- never across a
    /// blocking syscall.
    private static let registryLock = NSLock()
    private static var registry: [String: HeldSession] = [:]

    private enum FrameReadResult {
        case data(Data, Int32?)
        case eof
        case timeout
    }

    /// Checked at the very top of `programaApp.init()`, before any
    /// AppKit/SwiftUI setup. Never returns if the holder-mode argument is
    /// present and `socketPathEnvironmentKey` is set; otherwise a no-op so
    /// normal app launches are unaffected.
    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard arguments.contains(launchModeArgument),
              let socketPath = environment[socketPathEnvironmentKey],
              !socketPath.isEmpty else { return }
        run(socketPath: socketPath)
    }

    private static func run(socketPath: String) -> Never {
        guard bindOrDetectExistingHolder(socketPath: socketPath) == false else {
            // Another holder is already live at this path (this process
            // lost a spawn race, or was spawned redundantly by a second
            // surface before the first holder was reachable) -- exit
            // quietly, nothing to do.
            #if DEBUG
            dlog("session.escrow.holder.run redundant socket=\(socketPath)")
            #endif
            Darwin.exit(0)
        }
        guard let listenFD = UnixDomainFDPassing.bindListening(socketPath: socketPath) else {
            #if DEBUG
            dlog("session.escrow.holder.run bind_failed socket=\(socketPath)")
            #endif
            Darwin.exit(0)
        }
        #if DEBUG
        dlog("session.escrow.holder.run listening socket=\(socketPath)")
        #endif
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continue }
            #if DEBUG
            dlog("session.escrow.holder.accept connFD=\(clientFD)")
            #endif
            Thread.detachNewThread {
                serve(connectionFD: clientFD)
            }
        }
    }

    /// Returns true if a holder is already listening at `socketPath` (this
    /// process should exit rather than bind). Never binds itself; the
    /// caller does that separately once this returns false.
    private static func bindOrDetectExistingHolder(socketPath: String) -> Bool {
        guard let probeFD = UnixDomainFDPassing.connect(to: socketPath) else { return false }
        close(probeFD)
        return true
    }

    /// One dedicated thread per accepted connection. Two shapes of
    /// connection use this same loop: the long-lived per-app-instance
    /// heartbeat/escrow connection (reads fixed-size frames until EOF or a
    /// bounded run of `SO_RCVTIMEO` timeouts without a heartbeat, then
    /// starts draining every session escrowed on THIS connection), and a
    /// short-lived one-shot retrieval connection (`SessionEscrowClient
    /// .retrieve` sends one `retrieveRequestType` frame, reads the
    /// response, and closes -- which this loop sees as an ordinary EOF with
    /// no locally-registered sessions to drain).
    private static func serve(connectionFD: Int32) {
        var timeout = timeval(tv_sec: SessionEscrowPolicy.recvTimeoutSeconds, tv_usec: 0)
        setsockopt(connectionFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var registeredSessionIds: Set<String> = []
        var lastActivity = Date()

        readLoop: while true {
            switch readFrame(connectionFD: connectionFD) {
            case .eof:
                #if DEBUG
                dlog("session.escrow.holder.death connFD=\(connectionFD) reason=eof sessions=\(registeredSessionIds.count)")
                #endif
                break readLoop
            case .timeout:
                if Date().timeIntervalSince(lastActivity) >= SessionEscrowPolicy.heartbeatStaleAfter {
                    #if DEBUG
                    dlog("session.escrow.holder.death connFD=\(connectionFD) reason=heartbeat_stale sessions=\(registeredSessionIds.count)")
                    #endif
                    break readLoop
                }
            case .data(let payload, let fd):
                lastActivity = Date()
                guard let decoded = EscrowWireFormat.decode(payload) else {
                    #if DEBUG
                    dlog("session.escrow.holder.frame.decode_failed connFD=\(connectionFD) bytes=\(payload.count) hasFD=\(fd != nil)")
                    #endif
                    if let fd { close(fd) }
                    continue
                }
                switch decoded.type {
                case EscrowWireFormat.escrowType:
                    guard let sessionId = decoded.sessionId,
                          let token = decoded.token,
                          let childPID = decoded.childPID,
                          let fd else {
                        if let fd { close(fd) }
                        continue
                    }
                    registerSession(sessionId: sessionId, fd: fd, token: token, childPID: childPID)
                    registeredSessionIds.insert(sessionId)
                    #if DEBUG
                    dlog("session.escrow.holder.registered session=\(sessionId.prefix(8)) childPID=\(childPID) fd=\(fd) tokenLen=\(token.count)")
                    #endif
                case EscrowWireFormat.heartbeatType:
                    // Expected steady-state traffic, no log spam.
                    break
                case EscrowWireFormat.retrieveRequestType:
                    // A retrieve request never carries an ancillary fd --
                    // never leak one if a caller sent it anyway.
                    if let fd { close(fd) }
                    guard let sessionId = decoded.sessionId, let token = decoded.token else { continue }
                    handleRetrieveRequest(connectionFD: connectionFD, sessionId: sessionId, token: token)
                default:
                    if let fd {
                        // Stray/unexpected ancillary fd on a frame type
                        // that shouldn't carry one -- never leak it.
                        #if DEBUG
                        dlog("session.escrow.holder.frame.unexpected connFD=\(connectionFD) type=\(decoded.type)")
                        #endif
                        close(fd)
                    }
                }
            }
        }

        close(connectionFD)
        if !registeredSessionIds.isEmpty {
            beginDraining(sessionIds: Array(registeredSessionIds))
        }
    }

    /// Inserts a newly escrowed session into the global registry. If a
    /// session with the same id already exists and is NOT currently
    /// draining, it's replaced (never leaking its older fd) -- matching the
    /// original single-connection dedup behavior, now global. If it IS
    /// currently draining, the new fd is refused (closed immediately)
    /// rather than risk closing an fd an active drain thread is still
    /// reading; this would require a colliding session id across two
    /// distinct processes, which should not happen in practice (session
    /// ids are UUIDs).
    private static func registerSession(sessionId: String, fd: Int32, token: [UInt8], childPID: Int32) {
        registryLock.lock()
        if let existing = registry[sessionId] {
            guard !existing.isDraining else {
                registryLock.unlock()
                close(fd)
                return
            }
            registry.removeValue(forKey: sessionId)
            existing.markClosedIfNeeded()
        }
        registry[sessionId] = HeldSession(sessionId: sessionId, fd: fd, token: token, childPID: childPID)
        registryLock.unlock()
    }

    /// Starts one drain thread per id that's registered and not already
    /// draining. Called once a connection's read loop ends (see `serve`);
    /// a no-op for any id already being drained by a prior death on a
    /// different connection (shouldn't happen given one connection per
    /// session id in practice, but harmless either way) or already removed
    /// from the registry (e.g. retrieved by a fast-racing second launch
    /// before this connection's death was even detected).
    private static func beginDraining(sessionIds: [String]) {
        for sessionId in sessionIds {
            registryLock.lock()
            guard let session = registry[sessionId], !session.isDraining else {
                registryLock.unlock()
                continue
            }
            session.isDraining = true
            registryLock.unlock()
            Thread.detachNewThread {
                drain(session: session)
            }
        }
    }

    /// Issue #182 slice 2: handles one `retrieveRequestType` frame. Denies
    /// (sends `granted: false`, no fd) for any unknown session id, a token
    /// mismatch, or a session not yet actively draining (the escrowing app
    /// might still be alive). On a match, removes the session from the
    /// registry immediately -- before even asking the drain thread to stop
    /// -- so a concurrent or retried request for the same id can never be
    /// granted twice, then coordinates the drain/retrieve race per the
    /// file-level "Drain/retrieve coordination" doc comment before finally
    /// sending the fd back over `connectionFD`.
    private static func handleRetrieveRequest(connectionFD: Int32, sessionId: String, token: [UInt8]) {
        registryLock.lock()
        guard let session = registry[sessionId] else {
            registryLock.unlock()
            #if DEBUG
            dlog("session.escrow.holder.retrieve.deny session=\(sessionId.prefix(8)) reason=unknown")
            #endif
            sendRetrieveResponse(granted: false, sessionId: sessionId, fd: nil, over: connectionFD)
            return
        }
        guard constantTimeTokensEqual(session.token, token) else {
            registryLock.unlock()
            #if DEBUG
            dlog("session.escrow.holder.retrieve.deny session=\(sessionId.prefix(8)) reason=token_mismatch")
            #endif
            sendRetrieveResponse(granted: false, sessionId: sessionId, fd: nil, over: connectionFD)
            return
        }
        guard session.isDraining else {
            registryLock.unlock()
            #if DEBUG
            dlog("session.escrow.holder.retrieve.deny session=\(sessionId.prefix(8)) reason=not_draining")
            #endif
            sendRetrieveResponse(granted: false, sessionId: sessionId, fd: nil, over: connectionFD)
            return
        }
        // Remove immediately: no second caller can ever observe this
        // session id in the registry again, regardless of how the rest of
        // this function turns out.
        registry.removeValue(forKey: sessionId)
        session.stopRequested = true
        registryLock.unlock()

        let stopped = session.drainStoppedSemaphore.wait(timeout: .now() + SessionEscrowPolicy.retrieveDrainStopTimeout) == .success
        guard stopped else {
            // The drain thread never acknowledged in time. Do not hand back
            // an fd that thread might still be touching -- deny. (The
            // drain thread will still observe `stopRequested` on its own
            // very next poll cycle and stop/signal regardless of whether
            // anyone is still waiting; a signal with no waiter is harmless.
            // This session is simply no longer retrievable once removed
            // above -- an acceptable best-effort degradation, never a
            // correctness risk.)
            #if DEBUG
            dlog("session.escrow.holder.retrieve.deny session=\(sessionId.prefix(8)) reason=drain_stop_timeout")
            #endif
            sendRetrieveResponse(granted: false, sessionId: sessionId, fd: nil, over: connectionFD)
            return
        }

        registryLock.lock()
        session.markHandedOff()
        registryLock.unlock()
        #if DEBUG
        dlog("session.escrow.holder.retrieve.grant session=\(sessionId.prefix(8)) fd=\(session.fd)")
        #endif
        sendRetrieveResponse(granted: true, sessionId: sessionId, fd: session.fd, over: connectionFD)
    }

    private static func sendRetrieveResponse(granted: Bool, sessionId: String, fd: Int32?, over connectionFD: Int32) {
        guard let frame = EscrowWireFormat.encodeRetrieveResponseFrame(sessionId: sessionId, granted: granted) else { return }
        _ = UnixDomainFDPassing.send(fd: granted ? fd : nil, payload: frame, over: connectionFD)
    }

    /// Fixed-length, no-early-exit byte compare so a token check's timing
    /// doesn't leak how many leading bytes matched. `EscrowWireFormat
    /// .tokenSize` is a small (32-byte) constant, so the extra fixed work
    /// here is negligible.
    private static func constantTimeTokensEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    /// Reads exactly `EscrowWireFormat.frameSize` bytes, looping over
    /// possibly-short `recvmsg` reads (stream sockets do not guarantee
    /// message boundaries) while preserving whichever partial read carried
    /// the ancillary fd, if any.
    private static func readFrame(connectionFD: Int32) -> FrameReadResult {
        var collected = Data()
        var capturedFD: Int32?
        while collected.count < EscrowWireFormat.frameSize {
            switch UnixDomainFDPassing.receiveChunk(maxBytes: EscrowWireFormat.frameSize - collected.count, from: connectionFD) {
            case .data(let chunk, let fd):
                guard !chunk.isEmpty else { return .eof }
                collected.append(chunk)
                if capturedFD == nil { capturedFD = fd }
            case .eof, .error:
                return .eof
            case .timeout:
                if collected.isEmpty { return .timeout }
                // Mid-frame timeout with partial bytes already buffered:
                // keep waiting for the rest: the outer loop's
                // `heartbeatStaleAfter` bound (measured from the last
                // *completed* frame) still applies as the overall backstop.
                continue
            }
        }
        return .data(collected, capturedFD)
    }

    /// Drains one escrowed session's master fd into its `wal.log`, reusing
    /// `SessionWALPaths`/`SessionWALPolicy` so the file this writes is
    /// exactly the same file (same path, same rotation cap) the app's own
    /// `SessionWALStore` was writing before it died. Runs on a dedicated
    /// thread -- this process has no rendering/latency constraints, unlike
    /// the app -- but no longer blocks in a bare `read()`: it `poll()`s
    /// first (bounded, `SessionEscrowPolicy.drainPollIntervalMilliseconds`)
    /// so `session.stopRequested` (set by a retrieval, see
    /// `handleRetrieveRequest`) is noticed promptly even while the child is
    /// producing no output. See the file-level "Drain/retrieve
    /// coordination" doc comment for the full contract. Unlike the
    /// pre-slice-2 version, this method does NOT unconditionally close
    /// `session.fd` on every exit path -- only on a genuine end-of-stream
    /// (the child truly exited). Stopping for a retrieval must leave the fd
    /// open and untouched so it can be handed back; closing it here would
    /// SIGHUP the child.
    private static func drain(session: HeldSession) {
        guard let paths = SessionWALPaths.make(sessionId: session.sessionId) else {
            #if DEBUG
            dlog("session.escrow.holder.drain.fail session=\(session.sessionId.prefix(8)) reason=no_paths")
            #endif
            endDraining(session: session, stoppedForRetrieve: false)
            return
        }
        try? FileManager.default.createDirectory(at: paths.sessionDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: paths.walURL.path) {
            FileManager.default.createFile(atPath: paths.walURL.path, contents: nil)
        }
        guard var handle = try? FileHandle(forWritingTo: paths.walURL) else {
            #if DEBUG
            dlog("session.escrow.holder.drain.fail session=\(session.sessionId.prefix(8)) reason=no_handle path=\(paths.walURL.path)")
            #endif
            endDraining(session: session, stoppedForRetrieve: false)
            return
        }
        handle.seekToEndOfFile()
        var currentSize = (try? FileManager.default.attributesOfItem(atPath: paths.walURL.path))
            .flatMap { $0[.size] as? Int64 } ?? 0
        var totalDrained: Int64 = 0

        // ghostty runs its own event loop against this fd with O_NONBLOCK
        // set, and that flag lives on the shared open file description --
        // not the fd number -- so the dup we escrowed inherited it too.
        // The holder owns this fd exclusively once the app is dead (ghostty
        // is gone), so it's safe and correct to clear O_NONBLOCK here and
        // let read() block until data or real EOF, instead of busy-looping
        // or (worse) treating an EAGAIN as end-of-stream and closing the
        // last reference to the master -- which is exactly what delivers
        // SIGHUP to the child. Best-effort: if fcntl somehow fails, the
        // read loop below still never treats EAGAIN as EOF, just retries.
        let currentFlags = fcntl(session.fd, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = fcntl(session.fd, F_SETFL, currentFlags & ~O_NONBLOCK)
        }
        #if DEBUG
        dlog("session.escrow.holder.drain.start session=\(session.sessionId.prefix(8)) fd=\(session.fd) walPath=\(paths.walURL.path) startSize=\(currentSize) clearedNonblock=\(currentFlags >= 0)")
        #endif

        var buffer = [UInt8](repeating: 0, count: SessionEscrowPolicy.drainReadBufferSize)
        var stoppedForRetrieve = false
        readLoop: while true {
            if isStopRequested(session) {
                stoppedForRetrieve = true
                break readLoop
            }

            // poll() first, bounded, so a retrieval's `stopRequested` is
            // noticed within one poll interval even when the child is
            // producing no output at all -- never block indefinitely in a
            // bare `read()`. See the file-level "Drain/retrieve
            // coordination" doc comment.
            var pfd = pollfd(fd: session.fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&pfd, 1, SessionEscrowPolicy.drainPollIntervalMilliseconds)
            if pollResult < 0 {
                let pollErrno = errno
                if pollErrno == EINTR { continue readLoop }
                #if DEBUG
                dlog("session.escrow.holder.drain.end session=\(session.sessionId.prefix(8)) reason=poll_error errno=\(pollErrno) totalDrained=\(totalDrained)")
                #endif
                break readLoop
            }
            guard pollResult > 0 else {
                // Timed out with nothing readable -- loop back to
                // re-check `stopRequested` rather than blocking further.
                continue readLoop
            }

            // Readable (or POLLHUP/POLLERR signaled, which `read` below
            // will resolve into either real data, EOF, or an error) --
            // this read is now effectively non-blocking, satisfying the
            // "bounded by one drainReadBufferSize read" contract a
            // retrieval waits out.
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                read(session.fd, raw.baseAddress, raw.count)
            }
            if n < 0 {
                let readErrno = errno
                // EAGAIN/EWOULDBLOCK means "no data right now", not EOF --
                // this should no longer occur now that O_NONBLOCK is
                // cleared above, but if that fcntl silently failed for any
                // reason, treat it as "keep waiting", never as a reason to
                // close the fd. EINTR is a plain retry. Anything else is a
                // genuine, unrecoverable error on this fd -- stop.
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK || readErrno == EINTR {
                    continue readLoop
                }
                #if DEBUG
                dlog("session.escrow.holder.drain.end session=\(session.sessionId.prefix(8)) reason=error errno=\(readErrno) totalDrained=\(totalDrained)")
                #endif
                break readLoop
            }
            guard n > 0 else {
                // n == 0: the slave side has no more writers (the child
                // exited and nothing else holds the pty open) -- true EOF,
                // the only case where ending the drain and closing the fd
                // is correct.
                #if DEBUG
                dlog("session.escrow.holder.drain.end session=\(session.sessionId.prefix(8)) reason=eof totalDrained=\(totalDrained)")
                #endif
                break readLoop
            }
            let chunk = Data(buffer.prefix(n))

            if currentSize + Int64(chunk.count) > SessionWALPolicy.walCapBytes {
                handle.closeFile()
                try? FileManager.default.removeItem(at: paths.walRotatedURL)
                try? FileManager.default.moveItem(at: paths.walURL, to: paths.walRotatedURL)
                FileManager.default.createFile(atPath: paths.walURL.path, contents: nil)
                guard let rotatedHandle = try? FileHandle(forWritingTo: paths.walURL) else { break }
                handle = rotatedHandle
                currentSize = 0
            }

            handle.write(chunk)
            handle.synchronizeFile()
            currentSize += Int64(chunk.count)
            totalDrained += Int64(chunk.count)
            #if DEBUG
            dlog("session.escrow.holder.drain.chunk session=\(session.sessionId.prefix(8)) bytes=\(chunk.count) totalDrained=\(totalDrained)")
            #endif

            // Check again right after finishing this chunk so a retrieval
            // that arrived mid-read doesn't wait a full extra poll cycle.
            if isStopRequested(session) {
                stoppedForRetrieve = true
                break readLoop
            }
        }
        handle.closeFile()
        endDraining(session: session, stoppedForRetrieve: stoppedForRetrieve)
    }

    private static func isStopRequested(_ session: HeldSession) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return session.stopRequested
    }

    /// Common drain exit bookkeeping. `stoppedForRetrieve: true` means a
    /// retrieval asked this thread to stop -- the fd must be left open and
    /// untouched (`handleRetrieveRequest` is the one waiting on
    /// `drainStoppedSemaphore` and owns what happens to the fd next).
    /// `stoppedForRetrieve: false` means a genuine end-of-stream/error/setup
    /// failure -- the child is gone (or this session was never usable), so
    /// this IS the final close, and the session is removed from the
    /// registry so a stray later retrieve cleanly denies instead of
    /// finding a stale entry.
    private static func endDraining(session: HeldSession, stoppedForRetrieve: Bool) {
        if stoppedForRetrieve {
            session.drainStoppedSemaphore.signal()
            return
        }
        registryLock.lock()
        session.markClosedIfNeeded()
        registry.removeValue(forKey: session.sessionId)
        registryLock.unlock()
    }
}
