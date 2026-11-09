// agent.prompt (#166 task 3): submit a prompt to an agent surface and wait for it to finish, in
// one request. Built directly on top of surface.wait's agent_state condition (task 2) and
// surface.send_text's injection path -- see docs/socket-api.md "agent.prompt (#166)" for
// the full semantics this implements.
//
// Semantics (documented, not just implied by the code -- keep the doc in sync with this file):
//   0. Hold for a person's draft (INC-687). If a person has unsent typed input in the surface,
//      nothing is sent yet. The connection's thread re-reads the draft every 100 ms within
//      `timeout_ms`; if the budget runs out while the person is still drafting, the call fails
//      with `draft_in_progress` and nothing was ever sent. Once the draft ends (submitted,
//      cleared, or idle for 60 s), a settle step lets a turn the person's own submit started
//      go first: wait up to min(`working_grace_ms`, 1500 ms) for `working`; if it is seen,
//      wait for `idle` within the remaining budget (budget out: `draft_in_progress`, nothing
//      sent). Then ONE main-thread hop re-reads the draft -- drafting again goes back to the
//      hold -- and runs step 1 in that same hop. The result gains `held_ms` (time held, settle
//      excluded) and `settle_ms`. `force: true` skips step 0.
//   1. Send the prompt text (+ Enter) using the exact same injection path `surface.send_text`
//      uses, and -- inside that SAME main-thread hop -- capture the surface's agent_state at
//      that instant and register a watcher for the next "working" transition. This closes the
//      race where a hook reacts to the injected text before a separately-registered watcher
//      would exist (same atomic check+register pattern as surface.wait).
//   2. Grace window (`working_grace_ms`, default 3000), capped by the remaining overall
//      `timeout_ms` budget: wait for the "working" transition.
//      - If observed, proceed to step 3.
//      - If the grace window or overall deadline elapses without ever seeing "working", there is
//        nothing further useful to wait for -- resolve immediately using whatever the surface's
//        agent_state already is (`working_observed: false`). This is deliberately not a hard
//        error: a prompt can finish faster than the grace window, or the hook simply may not fire
//        for a trivial prompt. If the surface never reported ANY agent_state at all (neither
//        before sending nor during the grace window), the response carries a `warning` field
//        instead of silently succeeding, since that combination usually means agent hooks were
//        never installed for this surface.
//   3. Once "working" is observed, wait (for the remaining overall `timeout_ms` budget) for the
//      surface's agent_state to reach "idle" (or clear entirely -- see surface.wait's no-state
//      rule) and resolve with `working_observed: true`.
//   4. If step 3's wait exceeds the overall timeout, the call fails with `timeout` -- the agent
//      started working but never finished within the requested budget. `timeout` always means
//      the prompt was sent; `draft_in_progress` always means it was not.
import Foundation

extension TerminalController {
    /// How often a held `agent.prompt` re-reads the person's draft (header step 0).
    private nonisolated static let agentPromptHoldPollInterval: TimeInterval = 0.1
    /// Upper bound on the settle step's wait for `working` after a draft ends (header step 0).
    private nonisolated static let agentPromptSettleGraceCapMs = 1_500

