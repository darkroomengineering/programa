import Foundation
import Darwin
import Security
import Bonsplit

// MARK: - App-side client

/// App-side singleton: owns the one persistent connection to the holder
/// for this app instance, lazily connecting (and spawning the holder if
/// nothing answers) on the first surface's escrow attempt. All socket I/O
/// is confined to `queue`, off-main. See the file-level doc comment for
/// the full protocol/degradation contract.
final class SessionEscrowClient {
    static let shared = SessionEscrowClient(
        resendLiveSessions: TerminalSurface.reescrowLiveSurfacesAfterHolderLoss
    )

    /// Returned to the caller on a successful escrow so it can be recorded
    /// in `meta.json` (`SessionWALStore.markEscrowed`).
    struct Result {
        let tokenHex: String
        let socketPath: String
    }

    /// The persistent holder connection's lifecycle. Claims live on the
    /// connection because only the holder that received them knows them: a
    /// replacement holder starts empty.
    private enum ConnectionState {
        case disconnected
        case connected(HolderConnection)
        /// The holder went away while holding these surfaces' masters, which
        /// the app still owns. Never empty; re-escrowed once a holder answers.
        case holderLost(unsentSurfaceIds: Set<String>)
    }

    private final class HolderConnection {
        let fd: Int32
        let heartbeat: DispatchSourceTimer
        let connectedAtSystemUptime = ProcessInfo.processInfo.systemUptime
        // A successful send can transfer the descriptor before its acknowledgement
        // arrives. Keep the release capability independently from durable success.
        var claimsBySurfaceId: [String: String] = [:]
        var acknowledgementBuffer = Data()

        init(fd: Int32, heartbeat: DispatchSourceTimer) {
            self.fd = fd
            self.heartbeat = heartbeat
        }
    }

    private let queue = DispatchQueue(label: "com.darkroom.programa.session-escrow-client", qos: .utility)
    private var state = ConnectionState.disconnected
    private lazy var socketPath = socketPathProvider()

    private let isEnabled: Bool
    private let heartbeatInterval: TimeInterval
    private let socketPathProvider: () -> String
    private let connectToHolder: (String) -> Int32?
    /// Asked to re-escrow the given surfaces once a replacement holder
    /// answers. Called on `queue`; must not block it, and must re-escrow
    /// through `escrow` with a fresh duplicate of each still-live master.
    private let resendLiveSessions: (Set<String>) -> Void

    /// Tests inject a transport and a resend hook; `shared` uses the real
    /// holder and stays disabled under XCTest.
    init(
        isEnabled: Bool = !SessionMachineryGate.isUnitTesting,
        heartbeatInterval: TimeInterval = SessionEscrowPolicy.heartbeatInterval,
        socketPath: @escaping () -> String = { SessionEscrowClient.escrowSocketPath() },
        connectToHolder: @escaping (String) -> Int32? = SessionEscrowClient.connectSpawningHolderIfNeeded,
        resendLiveSessions: @escaping (Set<String>) -> Void
    ) {
        self.isEnabled = isEnabled
        self.heartbeatInterval = heartbeatInterval
        self.socketPathProvider = socketPath
        self.connectToHolder = connectToHolder
        self.resendLiveSessions = resendLiveSessions
    }

    deinit {
        if case .connected(let connection) = state {
            connection.heartbeat.cancel()
            close(connection.fd)
        }
    }

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
        guard isEnabled else {
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

            guard let connection = self.ensureConnection() else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=no_connection")
                #endif
                completion(nil)
                return
            }
            guard connection.claimsBySurfaceId[surfaceId] == nil else {
                #if DEBUG
                dlog("session.escrow.client.skip surface=\(surfaceId.prefix(8)) reason=already_escrowed")
                #endif
                completion(nil)
                return
            }
            let fd = connection.fd

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

