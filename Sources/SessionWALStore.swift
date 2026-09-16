import Foundation
import Darwin
import Bonsplit

/// Per-surface durable PTY output WAL + fact file (issue #181, slice 1).
///
/// This file used to be the feat/session-wal-spike byte-counting spike
/// (`SessionOutputTapSpike`) that proved tapping PTY output via Ghostty's
/// PTY tee has no measurable typing-latency cost.
/// It now replaces that counter with a real writer. The filename is kept
/// as-is (not renamed to SessionWAL.swift) because this change was made by
/// an agent without filesystem move/delete tools; the type names below are
/// renamed. A follow-up `git mv` + pbxproj path/name tweak is cosmetic only.
///
/// ## Threading path, tee callback to WAL
/// 1. `ghostty_surface_set_pty_tee_cb`'s C callback fires on ghostty's
///    io-reader thread before the VT parser sees the bytes. It must be cheap:
///    copy bytes out, no allocation, no calls back into
///    `ghostty_surface_*`, no waiting.
/// 2. The callback (`sessionWALPTYTeeCallback`) does exactly one thing:
///    `SessionWALRingBuffer.append` — a bounded memcpy into a fixed-capacity
///    buffer preallocated at registration time (never in the callback).
/// 3. A single shared background queue (`SessionWALStore.writeQueue`, a
///    serial `DispatchQueue`) runs a periodic timer every ~100ms
///    (`SessionWALPolicy.drainInterval`) that drains every registered
///    surface's ring buffer and appends the bytes to that session's
///    `wal.log`. WAL fsync is batched separately at
///    `SessionWALPolicy.walSyncInterval`, avoiding one serial fsync per
///    output-bearing tick and writer.
/// 4. `meta.json` (the fact file) is refreshed only at the heartbeat cadence
///    or immediately when identity/escrow/generation changes.
///
/// ## Ring buffer lock, a disclosed pragmatic tradeoff
/// The callback must not allocate or block. A textbook wait-free SPSC ring
/// buffer needs atomics; this project has no swift-atomics dependency, and
/// the macOS 14 deployment target (see project.pbxproj) predates Swift's
/// built-in `Synchronization.Atomic` (macOS 15+). Adding a new dependency is
/// out of scope for this slice. `SessionWALRingBuffer` instead uses
/// two buffers preallocated at registration time. The callback uses
/// `os_unfair_lock_trylock`, so it never waits: in the rare instant that the
/// drain queue is swapping buffers, that callback chunk is dropped rather
/// than blocking Ghostty while its renderer mutex is held. The drain side
/// holds the lock only long enough to swap the active buffer index and byte
/// counters; allocation and the up-to-64 KiB copy happen after unlock.
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
/// registers the tee, so there is nothing to dereference after a surface
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
/// replays saved scrollback text via `SessionFreshSpawnScrollbackSeed`. When a
/// persisted `SessionPanelSnapshot.terminal?.scrollback` is missing or blank
/// (the app died before the next autosave/clean-quit snapshot captured it),
/// it falls back to `SessionWALStore.shared.readFallbackScrollbackText(sessionId:)`
/// for that same OLD panel/surface id (`SessionPanelSnapshot.id` — the same
/// UUID a session's WAL directory is named after, since `TerminalPanel.id ==
/// TerminalSurface.id`). That method prefers a captured frame + WAL delta
/// (see "Periodic frame capture" above) when a usable one exists, and falls
/// back to the plain WAL tail otherwise. Either way the returned text is fed
/// through the exact same `SessionFreshSpawnScrollbackSeed`/
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
///   be determined at all is kept. Every bundle's current snapshot protects
///   its terminal directories regardless of age; unreadable snapshots defer
///   the sweep so tagged builds cannot destroy production retrieval tokens.
enum SessionWALPolicy {
    /// Fixed capacity of the in-memory ring buffer the tee callback writes
    /// into. Large enough to absorb a burst between 100ms drains for normal
    /// interactive/agent output; a sustained flood faster than this drops
    /// its oldest interior bytes (documented tradeoff, never blocks).
    static let ringBufferCapacityBytes = 64 * 1024
    /// Per-session wal.log cap before rotating to wal.log.1.
    static let walCapBytes: Int64 = 8 * 1024 * 1024
    static let drainInterval: TimeInterval = 0.1
    /// WAL durability is intentionally batched instead of issuing a serial
    /// fsync for every 100ms drain tick. Rotation and final writer teardown
    /// still force an immediate sync.
    static let walSyncInterval: TimeInterval = 1.0
    /// Fact-file heartbeat cadence. Identity, escrow, and generation changes
    /// bypass this throttle and are persisted immediately.
    static let metaRefreshInterval: TimeInterval = 5.0
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

/// Fixed-size double-buffered circular byte buffer. `append` is called only
/// from ghostty's io-reader thread (the tee callback); `drain` is called only
/// from `SessionWALStore.writeQueue`.
final class SessionWALRingBuffer {
    struct Capture {
        let bytes: [UInt8]
        let generation: UUID
    }
    private let capacity: Int
    private let firstStorage: UnsafeMutablePointer<UInt8>
    private let secondStorage: UnsafeMutablePointer<UInt8>
    private var activeStorageIndex = 0
    private var head = 0
    private var count = 0
    private var lock = os_unfair_lock()
    private var policy: SessionScrollbackPolicy

    init(capacity: Int, policy: SessionScrollbackPolicy = .init(enabled: true, generation: UUID())) {
        self.capacity = capacity
        self.policy = policy
        self.firstStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        self.secondStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
    }

    deinit {
        firstStorage.deallocate()
        secondStorage.deallocate()
    }

