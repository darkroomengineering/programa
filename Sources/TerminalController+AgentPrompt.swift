// agent.prompt (#166 task 3): submit a prompt to an agent surface and wait for it to finish, in
// one request. Built directly on top of surface.wait's agent_state condition (task 2) and
// surface.send_text's injection path -- see docs/v2-api-migration.md "agent.prompt (#166)" for
// the full semantics this implements.
//
// Semantics (documented, not just implied by the code -- keep the doc in sync with this file):
//   1. Send the prompt text (+ Enter) using the exact same injection path `surface.send_text`
//      uses, and -- inside that SAME main-thread hop -- capture the surface's agent_state at
//      that instant and register a watcher for the next "working" transition. This closes the
//      race where a hook reacts to the injected text before a separately-registered watcher
//      would exist (same atomic check+register pattern as surface.wait).
//   2. Grace window (`working_grace_ms`, default 3000): wait for the "working" transition.
//      - If observed, proceed to step 3.
//      - If the grace window elapses without ever seeing "working", there is nothing further
//        useful to wait for -- resolve immediately using whatever the surface's agent_state
//        already is (`working_observed: false`). This is deliberately not a hard error: a
//        prompt can finish faster than the grace window, or the hook simply may not fire for a
//        trivial prompt. If the surface never reported ANY agent_state at all (neither before
//        sending nor during the grace window), the response carries a `warning` field instead
//        of silently succeeding, since that combination usually means agent hooks were never
//        installed for this surface.
//   3. Once "working" is observed, wait (for the remaining overall `timeout_ms` budget) for the
//      surface's agent_state to reach "idle" (or clear entirely -- see surface.wait's no-state
//      rule) and resolve with `working_observed: true`.
//   4. If step 3's wait exceeds the overall timeout, the call fails with `timeout` -- the agent
//      started working but never finished within the requested budget.
import Foundation

extension TerminalController {
    /// `agent.prompt`: send `text` to an agent surface and block (single request/response) until
    /// the agent finishes, per the phased semantics documented on this file and in
    /// docs/v2-api-migration.md.
    func v2AgentPrompt(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawText = params["text"] as? String, !rawText.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        let totalTimeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 120_000)
        let workingGraceMs = max(1, v2Int(params, "working_grace_ms") ?? 3_000)
        let totalDeadline = Date().addingTimeInterval(Double(totalTimeoutMs) / 1000.0)