            guard UnixDomainFDPassing.send(fd: dupedMasterFD, payload: frame, over: fd) else {
                #if DEBUG
                dlog("session.escrow.client.fail surface=\(surfaceId.prefix(8)) reason=send errno=\(errno)")
                #endif
                self.connectionLost(reason: "send")
                completion(nil)
                return
            }
            connection.claimsBySurfaceId[surfaceId] = tokenHex
            let acknowledged = Self.receiveEscrowAcknowledgement(
                over: fd, sessionId: surfaceId, buffer: &connection.acknowledgementBuffer
            )
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
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            // Deliberately does NOT open a connection: if we have none, the
            // holder either never got this session or is already gone.
            switch self.state {
            case .disconnected:
                return
            case .holderLost(var unsentSurfaceIds):
                // A pane closed for good must not be handed to the next holder.
                unsentSurfaceIds.remove(surfaceId)
                self.state = unsentSurfaceIds.isEmpty ? .disconnected : .holderLost(unsentSurfaceIds: unsentSurfaceIds)
            case .connected(let connection):
                // Nothing to release if we never escrowed it, and dropping the id
                // here keeps a later re-escrow of the same surface id working.
                guard let tokenHex = connection.claimsBySurfaceId.removeValue(forKey: surfaceId),
                      let token = Self.tokenBytes(fromHex: tokenHex),
                      let frame = EscrowWireFormat.encodeReleaseFrame(sessionId: surfaceId, token: token) else {
                    return
                }
                if !UnixDomainFDPassing.send(fd: nil, payload: frame, over: connection.fd) {
                    self.connectionLost(reason: "release")
                }
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
    /// attempts to connect through `connectToHolder`. Reconnecting after a
    /// holder loss asks `resendLiveSessions` to re-escrow the lost surfaces.
    private func ensureConnection() -> HolderConnection? {
        let unsentSurfaceIds: Set<String>
        switch state {
        case .connected(let connection): return connection
        case .disconnected: unsentSurfaceIds = []
        case .holderLost(let surfaceIds): unsentSurfaceIds = surfaceIds
        }
        guard let fd = connectToHolder(socketPath) else { return nil }
        let connection = HolderConnection(fd: fd, heartbeat: makeHeartbeat(fd: fd))
        state = .connected(connection)
        if !unsentSurfaceIds.isEmpty {
            dilog("escrow.client", "holder_reconnected resending=\(unsentSurfaceIds.count) connFD=\(fd)")
            resendLiveSessions(unsentSurfaceIds)
        }
        return connection
    }

    /// `queue`-confined. The only way out of `.connected`: closes the socket
    /// and keeps the claimed surfaces for the next holder. A holder that dies
    /// soon after accepting does not reconnect here, or one that dies on every
    /// escrow would respawn forever; the next `escrow` or wake retries instead.
    private func connectionLost(reason: String) {
        guard case .connected(let connection) = state else { return }
        connection.heartbeat.cancel()
        close(connection.fd)
        let unsentSurfaceIds = Set(connection.claimsBySurfaceId.keys)
        guard !unsentSurfaceIds.isEmpty else {
            state = .disconnected
            return
        }
        state = .holderLost(unsentSurfaceIds: unsentSurfaceIds)
        let age = ProcessInfo.processInfo.systemUptime - connection.connectedAtSystemUptime
        dilog("escrow.client", "holder_lost reason=\(reason) sessions=\(unsentSurfaceIds.count) connectionAge=\(Int(age))")
        guard age >= SessionEscrowPolicy.holderLossAutoReconnectMinimumAge else { return }
        queue.async { [weak self] in _ = self?.ensureConnection() }
    }

    /// Connects to the holder at `socketPath`, spawning it once (on the
    /// first failed attempt only) if nothing answers. Bounded by
    /// `SessionEscrowPolicy.connectRetryCount` short retries; never
    /// blocks indefinitely.
    static func connectSpawningHolderIfNeeded(socketPath: String) -> Int32? {
        var spawnedHolder = false
        for attempt in 0..<SessionEscrowPolicy.connectRetryCount {
            if let fd = UnixDomainFDPassing.connect(to: socketPath) {
                #if DEBUG
                dlog("session.escrow.client.connected attempt=\(attempt) socket=\(socketPath)")
                #endif
                return fd
            }
            if !spawnedHolder {
                spawnedHolder = true
                spawnHolderIfNeeded(socketPath: socketPath)
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

    private func makeHeartbeat(fd: Int32) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + heartbeatInterval,
            repeating: heartbeatInterval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            guard let self, case .connected(let connection) = self.state, connection.fd == fd else { return }
            if !UnixDomainFDPassing.send(fd: nil, payload: EscrowWireFormat.heartbeatFrame(), over: fd) {
                self.connectionLost(reason: "heartbeat")
            }
        }
        timer.resume()
        return timer
    }

    /// Called from `AppDelegate`'s `NSWorkspace.didWakeNotification` handler.
    /// Sends a heartbeat immediately instead of waiting for the next
    /// `heartbeatInterval` tick, so the holder's `lastActivity` (now measured
    /// with `ProcessInfo.systemUptime`, see `serve`) is refreshed as soon as
    /// possible after wake rather than up to `heartbeatInterval` seconds
    /// later. A dead/closed connection is torn down here, and a lost holder
    /// is replaced so its surfaces are re-escrowed. Never blocks the caller
    /// (main actor): the work itself is dispatched onto `queue`.
    func notifySystemDidWake() {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if case .connected(let connection) = self.state {
                let fd = connection.fd
                if UnixDomainFDPassing.send(fd: nil, payload: EscrowWireFormat.heartbeatFrame(), over: fd) {
                    dilog("escrow.client", "wake heartbeat=sent connFD=\(fd)")
                    return
                }
                dilog("escrow.client", "wake heartbeat=failed connFD=\(fd) errno=\(errno) -- tearing down for reconnect")
                self.connectionLost(reason: "wake")
            }
            guard case .holderLost = self.state else {
                dilog("escrow.client", "wake reconnect=skipped reason=no_connection")
                return
            }
            if self.ensureConnection() == nil {
                dilog("escrow.client", "wake reconnect=failed")
            }
        }
    }

    /// Version the holder policy so upgraded apps register with the new
    /// snapshot-aware reaper. Retrieval still uses the socket recorded in
    /// each session's metadata, allowing old holders to hand sessions over.
    ///
    /// A control socket under the world-writable `/tmp` moves the escrow
    /// socket into the per-user (0700) `NSTemporaryDirectory()`, so another
    /// local user cannot pre-create or squat the path. Falls back to the
    /// sibling path when the per-user one would not fit `sun_path`.
    static func escrowSocketPath(
        controlSocketPath: String = SocketControlSettings.socketPath(),
        perUserTemporaryDirectory: String = NSTemporaryDirectory()
    ) -> String {
        let baseURL = URL(fileURLWithPath: controlSocketPath)
        let fileName = baseURL.deletingPathExtension().lastPathComponent + "-escrow-v2.sock"
        let sibling = baseURL.deletingLastPathComponent().appendingPathComponent(fileName).path
        let parent = baseURL.deletingLastPathComponent().standardizedFileURL.path
        guard parent == "/tmp" || parent == "/private/tmp", !perUserTemporaryDirectory.isEmpty else {
            return sibling
        }
        let perUser = URL(fileURLWithPath: perUserTemporaryDirectory, isDirectory: true)
            .appendingPathComponent(fileName).path
        // sockaddr_un.sun_path is 104 bytes including the terminating NUL.
        return perUser.utf8.count < 104 ? perUser : sibling
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
    /// instead of being treated as a permanent fallback. `retryDeadline`
    /// exists for tests; production callers share `sharedDenyRetryDeadline`.
    static func retrieve(
        sessionId: String,
        tokenHex: String,
        socketPath: String,
        recvTimeout: TimeInterval = SessionEscrowPolicy.retrieveRecvTimeout,
        retryDeadline: DispatchTime? = nil
    ) -> Int32? {
        if case .granted(let fd) = retrieveOutcome(
            sessionId: sessionId, tokenHex: tokenHex, socketPath: socketPath,
            recvTimeout: recvTimeout, retryDeadline: retryDeadline
        ) { return fd }
        return nil
    }

    static func retrieveOutcome(
        sessionId: String,
        tokenHex: String,
        socketPath: String,
        recvTimeout: TimeInterval = SessionEscrowPolicy.retrieveRecvTimeout,
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
                // Retryability first: a permanent denial (unknown session,
                // token mismatch) must not be the access that anchors the
                // lazy shared window, or it silently eats the budget a
                // later legitimate not_draining denial needs.
                guard reason == .notDraining else { return .denied(reason) }
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
                if receivedFD == nil {
                    receivedFD = chunkFD
                } else if let chunkFD {
                    close(chunkFD)
                }
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