    /// Tap-callback hot path: copy `len` bytes in, dropping the oldest
    /// buffered bytes first if `len` would overflow capacity. No allocation,
    /// no syscalls, no waiting, bounded memcpy only. If the drain queue is
    /// in its tiny index-swap critical section, drop this chunk rather than
    /// waiting while Ghostty holds its renderer mutex.
    func append(_ buf: UnsafePointer<UInt8>, _ len: Int) {
        guard len > 0 else { return }
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        guard policy.enabled else { return }
        let storage = storage(at: activeStorageIndex)

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

    /// Background-queue only: swaps the active preallocated buffer while
    /// holding the lock, then allocates and copies after unlocking. Returns
    /// nil if there was nothing to drain.
    func drain() -> [UInt8]? {
        drainCaptured()?.bytes
    }

    func transition(to policy: SessionScrollbackPolicy) {
        os_unfair_lock_lock(&lock)
        self.policy = policy
        head = 0
        count = 0
        os_unfair_lock_unlock(&lock)
    }

    func drainCaptured() -> Capture? {
        os_unfair_lock_lock(&lock)
        guard count > 0 else {
            os_unfair_lock_unlock(&lock)
            return nil
        }
        let drainingStorageIndex = activeStorageIndex
        let drainingHead = head
        let drainingCount = count
        let generation = policy.generation
        activeStorageIndex = 1 - activeStorageIndex
        head = 0
        count = 0
        os_unfair_lock_unlock(&lock)

        let storage = storage(at: drainingStorageIndex)
        var out = [UInt8](repeating: 0, count: drainingCount)
        out.withUnsafeMutableBytes { dst in
            let firstChunk = min(drainingCount, capacity - drainingHead)
            memcpy(dst.baseAddress!, storage.advanced(by: drainingHead), firstChunk)
            if firstChunk < drainingCount {
                memcpy(
                    dst.baseAddress!.advanced(by: firstChunk),
                    storage,
                    drainingCount - firstChunk
                )
            }
        }
        return Capture(bytes: out, generation: generation)
    }

    @inline(__always)
    private func storage(at index: Int) -> UnsafeMutablePointer<UInt8> {
        index == 0 ? firstStorage : secondStorage
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

/// Bundle-specific policy lives beside the bundle-specific snapshot. Session
/// directories themselves are shared across app variants, so their parent is
/// not a sufficient namespace for this policy.
struct SessionScrollbackPolicyPaths {
    let policyURL: URL
    let nextURL: URL
    let lockURL: URL

    init(snapshotFileURL: URL) {
        let base = snapshotFileURL.deletingPathExtension()
        policyURL = base.appendingPathExtension("scrollback-policy.json")
        nextURL = policyURL.appendingPathExtension("next")
        lockURL = base.appendingPathExtension("scrollback-policy.lock")
    }

    static func make(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil
    ) -> SessionScrollbackPolicyPaths? {
        guard let snapshotFileURL = SessionPersistenceStore.defaultSnapshotFileURL(
            bundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        ) else { return nil }
        return SessionScrollbackPolicyPaths(snapshotFileURL: snapshotFileURL)
    }
}

struct SessionScrollbackPolicy: Codable, Equatable {
    let enabled: Bool
    let generation: UUID
}

/// Durable coordination point for the app and detached holders. Callers must
/// acquire this policy lock before a session's WAL lock when using both.
enum SessionScrollbackPolicyStore {
    /// Failure to read/lock the policy suppresses content; actual content I/O
    /// errors still propagate to the caller as errors, not suppression.
    static func withContentPermission<T>(
        at paths: SessionScrollbackPolicyPaths?,
        capturedGeneration: UUID?,
        _ body: () throws -> T
    ) throws -> T? {
        guard let paths else { return nil }
        let result: Result<T, Error>? = try? withPolicy(at: paths) { policy -> Result<T, Error>? in
            guard policy.enabled,
                  capturedGeneration == nil || capturedGeneration == policy.generation else { return nil }
            return Result { try body() }
        }
        return try result?.get()
    }

    static func read(at paths: SessionScrollbackPolicyPaths) throws -> SessionScrollbackPolicy {
        try withPolicy(at: paths) { $0 }
    }

    static func withPolicy<T>(
        at paths: SessionScrollbackPolicyPaths,
        _ body: (SessionScrollbackPolicy) throws -> T
    ) throws -> T {
        try withProcessLock(at: paths) {
            let policy = try JSONDecoder().decode(
                SessionScrollbackPolicy.self,
                from: Data(contentsOf: paths.policyURL)
            )
            return try body(policy)
        }
    }

    @discardableResult
    static func transition(
        enabled: Bool,
        at paths: SessionScrollbackPolicyPaths
    ) throws -> SessionScrollbackPolicy {
        try withProcessLock(at: paths) {
            let policy = SessionScrollbackPolicy(enabled: enabled, generation: UUID())
            let data = try JSONEncoder().encode(policy)
            guard FileManager.default.createFile(atPath: paths.nextURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? FileManager.default.removeItem(at: paths.nextURL) }
            let handle = try FileHandle(forWritingTo: paths.nextURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            let renamed = paths.nextURL.path.withCString { source in
                paths.policyURL.path.withCString { destination in
                    Darwin.rename(source, destination) == 0
                }
            }
            guard renamed else { throw posixError() }

            // Make the replacement directory entry durable before reporting
            // success, in addition to synchronizing the policy bytes above.
            let directoryFD = paths.policyURL.deletingLastPathComponent().path.withCString {
                Darwin.open($0, O_RDONLY)
            }
            guard directoryFD >= 0 else { throw posixError() }
            defer { Darwin.close(directoryFD) }
            guard fsync(directoryFD) == 0 else { throw posixError() }
            return policy
        }
    }

    private static func withProcessLock<T>(
        at paths: SessionScrollbackPolicyPaths,
        _ body: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: paths.policyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = paths.lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw posixError() }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Filesystem layout for one session's WAL + fact file, under
/// `Application Support/programa/sessions/<session-uuid>/`. Reuses
/// `SessionPersistenceStore.defaultSnapshotFileURL`'s app-support
/// resolution (bundle id sanitization, Application Support lookup) rather
/// than duplicating it.
struct SessionWALPaths {
    let sessionDirectory: URL
    let policyPaths: SessionScrollbackPolicyPaths?
    let walURL: URL
    let walRotatedURL: URL
    let metaURL: URL
    /// Stable inode used with `flock(2)` to serialize app/holder filesystem
    /// mutations across process boundaries.
    let lockURL: URL
    /// Committed frame: a VT-formatted dump of the current screen, written
    /// atomically via `frameNextURL` + fsync + `rename(2)`.
    let frameURL: URL
    /// Staging path for the next frame write, renamed over `frameURL` once
    /// complete. Never read directly by restore.
    let frameNextURL: URL
    /// WAL offset + rotation generation recorded at frame capture time.
    let frameMetaURL: URL

    init(
        sessionDirectory: URL,
        policyPaths: SessionScrollbackPolicyPaths? = SessionScrollbackPolicyPaths.make()
    ) {
        self.sessionDirectory = sessionDirectory
        self.policyPaths = policyPaths
        self.walURL = sessionDirectory.appendingPathComponent("wal.log", isDirectory: false)
        self.walRotatedURL = sessionDirectory.appendingPathComponent("wal.log.1", isDirectory: false)
        self.metaURL = sessionDirectory.appendingPathComponent("meta.json", isDirectory: false)
        self.lockURL = sessionDirectory.appendingPathComponent("wal.lock", isDirectory: false)
        self.frameURL = sessionDirectory.appendingPathComponent("frame.vt", isDirectory: false)
        self.frameNextURL = sessionDirectory.appendingPathComponent("frame.vt.next", isDirectory: false)
        self.frameMetaURL = sessionDirectory.appendingPathComponent("frame.meta.json", isDirectory: false)
    }

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
            policyPaths: SessionScrollbackPolicyPaths.make(appSupportDirectory: appSupportDirectory)
        )
    }
}

/// Pure, process-safe filesystem core shared by the app writer and escrow
/// holder. Every append takes the session's stable `wal.lock` with
/// `flock(LOCK_EX)`, checks the on-disk size, and performs rotation when
/// needed. Rotation first atomically persists `walGeneration + 1` into the
/// existing fact file and only then renames `wal.log`; a crash between those
/// steps can invalidate an otherwise usable frame, but can never leave a
/// stale generation that accepts an offset from the wrong WAL incarnation.
enum SessionWALCore {
    struct AppendResult {
        let currentWalSize: Int64
        let walGeneration: Int
        let didRotate: Bool
        let didSynchronize: Bool
        var didSuppress = false
    }

    private enum CoreError: Error {
        case cannotOpenLock
        case cannotLock
        case cannotOpenWAL
        case cannotCommitMeta
        case cannotCommitFrame
    }

    private static let metaEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let metaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The single WAL append+rotation primitive. It is deliberately
    /// stateless: reopening under the process lock means neither the app nor
    /// holder can retain a file handle to an inode the other process rotated.
    static func append(
        _ data: Data,
        to paths: SessionWALPaths,
        walCapBytes: Int64 = SessionWALPolicy.walCapBytes,
        synchronize: Bool,
        capturedGeneration: UUID? = nil
    ) throws -> AppendResult {
        let result = try SessionScrollbackPolicyStore.withContentPermission(
            at: paths.policyPaths, capturedGeneration: capturedGeneration
        ) {
            try appendAllowed(data, to: paths, walCapBytes: walCapBytes, synchronize: synchronize)
        }
        return result ?? AppendResult(
            currentWalSize: 0, walGeneration: 0, didRotate: false,
            didSynchronize: false, didSuppress: true
        )
    }

    private static func appendAllowed(
        _ data: Data, to paths: SessionWALPaths, walCapBytes: Int64, synchronize: Bool
    ) throws -> AppendResult {
        try withProcessLock(paths: paths) {
            try FileManager.default.createDirectory(
                at: paths.sessionDirectory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: paths.walURL.path) {
                _ = FileManager.default.createFile(atPath: paths.walURL.path, contents: nil)
            }

            var currentSize = fileSize(at: paths.walURL)
            var meta = readMetaUnlocked(paths: paths)
            var generation = meta?.walGeneration ?? 0
            var didRotate = false

            if !data.isEmpty, currentSize + Int64(data.count) > walCapBytes {
                // Sync the outgoing incarnation before its pathname changes.
                try synchronizeWALUnlocked(paths: paths)

                generation += 1
                if meta == nil {
                    meta = SessionWALMeta(
                        sessionId: paths.sessionDirectory.lastPathComponent,
                        childPID: nil,
                        ptyPath: nil,
                        workingDirectory: nil,
                        lastHeartbeatAt: Date(),
                        walGeneration: generation,
                        escrowed: nil,
                        escrowSocketPath: nil,
                        escrowToken: nil
                    )
                } else {
                    meta?.walGeneration = generation
                    meta?.lastHeartbeatAt = Date()
                }
                guard let meta else { throw CoreError.cannotCommitMeta }

                // Persisting first makes either crash ordering conservative:
                // new generation + old WAL rejects the frame; old generation
                // + new WAL is impossible.
                try persistMetaUnlocked(meta, paths: paths)

                if FileManager.default.fileExists(atPath: paths.walRotatedURL.path) {
                    try FileManager.default.removeItem(at: paths.walRotatedURL)
                }
                try FileManager.default.moveItem(at: paths.walURL, to: paths.walRotatedURL)
                _ = FileManager.default.createFile(atPath: paths.walURL.path, contents: nil)
                currentSize = 0
                didRotate = true
            }

            if !data.isEmpty {
                guard let handle = try? FileHandle(forWritingTo: paths.walURL) else {
                    throw CoreError.cannotOpenWAL
                }
                handle.seekToEndOfFile()
                handle.write(data)
                if synchronize || didRotate {
                    handle.synchronizeFile()
                }
                handle.closeFile()
                currentSize += Int64(data.count)
            }

            return AppendResult(
                currentWalSize: currentSize,
                walGeneration: generation,
                didRotate: didRotate,
                didSynchronize: synchronize || didRotate
            )
        }
    }

    /// Persists fact-file changes under the same process lock as rotation.
    /// A writer with stale in-memory state may not lower a generation already
    /// advanced by another process.
    @discardableResult
    static func persistMeta(_ proposedMeta: SessionWALMeta, to paths: SessionWALPaths) throws -> SessionWALMeta {
        try withProcessLock(paths: paths) {
            var mergedMeta = proposedMeta
            let current = readMetaUnlocked(paths: paths)
            let onDiskGeneration = current?.walGeneration ?? 0
            mergedMeta.walGeneration = max(proposedMeta.walGeneration ?? 0, onDiskGeneration)
            // Holder acknowledgement precedes the app's asynchronous escrow
            // callback. A heartbeat with stale local facts cannot revoke the
            // ownership that was just acknowledged durably.
            if let current, current.escrowed == true, proposedMeta.escrowed != true {
                mergedMeta.escrowed = true
                mergedMeta.escrowSocketPath = current.escrowSocketPath
                mergedMeta.escrowToken = current.escrowToken
            }
            try persistMetaUnlocked(mergedMeta, paths: paths)
            return mergedMeta
        }
    }

    static func synchronizeWAL(at paths: SessionWALPaths) throws {
        try withProcessLock(paths: paths) {
            try synchronizeWALUnlocked(paths: paths)
        }
    }

    static func readMeta(at paths: SessionWALPaths) -> SessionWALMeta? {
        try? withProcessLock(paths: paths) {
            readMetaUnlocked(paths: paths)
        }
    }

    static func clearEscrowClaim(at paths: SessionWALPaths, ifSocketMatches socketPath: String) throws {
        try withProcessLock(paths: paths) {
            guard var meta = readMetaUnlocked(paths: paths), meta.escrowSocketPath == socketPath else { return }
            meta.escrowed = false
            try persistMetaUnlocked(meta, paths: paths)
        }
    }

    /// Pure frame + current-WAL delta replay used by production restore and
    /// by behavioral core tests. A generation mismatch always rejects the
    /// frame, even when the new WAL has regrown beyond the old byte offset.
    static func readFrameAndDelta(
        at paths: SessionWALPaths,
        walCapBytes: Int64 = SessionWALPolicy.walCapBytes
    ) -> String? {
        try? withProcessLock(paths: paths) {
            guard let frameMetaData = try? Data(contentsOf: paths.frameMetaURL),
                  let frameMeta = try? metaDecoder.decode(SessionFrameMeta.self, from: frameMetaData),
                  let frameData = try? Data(contentsOf: paths.frameURL),
                  !frameData.isEmpty else {
                return nil
            }
            let currentGeneration = readMetaUnlocked(paths: paths)?.walGeneration ?? 0
            guard frameMeta.walGeneration == currentGeneration else { return nil }

            let frameText = String(decoding: frameData, as: UTF8.self)
            guard let currentWalData = try? Data(contentsOf: paths.walURL) else {
                return frameText
            }
            guard frameMeta.walOffset >= 0,
                  Int64(currentWalData.count) >= frameMeta.walOffset else {
                return nil
            }
            var delta = currentWalData.subdata(in: Int(frameMeta.walOffset)..<currentWalData.count)
            if delta.count > walCapBytes {
                delta = delta.suffix(Int(walCapBytes))
            }
            // Both raw byte cuts above (`walOffset` and the suffix cap) can
            // land mid-escape-sequence or mid-UTF-8-scalar. Trim once, here,
            // after both cuts are applied -- this single call site covers
            // whichever cut produced the leading edge of `delta`.
            delta = trimTornLeadingBytes(delta)
            guard !delta.isEmpty else { return frameText }
            return frameText + String(decoding: delta, as: UTF8.self)
        }
    }

    /// Trims a WAL delta's leading bytes so replay never starts with the
    /// orphaned tail of a sequence torn by a raw byte cut. `readFrameAndDelta`
    /// slices `wal.log` at two byte offsets that know nothing about ANSI or
    /// UTF-8 structure (`walOffset`, captured mid-stream by
    /// `finishFrameCapture`, and the `walCapBytes` suffix cap above) -- a cut
    /// landing inside a CSI escape sequence or a multi-byte UTF-8 scalar
    /// otherwise leaks the torn fragment into the terminal as literal text
    /// (the "m0de"-style mid-word corruption users see after restore).
    ///
    /// This is a heuristic, not a stateful escape parser: it only looks at
    /// the bytes at the very front of `data`, since a delta carries no
    /// header saying whether its first byte is "on a boundary". Two
    /// independent leading defects are corrected, and they are mutually
    /// exclusive -- at most one ever fires per call:
    ///
    /// 1. UTF-8 continuation bytes (`0b10xxxxxx`) at the start mean the cut
    ///    landed inside a multi-byte scalar -- advance past all of them so
    ///    `String(decoding:as:)` never has to emit U+FFFD for an orphaned
    ///    tail. This is unambiguous (no valid UTF-8 text legitimately opens
    ///    with a continuation byte), so it is not bounded.
    /// 2. CSI parameter/intermediate bytes (`0x30-0x3F`, `0x20-0x2F`) at the
    ///    start, with no preceding `ESC [` visible in this same buffer, mean
    ///    the cut *may* have landed inside a control sequence. If a final
    ///    byte (`0x40-0x7E`) shows up within the next `csiTailScanCapBytes`
    ///    bytes, drop straight through it and resume after. This case is
    ///    genuinely ambiguous, unlike (1): space (`0x20`) is a legal CSI
    ///    intermediate byte, so "123;456 Main St" and a torn
    ///    `ESC[123;456 m`-style sequence are byte-for-byte indistinguishable
    ///    at the front of a buffer -- there is no way to tell them apart by
    ///    inspection. What *can* be bounded is the damage: real-world torn
    ///    SGR params (e.g. `38;2;255;255;255`) are well under
    ///    `csiTailScanCapBytes`, so if no final byte appears within that
    ///    window, this is treated as plain text and left untouched --
    ///    intentionally trading a small chance of leaving a torn escape in
    ///    place against the much likelier case of eating real leading text.
    ///
    ///    Case (2) only ever runs when case (1) consumed nothing. Escape
    ///    sequences are pure ASCII, so if the buffer opened with UTF-8
    ///    continuation bytes, the cut was inside a multi-byte *character*,
    ///    not inside an escape sequence -- whatever follows the character is
    ///    ordinary text, and running the CSI scan against it can only ever
    ///    eat legitimate content. (A cut inside "é" of "é123Main" would
    ///    otherwise strip the continuation byte *and* scan into "123Main",
    ///    finding 'M' as a bogus "final byte" and stripping "123M" too,
    ///    leaving "ain".)
    ///
    /// Failure mode, stated honestly and now structurally bounded rather
    /// than probabilistic: worst case, case (2) drops at most
    /// `csiTailScanCapBytes` leading bytes of a restored delta (a torn CSI
    /// run whose final byte happens to land inside the scan window but was
    /// actually plain text), or leaves a torn escape in place (a torn CSI
    /// run whose final byte lands outside the window). Both outcomes are
    /// confined to the first `csiTailScanCapBytes` bytes of a replay; only
    /// the leading edge is ever cut, so this cannot recur deeper in the
    /// delta.
    private static let csiTailScanCapBytes = 16

    /// Pure "concat rotated+current, cap to `walCapBytes`, trim any torn
    /// leading edge, decode" step behind `SessionWALStore
    /// .readFallbackScrollbackText`'s plain-tail fallback (used when no
    /// frame+delta replay is available -- see that function's doc comment).
    /// Extracted out of the singleton/file-system-coupled store method so it
    /// is directly unit-testable: the raw-byte suffix cut below has the exact
    /// same torn-escape/torn-UTF-8 hazard `readFrameAndDelta` already guards
    /// against at its own cut sites (~554) -- this call site was previously
    /// missing that guard, leaking orphaned CSI/UTF-8 fragments as literal
    /// replayed text.
    static func decodeFallbackScrollbackText(
        rotated: Data?,
        current: Data?,
        walCapBytes: Int64 = SessionWALPolicy.walCapBytes
    ) -> String? {
        var combined = Data()
        if let rotated { combined.append(rotated) }
        if let current { combined.append(current) }
        guard !combined.isEmpty else { return nil }
        if combined.count > walCapBytes {
            // Only a suffix cut can tear an escape sequence or UTF-8 scalar;
            // uncut data starts at a genuine stream beginning, where the torn-CSI
            // heuristic would misread legitimate leading text (e.g. "123Main")
            // as an orphaned parameter run and eat it.
            combined = trimTornLeadingBytes(combined.suffix(Int(walCapBytes)))
        }
        return String(decoding: combined, as: UTF8.self)
    }

    private static func trimTornLeadingBytes(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var start = data.startIndex

        // 1) Skip leading UTF-8 continuation bytes (mid-scalar cut).
        while start < data.endIndex, (data[start] & 0xC0) == 0x80 {
            start = data.index(after: start)
        }
        guard start < data.endIndex else { return Data() }
        let consumedContinuationBytes = start > data.startIndex

        // 2) Skip a leading, unterminated-from-our-view CSI parameter/
        // intermediate run (mid-escape-sequence cut) through its final byte,
        // if one turns up within the bounded scan window. Only trips when
        // (1) consumed nothing -- see this function's doc comment for why
        // the two causes are mutually exclusive -- and the first surviving
        // byte looks like a CSI parameter/intermediate byte.
        let firstByte = data[start]
        let looksLikeCSITail = !consumedContinuationBytes
            && ((0x30...0x3F).contains(firstByte) || (0x20...0x2F).contains(firstByte))
        if looksLikeCSITail {
            let scanLimit = data.index(start, offsetBy: csiTailScanCapBytes, limitedBy: data.endIndex) ?? data.endIndex
            var cursor = start
            while cursor < scanLimit {
                let byte = data[cursor]
                if (0x40...0x7E).contains(byte) {
                    // Final byte of the torn sequence, found within the
                    // bounded window -- drop through it.
                    start = data.index(after: cursor)
                    break
                }
                guard (0x30...0x3F).contains(byte) || (0x20...0x2F).contains(byte) else {
                    // Not a parameter/intermediate byte and no final byte
                    // turned up first -- this was not actually a torn CSI
                    // run. Leave `start` at its pre-branch value.
                    break
                }
                cursor = data.index(after: cursor)
            }
            // If the scan ran off the end of the bounded window without
            // finding a final byte (and without hitting the `break` above),
            // `start` is left untouched -- no trim. See the cap rationale
            // in this function's doc comment.
        }

        return start > data.startIndex ? data.suffix(from: start) : data
    }

    /// Shared frame commit: fsync the staging file, rename it atomically,
    /// then write metadata using restore's date encoding under the same lock.
    @discardableResult
    static func writeFrame(
        _ text: String,
        meta: SessionFrameMeta,
        to paths: SessionWALPaths,
        capturedGeneration: UUID? = nil
    ) throws -> Bool {
        try SessionScrollbackPolicyStore.withContentPermission(
            at: paths.policyPaths, capturedGeneration: capturedGeneration
        ) {
            try writeFrameAllowed(text, meta: meta, to: paths)
            return true
        } ?? false
    }

    private static func writeFrameAllowed(
        _ text: String, meta: SessionFrameMeta, to paths: SessionWALPaths
    ) throws {
        try withProcessLock(paths: paths) {
            guard FileManager.default.createFile(atPath: paths.frameNextURL.path, contents: nil) else {
                throw CoreError.cannotCommitFrame
            }
            let handle = try FileHandle(forWritingTo: paths.frameNextURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            guard atomicRename(from: paths.frameNextURL, to: paths.frameURL) else {
                throw CoreError.cannotCommitFrame
            }
            let data = try metaEncoder.encode(meta)
            try data.write(to: paths.frameMetaURL, options: .atomic)
        }
    }

    private static func withProcessLock<T>(
        paths: SessionWALPaths,
        _ body: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: paths.sessionDirectory,
            withIntermediateDirectories: true
        )
        let fd = paths.lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw CoreError.cannotOpenLock }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CoreError.cannotLock }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private static func readMetaUnlocked(paths: SessionWALPaths) -> SessionWALMeta? {
        guard let data = try? Data(contentsOf: paths.metaURL) else { return nil }
        return try? metaDecoder.decode(SessionWALMeta.self, from: data)
    }

    private static func persistMetaUnlocked(_ meta: SessionWALMeta, paths: SessionWALPaths) throws {
        let data = try metaEncoder.encode(meta)
        let nextURL = paths.sessionDirectory.appendingPathComponent("meta.json.next")
        _ = FileManager.default.createFile(atPath: nextURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: nextURL) else {
            throw CoreError.cannotCommitMeta
        }
        handle.truncateFile(atOffset: 0)
        handle.write(data)
        handle.synchronizeFile()
        handle.closeFile()
        guard atomicRename(from: nextURL, to: paths.metaURL) else {
            throw CoreError.cannotCommitMeta
        }
    }

    private static func synchronizeWALUnlocked(paths: SessionWALPaths) throws {
        guard FileManager.default.fileExists(atPath: paths.walURL.path) else { return }
        guard let handle = try? FileHandle(forWritingTo: paths.walURL) else {
            throw CoreError.cannotOpenWAL
        }
        handle.synchronizeFile()
        handle.closeFile()
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static func atomicRename(from sourceURL: URL, to destinationURL: URL) -> Bool {
        sourceURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                Darwin.rename(source, destination) == 0
            }
        }
    }
}

/// writeQueue-confined per-session state: the tee `Context` (shared with the
/// live ghostty tap), resolved paths, and the size/durability/heartbeat
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
    var currentWalSize: Int64 = 0
    var lastMetaWriteAt: Date = .distantPast
    var lastWALSyncAt: Date = .distantPast
    var hasUnsynchronizedWALWrites = false
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
            self.ringBuffer = SessionWALRingBuffer(
                capacity: SessionWALPolicy.ringBufferCapacityBytes,
                policy: SessionScrollbackPolicy(enabled: false, generation: UUID())
            )
        }
    }

    static let shared = SessionWALStore()

    private let writeQueue = DispatchQueue(label: "com.darkroom.programa.session-wal", qos: .utility)
    private var writersBySurfaceId: [String: SessionWALWriter] = [:]
    private var drainTimer: DispatchSourceTimer?
    private var frameCaptureTimer: DispatchSourceTimer?
    private var hasScheduledOrphanSweep = false
    private var capturePolicy = SessionScrollbackPolicy(enabled: false, generation: UUID())
    /// Injected once (`TerminalController.init` wires this to
    /// `captureSessionWALFrameText(forSurfaceId:)`) since VT export is
    /// main-thread/AppKit-bound and `SessionWALStore` must never touch
    /// AppKit itself. Only ever read/written on `writeQueue`. Takes a
    /// completion handler (called on an unspecified queue) rather than
    /// returning synchronously so the writeQueue can hop to main and back
    /// without blocking.
    private var frameTextProvider: ((String, @escaping (String?) -> Void) -> Void)?

    /// Mirrors the core's date strategy for metadata reads and the orphan
    /// sweep's conservative age check, never the tee-callback/write hot path.
    private static let metaDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {}

    func currentCapturePolicy() -> SessionScrollbackPolicy {
        writeQueue.sync { capturePolicy }
    }

    /// Settings/startup only. Existing writes finish before the transition;
    /// capture admission stays disabled if the durable transition fails.
    func transitionPersistence(enabled: Bool) throws {
        try writeQueue.sync {
            applyCapturePolicy(SessionScrollbackPolicy(enabled: false, generation: UUID()))
            guard let paths = SessionScrollbackPolicyPaths.make() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let policy = try SessionScrollbackPolicyStore.transition(enabled: enabled, at: paths)
            applyCapturePolicy(policy)
        }
    }

    private func applyCapturePolicy(_ policy: SessionScrollbackPolicy) {
        capturePolicy = policy
        for writer in writersBySurfaceId.values {
            writer.context.ringBuffer.transition(to: policy)
        }
    }

    /// Registers the PTY tee for a newly created surface and starts its
    /// WAL writer off-main. The caller (`TerminalSurface`) must hold onto
    /// the returned `Unmanaged<Context>` and release it exactly once, right
    /// after clearing the tee at teardown via `unregister`.
    func register(
        surface: ghostty_surface_t,
        surfaceId: String,
        workingDirectory: String?
    ) -> Unmanaged<Context> {
        let context = Context(surfaceId: surfaceId)
        let unmanaged = Unmanaged<Context>.passRetained(context)
        if SessionMachineryGate.isUnitTesting {
            return unmanaged
        }

        ghostty_surface_set_pty_tee_cb(surface, sessionWALPTYTeeCallback, unmanaged.toOpaque())

        writeQueue.async { [weak self] in
            self?.startWriter(surfaceId: surfaceId, context: context, workingDirectory: workingDirectory)
        }
        return unmanaged
    }

    /// Clears the tee (passing a NULL callback, per the C API contract),
    /// flushes any remaining buffered bytes, and forgets the writer.
    /// `deleteDirectory` should be `true` only at a surface's genuine final
    /// teardown (normal close) — see the file-level "Cleanup" doc comment.
    func unregister(surface: ghostty_surface_t?, surfaceId: String, deleteDirectory: Bool = false) {
        if let surface {
            ghostty_surface_set_pty_tee_cb(surface, nil, nil)
        }
        writeQueue.async { [weak self] in
            self?.stopWriter(surfaceId: surfaceId, deleteDirectory: deleteDirectory)
        }
    }

    /// Records escrow facts for a revived session whose runtime surface has not
    /// been created yet (a hidden tab at restore — its ghostty surface, and with
    /// it the normal `register`/`markEscrowed` flow, only exists once the tab is
    /// first shown). Creates the writer (and the session directory + meta.json)
    /// if needed so the facts are durable NOW; the eventual full `register()`
    /// replaces the writer but re-hydrates these fields from disk (see
    /// `startWriter`), so nothing is lost at realization.
    func stampDeferredReviveEscrow(
        surfaceId: String,
        socketPath: String,
        token: String,
        childPID: Int32?,
        workingDirectory: String?
    ) {
        writeQueue.async { [weak self] in
            guard let self else { return }
            if self.writersBySurfaceId[surfaceId] == nil {
                self.startWriter(
                    surfaceId: surfaceId,
                    context: Context(surfaceId: surfaceId),
                    workingDirectory: workingDirectory
                )
            }
            guard let writer = self.writersBySurfaceId[surfaceId] else { return }
            writer.escrowed = true
            writer.escrowSocketPath = socketPath
            writer.escrowToken = token
            if writer.childPID == nil, let childPID {
                writer.childPID = childPID
            }
            let now = Date()
            self.writeMeta(writer: writer, at: now)
            writer.lastMetaWriteAt = now
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

    /// Issue #307 orphan-reconciliation fix: launch-time scan for session
    /// directories that are still escrow-claimed (`meta.escrowed == true`)
    /// but weren't reattached by the coarse-snapshot restore that just ran.
    /// Mirrors `sweepOrphanedSessionDirectories`'s own
    /// `FileManager.contentsOfDirectory` listing idiom below, and `readMeta`
    /// above for the per-directory read -- synchronous, direct file reads,
    /// no `writeQueue` dispatch (reads never need the write queue; only
    /// mutations do, per `discardOrphanedSession`). `known` is whatever the
    /// caller already reattached this launch; entries whose directory name
    /// is in that set are skipped without a read.
    func escrowedSessionIds(excluding known: Set<String>) -> [(sessionId: String, meta: SessionWALMeta)] {
        guard let root = SessionWALPaths.sessionsRootURL() else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [(sessionId: String, meta: SessionWALMeta)] = []
        for entry in entries {
            let sessionId = entry.lastPathComponent
            guard !known.contains(sessionId) else { continue }
            guard let meta = readMeta(sessionId: sessionId), meta.escrowed == true else { continue }
            result.append((sessionId: sessionId, meta: meta))
        }
        return result
    }

    /// Restore-path fallback read. Synchronous and launch-time only (mirrors
    /// `SessionPersistenceStore.load`'s synchronous snapshot read) — never
    /// called from the tee callback or any latency-sensitive path. Reads the
    /// rotated tail (if any) then the current file, capped to
    /// `SessionWALPolicy.walCapBytes`, and decodes leniently since PTY bytes
    /// may include partial UTF-8 sequences at the truncation boundary.
    func readFallbackScrollbackText(sessionId: String) -> String? {
        guard ScrollbackPersistenceSettings.isEnabled(),
              let paths = SessionScrollbackPolicyPaths.make(),
              (try? SessionScrollbackPolicyStore.read(at: paths).enabled) == true else { return nil }
        if let frameReplay = readFrameAndDeltaScrollbackText(sessionId: sessionId) {
            return frameReplay
        }
        guard let paths = SessionWALPaths.make(sessionId: sessionId) else { return nil }
        let rotated = try? Data(contentsOf: paths.walRotatedURL)
        let current = try? Data(contentsOf: paths.walURL)
        return SessionWALCore.decodeFallbackScrollbackText(rotated: rotated, current: current)
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
        return SessionWALCore.readFrameAndDelta(at: paths)
    }

    /// Deletes one specific old session's directory once its restore
    /// fallback has been consumed (or found empty). `sessionId` here is
    /// always an OLD (pre-restore) surface id, distinct from any live
    /// surface's freshly generated id.
    ///
    /// NOT safe to call unconditionally anymore (2026-08-10 mass-drain
    /// fix): a directory whose `meta.json` records an escrow claim may
    /// describe a child that is STILL ALIVE in the holder, and that
    /// `meta.json` holds the only copy of the retrieval token -- deleting
    /// it forecloses any reattach forever. Escrowed directories are
    /// therefore preserved here UNCONDITIONALLY (no client-side freshness
    /// check: the holder expires sessions from `drainingStartedAt` on its
    /// own 30s reaper cadence, and mirroring that TTL here from the
    /// different `lastHeartbeatAt` clock is exactly the two-clocks race
    /// that would delete a live child's token near the boundary) and left
    /// to the orphan sweep (`sweepOrphanedSessionDirectories`), which protects
    /// snapshot-owned sessions and ages unowned directories for 24h, beyond
    /// the holder's unowned-session TTL (1h). `force` bypasses preservation for
    /// callers that KNOW the claim is consumed -- the revive-success path,
    /// where the holder has already removed the session from its registry,
    /// leaving `meta.json`'s escrow fields stale-but-live-looking.
    func discardOrphanedSession(
        sessionId: String,
        appSupportDirectory: URL? = nil,
        force: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        writeQueue.async {
            defer { completion?() }
            guard let paths = SessionWALPaths.make(
                sessionId: sessionId,
                appSupportDirectory: appSupportDirectory
            ) else { return }
            if !force,
               let data = try? Data(contentsOf: paths.metaURL),
               let meta = try? Self.metaDecoder.decode(SessionWALMeta.self, from: data),
               meta.escrowed == true {
                dilog("escrow.reattach", "preserve session=\(sessionId.prefix(8)) reason=escrow_claim")
                return
            }
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
        context.ringBuffer.transition(to: capturePolicy)
        // Durable-fact hydration: a re-registration for a surfaceId that already
        // has a meta.json on disk (deferred-revive escrow stamp before the runtime
        // surface exists, or a runtime-surface recreation) must not clobber facts
        // recorded earlier — escrow state and child identity are written once and
        // the NEXT launch's reattach depends on reading them back.
        if let data = try? Data(contentsOf: paths.metaURL),
           let existing = try? Self.metaDecoder.decode(SessionWALMeta.self, from: data) {
            writer.escrowed = existing.escrowed ?? false
            writer.escrowSocketPath = existing.escrowSocketPath
            writer.escrowToken = existing.escrowToken
            writer.childPID = existing.childPID
            writer.ptyPath = existing.ptyPath
        }
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
        drain(writer: writer, forceMetaWrite: false, forceWALSync: true)
        if deleteDirectory {
            try? FileManager.default.removeItem(at: writer.paths.sessionDirectory)
        }
        stopTimersIfIdle()
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

    private func stopTimersIfIdle() {
        guard writersBySurfaceId.isEmpty else { return }
        // Dispatch sources cannot be safely reconfigured after cancellation;
        // clear them here and the next registration lazily recreates/resumes
        // both sweeps.
        drainTimer?.cancel()
        drainTimer = nil
        frameCaptureTimer?.cancel()
        frameCaptureTimer = nil
    }

    /// Fires every `frameCaptureCheckInterval`; writers that are due
    /// (`frameCaptureInterval` elapsed, not already mid-capture, and with
    /// new WAL bytes) are assigned evenly spaced launch slots across the
    /// full capture interval. Each slot reserves the current WAL
    /// offset/generation *before* handing off to the main-thread VT export,
    /// so the reservation can never be ahead of what the export actually
    /// sees (see file-level doc comment).
    private func considerFrameCaptureTick() {
        guard capturePolicy.enabled, let frameTextProvider else { return }
        let captureGeneration = capturePolicy.generation
        let now = Date()
        let dueWriters = writersBySurfaceId.values
            .filter { Self.shouldAttemptFrameCapture(writer: $0, now: now) }
            .sorted { $0.context.surfaceId < $1.context.surfaceId }
        guard !dueWriters.isEmpty else { return }

        let spacing = SessionWALPolicy.frameCaptureInterval / Double(dueWriters.count)
        for (index, writer) in dueWriters.enumerated() {
            // Mark scheduled captures as in-flight immediately so the next
            // sweep cannot enqueue the same writer again before its slot.
            writer.frameCaptureInFlight = true
            writeQueue.asyncAfter(deadline: .now() + spacing * Double(index)) { [weak self] in
                guard let self,
                      self.writersBySurfaceId[writer.context.surfaceId] === writer else {
                    writer.frameCaptureInFlight = false
                    return
                }
                guard self.capturePolicy.enabled,
                      self.capturePolicy.generation == captureGeneration else {
                    writer.frameCaptureInFlight = false
                    return
                }
                self.beginFrameCapture(writer: writer, provider: frameTextProvider)
            }
        }
    }

    private func beginFrameCapture(
        writer: SessionWALWriter,
        provider: @escaping (String, @escaping (String?) -> Void) -> Void
    ) {
        writer.lastFrameCaptureAttemptAt = Date()
        let reservedOffset = writer.currentWalSize
        let reservedGeneration = writer.walGeneration
        let reservedTotalBytes = writer.totalBytesWrittenEver
        let captureGeneration = capturePolicy.generation
        provider(writer.context.surfaceId) { [weak self] text in
            self?.writeQueue.async {
                self?.finishFrameCapture(
                    writer: writer,
                    text: text,
                    reservedOffset: reservedOffset,
                    reservedGeneration: reservedGeneration,
                    reservedTotalBytes: reservedTotalBytes,
                    captureGeneration: captureGeneration
                )
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
        reservedTotalBytes: Int64,
        captureGeneration: UUID
    ) {
        writer.frameCaptureInFlight = false
        guard writersBySurfaceId[writer.context.surfaceId] === writer else { return }
        guard capturePolicy.enabled, capturePolicy.generation == captureGeneration else { return }
        guard let text, !text.isEmpty else {
#if DEBUG
            dlog("session.wal.frame.capture.skipped surface=\(writer.context.surfaceId.prefix(8)) reason=empty_or_failed")
#endif
            return
        }
        let frameMeta = SessionFrameMeta(
            sessionId: writer.context.surfaceId,
            capturedAt: Date(),
            walOffset: reservedOffset,
            walGeneration: reservedGeneration
        )
        do {
            guard try SessionWALCore.writeFrame(
                text, meta: frameMeta, to: writer.paths, capturedGeneration: captureGeneration
            ) else { return }
        } catch {
#if DEBUG
            dlog("session.wal.frame.capture.failed surface=\(writer.context.surfaceId.prefix(8)) reason=write_or_rename")
#endif
            return
        }
        writer.lastFrameCaptureBytes = reservedTotalBytes
    }

    private func drainAllWriters() {
        for writer in writersBySurfaceId.values {
            drain(writer: writer, forceMetaWrite: false, forceWALSync: false)
        }
    }

    private func drain(
        writer: SessionWALWriter,
        forceMetaWrite: Bool,
        forceWALSync: Bool
    ) {
        let capture = writer.context.ringBuffer.drainCaptured()
        let hadBytes = (capture?.bytes.isEmpty == false)
        let now = Date()
        if let capture, hadBytes {
            appendToWAL(capture, writer: writer, at: now, forceSync: forceWALSync)
        } else if writer.hasUnsynchronizedWALWrites,
                  forceWALSync
                    || now.timeIntervalSince(writer.lastWALSyncAt) >= SessionWALPolicy.walSyncInterval {
            if (try? SessionWALCore.synchronizeWAL(at: writer.paths)) != nil {
                writer.hasUnsynchronizedWALWrites = false
                writer.lastWALSyncAt = now
            }
        }
        if forceMetaWrite
            || now.timeIntervalSince(writer.lastMetaWriteAt) >= SessionWALPolicy.metaRefreshInterval {
            writeMeta(writer: writer, at: now)
            writer.lastMetaWriteAt = now
        }
    }

    private func appendToWAL(
        _ capture: SessionWALRingBuffer.Capture,
        writer: SessionWALWriter,
        at date: Date,
        forceSync: Bool
    ) {
        guard capturePolicy.enabled, capturePolicy.generation == capture.generation else { return }
        let data = Data(capture.bytes)
        let shouldSynchronize = forceSync
            || date.timeIntervalSince(writer.lastWALSyncAt) >= SessionWALPolicy.walSyncInterval
        guard let result = try? SessionWALCore.append(
            data,
            to: writer.paths,
            synchronize: shouldSynchronize,
            capturedGeneration: capture.generation
        ), !result.didSuppress else { return }

        writer.currentWalSize = result.currentWalSize
        writer.walGeneration = result.walGeneration
        if result.didSynchronize {
            writer.lastWALSyncAt = date
            writer.hasUnsynchronizedWALWrites = false
        } else {
            writer.hasUnsynchronizedWALWrites = true
        }
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
        guard let persisted = try? SessionWALCore.persistMeta(meta, to: writer.paths) else { return }
        writer.walGeneration = persisted.walGeneration ?? writer.walGeneration
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
        Self.sweepOrphanedSessionDirectories(at: root, registeredSessionIDs: Set(writersBySurfaceId.keys))
    }

    static func sweepOrphanedSessionDirectories(
        at root: URL,
        registeredSessionIDs: Set<String>,
        now: Date = Date()
    ) {
        guard let owned = SessionPersistenceStore.allOwnedTerminalSessionIDs(
            in: root.deletingLastPathComponent()
        ) else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return }
        let cutoff = now.addingTimeInterval(-SessionWALPolicy.orphanDirectoryMaxAge)
        for entry in entries {
            let name = entry.lastPathComponent
            guard !registeredSessionIDs.contains(name), !owned.contains(name.uppercased()) else { continue }
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

/// C callback registered via `ghostty_surface_set_pty_tee_cb`. Runs on
/// ghostty's io-reader thread before the VT parser; this must stay
/// allocation/lock-free from ghostty's point of view. This body does exactly
/// one thing: hand the bytes to the preallocated ring buffer. Nothing else —
/// no dlog, no DispatchQueue, no file I/O, no Swift runtime calls that can
/// allocate or reach back into ghostty.
private func sessionWALPTYTeeCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ len: UInt
) {
    guard let bytes, let userdata, len > 0 else { return }
    let context = Unmanaged<SessionWALStore.Context>.fromOpaque(userdata).takeUnretainedValue()
    let buf = UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self)
    context.ringBuffer.append(buf, Int(len))
}
