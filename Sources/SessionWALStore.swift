import Foundation
import Darwin

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
/// `meta.json` is intentionally minimal: session id, cwd, and a heartbeat
/// timestamp. `childPID` and `ptyPath` fields exist in the schema but are
/// not populated in this slice: `ghostty_surface_t` does not expose either
/// via the C API today (checked `ghostty/include/ghostty.h` — no `pid_t` or
/// pty-path accessor), and adding one is out of scope here (would require a
/// ghostty submodule change, which this slice's scope boundary forbids).
/// Issue #182 is expected to extend this schema with richer heartbeat
/// fields; keep additions optional/backward compatible.
///
/// ## Restore fallback
/// `Workspace+Persistence.swift`'s `createPanel(from:inPane:)` already
/// replays saved scrollback text via `SessionScrollbackReplayStore`. When a
/// persisted `SessionPanelSnapshot.terminal?.scrollback` is missing or blank
/// (the app died before the next autosave/clean-quit snapshot captured it),
/// it falls back to `SessionWALStore.shared.readFallbackScrollbackText(sessionId:)`
/// for that same OLD panel/surface id (`SessionPanelSnapshot.id` — the same
/// UUID a session's WAL directory is named after, since `TerminalPanel.id ==
/// TerminalSurface.id`). The returned text is fed through the exact same
/// `SessionScrollbackReplayStore`/`SessionPersistencePolicy` ANSI-safe
/// truncation path as clean-quit scrollback, so this is purely an
/// alternative source of the same kind of text, not a parallel restore path.
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
/// file-level doc comment for why `childPID`/`ptyPath` are nil in this
/// slice. Issue #182 is expected to extend this; keep additions optional.
struct SessionWALMeta: Codable {
    var schemaVersion: Int = 1
    var sessionId: String
    var childPID: Int32?
    var ptyPath: String?
    var workingDirectory: String?
    var lastHeartbeatAt: Date
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
            metaURL: directory.appendingPathComponent("meta.json", isDirectory: false)
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
    var fileHandle: FileHandle?
    var currentWalSize: Int64 = 0
    var lastMetaWriteAt: Date = .distantPast

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
    private var hasScheduledOrphanSweep = false

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

    /// Restore-path fallback read. Synchronous and launch-time only (mirrors
    /// `SessionPersistenceStore.load`'s synchronous snapshot read) — never
    /// called from the tap callback or any latency-sensitive path. Reads the
    /// rotated tail (if any) then the current file, capped to
    /// `SessionWALPolicy.walCapBytes`, and decodes leniently since PTY bytes
    /// may include partial UTF-8 sequences at the truncation boundary.
    func readFallbackScrollbackText(sessionId: String) -> String? {
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
        }

        let data = Data(bytes)
        writer.fileHandle?.write(data)
        writer.fileHandle?.synchronizeFile()
        writer.currentWalSize += Int64(data.count)
    }

    private func writeMeta(writer: SessionWALWriter, at date: Date) {
        let meta = SessionWALMeta(
            sessionId: writer.context.surfaceId,
            childPID: nil,
            ptyPath: nil,
            workingDirectory: writer.workingDirectory,
            lastHeartbeatAt: date
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
