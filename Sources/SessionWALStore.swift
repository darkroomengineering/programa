import Foundation
import Darwin
import Bonsplit

/// Per-surface durable PTY output WAL + fact file (issue #181, slice 1).
///
/// This file used to be the feat/session-wal-spike byte-counting spike
/// (`SessionOutputTapSpike`) that proved tapping PTY output via
/// `ghostty_surface_set_output_tap` has no measurable typing-latency cost.
/// It now replaces that counter with a real writer. The filename is kept
/// as-is (not renamed to SessionWAL.swift) because this change was made by
/// an agent without filesystem move/delete tools; the type names below are
/// renamed. A follow-up `git mv` + pbxproj path/name tweak is cosmetic only.
///
/// ## Threading path, tap callback to fsync
/// 1. `ghostty_surface_set_output_tap`'s C callback fires on ghostty's
///    io-reader thread, under the surface's renderer_state mutex. Per
///    `ghostty/include/ghostty.h`, it must be cheap: copy bytes out, no
///    allocation, no calls back into `ghostty_surface_*`, no blocking.
/// 2. The callback (`sessionWALOutputTapCallback`) does exactly one thing:
///    `SessionWALRingBuffer.append` — a bounded memcpy into a fixed-capacity
///    buffer preallocated at registration time (never in the callback).
/// 3. A single shared background queue (`SessionWALStore.writeQueue`, a
///    serial `DispatchQueue`) runs a periodic timer every ~100ms
///    (`SessionWALPolicy.drainInterval`) that drains every registered
///    surface's ring buffer, appends the bytes to that session's `wal.log`,
///    and calls `FileHandle.synchronizeFile()` (fsync) — so a SIGKILL loses
///    at most one drain interval (~100ms) of output.
/// 4. `meta.json` (the fact file) is refreshed on the same tick, throttled
///    to at most once/second per session unless new bytes were written.
///
/// ## Ring buffer lock, a disclosed pragmatic tradeoff
/// The callback must not allocate or block. A textbook wait-free SPSC ring
/// buffer needs atomics; this project has no swift-atomics dependency, and
/// the macOS 14 deployment target (see project.pbxproj) predates Swift's
/// built-in `Synchronization.Atomic` (macOS 15+). Adding a new dependency is
/// out of scope for this slice. `SessionWALRingBuffer` instead uses
/// `os_unfair_lock` around index bookkeeping + one bounded memcpy — no
/// syscalls, no allocation, single-digit-nanosecond uncontended cost. The
/// only other thread that ever touches the lock is the background drain
/// timer, briefly, once per ~100ms, so contention is negligible relative to
/// a keystroke-latency budget. This is the same category of tradeoff the
/// original spike made explicitly for its own counter; see git history for
/// that comment if useful context.
///
/// ## WAL cap / rotation
/// Each session's `wal.log` is capped at `SessionWALPolicy.walCapBytes` (8
/// MB). When a write would exceed the cap, the current file is rotated to
/// `wal.log.1` (overwriting any previous rotation) and a fresh `wal.log` is
/// started. Restore reads `wal.log.1` then `wal.log`, in that order, and
/// keeps only the tail if the combined size still exceeds the cap. A session
/// open for days therefore never grows past ~2x the cap on disk, and restore
/// always has a bounded tail to read.
///
/// ## Fact file
/// `meta.json` is intentionally minimal: session id, cwd, a heartbeat
/// timestamp, and `childPID`/`ptyPath` (via `ghostty_surface_child_pid` and
/// `ghostty_surface_pty_path`, exposed in `ghostty/include/ghostty.h`).
/// Both are resolved by `TerminalSurface` from its own already-valid
/// surface handle right after registration, with a bounded main-actor
/// retry if the child has not spawned yet, then pushed into this store as
/// plain values via `updateSurfaceIdentity` -- `SessionWALStore` itself
/// never retains a raw `ghostty_surface_t` past the synchronous call that
/// registers the tap, so there is nothing to dereference after a surface
/// tears down. Either field can legitimately stay nil for the lifetime of
/// a session whose child never spawns. Issue #182 is expected to extend
/// this schema with richer heartbeat fields; keep additions optional.
///
/// ## Periodic frame capture (issue #181 layer L1, `docs/plans/detached-sessions.md`)
/// A flat WAL byte tail replays PTY output from an arbitrary starting point,
/// so it can't reproduce cursor position, scroll region, alt-screen state,
/// or styling exactly. To fix that without replaying a long arbitrary tail,
/// each writer also captures a periodic screen "frame": a VT-formatted dump
/// of the CURRENT SCREEN ONLY (`write_screen_file:copy,vt`'s `.screen`
/// location in ghostty — the visible viewport, not the scrollback history;
/// see `ghostty/src/Surface.zig` `writeScreenFile`), the same styled export
/// already used at quit/autosave for scrollback snapshots
/// (`TerminalController.readTerminalTextFromVTExportForSnapshot`).
/// - Cadence: at most once every `SessionWALPolicy.frameCaptureInterval`
///   (~25s) per session, gated by a lighter `frameCaptureCheckInterval`
///   (~5s) sweep timer. A session with no new WAL bytes since its last
///   captured frame is skipped entirely (`SessionWALWriter.totalBytesWrittenEver`
///   vs `lastFrameCaptureBytes`) — idle sessions never pay the main-thread
///   VT-export cost.
/// - The VT export itself is main-thread/AppKit-bound (NSPasteboard swap),
///   so `SessionWALStore` never calls it directly. It's injected via
///   `frameTextProvider` (wired once in `TerminalController.init` to
///   `captureSessionWALFrameText(forSurfaceId:)`, looked up through
///   `TerminalSurfaceRegistry.shared.allSurfaces()`), invoked with a
///   completion handler so the writeQueue can hop to main and back without
///   blocking. If capture fails, times out, or returns empty text, that
///   attempt is simply skipped (rate-limited by `lastFrameCaptureAttemptAt`
///   either way) — the plain WAL tail below is always the fallback.
/// - Written atomically: `frame.vt.next` is written, fsync'd, then moved
///   over `frame.vt` with a single `rename(2)` call (`Darwin.rename`, not
///   `FileManager.moveItem`, which refuses to replace an existing
///   destination) — a reader always sees either the complete new frame or
///   the complete previous one, never a torn write.
/// - The WAL byte offset AND the writer's rotation generation
///   (`SessionWALWriter.walGeneration`, incremented every time `wal.log` is
///   rotated to `wal.log.1`) are recorded alongside the frame in
///   `frame.meta.json`, snapshotted on the writeQueue *before* the
///   main-thread export runs (so the recorded offset is always <= the
///   frame's true content, never past it — worst case on restore is a few
///   bytes of harmless duplicate replay, never dropped bytes). Restore
///   compares `frame.meta.json`'s generation against `meta.json`'s current
///   `walGeneration`: if they differ, at least one rotation happened since
///   the frame was captured, the recorded offset no longer points into the
///   right file, and the frame is treated as too old (fall back to the
///   plain tail below).
///
/// ## Restore fallback
/// `Workspace+Persistence.swift`'s `createPanel(from:inPane:)` already
/// replays saved scrollback text via `SessionScrollbackReplayStore`. When a
/// persisted `SessionPanelSnapshot.terminal?.scrollback` is missing or blank
/// (the app died before the next autosave/clean-quit snapshot captured it),
/// it falls back to `SessionWALStore.shared.readFallbackScrollbackText(sessionId:)`
/// for that same OLD panel/surface id (`SessionPanelSnapshot.id` — the same
/// UUID a session's WAL directory is named after, since `TerminalPanel.id ==
/// TerminalSurface.id`). That method prefers a captured frame + WAL delta
/// (see "Periodic frame capture" above) when a usable one exists, and falls
/// back to the plain WAL tail otherwise. Either way the returned text is fed
/// through the exact same `SessionScrollbackReplayStore`/
/// `SessionPersistencePolicy` ANSI-safe truncation path as clean-quit
/// scrollback, so this is purely an alternative source of the same kind of
/// text, not a parallel restore path.
///
/// ## Cleanup
/// - A surface that tears down for real (`TerminalSurface.teardownSurface()`
///   or `deinit`, whichever actually runs the free — the other is a no-op
///   guarded by `surface == nil`) deletes its session directory.
/// - Once restore has consumed (or found empty) an old session's WAL as
///   fallback, `Workspace+Persistence.swift` calls
///   `SessionWALStore.shared.discardOrphanedSession(sessionId:)` to delete
///   that specific old directory immediately. This is safe because it only
///   runs after `createPanel(from:inPane:)` has already performed its one
///   synchronous read of that directory's WAL tail.
/// - Five seconds after the first registration each launch, a one-time sweep
///   considers deleting any session directory that has no live writer. This
///   is deliberately conservative (issue #181 postmortem: an earlier version
///   deleted any no-live-writer directory unconditionally, which could race
///   ahead of a slow/multi-panel restore and destroy a WAL that
///   `createPanel` had not read yet). A directory is only removed here if
///   its `meta.json` heartbeat (or, if that can't be parsed, its own
///   filesystem modification date) is older than
///   `SessionWALPolicy.orphanDirectoryMaxAge`. A directory whose age cannot
///   be determined at all is kept. This only catches sessions from a run
///   further back than the current snapshot references, not anything from
///   the run that is currently restoring.
enum SessionWALPolicy {
    /// Fixed capacity of the in-memory ring buffer the tap callback writes
    /// into. Large enough to absorb a burst between 100ms drains for normal
    /// interactive/agent output; a sustained flood faster than this drops
    /// its oldest interior bytes (documented tradeoff, never blocks).
    static let ringBufferCapacityBytes = 64 * 1024
    /// Per-session wal.log cap before rotating to wal.log.1.
    static let walCapBytes: Int64 = 8 * 1024 * 1024
    static let drainInterval: TimeInterval = 0.1
    static let metaRefreshInterval: TimeInterval = 1.0
    static let orphanSweepDelay: TimeInterval = 5.0
    /// Minimum spacing between successful/attempted frame captures for a
    /// single session. Deliberately slow (20-30s) since capture is
    /// main-thread/AppKit-bound; never runs on the WAL's 100ms drain cadence.
    static let frameCaptureInterval: TimeInterval = 25.0
    /// How often the writeQueue timer wakes to check which writers are due
    /// for a frame capture. Lighter than `frameCaptureInterval` itself so a
    /// writer becoming eligible doesn't wait a full cycle before capture.
    static let frameCaptureCheckInterval: TimeInterval = 5.0
    /// A session directory with no live writer is only eligible for deletion
    /// by the sweep once it is at least this old (by `meta.json` heartbeat,
    /// or filesystem modification date as a fallback). Generous on purpose:
    /// this is the backstop against destroying not-yet-restored crash data,
    /// not the primary cleanup path (that's `discardOrphanedSession`, which
    /// only runs after a directory has actually been consumed).
    static let orphanDirectoryMaxAge: TimeInterval = 24 * 60 * 60
}

