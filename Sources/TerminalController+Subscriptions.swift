// Socket event subscriptions (#167): push agent-state, output, and workspace-lifecycle events
// over a long-lived connection instead of making external tools (dashboards, orchestrators, a
// menu bar on another machine) poll `surface.list`/`workspace.list` in a loop.
//
// Design (see docs/v2-api-migration.md "Socket Event Subscriptions (#167)" for the full spec,
// written before this was implemented):
//   - `subscribe` upgrades the calling connection: it keeps answering ordinary v2 requests on
//     the same connection (including `unsubscribe`), but frames pushed by
//     `SocketEventBroadcaster` are interleaved on the same socket, serialized through
//     `SocketConnection.writeLock` so a push can never corrupt an in-flight response line.
//   - The one-shot `surface.wait` helpers (#166) remain the front door for simple "wait for one
//     thing" callers; subscriptions are for consumers that want many events over time, so a
//     casual caller never has to touch a queue/backpressure/reconnect model.
//   - Backpressure: each subscription owns a bounded (256-event) drop-oldest queue drained on
//     its own dedicated serial dispatch queue -- never on the thread that mutated app state, so
//     a slow/blocked client socket write never stalls a telemetry mutation or the main thread.
//     When the queue overflows, a synthetic `{"event":"dropped","count":N}` frame is spliced in
//     ahead of the next real frame so a client always knows to re-sync via `surface.list`/
//     `workspace.list` rather than silently missing events.
//   - Disconnect: the first failed `write()` (client gone) tears the subscription down and
//     unregisters it from the broadcaster; `handleClient`'s existing read-loop teardown also
//     unconditionally tears down any subscription on that connection (client-initiated close,
//     or the app shutting the listener down).
import Foundation

/// Event classes selectable via `subscribe`'s `classes` param (#167).
enum SocketEventClass: String, CaseIterable {
    case agentState = "agent_state"
    case output
    case workspaceLifecycle = "workspace_lifecycle"
}

/// Wraps a single accepted v2 socket connection (one per `TerminalController.handleClient`
/// invocation) so that ordinary request/response writes and subscription event pushes -- which
/// can originate from different threads -- serialize onto the same underlying fd through one
/// lock, and so a subscription can be torn down deterministically when the connection closes.
final class SocketConnection: @unchecked Sendable {
    private let socket: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false
    private(set) var subscription: EventSubscription?

    init(socket: Int32) {
        self.socket = socket
    }

    /// Writes one newline-terminated line to the connection's socket. Used for both ordinary
    /// v2 responses and pushed event frames -- the lock is what keeps them from interleaving.
    /// Returns `false` on a write failure (client gone), at which point the caller should treat
    /// the connection as dead (the read loop will observe this on its next `read()` regardless).
    @discardableResult
    func writeLine(_ line: String) -> Bool {
        stateLock.lock()
        let alreadyClosed = closed
        stateLock.unlock()
        guard !alreadyClosed else { return false }

        let bytes = Array((line + "\n").utf8)
        writeLock.lock()
        defer { writeLock.unlock() }
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer -> Int in
                write(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            }
            if written <= 0 {
                return false
            }
            offset += written
        }
        return true
    }

    /// Attaches a subscription to this connection, tearing down any previous one first --
    /// `subscribe` replaces an existing subscription rather than stacking a second one (a
    /// connection has at most one).
    func attach(_ subscription: EventSubscription) {
        stateLock.lock()
        let previous = self.subscription
        self.subscription = subscription
        stateLock.unlock()
        previous?.teardown()
    }

    func detachSubscription() {
        stateLock.lock()
        let previous = subscription
        subscription = nil
        stateLock.unlock()
        previous?.teardown()
    }

    /// Called from `handleClient`'s `defer`, in addition to (and before) closing the raw fd.
    func teardown() {
        stateLock.lock()
        closed = true
        let previous = subscription
        subscription = nil
        stateLock.unlock()
        previous?.teardown()
    }
}

