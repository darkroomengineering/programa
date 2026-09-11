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
/// Nothing is always-running in the normal desktop case. Rather than add a second Xcode
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
/// picks up at a byte offset with no gap and no duplicate. After a
/// successful send, `HeldSession.markHandedOff()` closes the holder's fd:
/// `SCM_RIGHTS` gives the recipient its own descriptor, which keeps the PTY
/// alive. A failed send retains the holder's fd so draining can resume.
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
    /// end-to-end. Unlike the other generous timeouts in this file, the
    /// generosity argument inverts here: `retrieve` runs SYNCHRONOUSLY on
    /// the main thread during session restore, once per escrowed panel,
    /// serially -- a present-but-unresponsive holder stalls launch by this
    /// entire duration, per panel. The holder is a local same-machine
    /// `AF_UNIX` socket that answers in microseconds when healthy, so this
    /// budget only ever gets spent on a genuinely dead/wedged holder; the
    /// cost of a false miss is just falling back to the scrollback-replay
    /// restore, not data loss.
    ///
    /// INVARIANT: this MUST exceed `retrieveDrainStopTimeout` plus margin.
    /// `handleRetrieveRequest` can legitimately take up to
    /// `retrieveDrainStopTimeout` to stop a session's drain thread before
    /// it ever sends a response -- if the client's own recv timeout were
    /// shorter (or too close), the client would abandon and close its
    /// socket while the holder is still doing correct, in-progress work,
    /// and the eventual send would either land in a closed connection
    /// (kernel drops the queued `SCM_RIGHTS` fd -- the session is silently
    /// lost) or, without `SO_NOSIGPIPE`/`SIG_IGN`, raise `SIGPIPE` and kill
    /// the holder outright, dropping every OTHER escrowed session it still
    /// holds too. A real relaunch hit exactly this: holder finishes in
    /// (0.5s, 3.0s], client had already timed out and closed. Serial
    /// main-thread restore means the only cost of this bound being large is
    /// added latency on a genuinely dead holder (once, not per panel worth
    /// avoiding) -- a dead holder costing 5s once is a far better trade than
    /// a live-but-slow holder costing the session.
    static let retrieveRecvTimeout: TimeInterval = 5.0
    /// How long a draining (app-is-gone) session waits to be reclaimed
    /// before the holder gives up and closes its pty master. Elapsed time
    /// alone cannot prove abandonment -- a machine that sleeps mid-relaunch,
    /// or a user who quits and reopens much later, can legitimately exceed
    /// 10 minutes, and a false expiry silently destroys a session someone
    /// wanted (SIGHUP to the shell; only scrollback survives via the
    /// fallback restore). One hour keeps the leak bounded while making
    /// false retirement implausible for real relaunch flows. The durable
    /// fix is explicit claim/renew reconciliation between app and holder,
    /// not a timer -- tracked separately; this TTL is a stopgap until then.
    static let unclaimedSessionTTL: TimeInterval = 3600
    /// 2026-08-10 mass-drain fix (retrieve-before-drain race): how long a
    /// relaunched app keeps retrying a retrieve the holder denied only
    /// because it has not yet detected the previous instance's death
    /// (`not_draining`). Must comfortably exceed `heartbeatStaleAfter` --
    /// the holder's slowest death-detection path -- so the drain is
    /// guaranteed to have started (making the retry grantable) before the
    /// retry window closes. The deadline is anchored once per process
    /// (`SessionEscrowClient.sharedDenyRetryDeadline`), not per session, so
    /// a serial restore of N panels stalls launch by at most one window
    /// total, never N of them.
    static let retrieveDenyRetryWindow: TimeInterval = 8.0
    /// Sleep between retries inside the window above. Small enough that the
    /// common case (EOF-driven death detection, now guaranteed by
    /// close-on-exec on the escrow sockets) grants on the first or second
    /// retry; large enough not to hammer the holder.
    static let retrieveDenyRetryInterval: TimeInterval = 0.25
    /// How often the holder sweeps for expired sessions.
    static let reaperInterval: TimeInterval = 30
    /// How long the holder waits, with an empty registry and no live
    /// connections, before exiting.
    static let idleExitGrace: TimeInterval = 30
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
    /// App -> holder: this session was closed by the user for real, so drop
    /// it instead of holding its pty master open. Session id + token, no
    /// ancillary fd, no response.
    ///
    /// Without this the holder has no way to learn that a session ended: it
    /// holds a dup of the pty master, so freeing the app-side surface never
    /// hangs up the terminal and the shell (with whatever agent is running
    /// in it) survives. A session closed while the app keeps running is not
    /// even covered by `unclaimedSessionTTL`, which only applies once a
    /// session is draining -- so it would be held until the holder exits.
    ///
    /// Only sent past the close-undo grace period (see
    /// `ClosedTerminalUndoStore`), never on app quit: quitting must keep
    /// escrowing so the next launch can reattach.
    ///
    /// Holders that predate this frame fall into `serve`'s `default` branch,
    /// which logs and skips, degrading to the previous behavior.
    static let releaseType: UInt8 = 0x05
    static let acknowledgedEscrowType: UInt8 = 0x06
    static let escrowAcknowledgementType: UInt8 = 0x07
    static let acknowledgedReleaseType: UInt8 = 0x08

    /// Why the holder denied a retrieve. Carried in the FIRST byte of the
    /// response frame's otherwise-unused 32-byte token padding
    /// (`retrieveDenyReasonOffset`), so pre-reason holders -- which
    /// zero-pad that region -- decode as `.unspecified` and the frame size
    /// never changes. This matters across an app UPDATE specifically: the
    /// holder outlives the app, so a new client routinely talks to a holder
    /// built from the previous version. `notDraining` is the only reason a
    /// rightful successor should retry (the holder resolves it on its own
    /// within `heartbeatStaleAfter`); every other reason is permanent.
    enum RetrieveDenyReason: UInt8 {
        case unspecified = 0
        case unknownSession = 1
        case tokenMismatch = 2
        case notDraining = 3
        case drainStopTimeout = 4
    }
    static let retrieveDenyReasonOffset = 1 + sessionIdSize

    struct Decoded {
        let type: UInt8
        let sessionId: String?
        let token: [UInt8]?
        let childPID: Int32?
        /// Only meaningful when `type == retrieveResponseType`: whether the
        /// holder granted the retrieval.
        let retrieveGranted: Bool?
        /// Only meaningful when `type == retrieveResponseType` and
        /// `retrieveGranted == false`. `.unspecified` for frames from
        /// pre-reason holders (zero padding) and for reason bytes this
        /// build does not know.
        let retrieveDenyReason: RetrieveDenyReason?
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

    static func encodeReleaseFrame(sessionId: String, token: [UInt8]) -> Data? {
        guard sessionId.utf8.count == sessionIdSize, token.count == tokenSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(releaseType)
        data.append(contentsOf: Array(sessionId.utf8))
        data.append(contentsOf: token)
        data.append(Data(count: childPIDSize)) // unused padding for this type
        return data
    }

    static func encodeRetrieveResponseFrame(
        sessionId: String,
        granted: Bool,
        denyReason: RetrieveDenyReason = .unspecified
    ) -> Data? {
        guard sessionId.utf8.count == sessionIdSize else { return nil }
        var data = Data(capacity: frameSize)
        data.append(retrieveResponseType)
        data.append(contentsOf: Array(sessionId.utf8))
        var padding = Data(count: tokenSize) // unused by pre-reason decoders
        padding[0] = granted ? 0 : denyReason.rawValue
        data.append(padding)
        data.append(contentsOf: [granted ? 1 : 0, 0, 0, 0])
        return data
    }

    static func decode(_ data: Data) -> Decoded? {
        guard data.count == frameSize else { return nil }
        let bytes = [UInt8](data)
        let type = bytes[0]
        switch type {
        case escrowType, acknowledgedEscrowType, retrieveRequestType, releaseType, acknowledgedReleaseType:
            var offset = 1
            let sessionIdBytes = Array(bytes[offset..<(offset + sessionIdSize)])
            offset += sessionIdSize
            let tokenBytes = Array(bytes[offset..<(offset + tokenSize)])
            offset += tokenSize
            let pidBytes = Array(bytes[offset..<(offset + childPIDSize)])
            guard let sessionId = String(bytes: sessionIdBytes, encoding: .utf8) else { return nil }
            let rawPID = pidBytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            let childPID: Int32? = (type == escrowType || type == acknowledgedEscrowType) ? Int32(littleEndian: rawPID) : nil
            return Decoded(type: type, sessionId: sessionId, token: tokenBytes, childPID: childPID, retrieveGranted: nil, retrieveDenyReason: nil)
        case retrieveResponseType, escrowAcknowledgementType:
            let offset = 1 + sessionIdSize + tokenSize
            let sessionIdBytes = Array(bytes[1..<(1 + sessionIdSize)])
            guard let sessionId = String(bytes: sessionIdBytes, encoding: .utf8) else { return nil }
            let grantedByte = bytes[offset]
            let denyReason = RetrieveDenyReason(rawValue: bytes[retrieveDenyReasonOffset]) ?? .unspecified
            return Decoded(type: type, sessionId: sessionId, token: nil, childPID: nil, retrieveGranted: grantedByte == 1, retrieveDenyReason: denyReason)
        default:
            return Decoded(type: type, sessionId: nil, token: nil, childPID: nil, retrieveGranted: nil, retrieveDenyReason: nil)
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
        return .live(fd)
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

// MARK: - App-side client

/// Keeps the retrieved master alive through deferred/failed surface creation.
/// The registry deliberately owns failed migrations until Retry can hand them
/// to a holder; deinitializing a failed panel must not close the last master.
final class SessionEscrowRetainedDescriptor: @unchecked Sendable {
    struct Destination {
        let sessionId: String
        let tokenHex: String
        let socketPath: String
    }

    private static let registryLock = NSLock()
    private static var registry: [String: SessionEscrowRetainedDescriptor] = [:]
    private let lock = NSLock()
    private var masterFD: Int32
    private var destination: Destination
    private var recoveryPending: Bool
    let sessionId: String
    let childPID: Int32

    private init(sessionId: String, masterFD: Int32, childPID: Int32, tokenHex: String, socketPath: String, recoveryPending: Bool) {
        self.sessionId = sessionId
        self.masterFD = masterFD
        self.childPID = childPID
        self.recoveryPending = recoveryPending
        destination = Destination(sessionId: sessionId, tokenHex: tokenHex, socketPath: socketPath)
    }

    static func retain(sessionId: String, masterFD: Int32, childPID: Int32, tokenHex: String, socketPath: String, recoveryPending: Bool = true) -> SessionEscrowRetainedDescriptor {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[sessionId] {
            close(masterFD)
            return existing
        }
        let owner = SessionEscrowRetainedDescriptor(
            sessionId: sessionId, masterFD: masterFD, childPID: childPID, tokenHex: tokenHex, socketPath: socketPath,
            recoveryPending: recoveryPending
        )
        registry[sessionId] = owner
        return owner
    }

    static func pending() -> [SessionEscrowRetainedDescriptor] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return Array(registry.values)
    }

    func duplicate() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard masterFD >= 0 else { return nil }
        let fd = dup(masterFD)
        return fd >= 0 ? fd : nil
    }

    func markRecoveryPending() {
        lock.lock()
        recoveryPending = true
        lock.unlock()
        DispatchQueue.main.async { ScrollbackPersistenceSettings.retryLegacyMigration() }
    }

    var canRecoverWithoutPanel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recoveryPending && masterFD >= 0
    }

    func recordDestination(sessionId: String, tokenHex: String, socketPath: String) {
        lock.lock()
        destination = Destination(sessionId: sessionId, tokenHex: tokenHex, socketPath: socketPath)
        lock.unlock()
    }

    func pendingDestination() -> Destination {
        lock.lock()
        defer { lock.unlock() }
        return destination
    }

    func releaseAfterOwnershipTransfer() {
        Self.registryLock.lock()
        defer { Self.registryLock.unlock() }
        lock.lock()
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        lock.unlock()
        if Self.registry[sessionId] === self { Self.registry.removeValue(forKey: sessionId) }
        DispatchQueue.main.async { ScrollbackPersistenceSettings.retryLegacyMigration() }
    }
}

