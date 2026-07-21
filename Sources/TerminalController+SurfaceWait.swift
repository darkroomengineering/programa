// surface.wait (#166 task 1): server-owned, event-driven waits on a terminal surface.
//
// An agent orchestrating a sibling surface previously had to poll `surface.read_text` in a
// loop and guess when the other side was done -- racy (state can flip between two polls) and
// wastes tokens. `surface.wait` blocks the calling socket connection (with a timeout) until
// the surface hits a condition and answers in a single request/response round trip.
//
// Threading: each socket connection is handled on its own detached thread (see
// `TerminalController.handleClient`, started via `Thread.detachNewThread` in the accept loop).
// There is no shared/serial command queue across connections -- `withSocketCommandPolicy` only
// holds a lock briefly to push/pop a stack, not around command execution. So blocking *this*
// connection's thread for the wait's duration is safe: it does not stall the main thread, does
// not stall other connections, and does not steal focus (surface.wait never mutates in-app
// focus/selection, matching the "read-only" socket focus policy).
import Foundation

/// Registry of pending `exit`-condition waiters for `surface.wait`, keyed by terminal surface id.
///
/// This is the event-driven half of `surface.wait` with `exit: true` -- there is no polling
/// involved. Ghostty reports child-process exit via the `GHOSTTY_ACTION_SHOW_CHILD_EXITED`
/// action (handled in `GhosttyApp.swift`), which always runs its follow-up work via
/// `DispatchQueue.main.async`. `fire(surfaceId:)` is called from that same main-thread block.
///
/// No-missed-events guarantee: `TerminalController.v2SurfaceWait` checks whether the surface has
/// *already* exited (i.e. its panel is already gone) and, if not, calls `addWaiter` with the
/// real completion callback -- both inside the same `v2MainSync` hop. Because the main dispatch
/// queue is FIFO/serial, and both the "did it already exit" check and the eventual
/// `fire(surfaceId:)` call run as main-queue work items, there is no window in which a
/// child-exit racing the wait call can be missed: either the exit's main-queue block ran first
/// (so the panel is already gone and the check short-circuits to "already satisfied"), or it
/// runs after (so the waiter registered moments earlier is still in the registry when `fire`
/// executes).
final class SurfaceExitWaitRegistry: @unchecked Sendable {
    static let shared = SurfaceExitWaitRegistry()

    private struct Entry {
        let token: UUID
        let callback: () -> Void
    }

    private let lock = NSLock()
    private var waiters: [UUID: [Entry]] = [:]

    /// Registers `callback` to run exactly once when `surfaceId`'s child process exits.
    /// Must be called on the main thread (see type doc for why that matters for correctness).
    /// Returns a token that can be passed to `removeWaiter` to cancel (e.g. on timeout).
    @discardableResult
    func addWaiter(surfaceId: UUID, callback: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        waiters[surfaceId, default: []].append(Entry(token: token, callback: callback))
        lock.unlock()
        return token
    }

    /// Cancels a previously-registered waiter (e.g. after `surface.wait` times out) so it is
    /// never invoked and the registry does not grow unbounded across many short-lived waits.
    func removeWaiter(surfaceId: UUID, token: UUID) {
        lock.lock()
        waiters[surfaceId]?.removeAll { $0.token == token }
        if waiters[surfaceId]?.isEmpty == true {
            waiters.removeValue(forKey: surfaceId)
        }
        lock.unlock()
    }

    /// Fires and clears all waiters registered for `surfaceId`. Must be called on the main
    /// thread from the same code path that observes the child-exit action, so it is ordered
    /// consistently with `addWaiter` (see type doc).
    func fire(surfaceId: UUID) {
        lock.lock()
        let entries = waiters.removeValue(forKey: surfaceId) ?? []
        lock.unlock()
        for entry in entries {
            entry.callback()
        }
    }
}

extension TerminalController {
    /// Poll interval used while waiting on a `pattern` condition. Ghostty does not expose a
    /// push-based "surface content changed" callback to the app layer (unlike child-exit, which
    /// has a dedicated action) -- `ghostty_surface_read_text` only supports point-in-time reads.
    /// So the pattern branch re-reads the surface's current text on a short timer instead of a
    /// true content-changed event. This still satisfies the "single call, no caller-side polling"
    /// goal of #166: the polling happens once, inside the app, on the connection's own thread,
    /// and the caller gets exactly one request/response round trip.
    private static let surfaceWaitPollInterval: TimeInterval = 0.1

    /// `surface.wait`: block (with timeout) until a surface hits a condition -- new output
    /// matching a regex `pattern`, or the surface's child process exiting (`exit: true`).
    /// Exactly one of `pattern` / `exit` must be provided.
    func v2SurfaceWait(params: [String: Any]) -> V2CallResult {
        let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 30_000)
        let timeout = Double(timeoutMs) / 1000.0
        let deadline = Date().addingTimeInterval(timeout)

        let patternRaw = v2String(params, "pattern")
        let waitForExit = v2Bool(params, "exit") ?? false

        guard (patternRaw != nil) != waitForExit else {
            return .err(
                code: "invalid_params",
                message: "Provide exactly one of 'pattern' (regex string) or 'exit' (true)",
                data: nil
            )
        }

        let regex: NSRegularExpression?
        if let patternRaw {
            do {
                regex = try NSRegularExpression(pattern: patternRaw)
            } catch {
                return .err(
                    code: "invalid_params",
                    message: "Invalid regex in 'pattern': \(error.localizedDescription)",
                    data: ["pattern": patternRaw]
                )
            }
        } else {
            regex = nil
        }

