import Foundation
import Darwin
import Security
import Bonsplit

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
        /// drain thread to stop after its current read. Set it through
        /// `requestStop()`, which also wakes the drain thread's `poll`.
        var stopRequested = false
        /// Self-pipe that wakes the drain thread's `poll` on a stop request
        /// instead of waiting out `drainPollIntervalMilliseconds`. Opened only
        /// once draining starts (`openWakePipeIfNeeded`), so a held-but-live
        /// session costs the holder one fd, not three. -1 until then, or when
        /// `pipe()` failed; the drain then falls back to the poll interval.
        private(set) var wakeReadFD: Int32 = -1
        private(set) var wakeWriteFD: Int32 = -1
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

        /// Opens the stop self-pipe. Idempotent; callers must hold
        /// `SessionEscrowHolder.registryLock`.
        func openWakePipeIfNeeded() {
            guard wakeReadFD < 0 else { return }
            var wakePipe: [Int32] = [-1, -1]
            guard pipe(&wakePipe) == 0 else { return }
            for wakeFD in wakePipe {
                _ = UnixDomainFDPassing.setCloseOnExec(on: wakeFD)
                let flags = fcntl(wakeFD, F_GETFL, 0)
                if flags >= 0 { _ = fcntl(wakeFD, F_SETFL, flags | O_NONBLOCK) }
            }
            wakeReadFD = wakePipe[0]
            wakeWriteFD = wakePipe[1]
        }

        /// Asks the drain thread to stop and wakes its `poll`. Callers must
        /// hold `SessionEscrowHolder.registryLock`.
        func requestStop() {
            stopRequested = true
            guard wakeWriteFD >= 0 else { return }
            var byte: UInt8 = 1
            // Non-blocking: a full pipe already guarantees a wakeup.
            _ = write(wakeWriteFD, &byte, 1)
        }

        /// Empties the self-pipe after a wakeup (non-blocking reads).
        func consumeWakeups() {
            guard wakeReadFD >= 0 else { return }
            var sink = [UInt8](repeating: 0, count: 64)
            while read(wakeReadFD, &sink, sink.count) > 0 {}
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
            if wakeReadFD >= 0 { close(wakeReadFD) }
            if wakeWriteFD >= 0 { close(wakeWriteFD) }
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
            guard UnixDomainFDPassing.peerIsCurrentUser(clientFD) else {
                dilog("escrow.conn", "refused connFD=\(clientFD) reason=peer_uid_mismatch")
                close(clientFD)
                continue
            }
            _ = UnixDomainFDPassing.setCloseOnExec(on: clientFD)
            UnixDomainFDPassing.suppressSigPipe(on: clientFD)
            let peerPID = UnixDomainFDPassing.peerPID(clientFD)
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
                serve(connectionFD: clientFD, peerPID: peerPID)
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
    private static func serve(connectionFD: Int32, peerPID: pid_t?) {
        var timeout = timeval(tv_sec: SessionEscrowPolicy.recvTimeoutSeconds, tv_usec: 0)
        setsockopt(connectionFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var registeredSessionIds: Set<String> = []
        // `ProcessInfo.systemUptime` is backed by the non-continuous mach clock: it
        // stops advancing while the machine is asleep and jumps back in at the same
        // value it had when sleep began. `Date()`/wall-clock elapsed time, by
        // contrast, includes however long the Mac was asleep -- which is routinely
        // far more than `heartbeatStaleAfter` (6s). Using wall-clock here meant every
        // sleep/wake cycle longer than 6s made the holder declare EVERY escrowed
        // session on this connection dead the instant the recv() timeout next fired
        // after wake (the app was suspended too, so no heartbeat could have arrived
        // during sleep either) and start draining -- reading from the same dup'd PTY
        // master the still-alive app was also reading from, racing it for bytes and
        // corrupting/freezing every terminal until the app was force-quit and
        // relaunched. `systemUptime` measures only time the machine was actually
        // awake, so a heartbeat sent right before sleep and the next one sent right
        // after wake are correctly seen as adjacent, not six-hours-apart.
        var lastActivity = ProcessInfo.processInfo.systemUptime

        readLoop: while true {
            switch readFrame(connectionFD: connectionFD) {
            case .eof:
                dilog("escrow.conn", "death connFD=\(connectionFD) reason=eof drainedCount=\(registeredSessionIds.count)")
                break readLoop
            case .timeout:
                let now = ProcessInfo.processInfo.systemUptime
                if SessionEscrowPolicy.isConnectionStale(lastActivitySystemUptime: lastActivity, nowSystemUptime: now) {
                    let elapsed = now - lastActivity
                    // A missed heartbeat alone does not prove death: App Nap,
                    // SIGSTOP or a debugger pause stall the app's timer while
                    // Ghostty still reads the same masters. A dead app always
                    // closes this socket (close-on-exec), so drain on staleness
                    // only once the peer pid is gone.
                    guard SessionEscrowPolicy.shouldDrainOnStaleHeartbeat(peerPID: peerPID) else {
                        dilog("escrow.conn", "heartbeat_stale_peer_alive connFD=\(connectionFD) peerPID=\(peerPID.map(String.init) ?? "nil") awakeElapsed=\(String(format: "%.1f", elapsed)) sessions=\(registeredSessionIds.count)")
                        lastActivity = now
                        continue readLoop
                    }
                    dilog("escrow.conn", "death connFD=\(connectionFD) reason=heartbeat_stale awakeElapsed=\(String(format: "%.1f", elapsed)) drainedCount=\(registeredSessionIds.count)")
                    break readLoop
                }
            case .data(let payload, let fd):
                lastActivity = ProcessInfo.processInfo.systemUptime
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
            session.openWakePipeIfNeeded()
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
        let candidate = registry[sessionId]
        let decision = HolderRetrieveDecision.decide(
            sessionExists: candidate != nil,
            tokenMatches: candidate.map { constantTimeTokensEqual($0.token, token) } ?? false,
            isDraining: candidate?.isDraining ?? false
        )
        guard case .grant = decision, let session = candidate else {
            registryLock.unlock()
            if case .deny(let reason) = decision {
                deny(reason: reason, label: HolderRetrieveDecision.label(for: reason))
            }
            return
        }
        // Remove immediately: no second caller can ever observe this
        // session id in the registry again, regardless of how the rest of
        // this function turns out.
        registry.removeValue(forKey: sessionId)
        session.requestStop()
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
    static func constantTimeTokensEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
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
    /// out any session absent from the snapshot that has been draining past
    /// `SessionEscrowPolicy.unclaimedSessionTTL`, and (2) exit the holder
    /// once it has had nothing to hold and no live connection for
    /// `SessionEscrowPolicy.idleExitGrace`. Both halves prevent an
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

    /// Closes out draining sessions absent from this bundle's snapshot whose
    /// `drainingStartedAt` exceeds `SessionEscrowPolicy.unclaimedSessionTTL`.
    /// Mirrors `handleRetrieveRequest`'s drain/retrieve
    /// coordination exactly (remove-from-registry, request-stop, wait on
    /// the semaphore, then close) so an expiry can never race a drain
    /// thread's in-flight read the way a bare `close()` would. Unlike a
    /// retrieval, nothing receives this fd, so `markHandedOff()` is never
    /// called -- only `markClosedIfNeeded()`.
    private static func retireExpiredSessions() {
        let now = Date()
        registryLock.lock()
        let candidates = registry.values.filter {
            $0.isDraining && $0.drainingStartedAt.map {
                now.timeIntervalSince($0) >= SessionEscrowPolicy.unclaimedSessionTTL
            } == true
        }
        registryLock.unlock()
        guard !candidates.isEmpty else { return }
        // Disk reads must never block registry operations or the drain threads.
        let owned = SessionPersistenceStore.ownedTerminalSessionIDs()
        var expired: [HeldSession] = []
        registryLock.lock()
        for session in candidates {
            if registry[session.sessionId] === session,
               SessionEscrowPolicy.shouldExpireSession(
                   sessionID: session.sessionId,
                   isDraining: session.isDraining,
                   drainingStartedAt: session.drainingStartedAt,
                   now: now,
                   ownedSessionIDs: owned
               ) {
                expired.append(session)
                registry.removeValue(forKey: session.sessionId)
                session.requestStop()
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
                guard !chunk.isEmpty else {
                    if let fd { close(fd) }
                    if let capturedFD { close(capturedFD) }
                    return .eof
                }
                collected.append(chunk)
                if capturedFD == nil {
                    capturedFD = fd
                } else if let fd {
                    close(fd)
                }
            case .eof, .error:
                if let capturedFD { close(capturedFD) }
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
    /// the app -- and never blocks in a bare `read()`: it `poll()`s
    /// first (bounded, `SessionEscrowPolicy.drainPollIntervalMilliseconds`)
    /// so `session.stopRequested` (set by a retrieval, see
    /// `handleRetrieveRequest`) is noticed promptly even while the child is
    /// producing no output. See the file-level "Drain/retrieve
    /// coordination" doc comment for the full contract. This method does NOT unconditionally close
    /// `session.fd` on every exit path -- only on a genuine end-of-stream
    /// (the child truly exited). Stopping for a retrieval must leave the fd
    /// open and untouched so it can be handed back; closing it here would
    /// SIGHUP the child.
    private static func drain(session: HeldSession) {
        let paths = SessionWALPaths.make(sessionId: session.sessionId)
        // Capturing to wal.log is best effort; holding the master is not. A
        // missing path or a failed append stops capture for this session but
        // keeps reading (so the child never blocks on a full PTY buffer) and
        // keeps the master retrievable -- see `SessionEscrowPolicy.drainAction`.
        var capturePaths = paths
        if paths == nil {
            dilog("escrow.drain", "capture_off session=\(session.sessionId.prefix(8)) reason=no_paths")
        }
        if let paths {
            try? FileManager.default.createDirectory(at: paths.sessionDirectory, withIntermediateDirectories: true)
        }
        var currentSize = paths.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.walURL.path))?[.size] as? Int64 } ?? 0
        var totalDrained: Int64 = 0
        var lastWALSyncAt = Date.distantPast
        var hasUnsynchronizedWrites = false

        // Never change this fd's flags. O_NONBLOCK lives on the open file
        // description shared with ghostty's copy of the master, and a drain
        // can start while the app is still alive (a connection EOF after a
        // failed send). Clearing it there leaves ghostty's pty reader in a
        // blocking read() that its quit pipe cannot interrupt, so closing
        // that terminal hangs the main thread in ghostty_surface_free. The
        // loop below polls before every read and treats EAGAIN as "keep
        // waiting", so it works with the fd left non-blocking.
        #if DEBUG
        dlog("session.escrow.holder.drain.start session=\(session.sessionId.prefix(8)) fd=\(session.fd) walPath=\(paths?.walURL.path ?? "nil") startSize=\(currentSize)")
        #endif

        var buffer = [UInt8](repeating: 0, count: SessionEscrowPolicy.drainReadBufferSize)
        var outcome = DrainOutcome.closeMaster
        readLoop: while true {
            if isStopRequested(session) {
                outcome = .stoppedForRetrieve
                break readLoop
            }

            // Capture admission before reading, so a chunk read around an
            // off/on transition cannot be written under the newer generation.
            let capturePolicy = capturePaths?.policyPaths.flatMap { try? SessionScrollbackPolicyStore.read(at: $0) }

            // poll() the master and the stop self-pipe together, bounded,
            // so a retrieval's `requestStop()` wakes this thread at once and
            // the bound only paces WAL syncs and policy re-reads. See the
            // file-level "Drain/retrieve coordination" doc comment.
            var pollFDs = [
                pollfd(fd: session.fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: session.wakeReadFD, events: Int16(POLLIN), revents: 0),
            ]
            let pollResult = poll(&pollFDs, nfds_t(pollFDs.count), SessionEscrowPolicy.drainPollIntervalMilliseconds)
            if pollResult < 0 {
                let pollErrno = errno
                if pollErrno == EINTR { continue readLoop }
                dilog("escrow.drain", "end session=\(session.sessionId.prefix(8)) reason=poll_error errno=\(pollErrno) totalDrained=\(totalDrained) master=kept")
                outcome = drainOutcome(for: .pollFailed) ?? .keepMaster
                break readLoop
            }
            if pollFDs[1].revents != 0 {
                session.consumeWakeups()
            }
            guard pollFDs[0].revents != 0 else {
                // Timed out (or only woken) with nothing readable -- loop
                // back to re-check `stopRequested` rather than blocking.
                let now = Date()
                if hasUnsynchronizedWrites, let paths,
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
                // EAGAIN/EWOULDBLOCK means "no data right now", not EOF (the
                // fd stays non-blocking, and another reader may have taken
                // the bytes poll reported), so keep waiting and never close
                // the fd for it. EINTR is a plain retry. Anything else (EIO
                // once the slave side is gone) ends the session.
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK || readErrno == EINTR {
                    continue readLoop
                }
                #if DEBUG
                dlog("session.escrow.holder.drain.end session=\(session.sessionId.prefix(8)) reason=error errno=\(readErrno) totalDrained=\(totalDrained)")
                #endif
                outcome = drainOutcome(for: .readFailed) ?? .closeMaster
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
                outcome = drainOutcome(for: .endOfStream) ?? .closeMaster
                break readLoop
            }
            guard let walPaths = capturePaths, let capturePolicy, capturePolicy.enabled else { continue readLoop }
            let chunk = Data(buffer.prefix(n))
            let now = Date()
            let shouldSynchronize =
                now.timeIntervalSince(lastWALSyncAt) >= SessionWALPolicy.walSyncInterval
            let appendResult: SessionWALCore.AppendResult
            do {
                appendResult = try SessionWALCore.append(
                    chunk,
                    to: walPaths,
                    synchronize: shouldSynchronize,
                    capturedGeneration: capturePolicy.generation
                )
            } catch {
                dilog("escrow.drain", "capture_off session=\(session.sessionId.prefix(8)) reason=wal_append_failed error=\(error) totalDrained=\(totalDrained) master=kept")
                guard let failureOutcome = drainOutcome(for: .walAppendFailed) else {
                    capturePaths = nil
                    continue readLoop
                }
                outcome = failureOutcome
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
                outcome = .stoppedForRetrieve
                break readLoop
            }
        }
        if hasUnsynchronizedWrites, let paths {
            try? SessionWALCore.synchronizeWAL(at: paths)
        }
        endDraining(session: session, outcome: outcome)
    }

    /// How a drain thread ended. Decides what happens to the master.
    enum DrainOutcome: Equatable {
        /// A retrieval or expiry asked to stop; the waiter owns the fd next.
        case stoppedForRetrieve
        /// The drain cannot continue, but the child may still be alive: keep
        /// the master in the registry so it stays retrievable (and expirable).
        case keepMaster
        /// The child is gone: close the master and forget the session.
        case closeMaster
    }

    /// Faults the drain loop can hit after it started.
    enum DrainFault {
        case walAppendFailed, pollFailed, readFailed, endOfStream
    }

    /// Pure decision seam for the drain loop. `nil` means "keep draining
    /// without capture". Only a master-side end of stream or read error
    /// closes the master: a WAL write failure (disk full, EIO) or a `poll`
    /// failure must never SIGHUP the escrowed child.
    static func drainOutcome(for fault: DrainFault) -> DrainOutcome? {
        switch fault {
        case .walAppendFailed: return nil
        case .pollFailed: return .keepMaster
        case .readFailed, .endOfStream: return .closeMaster
        }
    }

    private static func isStopRequested(_ session: HeldSession) -> Bool {
        registryLock.lock()
        defer { registryLock.unlock() }
        return session.stopRequested
    }

    /// Common drain exit bookkeeping. `.stoppedForRetrieve` means a
    /// retrieval (or expiry) asked this thread to stop -- the fd must be
    /// left open and untouched (the caller waiting on
    /// `drainStoppedSemaphore` owns what happens to the fd next).
    /// `.keepMaster` leaves the fd open and registered for the same reason.
    /// `.closeMaster` means a genuine end-of-stream or master read error --
    /// the child is gone, so this IS the final close, and the session is
    /// removed from the registry so a stray later retrieve cleanly denies
    /// instead of finding a stale entry.
    private static func endDraining(session: HeldSession, outcome: DrainOutcome) {
        switch outcome {
        case .stoppedForRetrieve, .keepMaster:
            // `keepMaster` leaves the session registered and draining, with
            // no thread reading it: a later retrieve or expiry consumes this
            // signal immediately instead of timing out.
            session.drainStoppedSemaphore.signal()
            return
        case .closeMaster:
            break
        }
        registryLock.lock()
        session.markClosedIfNeeded()
        registry.removeValue(forKey: session.sessionId)
        registryLock.unlock()
    }
}
