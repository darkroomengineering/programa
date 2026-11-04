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
/// `ghostty_surface_pty_master_fd(surface)` and duplicates it
/// (`F_DUPFD_CLOEXEC`) once the child
/// PID is known -- both on the main actor, matching the existing sibling
/// accessor calls' cost class. The dup and the actual socket send are
/// deliberately split: only the cheap duplicate syscall happens on main; the
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
/// process is wedged rather than exited. That backstop measures elapsed
/// time with `ProcessInfo.systemUptime` (pauses across system sleep), not
/// `Date()` (wall clock, keeps advancing through sleep) -- see `serve`'s
/// death-detection loop for why: with wall clock, any sleep/wake cycle
/// longer than `heartbeatStaleAfter` false-positived every escrowed
/// session as dead the moment the app woke back up, because neither side
/// could have sent/received a heartbeat while the machine was asleep
/// either. Both bounds are small constants,
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
/// never blocks in a bare `read()`: it `poll()`s the fd together with
/// the session's self-pipe (`HeldSession.requestStop()` writes one byte to
/// it), so a stop is noticed immediately even while the child is producing
/// no output at all, and only calls the actual (effectively non-blocking, since
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