/// A single connection's live event subscription (#167). Backpressure/disconnect semantics are
/// documented on the file header; this type owns the bounded queue and the dedicated drain
/// queue that decouples "an app-state mutation happened" from "write it to a socket".
final class EventSubscription: @unchecked Sendable {
    let id = UUID()
    let classes: Set<SocketEventClass>
    /// Surfaces this subscription wants `output` events for. Required (and non-empty) when
    /// `classes` contains `.output` -- broadcasting every keystroke on every surface to every
    /// subscriber by default would be prohibitively expensive, so `output` is opt-in per surface.
    let outputSurfaceIds: Set<UUID>

    /// Bounded per-connection queue size before drop-oldest kicks in. 256 events comfortably
    /// covers a burst across several watched surfaces at the ~100ms output-coalescing tick (see
    /// `TerminalController.v2PollSubscribedOutputOnce`) plus agent-state/lifecycle churn, while
    /// still bounding worst-case memory for a client that stops reading.
    static let maxQueuedEvents = 256

    private weak var connection: SocketConnection?
    private let drainQueue: DispatchQueue
    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    private var droppedCount = 0
    private var isDraining = false
    private var isTornDown = false

    init(connection: SocketConnection, classes: Set<SocketEventClass>, outputSurfaceIds: Set<UUID>) {
        self.connection = connection
        self.classes = classes
        self.outputSurfaceIds = outputSurfaceIds
        self.drainQueue = DispatchQueue(label: "programa.socket.subscription.\(id.uuidString)")
    }

    /// Enqueues `frame` for delivery. Safe to call from any thread. Drop-oldest: when the queue
    /// is already at `maxQueuedEvents`, the oldest queued event is discarded to make room for
    /// this one (a subscriber falling behind gets the *freshest* events, not a growing backlog).
    func enqueue(_ frame: [String: Any]) {
        lock.lock()
        guard !isTornDown else { lock.unlock(); return }
        if pending.count >= Self.maxQueuedEvents {
            pending.removeFirst()
            droppedCount += 1
        }
        pending.append(frame)
        let shouldSchedule = !isDraining
        if shouldSchedule { isDraining = true }
        lock.unlock()

        if shouldSchedule {
            drainQueue.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            if isTornDown {
                isDraining = false
                lock.unlock()
                return
            }
            if droppedCount > 0 {
                let count = droppedCount
                droppedCount = 0
                lock.unlock()
                let droppedFrame: [String: Any] = ["event": "dropped", "count": count]
                guard writeFrame(droppedFrame) else { teardown(); return }
                continue
            }
            guard !pending.isEmpty else {
                isDraining = false
                lock.unlock()
                return
            }
            let frame = pending.removeFirst()
            lock.unlock()

            guard writeFrame(frame) else { teardown(); return }
        }
    }

    private func writeFrame(_ frame: [String: Any]) -> Bool {
        guard let line = SocketEventBroadcaster.encodeFrame(frame) else { return true }
        guard let connection else { return false }
        return connection.writeLine(line)
    }

    /// Idempotent. Called on write failure (client gone), on `unsubscribe`, and from
    /// `SocketConnection.teardown()` when the connection itself is closing.
    func teardown() {
        lock.lock()
        guard !isTornDown else { lock.unlock(); return }
        isTornDown = true
        pending.removeAll()
        lock.unlock()
        SocketEventBroadcaster.shared.unregister(self)
    }
}

/// Fan-out hub for #167 socket event subscriptions. `publish*` methods are safe to call from any
/// thread and are cheap when there are no subscribers (the common case) -- callers on hot paths
/// (agent-state mutation, output polling) call them unconditionally rather than checking first.
final class SocketEventBroadcaster: @unchecked Sendable {
    static let shared = SocketEventBroadcaster()

    private let lock = NSLock()
    private var subscriptions: [UUID: EventSubscription] = [:]
    /// Last-seen full text length per watched surface, used to compute the "new tail" diff for
    /// `output` events. Cleared when the last subscriber watching a surface unregisters.
    private var lastOutputLength: [UUID: Int] = [:]

    func register(_ subscription: EventSubscription) {
        lock.lock()
        subscriptions[subscription.id] = subscription
        lock.unlock()
    }