/// Fixed-size circular byte buffer. `append` is called only from ghostty's
/// io-reader thread (the tap callback); `drain` is called only from
/// `SessionWALStore.writeQueue`. See the type-level doc comment above for
/// the `os_unfair_lock` tradeoff.
final class SessionWALRingBuffer {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<UInt8>
    private var head = 0
    private var count = 0
    private var lock = os_unfair_lock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Tap-callback hot path: copy `len` bytes in, dropping the oldest
    /// buffered bytes first if `len` would overflow capacity. No allocation,
    /// no syscalls, bounded memcpy only.
    func append(_ buf: UnsafePointer<UInt8>, _ len: Int) {
        guard len > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        if len >= capacity {
            let src = buf.advanced(by: len - capacity)
            memcpy(storage, src, capacity)
            head = 0
            count = capacity
            return
        }

        let writeStart = (head + count) % capacity
        let firstChunk = min(len, capacity - writeStart)
        memcpy(storage.advanced(by: writeStart), buf, firstChunk)
        if firstChunk < len {
            memcpy(storage, buf.advanced(by: firstChunk), len - firstChunk)
        }

        let newCount = count + len
        if newCount > capacity {
            head = (head + (newCount - capacity)) % capacity
            count = capacity
        } else {
            count = newCount
        }
    }