/// App-side singleton: owns the one persistent connection to the holder
/// for this app instance, lazily connecting (and spawning the holder if
/// nothing answers) on the first surface's escrow attempt. All socket I/O
/// is confined to `queue`, off-main. See the file-level doc comment for
/// the full protocol/degradation contract.
final class SessionEscrowClient {
    static let shared = SessionEscrowClient()
    private static let migrationQueue = DispatchQueue(label: "com.darkroom.programa.scrollback-migration", qos: .utility)

    private static func legacySessions() throws -> [(sessionId: String, meta: SessionWALMeta)] {
        guard let root = SessionWALPaths.sessionsRootURL() else { throw CocoaError(.fileNoSuchFile) }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [(sessionId: String, meta: SessionWALMeta)] = []
        for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
            let paths = SessionWALPaths(sessionDirectory: entry)
            guard FileManager.default.fileExists(atPath: paths.metaURL.path) else { continue }
            let meta = try decoder.decode(SessionWALMeta.self, from: Data(contentsOf: paths.metaURL))
            if meta.escrowed == true, meta.escrowSocketPath == legacySocketPath() {
                result.append((entry.lastPathComponent, meta))
            }
        }
        return result
    }

    static func hasLegacySessions() -> Bool {
        guard let legacy = try? legacySessions() else { return true }
        return !legacy.isEmpty || !SessionEscrowRetainedDescriptor.pending().isEmpty
    }

    static func migrateLegacySessions(completion: @escaping (Bool) -> Void) {
        migrationQueue.async {
            // An early re-escrow may still be acknowledging ownership when a
            // deferred native creation fails. Resolve that attempt first.
            shared.queue.sync {}
            var success = true
            guard let candidates = try? legacySessions() else { completion(false); return }
            let retainedIds = Set(SessionEscrowRetainedDescriptor.pending().map(\.sessionId))
            for candidate in candidates where !retainedIds.contains(candidate.sessionId) {
                guard let token = candidate.meta.escrowToken, let pid = candidate.meta.childPID else {
                    success = false
                    continue
                }
                switch retrieveOutcome(
                    sessionId: candidate.sessionId, tokenHex: token, socketPath: legacySocketPath(),
                    allowUnspecifiedDenyRetry: true,
                    retryDeadline: .now() + SessionEscrowPolicy.retrieveDenyRetryWindow
                ) {
                case .granted(let fd):
                    _ = SessionEscrowRetainedDescriptor.retain(
                        sessionId: candidate.sessionId, masterFD: fd, childPID: pid,
                        tokenHex: token, socketPath: legacySocketPath()
                    )
                case .denied(.unknownSession):
                    // Only this explicit denial establishes that this holder
                    // no longer owns the session. Transport/token errors do not.
                    guard let paths = SessionWALPaths.make(sessionId: candidate.sessionId) else {
                        success = false
                        continue
                    }
                    if (try? SessionWALCore.clearEscrowClaim(at: paths, ifSocketMatches: legacySocketPath())) == nil { success = false }
                default:
                    success = false
                }
            }
            for owner in SessionEscrowRetainedDescriptor.pending() {
                if !owner.canRecoverWithoutPanel || !migrateRetainedDescriptor(owner) { success = false }
            }
            completion(success && !hasLegacySessions())
        }
    }

    private static func migrateRetainedDescriptor(_ owner: SessionEscrowRetainedDescriptor) -> Bool {
        let destination = owner.pendingDestination()
        let targetSocket = escrowSocketPath()
        // A lost acknowledgement may already have handed the master to the
        // new holder. Stop that drain before issuing the same session again.
        if destination.socketPath == targetSocket,
           let probeFD = UnixDomainFDPassing.connect(to: targetSocket) {
            close(probeFD)
            switch retrieveOutcome(
                sessionId: destination.sessionId, tokenHex: destination.tokenHex, socketPath: targetSocket,
                retryDeadline: .now() + SessionEscrowPolicy.retrieveDenyRetryWindow
            ) {
            case .granted(let fd): close(fd) // owner still holds the master
            case .denied(.unknownSession): break
            case .denied(.notDraining):
                guard releaseUnclaimedRegistration(destination, socketPath: targetSocket) else { return false }
            default: return false
            }
        }
        var connection: Int32?
        var spawned = false
        for attempt in 0..<SessionEscrowPolicy.connectRetryCount {
            connection = UnixDomainFDPassing.connect(to: targetSocket)
            if connection != nil { break }
            if !spawned {
                spawned = true
                spawnHolderIfNeeded(socketPath: targetSocket)
            }
            if attempt + 1 < SessionEscrowPolicy.connectRetryCount {
                Thread.sleep(forTimeInterval: SessionEscrowPolicy.connectRetryDelay)
            }
        }
        guard let connection else { return false }
        // EOF starts the new holder's drain without creating unrelated UI.
        defer { close(connection) }
        guard let fd = owner.duplicate() else { return true }
        defer { close(fd) }
        guard let token = decodeHexToken(destination.tokenHex),
              var frame = EscrowWireFormat.encodeEscrowFrame(
                sessionId: destination.sessionId, token: token, childPID: owner.childPID
              ) else { return false }
        frame[0] = EscrowWireFormat.acknowledgedEscrowType
        owner.recordDestination(sessionId: destination.sessionId, tokenHex: destination.tokenHex, socketPath: targetSocket)
        guard UnixDomainFDPassing.send(fd: fd, payload: frame, over: connection),
              receiveEscrowAcknowledgement(over: connection, sessionId: destination.sessionId) else { return false }
        owner.releaseAfterOwnershipTransfer()
        if destination.sessionId != owner.sessionId,
           let paths = SessionWALPaths.make(sessionId: owner.sessionId) {
            return (try? SessionWALCore.clearEscrowClaim(at: paths, ifSocketMatches: legacySocketPath())) != nil
        }
        return true
    }

    private static func releaseUnclaimedRegistration(
        _ destination: SessionEscrowRetainedDescriptor.Destination, socketPath: String
    ) -> Bool {
        guard let connection = UnixDomainFDPassing.connect(to: socketPath) else { return false }
        defer { close(connection) }
        guard let token = decodeHexToken(destination.tokenHex),
              var frame = EscrowWireFormat.encodeReleaseFrame(sessionId: destination.sessionId, token: token) else { return false }
        frame[0] = EscrowWireFormat.acknowledgedReleaseType
        return UnixDomainFDPassing.send(fd: nil, payload: frame, over: connection)
            && receiveEscrowAcknowledgement(over: connection, sessionId: destination.sessionId)
    }

    /// Returned to the caller on a successful escrow so it can be recorded
    /// in `meta.json` (`SessionWALStore.markEscrowed`).
    struct Result {
        let tokenHex: String
        let socketPath: String
    }

    private let queue = DispatchQueue(label: "com.darkroom.programa.session-escrow-client", qos: .utility)
    private var connectionFD: Int32?
    private var heartbeatTimer: DispatchSourceTimer?
    // A successful send can transfer the descriptor before its acknowledgement
    // arrives. Keep the release capability independently from durable success.
    private var sentClaimsBySurfaceId: [String: String] = [:]
    private var acknowledgementBuffer = Data()
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
        retainedDescriptor: SessionEscrowRetainedDescriptor? = nil,
        completion: @escaping (Result?) -> Void
    ) {
        guard !SessionMachineryGate.isUnitTesting else {
            close(dupedMasterFD)
            completion(nil)
            return
        }

        queue.async { [weak self] in
            guard let self else {
                close(dupedMasterFD)
                completion(nil)
                return
            }
            defer { close(dupedMasterFD) }

            guard self.sentClaimsBySurfaceId[surfaceId] == nil else {
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
                  var frame = EscrowWireFormat.encodeEscrowFrame(sessionId: surfaceId, token: token, childPID: childPID) else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=encode_or_random status=\(randomStatus)")
                #endif
                completion(nil)
                return
            }
            frame[0] = EscrowWireFormat.acknowledgedEscrowType
            let tokenHex = token.map { String(format: "%02x", $0) }.joined()
            retainedDescriptor?.recordDestination(sessionId: surfaceId, tokenHex: tokenHex, socketPath: self.socketPath)

            guard UnixDomainFDPassing.send(fd: dupedMasterFD, payload: frame, over: fd) else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=send errno=\(errno)")
                #endif
                self.teardownConnection()
                completion(nil)
                return
            }
            self.sentClaimsBySurfaceId[surfaceId] = tokenHex
            var buffer = self.acknowledgementBuffer
            let acknowledged = Self.receiveEscrowAcknowledgement(
                over: fd, sessionId: surfaceId, buffer: &buffer
            )
            self.acknowledgementBuffer = buffer
            guard acknowledged else {
                // The holder may already own the duplicate. Keep heartbeats
                // alive so uncertainty does not start a second PTY reader.
                // A failed-panel recovery explicitly withdraws this claim.
                completion(nil)
                return
            }

            #if DEBUG
            dlog("session.escrow.client.sent surface=\(surfaceId.prefix(8)) childPID=\(childPID) connFD=\(fd) masterFD=\(dupedMasterFD)")
            #endif
            completion(Result(tokenHex: tokenHex, socketPath: self.socketPath))
        }
    }

    /// Tells the holder a session is genuinely closed so it stops holding the
    /// pty master open. Fire-and-forget: the holder sends no response, and a
    /// failure here is not worth surfacing -- the worst case is the previous
    /// behavior, where the session lingers until the holder drops it.
    ///
    /// Callers must only use this once the close is final (past the undo
    /// grace period) and never during app termination.
    func release(surfaceId: String) {
        guard !SessionMachineryGate.isUnitTesting else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Nothing to release if we never escrowed it, and dropping the id
            // here keeps a later re-escrow of the same surface id working.
            guard let tokenHex = self.sentClaimsBySurfaceId[surfaceId] else { return }
            guard let token = Self.tokenBytes(fromHex: tokenHex),
                  let frame = EscrowWireFormat.encodeReleaseFrame(sessionId: surfaceId, token: token) else {
                return
            }
            // Deliberately does NOT open a connection: if we have none, the
            // holder either never got this session or is already gone.
            guard let fd = self.connectionFD else { return }
            if UnixDomainFDPassing.send(fd: nil, payload: frame, over: fd) {
                self.sentClaimsBySurfaceId.removeValue(forKey: surfaceId)
            } else {
                self.teardownConnection()
            }
        }
    }

    private static func tokenBytes(fromHex hex: String) -> [UInt8]? {
        let characters = Array(hex)
        guard characters.count == EscrowWireFormat.tokenSize * 2 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(EscrowWireFormat.tokenSize)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index...(index + 1)]), radix: 16) else { return nil }
            bytes.append(byte)
            index += 2
        }
        return bytes
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
        acknowledgementBuffer.removeAll(keepingCapacity: true)
    }

    /// Derived from the app's own control-socket path
    /// (`SocketControlSettings.socketPath()`), which is already
    /// bundle-id/tag-scoped and already lives under `/tmp` specifically to
    /// stay well under `sockaddr_un.sun_path`'s ~104-byte limit -- see
    /// `SocketControlSettings.taggedDebugSocketPath`. Reusing that scoping
    /// means a tagged debug build and the production app (or two different
    /// tags) always get distinct holder sockets, matching the isolation
    /// the rest of the socket-path machinery already guarantees.
    static func legacySocketPath() -> String {
        let base = SocketControlSettings.socketPath()
        let baseURL = URL(fileURLWithPath: base)
        let name = baseURL.deletingPathExtension().lastPathComponent + "-escrow"
        return baseURL.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension("sock")
            .path
    }

    static func escrowSocketPath() -> String {
        let legacy = URL(fileURLWithPath: legacySocketPath()).deletingPathExtension()
        return legacy.deletingLastPathComponent()
            .appendingPathComponent(legacy.lastPathComponent + "-v2.sock").path
    }

    private static func receiveEscrowAcknowledgement(over fd: Int32, sessionId: String) -> Bool {
        var buffer = Data()
        return receiveEscrowAcknowledgement(over: fd, sessionId: sessionId, buffer: &buffer)
    }

    /// The persistent caller owns `buffer` on its serial queue. Timeouts retain
    /// partial frames; late replies are consumed and correlated before waiting
    /// for the current session. The deadline bounds the entire read, not each
    /// fragment or unrelated reply.
    static func receiveEscrowAcknowledgement(
        over fd: Int32,
        sessionId: String,
        buffer: inout Data,
        timeout: TimeInterval = 5
    ) -> Bool {
        guard timeout.isFinite, timeout > 0 else { return false }
        let startedAt = ProcessInfo.processInfo.systemUptime
        while true {
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - startedAt)
            guard remaining > 0 else { return false }
            if buffer.count >= EscrowWireFormat.frameSize {
                let payload = Data(buffer.prefix(EscrowWireFormat.frameSize))
                buffer.removeFirst(EscrowWireFormat.frameSize)
                if let response = EscrowWireFormat.decode(payload),
                   response.type == EscrowWireFormat.escrowAcknowledgementType,
                   let replySessionId = response.sessionId,
                   let granted = response.retrieveGranted {
                    if replySessionId == sessionId { return granted }
                }
                continue
            }
            let bounded = min(remaining, 5)
            let wholeSeconds = bounded.rounded(.down)
            var receiveTimeout = timeval(
                tv_sec: Int(wholeSeconds),
                tv_usec: max(1, suseconds_t((bounded - wholeSeconds) * 1_000_000))
            )
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return false }
            switch UnixDomainFDPassing.receiveChunk(maxBytes: EscrowWireFormat.frameSize - buffer.count, from: fd) {
            case .data(let chunk, let receivedFD):
                if let receivedFD { close(receivedFD) }
                guard !chunk.isEmpty else { return false }
                buffer.append(chunk)
            case .timeout: continue
            default: return false
            }
        }
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
    /// Time-bounded circuit breaker state for `retrieve`, keyed by holder
    /// socket path -- see `retrieve`'s "Escrow follow-up" doc comment for
    /// the rationale. `retrieve` itself is only ever called from the
    /// main-thread session-restore path (`Workspace+Persistence.swift`'s
    /// `attemptSessionReattach`), one call at a time, so nothing here is
    /// actually contended in production; the lock exists purely so tests
    /// (which may probe from a background accept thread) never have to
    /// reason about a data race, at negligible cost on the real serial
    /// restore path.
    /// Monotonic (`DispatchTime.now()`, backed by `CLOCK_UPTIME_RAW`) rather
    /// than wall-clock `Date` -- a backward clock jump (NTP sync, sleep/wake,
    /// manual clock change) must not keep the circuit open longer than
    /// `circuitBreakerWindow` actually elapsed.
    private static var recentRetrieveTimeoutsByPath: [String: DispatchTime] = [:]
    private static let circuitBreakerLock = NSLock()
    /// How long a path stays "open" (skipped without connecting) after a
    /// recorded timeout. Comfortably covers a full serial restore sweep
    /// (bounded by panel count in a real workspace) while not permanently
    /// blacklisting a holder that recovers -- the window doubling as the
    /// only reset mechanism is deliberate, see `retrieve`'s doc comment.
    private static let circuitBreakerWindow: TimeInterval = 60.0

    /// Test-only: clears breaker state so test cases don't leak it into
    /// each other, and lets a test simulate the window elapsing without an
    /// actual 60s sleep by re-arming a fresh state instead.
    static func resetCircuitBreakerForTesting() {
        circuitBreakerLock.lock()
        recentRetrieveTimeoutsByPath.removeAll()
        circuitBreakerLock.unlock()
    }

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
    /// .retrieveRecvTimeout`; any failure (holder unreachable,
    /// unknown session, token mismatch, child already exited, timeout)
    /// returns nil so the caller can fall through to its existing
    /// spawn-fresh path unchanged.
    ///
    /// Escrow follow-up (issue tracker #6, post-#182): app-launch restore
    /// (`Workspace+Persistence.swift`'s `attemptSessionReattach`) calls this
    /// SERIALLY on the main thread, once per escrowed panel, and nearly
    /// every panel shares the SAME deterministic holder socket path. A
    /// missing/stale socket fails fast (`connect` returns nil immediately,
    /// see `UnixDomainFDPassing.connect`'s doc comment) -- the
    /// `retrieveRecvTimeout` cost is only ever paid when a holder ACCEPTS
    /// the connection but never answers (wedged). Without a breaker, N
    /// sessions against one wedged holder cost N * `retrieveRecvTimeout` of
    /// main-thread stall at launch. `recentRetrieveTimeoutsByPath` makes
    /// that a one-time cost per launch per path: once a path has timed out,
    /// every other `retrieve` call against that SAME path within
    /// `circuitBreakerWindow` returns nil immediately, without even
    /// attempting to connect. The window is intentionally short and
    /// self-healing rather than a manual reset -- 60s comfortably covers a
    /// full serial restore sweep (bounded by how many panels a real
    /// workspace has) while not permanently blacklisting a holder that
    /// recovers (e.g. survives a transient hang and answers normally on the
    /// next real request after this launch).
    /// Outcome of one holder round trip -- internal to the retry loop in
    /// `retrieve`. `.failed` covers every transport-level dead end (no
    /// holder, timeout, malformed frame): never retried here, the existing
    /// circuit breaker already bounds those. `.denied` carries the holder's
    /// wire reason so the loop can distinguish the one retryable denial
    /// (`.notDraining`) from the permanent ones.
    enum RetrieveOutcome {
        case granted(Int32)
        case denied(EscrowWireFormat.RetrieveDenyReason)
        case failed
    }

    /// Process-wide anchor for deny retries: `static let` is evaluated
    /// lazily on the first denial that wants a retry, so the serial
    /// launch-restore sweep shares ONE `retrieveDenyRetryWindow` across all
    /// its sessions. The race this exists for -- the holder has not yet
    /// noticed the old app died -- resolves for every session at once when
    /// the drain begins, so a per-session window would stall launch N times
    /// over for nothing.
    /// Monotonic (`DispatchTime`), matching the circuit breaker above and
    /// for the same reason: a backward wall-clock jump (NTP sync at boot is
    /// exactly launch-restore time) must never extend this synchronous
    /// main-thread retry loop past the real elapsed window.
    private static let sharedDenyRetryDeadline: DispatchTime = .now() + SessionEscrowPolicy.retrieveDenyRetryWindow

    /// 2026-08-10 mass-drain fix on top of the single-shot retrieval below:
    /// a denial whose wire reason is `.notDraining` is the
    /// retrieve-before-drain race (this launch beat the holder's death
    /// detection), and the holder resolves it BY ITSELF within
    /// `heartbeatStaleAfter` -- so it is retried on a bounded deadline
    /// instead of being treated as a permanent fallback. `.unspecified`
    /// may be that same race reported by a pre-reason holder (the holder
    /// OUTLIVES the app, so an updated client talking to a previous
    /// version's holder is the normal update path, not an edge case); it is
    /// retried only when the caller vouches via `allowUnspecifiedDenyRetry`
    /// (Workspace restore passes meta.json heartbeat freshness -- an app
    /// that was alive seconds ago is the race signature; one long dead is
    /// not worth stalling on). `retryDeadline` exists for tests; production
    /// callers share `sharedDenyRetryDeadline`.
    static func retrieve(
        sessionId: String,
        tokenHex: String,
        socketPath: String,
        recvTimeout: TimeInterval = SessionEscrowPolicy.retrieveRecvTimeout,
        allowUnspecifiedDenyRetry: Bool = false,
        retryDeadline: DispatchTime? = nil
    ) -> Int32? {
        if case .granted(let fd) = retrieveOutcome(
            sessionId: sessionId, tokenHex: tokenHex, socketPath: socketPath,
            recvTimeout: recvTimeout, allowUnspecifiedDenyRetry: allowUnspecifiedDenyRetry,
            retryDeadline: retryDeadline
        ) { return fd }
        return nil
    }

    static func retrieveOutcome(
        sessionId: String,
        tokenHex: String,
        socketPath: String,
        recvTimeout: TimeInterval = SessionEscrowPolicy.retrieveRecvTimeout,
        allowUnspecifiedDenyRetry: Bool = false,
        retryDeadline: DispatchTime? = nil
    ) -> RetrieveOutcome {
        var attempt = 0
        while true {
            attempt += 1
            switch retrieveOnce(
                sessionId: sessionId,
                tokenHex: tokenHex,
                socketPath: socketPath,
                recvTimeout: recvTimeout
            ) {
            case .granted(let fd):
                return .granted(fd)
            case .failed:
                return .failed
            case .denied(let reason):
                let retryable = reason == .notDraining
                    || (reason == .unspecified && allowUnspecifiedDenyRetry)
                // Retryability first: a permanent denial (unknown session,
                // token mismatch) must not be the access that anchors the
                // lazy shared window, or it silently eats the budget a
                // later legitimate not_draining denial needs.
                guard retryable else { return .denied(reason) }
                let deadline = retryDeadline ?? sharedDenyRetryDeadline
                guard DispatchTime.now() < deadline else { return .denied(reason) }
                dilog("escrow.retrieve", "retry session=\(sessionId.prefix(8)) attempt=\(attempt) reason=\(reason)")
                Thread.sleep(forTimeInterval: SessionEscrowPolicy.retrieveDenyRetryInterval)
            }
        }
    }

    private static func retrieveOnce(
        sessionId: String,
        tokenHex: String,
        socketPath: String,
        recvTimeout: TimeInterval
    ) -> RetrieveOutcome {
        let attemptStartedAt = Date()
        let timeoutMs = Int(recvTimeout * 1000)
        dilog("escrow.retrieve", "attempt session=\(sessionId.prefix(8)) socket=\(socketPath) timeoutMs=\(timeoutMs)")
        func logOutcome(_ outcome: String) {
            let elapsedMs = Int(Date().timeIntervalSince(attemptStartedAt) * 1000)
            dilog("escrow.retrieve", "outcome session=\(sessionId.prefix(8)) result=\(outcome) elapsedMs=\(elapsedMs)")
        }

        circuitBreakerLock.lock()
        let recordedOpenedAt = recentRetrieveTimeoutsByPath[socketPath]
        circuitBreakerLock.unlock()
        if let openedAt = recordedOpenedAt {
            let sinceNs = DispatchTime.now().uptimeNanoseconds &- openedAt.uptimeNanoseconds
            let sinceMs = Int(sinceNs / 1_000_000)
            if sinceNs < UInt64(circuitBreakerWindow * 1_000_000_000) {
                dilog("escrow.retrieve", "skipped session=\(sessionId.prefix(8)) reason=circuit_open path_failed_ago_ms=\(sinceMs)")
                return .failed
            }
        }

        guard let token = decodeHexToken(tokenHex) else {
            logOutcome("error_bad_token_hex")
            return .failed
        }
        guard let connectionFD = UnixDomainFDPassing.connect(to: socketPath) else {
            logOutcome("error_no_connection")
            return .failed
        }
        defer { close(connectionFD) }

        // Sub-second timeout, so this must split whole seconds from the
        // fractional remainder rather than truncating straight to
        // `tv_sec` -- a bare `Int(recvTimeout)` would silently become 0
        // seconds with no microsecond budget at all.
        let recvTimeoutWholeSeconds = recvTimeout.rounded(.down)
        var timeout = timeval(
            tv_sec: Int(recvTimeoutWholeSeconds),
            tv_usec: suseconds_t((recvTimeout - recvTimeoutWholeSeconds) * 1_000_000)
        )
        setsockopt(connectionFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let requestFrame = EscrowWireFormat.encodeRetrieveRequestFrame(sessionId: sessionId, token: token),
              UnixDomainFDPassing.send(fd: nil, payload: requestFrame, over: connectionFD) else {
            logOutcome("error_send errno=\(errno)")
            return .failed
        }

        var collected = Data()
        var receivedFD: Int32?
        while collected.count < EscrowWireFormat.frameSize {
            switch UnixDomainFDPassing.receiveChunk(maxBytes: EscrowWireFormat.frameSize - collected.count, from: connectionFD) {
            case .data(let chunk, let chunkFD):
                guard !chunk.isEmpty else {
                    if let chunkFD { close(chunkFD) }
                    logOutcome("eof")
                    return .failed
                }
                collected.append(chunk)
                if receivedFD == nil { receivedFD = chunkFD }
            case .eof:
                if let receivedFD { close(receivedFD) }
                logOutcome("eof")
                return .failed
            case .timeout:
                if let receivedFD { close(receivedFD) }
                circuitBreakerLock.lock()
                recentRetrieveTimeoutsByPath[socketPath] = DispatchTime.now()
                circuitBreakerLock.unlock()
                dilog("escrow.retrieve", "circuit_opened session=\(sessionId.prefix(8)) path=\(socketPath)")
                logOutcome("timeout")
                return .failed
            case .error:
                if let receivedFD { close(receivedFD) }
                logOutcome("error_recv errno=\(errno)")
                return .failed
            }
        }

        guard let decoded = EscrowWireFormat.decode(collected),
              decoded.type == EscrowWireFormat.retrieveResponseType,
              decoded.sessionId == sessionId else {
            if let receivedFD { close(receivedFD) }
            logOutcome("error_bad_response_frame")
            return .failed
        }
        if decoded.retrieveGranted == true {
            guard let receivedFD else {
                logOutcome("error_granted_without_fd")
                return .failed
            }
            logOutcome("granted fd=\(receivedFD)")
            return .granted(receivedFD)
        }
        if let receivedFD { close(receivedFD) }
        let reason = decoded.retrieveDenyReason ?? .unspecified
        logOutcome("denied reason=\(reason)")
        return .denied(reason)
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
    final class HeldSession {
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
        /// Set (under `SessionEscrowHolder.registryLock`), at the same
        /// point `isDraining` flips true, to the moment draining began.
        /// Read by the reaper to decide whether an unclaimed session's
        /// `SessionEscrowPolicy.unclaimedSessionTTL` has elapsed.
        var drainingStartedAt: Date?
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

        /// Closes the holder's fd after a successful `SCM_RIGHTS` send.
        /// The recipient owns a duplicate; closing this descriptor does not
        /// close theirs. Callers must hold `SessionEscrowHolder.registryLock`.
        func markHandedOff() {
            markClosedIfNeeded()
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

    /// Guards `registry`, `activeConnectionCount`, and every `HeldSession`'s
    /// mutable fields (`isDraining`, `drainingStartedAt`, `stopRequested`,
    /// `closed`). Held only very briefly (dictionary lookups/mutations,
    /// flag flips, counter increments). A new acknowledged registration also
    /// holds it while committing metadata, before exposing the registry entry.
    private static let registryLock = NSLock()
    private static var registry: [String: HeldSession] = [:]
    /// Count of `serve(connectionFD:)` threads currently running. Read by
    /// the reaper alongside `registry.isEmpty` to decide whether the
    /// holder has nothing left to hold. Guarded by `registryLock`.
    private static var activeConnectionCount = 0
    /// The moment the holder first observed `registry.isEmpty &&
    /// activeConnectionCount == 0`, or nil if it isn't currently idle.
    /// Reset the instant either becomes non-empty/non-zero. Only ever
    /// touched from the reaper thread, so it needs no lock of its own.
    private static var idleSince: Date?
    /// Set once, under `registryLock`, in the SAME lock acquisition that
    /// re-confirms the exit precondition (`registry.isEmpty &&
    /// activeConnectionCount == 0` for `idleExitGrace`) right before
    /// `reaperTick` calls `Darwin.exit(0)`. The accept loop in `run()`
    /// checks this under that same lock when it would otherwise register a
    /// new connection, so "decide to exit" and "stop accepting new
    /// sessions" are atomic with respect to each other -- without this, a
    /// connection could be accepted and register a pty fd in the window
    /// between the reaper's snapshot and its `exit()` call, and `exit()`
    /// would then destroy that live session.
    private static var shuttingDown = false

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
        holderSocketPath = socketPath
        // Must happen before ANY socket work below. A holder that finishes
        // a retrieval inside `handleRetrieveRequest`'s
        // `retrieveDrainStopTimeout` window but after the client itself
        // gave up and closed its socket (see `SessionEscrowPolicy
        // .retrieveRecvTimeout`'s doc comment) would otherwise raise
        // `SIGPIPE` on the eventual `send`/`sendmsg` -- default disposition
        // kills this process outright, which SIGHUPs every OTHER escrowed
        // child this holder still has open, not just the one send that
        // failed. `SO_NOSIGPIPE` (set per-socket below, see
        // `UnixDomainFDPassing.suppressSigPipe`) is belt-and-suspenders on
        // top of this process-wide ignore, not a substitute for it: this
        // line is what keeps a late send from ever being fatal in the first
        // place, on every fd this process touches, including ones a future
        // change might forget to tag individually.
        signal(SIGPIPE, SIG_IGN)
        #if DEBUG
        dlog("session.escrow.holder.sigpipe_ignored")
        #endif
        guard let listenFD = UnixDomainFDPassing.bindListening(socketPath: socketPath) else {
            #if DEBUG
            dlog("session.escrow.holder.run bind_failed socket=\(socketPath)")
            #endif
            Darwin.exit(0)
        }
        #if DEBUG
        dlog("session.escrow.holder.run listening socket=\(socketPath)")
        #endif
        // Started before the accept loop below so its first sweep can only
        // ever land after `reaperInterval` has elapsed -- comfortably
        // longer than the app's own connect budget
        // (`SessionEscrowPolicy.connectRetryCount` *
        // `connectRetryDelay`), so the very first client to connect is
        // always counted as an active connection before the reaper could
        // ever consider this holder idle. See constraint 3 in the
        // file-level "Reaper" doc comment.
        startReaper()
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { continue }
            UnixDomainFDPassing.suppressSigPipe(on: clientFD)
            #if DEBUG
            dlog("session.escrow.holder.accept connFD=\(clientFD)")
            #endif
            registryLock.lock()
            guard !shuttingDown else {
                registryLock.unlock()
                // The reaper has already committed to exiting (see
                // `shuttingDown`'s doc comment) -- refuse this connection
                // rather than register it into a process about to call
                // `exit()`. The client's own connect retry/spawn-holder
                // path handles a refused connection the same as any other
                // unreachable holder.
                #if DEBUG
                dlog("session.escrow.holder.accept.refused connFD=\(clientFD) reason=shutting_down")
                #endif
                close(clientFD)
                continue
            }
            activeConnectionCount += 1
            registryLock.unlock()
            Thread.detachNewThread {
                defer {
                    registryLock.lock()
                    activeConnectionCount -= 1
                    registryLock.unlock()
                }
                serve(connectionFD: clientFD)
            }
        }
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
                dilog("escrow.conn", "death connFD=\(connectionFD) reason=eof drainedCount=\(registeredSessionIds.count)")
                break readLoop
            case .timeout:
                if Date().timeIntervalSince(lastActivity) >= SessionEscrowPolicy.heartbeatStaleAfter {
                    dilog("escrow.conn", "death connFD=\(connectionFD) reason=heartbeat_stale drainedCount=\(registeredSessionIds.count)")
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
                case EscrowWireFormat.escrowType, EscrowWireFormat.acknowledgedEscrowType:
                    guard let sessionId = decoded.sessionId,
                          let token = decoded.token,
                          let childPID = decoded.childPID,
                          let fd else {
                        if let fd { close(fd) }
                        continue
                    }
                    let accepted = registerSession(
                        sessionId: sessionId, fd: fd, token: token, childPID: childPID,
                        requiresDurability: decoded.type == EscrowWireFormat.acknowledgedEscrowType
                    )
                    if accepted { registeredSessionIds.insert(sessionId) }
                    if decoded.type == EscrowWireFormat.acknowledgedEscrowType {
                        if var response = EscrowWireFormat.encodeRetrieveResponseFrame(sessionId: sessionId, granted: accepted) {
                            response[0] = EscrowWireFormat.escrowAcknowledgementType
                            _ = UnixDomainFDPassing.send(fd: nil, payload: response, over: connectionFD)
                        }
                    }
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
                case EscrowWireFormat.releaseType, EscrowWireFormat.acknowledgedReleaseType:
                    // Like a retrieve request, this never carries an fd.
                    if let fd { close(fd) }
                    guard let sessionId = decoded.sessionId, let token = decoded.token else { continue }
                    let released = releaseSession(
                        sessionId: sessionId, token: token,
                        unknownIsSuccess: decoded.type == EscrowWireFormat.acknowledgedReleaseType
                    )
                    if released {
                        // Drop it from this connection's set too, so the
                        // connection's death does not later try to drain a
                        // session that is already gone.
                        registeredSessionIds.remove(sessionId)
                    }
                    if decoded.type == EscrowWireFormat.acknowledgedReleaseType,
                       var response = EscrowWireFormat.encodeRetrieveResponseFrame(sessionId: sessionId, granted: released) {
                        response[0] = EscrowWireFormat.escrowAcknowledgementType
                        _ = UnixDomainFDPassing.send(fd: nil, payload: response, over: connectionFD)
                    }
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
    private static var holderSocketPath = ""

    private static func persistEscrowOwnership(sessionId: String, token: [UInt8], childPID: Int32) -> Bool {
        guard let paths = SessionWALPaths.make(sessionId: sessionId) else { return false }
        var meta = SessionWALCore.readMeta(at: paths) ?? SessionWALMeta(
            sessionId: sessionId, childPID: childPID, ptyPath: nil, workingDirectory: nil,
            lastHeartbeatAt: Date(), walGeneration: 0, escrowed: true,
            escrowSocketPath: holderSocketPath, escrowToken: nil
        )
        meta.childPID = childPID
        meta.escrowed = true
        meta.escrowSocketPath = holderSocketPath
        meta.escrowToken = token.map { String(format: "%02x", $0) }.joined()
        return (try? SessionWALCore.persistMeta(meta, to: paths)) != nil
    }

    @discardableResult
    private static func registerSession(sessionId: String, fd: Int32, token: [UInt8], childPID: Int32, requiresDurability: Bool = false) -> Bool {
        registryLock.lock()
        if let existing = registry[sessionId] {
            guard !existing.isDraining, !requiresDurability else {
                registryLock.unlock()
                close(fd)
                return false
            }
            registry.removeValue(forKey: sessionId)
            existing.markClosedIfNeeded()
        }
        if requiresDurability,
           !persistEscrowOwnership(sessionId: sessionId, token: token, childPID: childPID) {
            registryLock.unlock()
            close(fd)
            return false
        }
        registry[sessionId] = HeldSession(sessionId: sessionId, fd: fd, token: token, childPID: childPID)
        registryLock.unlock()
        return true
    }

    /// Drops a session the app has told us is genuinely closed, closing the
    /// pty master we hold so the shell finally sees SIGHUP.
    ///
    /// Refuses a session that is already draining: draining means the owning
    /// app died and a successor may still retrieve this session, which is
    /// exactly the case escrow exists for. A release only ever arrives from
    /// a live app over its own connection, so that combination should not
    /// occur -- declining is the conservative branch either way, since the
    /// TTL still bounds a draining session.
    ///
    /// Returns whether the session was actually dropped.
    @discardableResult
    private static func releaseSession(sessionId: String, token: [UInt8], unknownIsSuccess: Bool = false) -> Bool {
        registryLock.lock()
        guard let session = registry[sessionId] else {
            registryLock.unlock()
            dilog("escrow.release", "session=\(sessionId.prefix(8)) outcome=unknown_session")
            return unknownIsSuccess
        }
        guard constantTimeTokensEqual(session.token, token) else {
            registryLock.unlock()
            dilog("escrow.release", "session=\(sessionId.prefix(8)) outcome=token_mismatch")
            return false
        }
        guard !session.isDraining else {
            registryLock.unlock()
            dilog("escrow.release", "session=\(sessionId.prefix(8)) outcome=declined_draining")
            return false
        }
        registry.removeValue(forKey: sessionId)
        registryLock.unlock()
        session.markClosedIfNeeded()
        dilog("escrow.release", "session=\(sessionId.prefix(8)) outcome=released")
        return true
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
            let startedAt = Date()
            session.isDraining = true
            session.drainingStartedAt = startedAt
            registryLock.unlock()
            dilog("escrow.drain", "begin session=\(sessionId.prefix(8)) at=\(startedAt.timeIntervalSince1970)")
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
        dilog("escrow.retrieve", "request session=\(sessionId.prefix(8))")
        func deny(reason: EscrowWireFormat.RetrieveDenyReason, label: String) {
            dilog("escrow.retrieve", "deny session=\(sessionId.prefix(8)) reason=\(label)")
            sendRetrieveResponse(granted: false, sessionId: sessionId, fd: nil, denyReason: reason, over: connectionFD)
        }

        registryLock.lock()
        guard let session = registry[sessionId] else {
            registryLock.unlock()
            deny(reason: .unknownSession, label: "unknown")
            return
        }
        guard constantTimeTokensEqual(session.token, token) else {
            registryLock.unlock()
            deny(reason: .tokenMismatch, label: "token_mismatch")
            return
        }
        guard session.isDraining else {
            // The escrowing app may genuinely still be alive -- only IT can
            // prove otherwise, via EOF or heartbeat staleness on its own
            // connection. The reason on the wire tells the (valid-token)
            // caller this denial is the retrieve-before-drain race and worth
            // retrying briefly, instead of a permanent fallback -- the
            // 2026-08-10 mass-drain was exactly that fallback, 4 seconds
            // before the drain would have made this same request grantable.
            registryLock.unlock()
            deny(reason: .notDraining, label: "not_draining")
            return
        }
        // Remove immediately: no second caller can ever observe this
        // session id in the registry again, regardless of how the rest of
        // this function turns out.
        registry.removeValue(forKey: sessionId)
        session.stopRequested = true
        registryLock.unlock()

        let waitStartedAt = Date()
        let stopped = session.drainStoppedSemaphore.wait(timeout: .now() + SessionEscrowPolicy.retrieveDrainStopTimeout) == .success
        let waitElapsedMs = Int(Date().timeIntervalSince(waitStartedAt) * 1000)
        dilog("escrow.retrieve", "drain_stop_wait session=\(sessionId.prefix(8)) stopped=\(stopped) elapsedMs=\(waitElapsedMs)")
        guard stopped else {
            // The drain thread never acknowledged in time. Do not hand back
            // an fd that thread might still be touching -- deny. (The
            // drain thread will still observe `stopRequested` on its own
            // very next poll cycle and stop/signal regardless of whether
            // anyone is still waiting; a signal with no waiter is harmless.
            // This session is simply no longer retrievable once removed
            // above -- an acceptable best-effort degradation, never a
            // correctness risk.)
            deny(reason: .drainStopTimeout, label: "drain_stop_timeout")
            return
        }

        // Do NOT mark this session handed off until the send that carries
        // its fd has actually been confirmed to land -- see this method's
        // doc comment and the file-level "Drain/retrieve coordination" doc
        // comment. The drain thread has already fully stopped by this
        // point (we just waited on `drainStoppedSemaphore` above), so the
        // fd is quiescent and it is safe to either hand it off or restart
        // draining on it, depending on what the send below actually does.
        let sendSucceeded = sendRetrieveResponse(granted: true, sessionId: sessionId, fd: session.fd, over: connectionFD)
        if sendSucceeded {
            registryLock.lock()
            session.markHandedOff()
            registryLock.unlock()
            dilog("escrow.retrieve", "grant session=\(sessionId.prefix(8)) fd=\(session.fd) sendSucceeded=true")
        } else {
            // The client already closed its end (it gave up waiting -- see
            // `SessionEscrowPolicy.retrieveRecvTimeout`'s invariant, which
            // makes this vanishingly rare in practice but not impossible),
            // or some other send failure occurred. The session was already
            // removed from the registry above so no other caller could
            // race it; putting it back and restarting a drain thread on
            // the same (still fully open, never-closed) fd keeps it
            // retrievable on a later relaunch instead of leaking the child
            // forever. Safe specifically because the prior drain thread
            // has unconditionally finished (confirmed via the semaphore
            // wait above) before this fd is touched again.
            registryLock.lock()
            session.isDraining = false
            session.stopRequested = false
            session.drainingStartedAt = nil
            registry[sessionId] = session
            registryLock.unlock()
            beginDraining(sessionIds: [sessionId])
            dilog("escrow.retrieve", "grant_send_failed session=\(sessionId.prefix(8)) fd=\(session.fd) reinserted=true")
        }
    }

    /// Returns whether the response frame (and, when granted, its
    /// `SCM_RIGHTS` fd) was actually sent successfully. Callers MUST check
    /// this -- see `handleRetrieveRequest`'s post-send handling -- rather
    /// than assuming a queued send always lands: the client may have
    /// already closed its end (abandoned after its own recv timeout, or a
    /// genuine socket error), in which case the kernel silently drops the
    /// in-flight ancillary fd and the session must not be treated as
    /// handed off.
    @discardableResult
    private static func sendRetrieveResponse(
        granted: Bool,
        sessionId: String,
        fd: Int32?,
        denyReason: EscrowWireFormat.RetrieveDenyReason = .unspecified,
        over connectionFD: Int32
    ) -> Bool {
        guard let frame = EscrowWireFormat.encodeRetrieveResponseFrame(
            sessionId: sessionId,
            granted: granted,
            denyReason: denyReason
        ) else { return false }
        return UnixDomainFDPassing.send(fd: granted ? fd : nil, payload: frame, over: connectionFD)
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

    // MARK: - Reaper (unclaimed session expiry + idle exit)

    /// Started once from `run()`, before the accept loop, and never
    /// stops. Wakes every `SessionEscrowPolicy.reaperInterval` to (1) close
    /// out any session that has been draining, unclaimed, past
    /// `SessionEscrowPolicy.unclaimedSessionTTL`, and (2) exit the holder
    /// once it has had nothing to hold and no live connection for
    /// `SessionEscrowPolicy.idleExitGrace`. Both halves of the fix for the
    /// escrow-holder leak: without (1) an unclaimed session (crash, force
    /// quit, a deleted tagged build, an update that reclaims nothing) is
    /// held forever; without (2) the holder itself never exits even once
    /// its registry is empty and nothing is connected to it.
    private static func startReaper() {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: SessionEscrowPolicy.reaperInterval)
                reaperTick()
            }
        }
    }

    private static func reaperTick() {
        retireExpiredSessions()

        // Snapshot-then-decide is intentionally split into two lock
        // acquisitions: the first (below) only updates `idleSince`
        // bookkeeping and is fine to race a new `accept()`, since nothing
        // irreversible happens here yet. The second, final re-check right
        // before `exit()` is the one that must be atomic with the accept
        // loop's own lock acquisition -- see `shuttingDown`'s doc comment.
        registryLock.lock()
        let registryIsEmpty = registry.isEmpty
        let connectionCount = activeConnectionCount
        registryLock.unlock()

        // Hard precondition, not a heuristic: never exit while a session is
        // still held or a connection is still live -- see the file-level
        // "Non-negotiable safety constraints" this reaper exists to honor.
        guard registryIsEmpty, connectionCount == 0 else {
            idleSince = nil
            return
        }
        guard let since = idleSince else {
            idleSince = Date()
            return
        }
        guard Date().timeIntervalSince(since) >= SessionEscrowPolicy.idleExitGrace else { return }

        // Final re-check + the shutdown decision itself, in ONE lock
        // acquisition: this is what makes "decide to exit" and "the accept
        // loop stops registering new connections" atomic with respect to
        // each other, closing the TOCTOU window a separate check-then-exit
        // would leave open (accept + register could land in between).
        registryLock.lock()
        guard registry.isEmpty, activeConnectionCount == 0 else {
            registryLock.unlock()
            idleSince = nil
            return
        }
        shuttingDown = true
        registryLock.unlock()

        #if DEBUG
        dlog("session.escrow.holder.exit reason=idle")
        #endif
        Darwin.exit(0)
    }

    /// Closes out every draining session whose `drainingStartedAt` is
    /// older than `SessionEscrowPolicy.unclaimedSessionTTL` -- no app ever
    /// came back for it. Mirrors `handleRetrieveRequest`'s drain/retrieve
    /// coordination exactly (remove-from-registry, request-stop, wait on
    /// the semaphore, then close) so an expiry can never race a drain
    /// thread's in-flight read the way a bare `close()` would. Unlike a
    /// retrieval, nothing receives this fd, so `markHandedOff()` is never
    /// called -- only `markClosedIfNeeded()`.
    private static func retireExpiredSessions() {
        let now = Date()
        var expired: [HeldSession] = []
        registryLock.lock()
        for (sessionId, session) in registry {
            if session.isDraining,
               let startedAt = session.drainingStartedAt,
               now.timeIntervalSince(startedAt) >= SessionEscrowPolicy.unclaimedSessionTTL {
                expired.append(session)
                registry.removeValue(forKey: sessionId)
                session.stopRequested = true
            }
        }
        registryLock.unlock()

        for session in expired {
            #if DEBUG
            dlog("session.escrow.holder.session.expire session=\(session.sessionId.prefix(8))")
            #endif
            let stopped = session.drainStoppedSemaphore.wait(timeout: .now() + SessionEscrowPolicy.retrieveDrainStopTimeout) == .success
            guard stopped else {
                // The drain thread never acknowledged in time -- same
                // situation `handleRetrieveRequest` guards against: it may
                // still be mid-poll/read on this exact fd, so closing it
                // here would be a use-after-close/fd-reuse hazard. Do NOT
                // touch the fd. It is already out of `registry` (removed
                // above) and `stopRequested` is already set, so the drain
                // thread will still notice on its very next poll cycle,
                // stop, and signal (harmlessly, to no waiter). `drain(session:)`
                // holds its own strong reference to this `HeldSession` for
                // as long as it runs, so the object cannot deallocate
                // before that thread actually returns -- `HeldSession
                // .deinit`'s safety-net close is what closes the fd, and it
                // necessarily happens only after the drain thread is done
                // touching it.
                #if DEBUG
                dlog("session.escrow.holder.session.expire.stop_timeout session=\(session.sessionId.prefix(8))")
                #endif
                continue
            }
            registryLock.lock()
            session.markClosedIfNeeded()
            registryLock.unlock()
        }
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
        var currentSize = (try? FileManager.default.attributesOfItem(atPath: paths.walURL.path))
            .flatMap { $0[.size] as? Int64 } ?? 0
        var totalDrained: Int64 = 0
        var lastWALSyncAt = Date.distantPast
        var hasUnsynchronizedWrites = false

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

            // Capture admission before reading, so a chunk read around an
            // off/on transition cannot be written under the newer generation.
            let capturePolicy = paths.policyPaths.flatMap { try? SessionScrollbackPolicyStore.read(at: $0) }

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
                let now = Date()
                if hasUnsynchronizedWrites,
                   now.timeIntervalSince(lastWALSyncAt) >= SessionWALPolicy.walSyncInterval,
                   (try? SessionWALCore.synchronizeWAL(at: paths)) != nil {
                    lastWALSyncAt = now
                    hasUnsynchronizedWrites = false
                }
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
            guard let capturePolicy, capturePolicy.enabled else { continue readLoop }
            let now = Date()
            let shouldSynchronize =
                now.timeIntervalSince(lastWALSyncAt) >= SessionWALPolicy.walSyncInterval
            guard let appendResult = try? SessionWALCore.append(
                chunk,
                to: paths,
                synchronize: shouldSynchronize,
                capturedGeneration: capturePolicy.generation
            ) else {
                #if DEBUG
                dlog("session.escrow.holder.drain.end session=\(session.sessionId.prefix(8)) reason=wal_append_failed totalDrained=\(totalDrained)")
                #endif
                break readLoop
            }
            if appendResult.didSuppress { continue readLoop }
            currentSize = appendResult.currentWalSize
            if appendResult.didSynchronize {
                lastWALSyncAt = now
                hasUnsynchronizedWrites = false
            } else {
                hasUnsynchronizedWrites = true
            }
            totalDrained += Int64(chunk.count)
            #if DEBUG
            dlog("session.escrow.holder.drain.chunk session=\(session.sessionId.prefix(8)) bytes=\(chunk.count) totalDrained=\(totalDrained) walSize=\(currentSize) walGeneration=\(appendResult.walGeneration) rotated=\(appendResult.didRotate)")
            #endif

            // Check again right after finishing this chunk so a retrieval
            // that arrived mid-read doesn't wait a full extra poll cycle.
            if isStopRequested(session) {
                stoppedForRetrieve = true
                break readLoop
            }
        }
        if hasUnsynchronizedWrites {
            try? SessionWALCore.synchronizeWAL(at: paths)
        }
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
