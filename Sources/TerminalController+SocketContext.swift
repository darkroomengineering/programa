import Foundation

/// Why `v2ResolveTabManager` returned nil for a selector the client did pass. The ~80 handlers
/// that call it answer a generic `unavailable` on nil; `v2Result` swaps that for this typed
/// error, so an unknown ref or UUID reads `not_found` and a malformed one `invalid_params`.
struct V2SelectorResolutionFailure {
    let code: String
    let message: String
    let data: [String: Any]
}

extension TerminalController {
    private nonisolated static let selectorResolutionFailureThreadKey =
        "com.darkroom.programa.socket-selector-resolution-failure"

    /// Records the failure for `key` on the current thread and returns nil, so a resolver can
    /// write `guard ... else { return v2SelectorUnresolved(params, "window_id") }`.
    nonisolated func v2SelectorUnresolved<T>(_ params: [String: Any], _ key: String) -> T? {
        let raw = (params[key] as? String) ?? String(describing: params[key] ?? "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wellFormed = UUID(uuidString: trimmed) != nil
            || trimmed.range(of: #"^[a-z_]+:[0-9]+$"#, options: .regularExpression) != nil
        let failure = wellFormed
            ? V2SelectorResolutionFailure(code: "not_found", message: "\(key) not found: \(trimmed)", data: [key: trimmed])
            : V2SelectorResolutionFailure(code: "invalid_params", message: "Missing or invalid \(key)", data: [key: raw])
        Thread.current.threadDictionary[Self.selectorResolutionFailureThreadKey] = failure
        return nil
    }

    /// Returns and clears the current thread's recorded failure.
    nonisolated static func v2TakeSelectorResolutionFailure() -> V2SelectorResolutionFailure? {
        let threadDictionary = Thread.current.threadDictionary
        let failure = threadDictionary[selectorResolutionFailureThreadKey] as? V2SelectorResolutionFailure
        threadDictionary.removeObject(forKey: selectorResolutionFailureThreadKey)
        return failure
    }

    /// Moves a failure recorded on main during a `v2MainSync` body to the socket thread that is
    /// blocked waiting for it (safe: that thread does nothing until `main.sync` returns).
    nonisolated static func v2MoveSelectorResolutionFailure(to caller: Thread) {
        guard let failure = v2TakeSelectorResolutionFailure() else { return }
        caller.threadDictionary[selectorResolutionFailureThreadKey] = failure
    }
}

extension TerminalController {
    /// Pinned `limit_reached` error for split requests at `SplitPolicy.maxPanesPerWorkspace`,
    /// checked before any panel is built (the Bonsplit veto alone surfaces as internal_error).
    func v2PaneLimitError(for workspace: Workspace) -> V2CallResult? {
        let maxPanes = SplitPolicy.maxPanesPerWorkspace
        guard workspace.bonsplitController.allPaneIds.count >= maxPanes else { return nil }
        return .err(
            code: "limit_reached",
            message: "Workspace already has the maximum of \(maxPanes) panes",
            data: ["max_panes": maxPanes]
        )
    }
}

extension TerminalController {
    /// Notification text and agent identity strings get the same kind of ceiling the sibling
    /// telemetry commands enforce: an oversized value is rejected, not stored.
    nonisolated static let v2NotificationTextLimits: [(key: String, maxBytes: Int)] = [
        ("title", SidebarTelemetryLimits.maxStatusValueBytes),
        ("subtitle", SidebarTelemetryLimits.maxStatusValueBytes),
        ("body", SidebarTelemetryLimits.maxLogMessageBytes),
    ]
    nonisolated static let v2AgentIdentityLimits: [(key: String, maxBytes: Int)] = [
        "provider", "session_id", "turn_id", "item_id", "label", "resolution",
    ].map { ($0, SidebarTelemetryLimits.maxKeyBytes) }

    nonisolated func v2TextLimitError(_ params: [String: Any], _ limits: [(key: String, maxBytes: Int)]) -> V2CallResult? {
        for limit in limits {
            guard let value = params[limit.key] as? String,
                  !SidebarTelemetryLimits.isWithinUTF8Limit(value, maxBytes: limit.maxBytes) else { continue }
            return .err(
                code: "invalid_params",
                message: "\(limit.key) exceeds \(limit.maxBytes) bytes",
                data: ["param": limit.key, "max_bytes": limit.maxBytes]
            )
        }
        return nil
    }

    nonisolated static var v2DefaultNotificationTitle: String {
        String(localized: "sock.notification.defaultTitle", defaultValue: "Notification")
    }
}

// MARK: - Long waits (surface.wait, agent.prompt)

enum V2WatchedWaitOutcome {
    case signaled
    case timedOut
    case surfaceClosed
    case clientGone
}

extension TerminalController {
    private nonisolated static let socketClientFDThreadKey = "com.darkroom.programa.socket-client-fd"
    /// How often a long wait re-checks that its surface and its client still exist.
    nonisolated static let watchedWaitCheckInterval: TimeInterval = 0.25
    /// Upper bound for caller-supplied surface.wait / agent.prompt timeouts (one hour).
    nonisolated static let watchedWaitMaxTimeoutMs = 3_600_000

    /// Called once by `handleClient` on its per-connection thread.
    nonisolated static func v2SetCurrentSocketClientFD(_ fd: Int32) {
        Thread.current.threadDictionary[socketClientFDThreadKey] = NSNumber(value: fd)
    }

    /// True when the client that issued the current request has hung up. Peeks without
    /// consuming, so a pipelined next request stays in the buffer for the read loop.
    nonisolated func v2SocketClientDisconnected() -> Bool {
        guard let fd = (Thread.current.threadDictionary[Self.socketClientFDThreadKey] as? NSNumber)?.int32Value else {
            return false
        }
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 0) > 0 else { return false }
        if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        guard descriptor.revents & Int16(POLLIN) != 0 else { return false }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    /// The workspace that currently holds `surfaceId`, looked up by id in every window (not via
    /// the request's selectors, which may now point elsewhere), then in the controller's own
    /// TabManager (covers a manager handed to `start(tabManager:)` that no window registered).
    func v2WorkspaceContaining(surfaceId: UUID) -> Workspace? {
        if let location = AppDelegate.shared?.locateSurface(surfaceId: surfaceId),
           let workspace = location.tabManager.tabs.first(where: { $0.id == location.workspaceId }) {
            return workspace
        }
        return tabManager?.tabs.first(where: { $0.panels[surfaceId] != nil })
    }

    nonisolated func v2SurfaceStillExists(_ surfaceId: UUID) -> Bool {
        v2MainSync { v2WorkspaceContaining(surfaceId: surfaceId) != nil }
    }

    /// Waits on `semaphore` in short slices so the wait ends early when the surface closes or
    /// the client disconnects, instead of pinning this connection's thread until the deadline.
    nonisolated func v2WatchedWait(_ semaphore: DispatchSemaphore, until deadline: Date, surfaceId: UUID) -> V2WatchedWaitOutcome {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timedOut }
            if semaphore.wait(timeout: .now() + min(remaining, Self.watchedWaitCheckInterval)) == .success {
                return .signaled
            }
            if v2SocketClientDisconnected() { return .clientGone }
            if !v2SurfaceStillExists(surfaceId) {
                // The event may have fired just before the panel went away; prefer it.
                return semaphore.wait(timeout: .now()) == .success ? .signaled : .surfaceClosed
            }
        }
    }

    nonisolated var v2ClientGoneError: V2CallResult {
        .err(code: "client_disconnected", message: "Client disconnected while waiting", data: nil)
    }
}