        // The caller supplies just the prompt text; agent.prompt always submits it (Enter),
        // mirroring "type the prompt, press Enter" -- callers don't need to know the surface's
        // line-ending convention. Any trailing whitespace/newline the caller already included is
        // stripped first so this never submits a stray blank line.
        let textToSend = rawText.trimmingCharacters(in: .whitespacesAndNewlines) + "\r"
        guard !textToSend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .err(code: "invalid_params", message: "text must contain non-whitespace content", data: nil)
        }

        let workingSemaphore = DispatchSemaphore(value: 0)
        let idleSemaphore = DispatchSemaphore(value: 0)

        var setupError: V2CallResult?
        var workspaceId: UUID?
        var surfaceIdOut: UUID?
        var windowId: UUID?
        var baselineState: AgentActivityState?
        var alreadyWorkingAtSendTime = false
        // Token for whichever watcher got registered inside the initial send+register hop:
        // the "working" watcher in the normal case, or an "idle" watcher directly when the
        // surface was already mid-task (`alreadyWorkingAtSendTime`) and there is nothing to
        // grace-wait for.
        var firstPhaseWaiterToken: UUID?
        // Written once from a registry callback (main thread) before it signals the matching
        // semaphore -- safe to read after `semaphore.wait` returns `.success` without an extra
        // lock, same reasoning as surface.wait's exit/agent_state branches.
        var resolvedState: AgentActivityState?

        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                setupError = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let surfaceId: UUID?
            if params["surface_id"] != nil {
                surfaceId = self.v2UUID(params, "surface_id")
                guard surfaceId != nil else {
                    setupError = .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
                    return
                }
            } else {
                surfaceId = ws.focusedPanelId
            }
            guard let surfaceId else {
                setupError = .err(code: "not_found", message: "No focused surface", data: nil)
                return
            }
            guard let panel = ws.panels[surfaceId] else {
                setupError = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            guard let terminalPanel = panel as? TerminalPanel else {
                setupError = .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
                return
            }

            workspaceId = ws.id
            surfaceIdOut = surfaceId
            windowId = self.v2ResolveWindowId(tabManager: tabManager)
            baselineState = ws.panelAgentStates[surfaceId]

            // Same injection path as surface.send_text (v2SurfaceSendText): prefer the live
            // ghostty surface; fall back to the queued path for a surface that hasn't attached
            // its view yet.
            if let surface = terminalPanel.surface.surface {
                self.sendSocketText(textToSend, surface: surface)
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2AgentPrompt")
            } else {
                terminalPanel.sendText(textToSend)
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }

            // Register the watcher in this SAME hop -- see file header step 1.
            if baselineState == .working {
                alreadyWorkingAtSendTime = true
                firstPhaseWaiterToken = AgentStateWaitRegistry.shared.addWaiter(surfaceId: surfaceId, condition: .idle) { state, _ in
                    resolvedState = state
                    idleSemaphore.signal()
                }
            } else {
                firstPhaseWaiterToken = AgentStateWaitRegistry.shared.addWaiter(surfaceId: surfaceId, condition: .working) { state, _ in
                    resolvedState = state
                    workingSemaphore.signal()
                }
            }
        }

        if let setupError { return setupError }
        guard let workspaceId, let surfaceIdOut, let firstPhaseWaiterToken else {
            return .err(code: "internal_error", message: "Failed to resolve surface", data: nil)
        }

        func result(workingObserved: Bool, finalState: AgentActivityState?, warning: String? = nil) -> V2CallResult {
            var payload: [String: Any] = [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: workspaceId),
                "surface_id": surfaceIdOut.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: surfaceIdOut),
                "window_id": self.v2OrNull(windowId?.uuidString),
                "window_ref": self.v2Ref(kind: .window, uuid: windowId),
                "working_observed": workingObserved,
                "final_state": self.v2OrNull(finalState?.rawValue)
            ]
            if let warning {
                payload["warning"] = warning
            }
            return .ok(payload)
        }

        if alreadyWorkingAtSendTime {
            // Already mid-task when we sent -- nothing to grace-wait for; go straight to
            // watching for idle, per file header step 1's "already working" branch.
            let remaining = totalDeadline.timeIntervalSinceNow
            guard remaining > 0, idleSemaphore.wait(timeout: .now() + max(0, remaining)) == .success else {
                AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: firstPhaseWaiterToken)
                return .err(
                    code: "timeout",
                    message: "Agent (already working when the prompt was sent) did not return to idle before timeout",
                    data: ["timeout_ms": totalTimeoutMs]
                )
            }
            return result(workingObserved: true, finalState: resolvedState)
        }

        // Step 2: grace window for a "working" transition.
        let observedWorking = workingSemaphore.wait(timeout: .now() + Double(workingGraceMs) / 1000.0) == .success
        if !observedWorking {
            AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: firstPhaseWaiterToken)

            var currentState: AgentActivityState?
            var stateReadError: V2CallResult?
            v2MainSync {
                guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                    stateReadError = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                currentState = ws.panelAgentStates[surfaceIdOut]
            }
            if let stateReadError { return stateReadError }

            let neverReportedAnything = baselineState == nil && currentState == nil
            let warning = neverReportedAnything
                ? "No agent_state was ever reported for this surface -- agent hooks may not be installed."
                : nil
            return result(workingObserved: false, finalState: currentState, warning: warning)
        }

        // Step 3: observed working -- wait (remaining overall timeout budget) for idle. Resolves
        // the same atomic check+register pattern again, since the transition to idle could in
        // principle have already happened between the working-signal firing and this hop.
        var idleWaiterToken: UUID?
        var idleSetupError: V2CallResult?
        v2MainSync {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                idleSetupError = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let currentState = ws.panelAgentStates[surfaceIdOut]
            if AgentStateWaitCondition.idle.isSatisfied(by: currentState) {
                resolvedState = currentState
            } else {
                idleWaiterToken = AgentStateWaitRegistry.shared.addWaiter(surfaceId: surfaceIdOut, condition: .idle) { state, _ in
                    resolvedState = state
                    idleSemaphore.signal()
                }
            }
        }
        if let idleSetupError { return idleSetupError }

        if let idleWaiterToken {
            let remaining = totalDeadline.timeIntervalSinceNow
            guard remaining > 0, idleSemaphore.wait(timeout: .now() + max(0, remaining)) == .success else {
                AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: idleWaiterToken)
                return .err(
                    code: "timeout",
                    message: "Agent started working but did not return to idle before timeout",
                    data: ["timeout_ms": totalTimeoutMs]
                )
            }
        }

        return result(workingObserved: true, finalState: resolvedState)
    }
}
