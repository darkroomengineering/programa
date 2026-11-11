import Foundation
import Darwin
import Security
import Bonsplit

enum SessionEscrowPolicy {
    static let heartbeatInterval: TimeInterval = 2.0
    static let heartbeatStaleAfter: TimeInterval = 6.0
    static let recvTimeoutSeconds: Int = 3
    static let nonProductionDisconnectedExitAfter: TimeInterval = 30 * 60

    #if DEBUG
    private static let isDebugBuild = true
    #else
    private static let isDebugBuild = false
    #endif

    static func isNonProductionHolder(isDebugBuild: Bool = isDebugBuild, socketPath: String) -> Bool {
        let name = URL(fileURLWithPath: socketPath).lastPathComponent
        return isDebugBuild || name.hasPrefix("programa-debug-") || name.hasPrefix("programa-smoke-")
    }

    static func shouldExitDisconnectedHolder(
        disconnectedFor: TimeInterval,
        isNonProduction: Bool
    ) -> Bool {
        isNonProduction && disconnectedFor >= nonProductionDisconnectedExitAfter
    }

    /// Whether a gap since the last successfully-read frame counts as a dead
    /// connection. Takes both timestamps as `ProcessInfo.systemUptime`
    /// values (mach-uptime based, pauses across system sleep) rather than
    /// `Date()`/wall-clock -- a factored-out, unit-testable seam so this
    /// math has a regression test independent of the real socket read loop in `serve`.
    static func isConnectionStale(
        lastActivitySystemUptime: TimeInterval,
        nowSystemUptime: TimeInterval,
        staleAfter: TimeInterval = heartbeatStaleAfter
    ) -> Bool {
        (nowSystemUptime - lastActivitySystemUptime) >= staleAfter
    }

    /// Whether a connection whose heartbeat went stale should start
    /// draining its sessions. Only when the peer pid is known to be gone
    /// (`kill(pid, 0)` fails with `ESRCH`); an unknown pid keeps the
    /// staleness backstop. `processProbe` returns `kill`'s result and errno.
    static func shouldDrainOnStaleHeartbeat(
        peerPID: pid_t?,
        processProbe: (pid_t) -> (result: Int32, errno: Int32) = { pid in
            let result = kill(pid, 0)
            return (result, result == 0 ? 0 : errno)
        }
    ) -> Bool {
        guard let peerPID, peerPID > 0 else { return true }
        let probe = processProbe(peerPID)
        return probe.result != 0 && probe.errno == ESRCH
    }
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
    /// fallback restore). This limit applies only to sessions absent from
    /// this bundle's durable snapshot. Snapshot-owned sessions survive long
    /// absences; unreadable snapshots defer expiry conservatively.
    static let unclaimedSessionTTL: TimeInterval = 3600

    static func shouldExpireSession(
        sessionID: String,
        isDraining: Bool,
        drainingStartedAt: Date?,
        now: Date,
        ownedSessionIDs: Set<String>?
    ) -> Bool {
        guard isDraining, let drainingStartedAt, let ownedSessionIDs,
              !ownedSessionIDs.contains(sessionID.uppercased()) else { return false }
        return now.timeIntervalSince(drainingStartedAt) >= unclaimedSessionTTL
    }
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