    func unregister(_ subscription: EventSubscription) {
        lock.lock()
        subscriptions.removeValue(forKey: subscription.id)
        let stillWatched = Set(subscriptions.values.flatMap { $0.outputSurfaceIds })
        lastOutputLength = lastOutputLength.filter { stillWatched.contains($0.key) }
        lock.unlock()
    }

    private func subscribers(for eventClass: SocketEventClass) -> [EventSubscription] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.values.filter { $0.classes.contains(eventClass) }
    }

    /// All surface ids any live subscription wants `output` events for -- polled by
    /// `TerminalController.v2PollSubscribedOutputOnce` on its ~100ms tick.
    func watchedOutputSurfaceIds() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.values.reduce(into: Set<UUID>()) { $0.formUnion($1.outputSurfaceIds) }
    }

    func publishAgentState(workspaceId: UUID, surfaceId: UUID, state: AgentActivityState?, source: AgentStateSource? = nil) {
        let subs = subscribers(for: .agentState)
        guard !subs.isEmpty else { return }
        let frame: [String: Any] = [
            "event": "agent_state",
            "workspace_id": workspaceId.uuidString,
            "surface_id": surfaceId.uuidString,
            "state": state.map { $0.rawValue } ?? NSNull(),
            "source": source.map { $0.rawValue } ?? NSNull(),
            "ts": Date().timeIntervalSince1970
        ]
        for sub in subs { sub.enqueue(frame) }
    }

    func publishWorkspaceLifecycle(kind: String, workspaceId: UUID, title: String?) {
        let subs = subscribers(for: .workspaceLifecycle)
        guard !subs.isEmpty else { return }
        let frame: [String: Any] = [
            "event": "workspace_lifecycle",
            "kind": kind,
            "workspace_id": workspaceId.uuidString,
            "title": title.map { $0 as Any } ?? NSNull(),
            "ts": Date().timeIntervalSince1970
        ]
        for sub in subs { sub.enqueue(frame) }
    }

    /// Diffs `fullText` against the last-seen length for `surfaceId` and, only for subscriptions
    /// actually watching that surface, publishes the newly-appended tail (capped) as one
    /// coalesced `output` event -- never per-byte. Called from
    /// `TerminalController.v2PollSubscribedOutputOnce`'s ~100ms tick, already inside a
    /// `v2MainSync` hop so `fullText` is a consistent point-in-time read.
    func publishOutputIfChanged(workspaceId: UUID, surfaceId: UUID, fullText: String) {
        let subs = subscribers(for: .output).filter { $0.outputSurfaceIds.contains(surfaceId) }
        guard !subs.isEmpty else { return }

        lock.lock()
        let previousLength = lastOutputLength[surfaceId] ?? fullText.count
        lastOutputLength[surfaceId] = fullText.count
        lock.unlock()

        guard fullText.count > previousLength else { return }
        // Text can also shrink/scroll between ticks (e.g. clear screen); in that case there is
        // no well-defined "tail" to report, so this tick is skipped rather than guessing.
        let tailStart = fullText.index(fullText.startIndex, offsetBy: previousLength)
        let tail = String(fullText[tailStart...].suffix(4000))
        guard !tail.isEmpty else { return }

        let frame: [String: Any] = [
            "event": "output",
            "workspace_id": workspaceId.uuidString,
            "surface_id": surfaceId.uuidString,
            "text": tail,
            "ts": Date().timeIntervalSince1970
        ]
        for sub in subs { sub.enqueue(frame) }
    }

    static func encodeFrame(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var s = String(data: data, encoding: .utf8) else {
            return nil
        }
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        return s
    }
}