    /// Background-queue only: copies out and clears everything currently
    /// buffered. Returns nil if there was nothing to drain.
    func drain() -> [UInt8]? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard count > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        out.withUnsafeMutableBytes { dst in
            let firstChunk = min(count, capacity - head)
            memcpy(dst.baseAddress!, storage.advanced(by: head), firstChunk)
            if firstChunk < count {
                memcpy(dst.baseAddress!.advanced(by: firstChunk), storage, count - firstChunk)
            }
        }
        head = 0
        count = 0
        return out
    }
}

/// Small, deliberately minimal fact file describing a session's PTY for
/// crash recovery ("what was running with zero live processes"). See the
/// file-level "Fact file" doc comment for how `childPID`/`ptyPath` are
/// resolved. Issue #182 is expected to extend this; keep additions optional.
struct SessionWALMeta: Codable {
    var schemaVersion: Int = 1
    var sessionId: String
    var childPID: Int32?
    var ptyPath: String?
    var workingDirectory: String?
    var lastHeartbeatAt: Date
    /// Rotation counter, incremented every time `wal.log` is rotated to
    /// `wal.log.1`. Optional so pre-existing `meta.json` files from before
    /// this field existed decode without failure. Used only by the frame
    /// restore path to detect whether a captured frame's recorded WAL offset
    /// still points into the current `wal.log` (see the file-level "Periodic
    /// frame capture" doc comment).
    var walGeneration: Int?
    /// Issue #182 slice 1 (`Sources/SessionEscrow.swift`): true once this
    /// session's PTY master fd has been successfully handed off to the
    /// escrow holder via `SCM_RIGHTS`. Optional/nil for every session from
    /// before this field existed, and for any session where escrow was
    /// never attempted or failed (degrades silently, see
    /// `SessionEscrowClient`) -- absence means "not escrowed", never
    /// "unknown".
    var escrowed: Bool?
    /// The holder's Unix domain socket path at escrow time, so a later
    /// slice's reattach path knows where to ask for the fd back.
    var escrowSocketPath: String?
    /// Hex-encoded capability token generated at escrow time. A later
    /// slice's reattach path must present this back to the holder; the
    /// holder never hands back an fd to a caller without it. This slice
    /// never reads this field back itself -- see `Sources/SessionEscrow
    /// .swift`'s "Token scheme" doc comment.
    var escrowToken: String?
}

/// Sidecar recorded alongside `frame.vt`: the WAL byte offset and rotation
/// generation at the moment the frame was captured. See the file-level
/// "Periodic frame capture" doc comment for why the generation check exists.
struct SessionFrameMeta: Codable {
    var schemaVersion: Int = 1
    var sessionId: String
    var capturedAt: Date
    var walOffset: Int64
    var walGeneration: Int
}

/// Filesystem layout for one session's WAL + fact file, under
/// `Application Support/programa/sessions/<session-uuid>/`. Reuses
/// `SessionPersistenceStore.defaultSnapshotFileURL`'s app-support
/// resolution (bundle id sanitization, Application Support lookup) rather
/// than duplicating it.
struct SessionWALPaths {
    let sessionDirectory: URL
    let walURL: URL
    let walRotatedURL: URL
    let metaURL: URL
    /// Committed frame: a VT-formatted dump of the current screen, written
    /// atomically via `frameNextURL` + fsync + `rename(2)`.
    let frameURL: URL
    /// Staging path for the next frame write, renamed over `frameURL` once
    /// complete. Never read directly by restore.
    let frameNextURL: URL
    /// WAL offset + rotation generation recorded at frame capture time.
    let frameMetaURL: URL

    static func sessionsRootURL(appSupportDirectory: URL? = nil) -> URL? {
        guard let snapshotFileURL = SessionPersistenceStore.defaultSnapshotFileURL(
            appSupportDirectory: appSupportDirectory
        ) else { return nil }
        return snapshotFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
    }