        let lineLimit = v2Int(params, "lines")
        if let lineLimit, lineLimit <= 0 {
            return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
        }

        // Declared up front (not inside the v2MainSync closure below) so the exit branch can
        // register the *real* completion callback in the very same main-thread hop that checks
        // whether the surface has already exited -- no separate "install the watcher" step that
        // could race a concurrent child-exit.
        let exitSemaphore = DispatchSemaphore(value: 0)

        var setupError: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var windowId: UUID?
        var alreadySatisfied = false
        var matchedText: String?
        var exitWaiterToken: UUID?

        // Single main-thread hop: resolve the target, and atomically (a) check whether the
        // condition is *already* true right now, and (b) if not, install the watcher (exit
        // registry entry with the real signal callback, or nothing extra for pattern -- the
        // poll loop below re-reads fresh state on every tick so there is no separate "install"
        // step to race against there). This is what guarantees a marker printed between
        // call-arrival and "watcher install" -- or a child-exit racing the call -- is never
        // missed.
        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupError = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupError = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId = self.v2UUID(params, "surface_id") ?? ws.focusedPanelId
            guard let surfaceId else {
                setupError = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }

            workspaceId = ws.id
            surfaceIdOut = surfaceId
            windowId = self.v2ResolveWindowId(tabManager: tabManager)

            guard let panel = ws.panels[surfaceId] else {
                // Surface is already gone. For `exit` that means the condition is already
                // satisfied (this is exactly the "a parallel state change can't be missed" case
                // for exit waits). For `pattern` there is nothing left to read.
                if waitForExit {
                    alreadySatisfied = true
                } else {
                    setupError = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                }
                return
            }

            if waitForExit {
                exitWaiterToken = SurfaceExitWaitRegistry.shared.addWaiter(surfaceId: surfaceId) {
                    exitSemaphore.signal()
                }
                return
            }

            guard let terminalPanel = panel as? TerminalPanel else {
                setupError = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            if let regex, let text = self.v2SurfaceWaitReadText(terminalPanel: terminalPanel, lineLimit: lineLimit) {
                if let match = self.v2SurfaceWaitFirstMatch(regex: regex, in: text) {
                    alreadySatisfied = true
                    matchedText = match
                }
            }
        }

        if let setupError { return setupError }
        guard let workspaceId, let surfaceIdOut else {
            return .err(code: "internal_error", message: "Failed to resolve surface", data: nil)
        }

        func result(waited: Bool, matched: String? = nil) -> V2CallResult {
            var payload: [String: Any] = [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "condition": waitForExit ? "exit" : "pattern",
                "waited": waited
            ]
            if let matched {
                payload["match"] = matched
            }
            return .ok(payload)
        }

        if alreadySatisfied {
            return result(waited: false, matched: matchedText)
        }

        if waitForExit {
            guard let exitWaiterToken else {
                return .err(code: "internal_error", message: "Failed to register exit watcher", data: nil)
            }
            if exitSemaphore.wait(timeout: .now() + timeout) == .success {
                return result(waited: true)
            }
            SurfaceExitWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: exitWaiterToken)
            return .err(code: "timeout", message: "Surface did not exit before timeout", data: ["timeout_ms": timeoutMs])
        }

        // Pattern condition: poll on this connection's own thread (not main, not a shared
        // command queue -- see file header) until the regex matches new state or the deadline
        // passes. Each tick re-resolves the surface, so a surface closed mid-wait resolves to a
        // clear error instead of hanging until timeout.
        guard let regex else {
            return .err(code: "internal_error", message: "Missing compiled pattern", data: nil)
        }
        while Date() < deadline {
            Thread.sleep(forTimeInterval: Self.surfaceWaitPollInterval)

            var tickError: V2CallResult?
            var tickMatch: String?
            v2MainSync {
                guard let tabManager = self.v2ResolveTabManager(params: params),
                      let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                    tickError = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                guard let panel = ws.panels[surfaceIdOut] else {
                    tickError = .err(code: "not_found", message: "Surface closed while waiting", data: ["surface_id": surfaceIdOut.uuidString])
                    return
                }
                guard let terminalPanel = panel as? TerminalPanel else {
                    tickError = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceIdOut.uuidString])
                    return
                }
                guard let text = self.v2SurfaceWaitReadText(terminalPanel: terminalPanel, lineLimit: lineLimit) else {
                    return
                }
                tickMatch = self.v2SurfaceWaitFirstMatch(regex: regex, in: text)
            }
            if let tickError { return tickError }
            if let tickMatch { return result(waited: true, matched: tickMatch) }
        }

        return .err(code: "timeout", message: "Pattern did not match before timeout", data: ["timeout_ms": timeoutMs])
    }

    /// Reads the surface's current text (screen + scrollback) for pattern matching. Always
    /// includes scrollback so a marker that has already scrolled off-screen by the time we poll
    /// is still found. `lineLimit` bounds the read cost for very long-lived waits.
    private func v2SurfaceWaitReadText(terminalPanel: TerminalPanel, lineLimit: Int?) -> String? {
        let response = readTerminalTextBase64(
            terminalPanel: terminalPanel,
            includeScrollback: true,
            lineLimit: lineLimit ?? 2000
        )
        guard response.hasPrefix("OK ") else { return nil }
        let base64 = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.isEmpty { return "" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func v2SurfaceWaitFirstMatch(regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
    }
}