    /// `agent.prompt`: send `text` to an agent surface and block (single request/response) until
    /// the agent finishes, per the phased semantics documented on this file and in
    /// docs/socket-api.md.
    nonisolated func v2AgentPrompt(params: [String: Any]) -> V2CallResult {
        let tabManagerAvailable = v2MainSync { self.v2ResolveTabManager(params: params) != nil }
        guard tabManagerAvailable else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let rawText = params["text"] as? String, !rawText.isEmpty else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        let requestedTimeoutMs = v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 120_000
        let totalTimeoutMs = min(Self.watchedWaitMaxTimeoutMs, max(1, requestedTimeoutMs))
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
        var queued = false
        // Token for whichever watcher got registered inside the send+register hop:
        // the "working" watcher in the normal case, or an "idle" watcher directly when the
        // surface was already mid-task (`alreadyWorkingAtSendTime`) and there is nothing to
        // grace-wait for.
        var firstPhaseWaiterToken: UUID?
        // Written once from a registry callback (main thread) before it signals the matching
        // semaphore -- safe to read after `semaphore.wait` returns `.success` without an extra
        // lock, same reasoning as surface.wait's exit/agent_state branches.
        var resolvedState: AgentActivityState?
        // Set when a person's draft held the prompt in the first hop (header step 0).
        var heldSince: Date?
        var heldMs: Int?
        var settleMs: Int?

        // Header step 1. Call only inside a `v2MainSync` hop: the send and the watcher
        // registration must share one hop, whichever hop ends up delivering.
        @MainActor func deliverAndRegister(ws: Workspace, surfaceId: UUID, terminalPanel: TerminalPanel) {
            workspaceId = ws.id
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
                queued = true
            }
            self.v2NoteSocketSubmit(text: textToSend, terminalPanel: terminalPanel)

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

        v2MainSync {
            guard let tabManager = self.v2ResolveTabManager(params: params) else {
                setupError = .err(code: "unavailable", message: "TabManager not available", data: nil)
                return
            }
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
            if self.v2DraftGuardRejection(params: params, surfaceId: surfaceId, terminalPanel: terminalPanel) != nil {
                heldSince = Date()
                return
            }
            deliverAndRegister(ws: ws, surfaceId: surfaceId, terminalPanel: terminalPanel)
        }

        if let setupError { return setupError }
        guard let surfaceIdOut, workspaceId != nil else {
            return .err(code: "internal_error", message: "Failed to resolve surface", data: nil)
        }

        func result(workingObserved: Bool, finalState: AgentActivityState?, warning: String? = nil, closed: Bool = false) -> V2CallResult {
            var payload: [String: Any] = [
                "workspace_id": self.v2OrNull(workspaceId?.uuidString),
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
            // The surface was not attached: the prompt went to the pending queue.
            if queued { payload["queued"] = true }
            if closed { payload["outcome"] = "closed" }
            if let heldMs { payload["held_ms"] = heldMs }
            if let settleMs { payload["settle_ms"] = settleMs }
            return .ok(payload)
        }

        if let heldSince {
            switch v2AgentPromptHold(
                heldSince: heldSince,
                surfaceId: surfaceIdOut,
                params: params,
                deadline: totalDeadline,
                timeoutMs: totalTimeoutMs,
                settleGraceMs: min(workingGraceMs, Self.agentPromptSettleGraceCapMs),
                deliver: { ws, panel in
                    windowId = AppDelegate.shared?.locateSurface(surfaceId: surfaceIdOut)?.windowId ?? windowId
                    deliverAndRegister(ws: ws, surfaceId: surfaceIdOut, terminalPanel: panel)
                }
            ) {
            case .delivered(let held, let settle):
                heldMs = held
                settleMs = settle
            case .closed(let held, let settle):
                heldMs = held
                settleMs = settle
                return result(workingObserved: false, finalState: nil, closed: true)
            case .failed(let error):
                return error
            }
        }

        guard let deliveredWorkspaceId = workspaceId, let firstPhaseWaiterToken else {
            return .err(code: "internal_error", message: "Failed to resolve surface", data: nil)
        }

        if alreadyWorkingAtSendTime {
            // Already mid-task when we sent -- nothing to grace-wait for; go straight to
            // watching for idle, per file header step 1's "already working" branch.
            let outcome = v2WatchedWait(idleSemaphore, until: totalDeadline, surfaceId: surfaceIdOut)
            guard case .signaled = outcome else {
                AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: firstPhaseWaiterToken)
                if case .surfaceClosed = outcome { return result(workingObserved: true, finalState: nil, closed: true) }
                if case .clientGone = outcome { return v2ClientGoneError }
                return .err(
                    code: "timeout",
                    message: "Agent (already working when the prompt was sent) did not return to idle before timeout",
                    data: ["timeout_ms": totalTimeoutMs]
                )
            }
            return result(workingObserved: true, finalState: resolvedState)
        }

        // Step 2: grace window for a "working" transition.
        let remaining = max(0, totalDeadline.timeIntervalSinceNow)
        let graceWait = min(Double(workingGraceMs) / 1000.0, remaining)
        let graceOutcome = v2WatchedWait(workingSemaphore, until: Date().addingTimeInterval(graceWait), surfaceId: surfaceIdOut)
        if case .surfaceClosed = graceOutcome {
            AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: firstPhaseWaiterToken)
            return result(workingObserved: false, finalState: nil, closed: true)
        }
        if case .clientGone = graceOutcome {
            AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: firstPhaseWaiterToken)
            return v2ClientGoneError
        }
        let observedWorking: Bool = { if case .signaled = graceOutcome { return true }; return false }()
        if !observedWorking {
            AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: firstPhaseWaiterToken)

            var currentState: AgentActivityState?
            var stateReadError: V2CallResult?
            v2MainSync {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: deliveredWorkspaceId) ?? self.tabManager,
                      let ws = tabManager.tabs.first(where: { $0.id == deliveredWorkspaceId }) else {
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
            guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: deliveredWorkspaceId) ?? self.tabManager,
                  let ws = tabManager.tabs.first(where: { $0.id == deliveredWorkspaceId }) else {
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
            let outcome = v2WatchedWait(idleSemaphore, until: totalDeadline, surfaceId: surfaceIdOut)
            guard case .signaled = outcome else {
                AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceIdOut, token: idleWaiterToken)
                if case .surfaceClosed = outcome { return result(workingObserved: true, finalState: nil, closed: true) }
                if case .clientGone = outcome { return v2ClientGoneError }
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

/// How a held `agent.prompt` ended (file header step 0).
private enum AgentPromptHoldOutcome {
    /// Sent in the hop that read the draft as released. Times are milliseconds.
    case delivered(heldMs: Int, settleMs: Int)
    /// The surface closed while held; nothing was sent.
    case closed(heldMs: Int, settleMs: Int)
    /// Return this response; nothing was sent.
    case failed(TerminalController.V2CallResult)
}

extension TerminalController {
    /// File header step 0. Runs on the connection's thread: waits while a person's draft holds
    /// the prompt, settles once it ends, then calls `deliver` inside the main hop that last read
    /// the draft as released, so that read and the send cannot be split by a keystroke.
    private nonisolated func v2AgentPromptHold(
        heldSince: Date,
        surfaceId: UUID,
        params: [String: Any],
        deadline: Date,
        timeoutMs: Int,
        settleGraceMs: Int,
        deliver: @MainActor (Workspace, TerminalPanel) -> Void
    ) -> AgentPromptHoldOutcome {
        // Never signalled: `v2WatchedWait` on it is a sleep that still notices a closed surface
        // or a disconnected client.
        let pollSemaphore = DispatchSemaphore(value: 0)
        var heldTotal: TimeInterval = 0
        var settleTotal: TimeInterval = 0
        var holdStart = heldSince
        // Non-nil while settling: when the draft was read as released.
        var releasedAt: Date?

        func ms(_ seconds: TimeInterval) -> Int { max(0, Int((seconds * 1000).rounded())) }
        func heldMsNow() -> Int { ms(heldTotal + (releasedAt == nil ? Date().timeIntervalSince(holdStart) : 0)) }
        func settleMsNow() -> Int { ms(settleTotal + (releasedAt.map { Date().timeIntervalSince($0) } ?? 0)) }
        func closed() -> AgentPromptHoldOutcome { .closed(heldMs: heldMsNow(), settleMs: settleMsNow()) }
        func notSent(_ reason: String, settling: Bool) -> AgentPromptHoldOutcome {
            let surfaceRef = (v2Ref(kind: .surface, uuid: surfaceId) as? String) ?? surfaceId.uuidString
            var data: [String: Any] = [
                "held_ms": heldMsNow(),
                "timeout_ms": timeoutMs,
                "surface_id": surfaceId.uuidString,
                "surface_ref": surfaceRef
            ]
            if settling { data["settle_ms"] = settleMsNow() }
            return .failed(.err(code: "draft_in_progress", message: "\(surfaceRef) \(reason); nothing was sent", data: data))
        }
        func watched(_ semaphore: DispatchSemaphore, until end: Date, token: UUID?) -> V2WatchedWaitOutcome {
            let outcome = v2WatchedWait(semaphore, until: end, surfaceId: surfaceId)
            let signaled: Bool = { if case .signaled = outcome { return true }; return false }()
            if let token, !signaled {
                AgentStateWaitRegistry.shared.removeWaiter(surfaceId: surfaceId, token: token)
            }
            return outcome
        }

        while true {
            // Hold: re-read the draft until it stops holding or the budget runs out.
            while releasedAt == nil {
                let sliceEnd = min(deadline, Date().addingTimeInterval(Self.agentPromptHoldPollInterval))
                switch watched(pollSemaphore, until: sliceEnd, token: nil) {
                case .surfaceClosed: return closed()
                case .clientGone: return .failed(v2ClientGoneError)
                case .signaled, .timedOut: break
                }
                var gone = false
                var holding = false
                v2MainSync {
                    guard let panel = self.v2WorkspaceContaining(surfaceId: surfaceId)?.panels[surfaceId] as? TerminalPanel else {
                        gone = true
                        return
                    }
                    holding = self.v2DraftGuardRejection(params: params, surfaceId: surfaceId, terminalPanel: panel) != nil
                }
                if gone { return closed() }
                if !holding {
                    let now = Date()
                    heldTotal += now.timeIntervalSince(holdStart)
                    releasedAt = now
                } else if Date() >= deadline {
                    return notSent("has unsent typed input", settling: false)
                }
            }

            // Settle: a `working` report now belongs to the turn the person's own submit started.
            // Same atomic check+register as the delivery phases; fresh semaphores per pass, since
            // a removed waiter's callback can still be in flight.
            let graceEnd = min(deadline, Date().addingTimeInterval(Double(settleGraceMs) / 1000.0))
            let settleWorking = DispatchSemaphore(value: 0)
            let settleIdle = DispatchSemaphore(value: 0)
            var gone = false
            var sawWorking = false
            var workingToken: UUID?
            v2MainSync {
                guard let ws = self.v2WorkspaceContaining(surfaceId: surfaceId) else {
                    gone = true
                    return
                }
                if AgentStateWaitCondition.working.isSatisfied(by: ws.panelAgentStates[surfaceId]) {
                    sawWorking = true
                } else if graceEnd > Date() {
                    workingToken = AgentStateWaitRegistry.shared.addWaiter(surfaceId: surfaceId, condition: .working) { _, _ in
                        settleWorking.signal()
                    }
                }
            }
            if gone { return closed() }
            if let workingToken {
                switch watched(settleWorking, until: graceEnd, token: workingToken) {
                case .signaled: sawWorking = true
                case .timedOut: break
                case .surfaceClosed: return closed()
                case .clientGone: return .failed(v2ClientGoneError)
                }
            }
            if sawWorking {
                var idleToken: UUID?
                v2MainSync {
                    guard let ws = self.v2WorkspaceContaining(surfaceId: surfaceId) else {
                        gone = true
                        return
                    }
                    if !AgentStateWaitCondition.idle.isSatisfied(by: ws.panelAgentStates[surfaceId]) {
                        idleToken = AgentStateWaitRegistry.shared.addWaiter(surfaceId: surfaceId, condition: .idle) { _, _ in
                            settleIdle.signal()
                        }
                    }
                }
                if gone { return closed() }
                if let idleToken {
                    switch watched(settleIdle, until: deadline, token: idleToken) {
                    case .signaled: break
                    case .timedOut: return notSent("is still running the turn the person submitted", settling: true)
                    case .surfaceClosed: return closed()
                    case .clientGone: return .failed(v2ClientGoneError)
                    }
                }
            }

            // Deliver, unless the person started typing again during the settle.
            var delivered = false
            var outOfTime = false
            v2MainSync {
                guard let ws = self.v2WorkspaceContaining(surfaceId: surfaceId),
                      let panel = ws.panels[surfaceId] as? TerminalPanel else {
                    gone = true
                    return
                }
                let now = Date()
                // The settle grace is capped at the deadline, so it can end exactly there; a send now
                // would leave no budget for observing the prompt's own turn. Checked before releasedAt
                // is cleared so the error's held_ms/settle_ms split stays right.
                if now >= deadline {
                    outOfTime = true
                    return
                }
                if let releasedAt { settleTotal += now.timeIntervalSince(releasedAt) }
                releasedAt = nil
                if self.v2DraftGuardRejection(params: params, surfaceId: surfaceId, terminalPanel: panel) != nil {
                    holdStart = now
                    return
                }
                deliver(ws, panel)
                delivered = true
            }
            if gone { return closed() }
            if outOfTime { return notSent("released its draft too close to the timeout", settling: true) }
            if delivered { return .delivered(heldMs: ms(heldTotal), settleMs: ms(settleTotal)) }
        }
    }
}