    static func make(sessionId: String, appSupportDirectory: URL? = nil) -> SessionWALPaths? {
        guard let root = sessionsRootURL(appSupportDirectory: appSupportDirectory) else { return nil }
        let directory = root.appendingPathComponent(sessionId, isDirectory: true)
        return SessionWALPaths(
            sessionDirectory: directory,
            walURL: directory.appendingPathComponent("wal.log", isDirectory: false),
            walRotatedURL: directory.appendingPathComponent("wal.log.1", isDirectory: false),
            metaURL: directory.appendingPathComponent("meta.json", isDirectory: false),
            frameURL: directory.appendingPathComponent("frame.vt", isDirectory: false),
            frameNextURL: directory.appendingPathComponent("frame.vt.next", isDirectory: false),
            frameMetaURL: directory.appendingPathComponent("frame.meta.json", isDirectory: false)
        )
    }
}

/// writeQueue-confined per-session state: the tap `Context` (shared with the
/// live ghostty tap), resolved paths, and the open file handle/size/heartbeat
/// bookkeeping needed to append and rotate. A class (not a struct) so the
/// periodic drain tick can mutate fields in place without dictionary
/// reassignment.
private final class SessionWALWriter {
    let context: SessionWALStore.Context
    let paths: SessionWALPaths
    var workingDirectory: String?
    /// Resolved once by `TerminalSurface.resolveSessionWALIdentity` and
    /// pushed in via `SessionWALStore.updateSurfaceIdentity`. May stay nil
    /// for the life of the writer if the child never spawns. See the
    /// file-level "Fact file" doc comment.
    var childPID: Int32?
    /// Resolved the same way as `childPID`, see above.
    var ptyPath: String?
    var fileHandle: FileHandle?
    var currentWalSize: Int64 = 0
    var lastMetaWriteAt: Date = .distantPast
    /// Incremented every time `wal.log` is rotated to `wal.log.1`. Recorded
    /// alongside a captured frame's WAL offset so restore can tell whether a
    /// rotation happened after the frame was captured (see the file-level
    /// "Periodic frame capture" doc comment).
    var walGeneration = 0
    /// Cumulative bytes ever appended to this session's WAL, never reset by
    /// rotation (unlike `currentWalSize`). Used only to detect "no new
    /// output since the last captured frame" so idle sessions skip capture
    /// entirely.
    var totalBytesWrittenEver: Int64 = 0
    /// `totalBytesWrittenEver` as of the last successfully captured frame.
    var lastFrameCaptureBytes: Int64 = 0
    var lastFrameCaptureAttemptAt: Date = .distantPast
    var frameCaptureInFlight = false
    /// Issue #182 slice 1 escrow state, set by `SessionWALStore
    /// .markEscrowed` once `SessionEscrowClient` confirms a successful
    /// hand-off. See `SessionWALMeta`'s matching fields for the contract.
    var escrowed = false
    var escrowSocketPath: String?
    var escrowToken: String?

    init(context: SessionWALStore.Context, paths: SessionWALPaths, workingDirectory: String?) {
        self.context = context
        self.paths = paths
        self.workingDirectory = workingDirectory
    }
}

final class SessionWALStore {
    /// Per-surface userdata handed to the C callback as `userdata` via
    /// `Unmanaged`. Holds ONLY the ring buffer and a stable id string —
    /// never a reference to Swift UI/runtime objects, since the callback
    /// must never touch anything that can lock (beyond the ring buffer's
    /// own short critical section) or allocate.
    final class Context {
        let surfaceId: String
        let ringBuffer: SessionWALRingBuffer

        init(surfaceId: String) {
            self.surfaceId = surfaceId
            self.ringBuffer = SessionWALRingBuffer(capacity: SessionWALPolicy.ringBufferCapacityBytes)
        }
    }

    static let shared = SessionWALStore()

    private let writeQueue = DispatchQueue(label: "com.darkroom.programa.session-wal", qos: .utility)
    private var writersBySurfaceId: [String: SessionWALWriter] = [:]
    private var drainTimer: DispatchSourceTimer?
    private var frameCaptureTimer: DispatchSourceTimer?
    private var hasScheduledOrphanSweep = false
    /// Injected once (`TerminalController.init` wires this to
    /// `captureSessionWALFrameText(forSurfaceId:)`) since VT export is
    /// main-thread/AppKit-bound and `SessionWALStore` must never touch
    /// AppKit itself. Only ever read/written on `writeQueue`. Takes a
    /// completion handler (called on an unspecified queue) rather than
    /// returning synchronously so the writeQueue can hop to main and back
    /// without blocking.
    private var frameTextProvider: ((String, @escaping (String?) -> Void) -> Void)?

    private static let metaEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Mirrors `metaEncoder`'s date strategy. Used only by the orphan sweep's
    /// conservative age check, never on the tap-callback/write hot path.
    private static let metaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {}

    /// Registers the output tap for a newly created surface and starts its
    /// WAL writer off-main. The caller (`TerminalSurface`) must hold onto
    /// the returned `Unmanaged<Context>` and release it exactly once, right
    /// after clearing the tap at teardown via `unregister`.
    func register(
        surface: ghostty_surface_t,
        surfaceId: String,
        workingDirectory: String?
    ) -> Unmanaged<Context> {
        let context = Context(surfaceId: surfaceId)
        let unmanaged = Unmanaged<Context>.passRetained(context)

        ghostty_surface_set_output_tap(surface, sessionWALOutputTapCallback, unmanaged.toOpaque())

        writeQueue.async { [weak self] in
            self?.startWriter(surfaceId: surfaceId, context: context, workingDirectory: workingDirectory)
        }
        return unmanaged
    }