extension TerminalController {
    /// `subscribe`: upgrades the calling connection to receive pushed events for the requested
    /// `classes` (any of `agent_state`, `output`, `workspace_lifecycle`). Replaces any existing
    /// subscription on this connection. `output` requires a non-empty `surface_ids` array.
    func v2Subscribe(params: [String: Any], connection: SocketConnection) -> V2CallResult {
        guard let rawClasses = v2StringArray(params, "classes"), !rawClasses.isEmpty else {
            return .err(
                code: "invalid_params",
                message: "classes must be a non-empty array of: agent_state, output, workspace_lifecycle",
                data: nil
            )
        }
        var classes: Set<SocketEventClass> = []
        for raw in rawClasses {
            guard let eventClass = SocketEventClass(rawValue: raw) else {
                return .err(
                    code: "invalid_params",
                    message: "Unknown event class '\(raw)' -- use: agent_state, output, workspace_lifecycle",
                    data: nil
                )
            }
            classes.insert(eventClass)
        }

        var outputSurfaceIds: Set<UUID> = []
        if classes.contains(.output) {
            guard let rawSurfaceIds = v2StringArray(params, "surface_ids"), !rawSurfaceIds.isEmpty else {
                return .err(
                    code: "invalid_params",
                    message: "surface_ids (non-empty array) is required when subscribing to 'output'",
                    data: nil
                )
            }
            for raw in rawSurfaceIds {
                guard let uuid = v2UUIDAny(raw) else {
                    return .err(code: "invalid_params", message: "Invalid surface id in surface_ids: \(raw)", data: nil)
                }
                outputSurfaceIds.insert(uuid)
            }
        }

        let subscription = EventSubscription(connection: connection, classes: classes, outputSurfaceIds: outputSurfaceIds)
        SocketEventBroadcaster.shared.register(subscription)
        connection.attach(subscription)
        if classes.contains(.output) {
            v2StartOutputPollLoopIfNeeded()
        }

        return .ok([
            "subscription_id": subscription.id.uuidString,
            "classes": classes.map { $0.rawValue }.sorted(),
            "surface_ids": outputSurfaceIds.map { $0.uuidString }.sorted(),
            "max_queued_events": EventSubscription.maxQueuedEvents
        ])
    }

    /// `unsubscribe`: tears down any live subscription on the calling connection. No-ops (still
    /// `ok`) if there wasn't one, so a client doesn't need to track whether it subscribed.
    func v2Unsubscribe(params: [String: Any], connection: SocketConnection) -> V2CallResult {
        connection.detachSubscription()
        return .ok(["unsubscribed": true])
    }

    // MARK: - Output event polling (#167 task 3)

    private static let outputPollInterval: TimeInterval = 0.1
    private static let outputPollLock = NSLock()
    private nonisolated(unsafe) static var outputPollStarted = false

    /// Lazily starts (once, process-lifetime) the shared thread that drives `output` events:
    /// every ~100ms it reads each currently-watched surface's text and publishes only the newly
    /// appended tail (see `SocketEventBroadcaster.publishOutputIfChanged`) -- coalesced, not
    /// per-byte, and self-throttling (a no-op tick whenever nothing is watched). One thread
    /// total regardless of subscriber/surface count, matching the pattern-wait poll's approach
    /// of reusing a single point-in-time text read rather than a push-based content-changed
    /// callback (Ghostty doesn't expose one at the app layer).
    func v2StartOutputPollLoopIfNeeded() {
        Self.outputPollLock.lock()
        defer { Self.outputPollLock.unlock() }
        guard !Self.outputPollStarted else { return }
        Self.outputPollStarted = true
        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: TerminalController.outputPollInterval)
                self?.v2PollSubscribedOutputOnce()
            }
        }
    }

    private func v2PollSubscribedOutputOnce() {
        let surfaceIds = SocketEventBroadcaster.shared.watchedOutputSurfaceIds()
        guard !surfaceIds.isEmpty else { return }

        for surfaceId in surfaceIds {
            v2MainSync {
                guard let located = AppDelegate.shared?.locateSurface(surfaceId: surfaceId),
                      let ws = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
                      let terminalPanel = ws.panels[surfaceId] as? TerminalPanel,
                      let text = self.v2SurfaceWaitReadText(terminalPanel: terminalPanel, lineLimit: 4000) else {
                    return
                }
                SocketEventBroadcaster.shared.publishOutputIfChanged(workspaceId: ws.id, surfaceId: surfaceId, fullText: text)
            }
        }
    }
}
