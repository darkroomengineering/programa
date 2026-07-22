import Foundation
#if DEBUG
import Bonsplit
#endif

/// SPIKE (feat/session-wal-spike): registers a PTY output tap on every
/// terminal surface via ghostty's `ghostty_surface_set_output_tap` C API and
/// counts bytes per surface. This is NOT the session WAL itself — it exists
/// only to measure whether tapping PTY output at all has a measurable
/// typing-latency cost, so CI's typing-lag job can compare this branch
/// against main.
///
/// Threading / atomicity decision (explicit, pragmatic spike tradeoff):
/// The C callback runs on ghostty's io-reader thread, under the
/// renderer_state mutex, exactly ONE fixed thread per surface for the
/// lifetime of the tap. It must be allocation/lock free (see ghostty.h).
/// The only reader of the counter is a DEBUG-only 10s timer that logs an
/// approximate byte count — it does not need a linearizable read. Given
/// that, and that this project does not depend on swift-atomics (checked
/// Package.swift / project.pbxproj — no match), the simplest option that
/// genuinely compiles without new dependencies and without locks in the
/// callback is a plain `Int64` written only from the io-reader thread and
/// read racily from the debug timer thread.
/// SPIKE: single-writer, racy-reader by design. Do not copy this pattern
/// for anything that needs a correct multi-writer counter or exact reads.
final class SessionOutputTapSpike {

    /// Per-surface context handed to the C callback as `userdata` via
    /// `Unmanaged`. Holds ONLY the byte counter and a stable id string for
    /// logging — never a reference to Swift UI/runtime objects, since the
    /// callback must never touch anything that can lock or allocate.
    final class Context {
        let surfaceId: String

        /// SPIKE: single-writer (io-reader thread), racy-reader (debug
        /// timer) by design — see type-level doc comment.
        var bytes: Int64 = 0

        init(surfaceId: String) {
            self.surfaceId = surfaceId
        }
    }

    static let shared = SessionOutputTapSpike()

    private var contextsById: [String: Context] = [:]
    private let bookkeepingLock = NSLock()
    #if DEBUG
    private var timer: DispatchSourceTimer?
    #endif

    private init() {
        #if DEBUG
        startDebugTimer()
        #endif
    }

    /// Registers the output tap for a newly created surface. The caller
    /// (`TerminalSurface`) must hold onto the returned `Unmanaged<Context>`
    /// and release it exactly once, right after clearing the tap at
    /// teardown via `unregister`.
    func register(surface: ghostty_surface_t, surfaceId: String) -> Unmanaged<Context> {
        let context = Context(surfaceId: surfaceId)
        let unmanaged = Unmanaged<Context>.passRetained(context)

        bookkeepingLock.lock()
        contextsById[surfaceId] = context
        bookkeepingLock.unlock()

        ghostty_surface_set_output_tap(surface, sessionOutputTapSpikeCallback, unmanaged.toOpaque())
        return unmanaged
    }

    /// Clears the tap (passing a NULL callback, per the C API contract) and
    /// forgets the bookkeeping entry used for debug logging. Callers must
    /// still separately release the `Unmanaged<Context>` returned from
    /// `register` after calling this.
    func unregister(surface: ghostty_surface_t?, surfaceId: String) {
        if let surface {
            ghostty_surface_set_output_tap(surface, nil, nil)
        }
        bookkeepingLock.lock()
        contextsById.removeValue(forKey: surfaceId)
        bookkeepingLock.unlock()
    }

    #if DEBUG
    private func startDebugTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.logCounters()
        }
        timer.resume()
        self.timer = timer
    }

    private func logCounters() {
        bookkeepingLock.lock()
        let snapshot = contextsById.map { ($0.key, $0.value.bytes) }
        bookkeepingLock.unlock()

        for (surfaceId, bytes) in snapshot {
            dlog("wal.tap surface=\(surfaceId) bytes=\(bytes)")
        }
    }
    #endif
}

/// C callback registered via `ghostty_surface_set_output_tap`. Runs on
/// ghostty's io-reader thread under the renderer_state mutex — per the
/// header contract this must stay allocation/lock free. This body does
/// exactly one thing: read userdata, add `len` to the counter. Nothing
/// else — no dlog, no DispatchQueue, no Swift runtime calls that can lock
/// or allocate.
private func sessionOutputTapSpikeCallback(
    _ buf: UnsafePointer<UInt8>?,
    _ len: UInt,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let userdata else { return }
    let context = Unmanaged<SessionOutputTapSpike.Context>.fromOpaque(userdata).takeUnretainedValue()
    context.bytes &+= Int64(len)
}