    /// Clears the tap (passing a NULL callback, per the C API contract),
    /// flushes any remaining buffered bytes, and forgets the writer.
    /// `deleteDirectory` should be `true` only at a surface's genuine final
    /// teardown (normal close) — see the file-level "Cleanup" doc comment.
    func unregister(surface: ghostty_surface_t?, surfaceId: String, deleteDirectory: Bool = false) {
        if let surface {
            ghostty_surface_set_output_tap(surface, nil, nil)
        }
        writeQueue.async { [weak self] in
            self?.stopWriter(surfaceId: surfaceId, deleteDirectory: deleteDirectory)
        }
    }

    /// Wires the main-thread/AppKit-bound VT screen export in
    /// (`TerminalController.captureSessionWALFrameText(forSurfaceId:)`).
    /// Safe to call once at app startup, before or after any surface
    /// registers; the periodic frame-capture tick reads this lazily.
    func setFrameTextProvider(_ provider: @escaping (String, @escaping (String?) -> Void) -> Void) {
        writeQueue.async { [weak self] in
            self?.frameTextProvider = provider
        }
    }

    /// Pushes newly resolved `childPID`/`ptyPath` values in from
    /// `TerminalSurface.resolveSessionWALIdentity` (see the file-level
    /// "Fact file" doc comment). Only fills fields that are still nil --
    /// never overwrites an already-resolved value, and passing nil here
    /// just means "still unknown", not "clear it". Forces an immediate meta
    /// write when something actually changed so a freshly resolved PID
    /// doesn't sit behind the up-to-1s heartbeat throttle; a no-op if the
    /// writer has already been torn down or nothing changed.
    func updateSurfaceIdentity(surfaceId: String, childPID: Int32?, ptyPath: String?) {
        guard childPID != nil || ptyPath != nil else { return }
        writeQueue.async { [weak self] in
            guard let self, let writer = self.writersBySurfaceId[surfaceId] else { return }
            var changed = false
            if writer.childPID == nil, let childPID {
                writer.childPID = childPID
                changed = true
            }
            if writer.ptyPath == nil, let ptyPath {
                writer.ptyPath = ptyPath
                changed = true
            }
            guard changed else { return }
            let now = Date()
            self.writeMeta(writer: writer, at: now)
            writer.lastMetaWriteAt = now
        }
    }

    /// Records a successful escrow hand-off (issue #182 slice 1, `Sources
    /// /SessionEscrow.swift`). Forces an immediate meta write, same as
    /// `updateSurfaceIdentity`, so `meta.json` reflects escrow state
    /// without waiting on the up-to-1s heartbeat throttle. A no-op if the
    /// writer has already been torn down (surface closed before the
    /// escrow round-trip completed).
    func markEscrowed(surfaceId: String, socketPath: String, token: String) {
        writeQueue.async { [weak self] in
            guard let self, let writer = self.writersBySurfaceId[surfaceId] else { return }
            writer.escrowed = true
            writer.escrowSocketPath = socketPath
            writer.escrowToken = token
            let now = Date()
            self.writeMeta(writer: writer, at: now)
            writer.lastMetaWriteAt = now
        }
    }

    /// Resolves a surface's child PID and PTY slave path via the ghostty C
    /// accessors added for issue #182 (`ghostty_surface_child_pid`,
    /// `ghostty_surface_pty_path`). Both take `renderer_state.mutex`
    /// internally and are safe to call on a half-initialized surface --
    /// they just return their sentinel (-1 / false) if the child has not
    /// spawned yet, has already exited, or has no subprocess. Deliberately
    /// a static, stateless call: `SessionWALStore` never retains the
    /// `surface` handle passed in here past this one synchronous call.
    /// Callers own the guarantee that `surface` is currently valid --
    /// see `TerminalSurface.resolveSessionWALIdentity`, which re-reads its
    /// own `surface` property fresh on every attempt rather than caching a
    /// raw pointer across a retry delay or a teardown boundary.
    static func resolveSurfaceIdentity(surface: ghostty_surface_t) -> (childPID: Int32?, ptyPath: String?) {
        let rawPID = ghostty_surface_child_pid(surface)
        let childPID: Int32? = rawPID >= 0 ? Int32(exactly: rawPID) : nil

        var buffer = [CChar](repeating: 0, count: 128)
        let ptyPath: String? = buffer.withUnsafeMutableBufferPointer { pointer -> String? in
            guard let base = pointer.baseAddress else { return nil }
            guard ghostty_surface_pty_path(surface, base, UInt(pointer.count)) else { return nil }
            return String(cString: base)
        }

        return (childPID, ptyPath)
    }

    /// Issue #182 slice 2: synchronous, launch-time-only read of a
    /// session's `meta.json`, used by the reattach path
    /// (`Workspace+Persistence.swift`'s `createPanel(from:inPane:)`) to
    /// check escrow bookkeeping (`escrowed`/`escrowSocketPath`
    /// /`escrowToken`/`childPID`) before attempting `SessionEscrowClient
    /// .retrieve`. Same contract as `readFallbackScrollbackText` below --
    /// never call this from a keystroke-hot path.
    func readMeta(sessionId: String) -> SessionWALMeta? {
        guard let paths = SessionWALPaths.make(sessionId: sessionId),
              let data = try? Data(contentsOf: paths.metaURL) else { return nil }
        return try? Self.metaDecoder.decode(SessionWALMeta.self, from: data)
    }

    /// Restore-path fallback read. Synchronous and launch-time only (mirrors
    /// `SessionPersistenceStore.load`'s synchronous snapshot read) — never
    /// called from the tap callback or any latency-sensitive path. Reads the
    /// rotated tail (if any) then the current file, capped to
    /// `SessionWALPolicy.walCapBytes`, and decodes leniently since PTY bytes
    /// may include partial UTF-8 sequences at the truncation boundary.
    func readFallbackScrollbackText(sessionId: String) -> String? {
        if let frameReplay = readFrameAndDeltaScrollbackText(sessionId: sessionId) {
            return frameReplay
        }
        guard let paths = SessionWALPaths.make(sessionId: sessionId) else { return nil }
        var combined = Data()
        if let rotated = try? Data(contentsOf: paths.walRotatedURL) {
            combined.append(rotated)
        }
        if let current = try? Data(contentsOf: paths.walURL) {
            combined.append(current)
        }
        guard !combined.isEmpty else { return nil }
        if combined.count > SessionWALPolicy.walCapBytes {
            combined = combined.suffix(Int(SessionWALPolicy.walCapBytes))
        }
        return String(decoding: combined, as: UTF8.self)
    }

    /// Prefers a captured frame + WAL delta over the plain tail. Returns nil
    /// (caller falls back to the plain tail above) when no frame exists, the
    /// frame's recorded `walGeneration` doesn't match `meta.json`'s current
    /// one (a rotation happened after the frame was captured, so the
    /// recorded offset no longer points into the right file), or any read is
    /// internally inconsistent. Synchronous, direct-file-read, launch-time
    /// only -- same contract as `readFallbackScrollbackText` above, and
    /// safe for the same reason: `sessionId` here is always an OLD
    /// (pre-restore) id with no live writer in `writersBySurfaceId`, so
    /// there's no writeQueue state to coordinate with.
    private func readFrameAndDeltaScrollbackText(sessionId: String) -> String? {
        guard let paths = SessionWALPaths.make(sessionId: sessionId) else { return nil }
        guard let frameMetaData = try? Data(contentsOf: paths.frameMetaURL),
              let frameMeta = try? Self.metaDecoder.decode(SessionFrameMeta.self, from: frameMetaData) else {
            return nil
        }
        guard let frameData = try? Data(contentsOf: paths.frameURL), !frameData.isEmpty else {
            return nil
        }
        let frameText = String(decoding: frameData, as: UTF8.self)

        let currentGeneration: Int
        if let sessionMetaData = try? Data(contentsOf: paths.metaURL),
           let sessionMeta = try? Self.metaDecoder.decode(SessionWALMeta.self, from: sessionMetaData) {
            currentGeneration = sessionMeta.walGeneration ?? 0
        } else {
            currentGeneration = 0
        }
        guard frameMeta.walGeneration == currentGeneration else {
            // wal.log rotated after this frame was captured -- the recorded
            // offset no longer points into the right file. Too old.
            return nil
        }

        guard let currentWalData = try? Data(contentsOf: paths.walURL) else {
            // No current wal.log at all; the frame alone is still a valid
            // (if slightly stale) screen state.
            return frameText
        }
        guard frameMeta.walOffset >= 0, Int64(currentWalData.count) >= frameMeta.walOffset else {
            // Inconsistent bookkeeping -- don't guess, fall back to the plain tail.
            return nil
        }
        var deltaData = currentWalData.subdata(in: Int(frameMeta.walOffset)..<currentWalData.count)
        guard !deltaData.isEmpty else { return frameText }
        if deltaData.count > SessionWALPolicy.walCapBytes {
            deltaData = deltaData.suffix(Int(SessionWALPolicy.walCapBytes))
        }
        return frameText + String(decoding: deltaData, as: UTF8.self)
    }

    /// Deletes one specific old session's directory once its restore
    /// fallback has been consumed (or found empty). Safe to call
    /// unconditionally: `sessionId` here is always an OLD (pre-restore)
    /// surface id, distinct from any live surface's freshly generated id.
    func discardOrphanedSession(sessionId: String) {
        writeQueue.async {
            guard let paths = SessionWALPaths.make(sessionId: sessionId) else { return }
            try? FileManager.default.removeItem(at: paths.sessionDirectory)
        }
    }

    // MARK: - writeQueue-confined

    private func startWriter(surfaceId: String, context: Context, workingDirectory: String?) {
        guard let paths = SessionWALPaths.make(sessionId: surfaceId) else { return }
        try? FileManager.default.createDirectory(
            at: paths.sessionDirectory,
            withIntermediateDirectories: true
        )
        // `workingDirectory` is nil whenever the surface was created without an
        // explicit override and ghostty's own config doesn't set one either (the
        // common case for a plain new tab, which then just inherits the PTY's
        // default cwd). meta.json's cwd is meant to answer "what was running"
        // after a crash with zero live processes, so it must never be silently
        // absent -- fall back to the user's home directory, the same default a
        // shell would land in with no explicit cwd.
        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }()
        let writer = SessionWALWriter(context: context, paths: paths, workingDirectory: resolvedWorkingDirectory)
        writersBySurfaceId[surfaceId] = writer
        let now = Date()
        writeMeta(writer: writer, at: now)
        writer.lastMetaWriteAt = now

        ensureDrainTimerStarted()
        ensureFrameCaptureTimerStarted()
        scheduleOrphanSweepIfNeeded()
    }

    private func stopWriter(surfaceId: String, deleteDirectory: Bool) {
        guard let writer = writersBySurfaceId.removeValue(forKey: surfaceId) else { return }
        drain(writer: writer, forceMetaWrite: false)
        writer.fileHandle?.closeFile()
        if deleteDirectory {
            try? FileManager.default.removeItem(at: writer.paths.sessionDirectory)
        }
    }

    private func ensureDrainTimerStarted() {
        guard drainTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        let interval = SessionWALPolicy.drainInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.drainAllWriters()
        }
        timer.resume()
        drainTimer = timer
    }

    private func ensureFrameCaptureTimerStarted() {
        guard frameCaptureTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        let interval = SessionWALPolicy.frameCaptureCheckInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.considerFrameCaptureTick()
        }
        timer.resume()
        frameCaptureTimer = timer
    }

    /// Fires every `frameCaptureCheckInterval`; for each writer that's due
    /// (spaced by `frameCaptureInterval`, not already mid-capture, and has
    /// produced new WAL bytes since its last captured frame) reserves the
    /// current WAL offset/generation *before* handing off to the
    /// main-thread VT export, so the reservation can never be ahead of what
    /// the export actually sees (see file-level doc comment).
    private func considerFrameCaptureTick() {
        guard let frameTextProvider else { return }
        let now = Date()
        for writer in writersBySurfaceId.values {
            guard Self.shouldAttemptFrameCapture(writer: writer, now: now) else { continue }
            writer.frameCaptureInFlight = true
            writer.lastFrameCaptureAttemptAt = now
            let surfaceId = writer.context.surfaceId
            let reservedOffset = writer.currentWalSize
            let reservedGeneration = writer.walGeneration
            let reservedTotalBytes = writer.totalBytesWrittenEver
            frameTextProvider(surfaceId) { [weak self] text in
                self?.writeQueue.async {
                    self?.finishFrameCapture(
                        writer: writer,
                        text: text,
                        reservedOffset: reservedOffset,
                        reservedGeneration: reservedGeneration,
                        reservedTotalBytes: reservedTotalBytes
                    )
                }
            }
        }
    }

    private static func shouldAttemptFrameCapture(writer: SessionWALWriter, now: Date) -> Bool {
        guard !writer.frameCaptureInFlight else { return false }
        guard writer.totalBytesWrittenEver != writer.lastFrameCaptureBytes else { return false }
        return now.timeIntervalSince(writer.lastFrameCaptureAttemptAt) >= SessionWALPolicy.frameCaptureInterval
    }

    /// Completion of a frame capture attempt, always re-entering writeQueue.
    /// A nil/empty `text` means the export failed, timed out, or the
    /// surface is gone by now -- log-and-carry-on, no state mutated beyond
    /// clearing the in-flight flag (retried next time this writer is due,
    /// rate-limited by `lastFrameCaptureAttemptAt` set before the attempt).
    private func finishFrameCapture(
        writer: SessionWALWriter,
        text: String?,
        reservedOffset: Int64,
        reservedGeneration: Int,
        reservedTotalBytes: Int64
    ) {
        writer.frameCaptureInFlight = false
        guard let text, !text.isEmpty else {
#if DEBUG
            dlog("session.wal.frame.capture.skipped surface=\(writer.context.surfaceId.prefix(8)) reason=empty_or_failed")
#endif
            return
        }
        guard writeFrameFile(text: text, writer: writer) else {
#if DEBUG
            dlog("session.wal.frame.capture.failed surface=\(writer.context.surfaceId.prefix(8)) reason=write_or_rename")
#endif
            return
        }
        let frameMeta = SessionFrameMeta(
            sessionId: writer.context.surfaceId,
            capturedAt: Date(),
            walOffset: reservedOffset,
            walGeneration: reservedGeneration
        )
        if let data = try? Self.metaEncoder.encode(frameMeta) {
            try? data.write(to: writer.paths.frameMetaURL, options: .atomic)
        }
        writer.lastFrameCaptureBytes = reservedTotalBytes
    }

    /// Writes `text` to `frame.vt.next`, fsyncs, then commits it over
    /// `frame.vt` with a single `rename(2)` call -- never a bespoke
    /// torn-write detector, rename(2) already gives atomicity on the same
    /// filesystem. Uses `Darwin.rename` directly rather than
    /// `FileManager.moveItem`, which refuses to replace an existing
    /// destination.
    private func writeFrameFile(text: String, writer: SessionWALWriter) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        let nextURL = writer.paths.frameNextURL
        FileManager.default.createFile(atPath: nextURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: nextURL) else { return false }
        handle.write(data)
        handle.synchronizeFile()
        handle.closeFile()
        return Self.atomicRename(from: nextURL, to: writer.paths.frameURL)
    }

    private static func atomicRename(from sourceURL: URL, to destinationURL: URL) -> Bool {
        sourceURL.path.withCString { src in
            destinationURL.path.withCString { dst in
                Darwin.rename(src, dst) == 0
            }
        }
    }

    private func drainAllWriters() {
        for writer in writersBySurfaceId.values {
            drain(writer: writer, forceMetaWrite: false)
        }
    }

    private func drain(writer: SessionWALWriter, forceMetaWrite: Bool) {
        let bytes = writer.context.ringBuffer.drain()
        let hadBytes = (bytes?.isEmpty == false)
        if let bytes, hadBytes {
            appendToWAL(bytes, writer: writer)
        }
        let now = Date()
        if forceMetaWrite || hadBytes
            || now.timeIntervalSince(writer.lastMetaWriteAt) >= SessionWALPolicy.metaRefreshInterval {
            writeMeta(writer: writer, at: now)
            writer.lastMetaWriteAt = now
        }
    }

    private func appendToWAL(_ bytes: [UInt8], writer: SessionWALWriter) {
        if writer.fileHandle == nil {
            if !FileManager.default.fileExists(atPath: writer.paths.walURL.path) {
                FileManager.default.createFile(atPath: writer.paths.walURL.path, contents: nil)
            }
            writer.fileHandle = try? FileHandle(forWritingTo: writer.paths.walURL)
            writer.fileHandle?.seekToEndOfFile()
            let attributes = try? FileManager.default.attributesOfItem(atPath: writer.paths.walURL.path)
            writer.currentWalSize = (attributes?[.size] as? Int64) ?? 0
        }
        guard let handle = writer.fileHandle else { return }

        if writer.currentWalSize + Int64(bytes.count) > SessionWALPolicy.walCapBytes {
            handle.closeFile()
            try? FileManager.default.removeItem(at: writer.paths.walRotatedURL)
            try? FileManager.default.moveItem(at: writer.paths.walURL, to: writer.paths.walRotatedURL)
            FileManager.default.createFile(atPath: writer.paths.walURL.path, contents: nil)
            writer.fileHandle = try? FileHandle(forWritingTo: writer.paths.walURL)
            writer.currentWalSize = 0
            // Bookkeeping only for the frame-capture restore path (see the
            // file-level "Periodic frame capture" doc comment); does not
            // change rotation behavior itself.
            writer.walGeneration += 1
        }

        let data = Data(bytes)
        writer.fileHandle?.write(data)
        writer.fileHandle?.synchronizeFile()
        writer.currentWalSize += Int64(data.count)
        writer.totalBytesWrittenEver += Int64(data.count)
    }

    private func writeMeta(writer: SessionWALWriter, at date: Date) {
        let meta = SessionWALMeta(
            sessionId: writer.context.surfaceId,
            childPID: writer.childPID,
            ptyPath: writer.ptyPath,
            workingDirectory: writer.workingDirectory,
            lastHeartbeatAt: date,
            walGeneration: writer.walGeneration,
            escrowed: writer.escrowed ? true : nil,
            escrowSocketPath: writer.escrowSocketPath,
            escrowToken: writer.escrowToken
        )
        guard let data = try? Self.metaEncoder.encode(meta) else { return }
        try? data.write(to: writer.paths.metaURL, options: .atomic)
    }

    private func scheduleOrphanSweepIfNeeded() {
        guard !hasScheduledOrphanSweep else { return }
        hasScheduledOrphanSweep = true
        writeQueue.asyncAfter(deadline: .now() + SessionWALPolicy.orphanSweepDelay) { [weak self] in
            self?.sweepOrphanedSessionDirectories()
        }
    }

    private func sweepOrphanedSessionDirectories() {
        guard let root = SessionWALPaths.sessionsRootURL() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        let cutoff = Date().addingTimeInterval(-SessionWALPolicy.orphanDirectoryMaxAge)
        for entry in entries {
            let name = entry.lastPathComponent
            guard writersBySurfaceId[name] == nil else { continue }
            guard Self.isDirectoryUnambiguouslyStale(entry, olderThan: cutoff) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Conservative staleness check for the orphan sweep only. Never called
    /// from `discardOrphanedSession` (that path already has a positive
    /// "consumed" signal and doesn't need an age check). Prefers
    /// `meta.json`'s own heartbeat as the freshest signal of last write
    /// activity; falls back to the directory's filesystem modification date
    /// if `meta.json` is missing or unparseable; if neither is available,
    /// keeps the directory rather than guessing.
    private static func isDirectoryUnambiguouslyStale(_ directory: URL, olderThan cutoff: Date) -> Bool {
        let metaURL = directory.appendingPathComponent("meta.json", isDirectory: false)
        if let data = try? Data(contentsOf: metaURL),
           let meta = try? metaDecoder.decode(SessionWALMeta.self, from: data) {
            return meta.lastHeartbeatAt < cutoff
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
              let modifiedDate = attributes[.modificationDate] as? Date else {
            return false
        }
        return modifiedDate < cutoff
    }
}

/// C callback registered via `ghostty_surface_set_output_tap`. Runs on
/// ghostty's io-reader thread under the renderer_state mutex — per the
/// header contract this must stay allocation/lock-free from ghostty's point
/// of view. This body does exactly one thing: hand the bytes to the
/// preallocated ring buffer. Nothing else — no dlog, no DispatchQueue, no
/// file I/O, no Swift runtime calls that can allocate or reach back into
/// ghostty.
private func sessionWALOutputTapCallback(
    _ buf: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let buf, let userdata, len > 0 else { return }
    let context = Unmanaged<SessionWALStore.Context>.fromOpaque(userdata).takeUnretainedValue()
    context.ringBuffer.append(buf, Int(len))
}
