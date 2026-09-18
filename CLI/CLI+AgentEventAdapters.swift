import Foundation

/// Provider adapters that translate Claude Code, Codex, and OpenCode hook events into
/// normalized `agent.event` socket calls. Split out of CLI+Hooks.swift (which owns the
/// per-provider hook dispatch and stays under its structural line budget) so the two can
/// grow independently; call sites live in CLI+Hooks.swift.
extension ProgramaCLI {
    /// Reports a normalized `agent.event` (docs/plans/agent-events.md) alongside the
    /// existing three-state `surface.report_agent_state` calls in CLI+Hooks.swift -- additive,
    /// not a replacement. Best-effort like `reportAgentState`/`clearAgentState`: a hook must
    /// never fail the user's tool call because programa's socket is unreachable.
    ///
    /// Was `private` in CLI+Hooks.swift; now internal (no access modifier) so the hook
    /// handlers there can still call it across files.
    func reportAgentEvent(
        client: SocketClient,
        provider: String,
        eventType: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String? = nil,
        pid: Int? = nil
    ) {
        var params: [String: Any] = [
            "provider": provider,
            "event_type": eventType,
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
        ]
        if let sessionId, !sessionId.isEmpty {
            params["session_id"] = sessionId
        }
        if let pid {
            params["pid"] = pid
        }
        _ = try? client.sendV2(method: "agent.event", params: params)
    }

    /// Reports a surface's agent activity state, then a matching `agent.event`, in that
    /// order, with the same workspace/surface ids -- combines the two adjacent calls that
    /// used to sit back-to-back at each hook call site in CLI+Hooks.swift. Same two socket
    /// sends, same order, same arguments as before; purely a call-site collapse.
    func reportAgentStateAndEvent(
        client: SocketClient,
        provider: String,
        eventType: String,
        workspaceId: String,
        surfaceId: String,
        state: CLIAgentActivityState,
        sessionId: String? = nil,
        pid: Int? = nil
    ) {
        reportAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId, state: state, provider: provider, sessionId: sessionId, pid: pid)
        reportAgentEvent(client: client, provider: provider, eventType: eventType, workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId, pid: pid)
    }

    /// Sends `agent.needs_input` (docs/plans/agent-state-unification.md T2): one atomic
    /// socket call replacing the `notification.create_for_target` +
    /// `workspace.set_status` "Needs input" + `surface.report_agent_state` trio a hook
    /// used to send independently for the same "needs input" moment.
    func reportAgentNeedsInput(
        client: SocketClient,
        provider: String,
        workspaceId: String,
        surfaceId: String,
        title: String,
        subtitle: String,
        body: String,
        sessionId: String? = nil,
        pid: Int? = nil,
        kind: String
    ) {
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "surface_id": surfaceId,
            "provider": provider,
            "title": title,
            "subtitle": subtitle,
            "body": body,
            "kind": kind,
        ]
        if let sessionId, !sessionId.isEmpty { params["session_id"] = sessionId }
        if let pid { params["pid"] = pid }
        _ = try? client.sendV2(method: "agent.needs_input", params: params)
    }

    /// Clears a surface's reported agent activity state, then reports a matching
    /// `agent.event`, in that order, with the same workspace/surface ids -- combines the
    /// two adjacent calls that used to sit back-to-back at each session-end call site in
    /// CLI+Hooks.swift. Same two socket sends, same order, same arguments as before.
    func clearAgentStateAndReportEvent(
        client: SocketClient,
        provider: String,
        eventType: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String? = nil
    ) {
        clearAgentState(client: client, workspaceId: workspaceId, surfaceId: surfaceId)
        reportAgentEvent(client: client, provider: provider, eventType: eventType, workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
    }

    /// Maps a classified notification subtitle ("Permission" / "Waiting") to the matching
    /// `agent.event` type. Mirrors the `switch summary.subtitle` blocks that used to sit
    /// inline at the Claude Code and Codex notification-hook call sites in CLI+Hooks.swift.
    func reportAgentEventForClassifiedNotificationSubtitle(
        client: SocketClient,
        provider: String,
        subtitle: String,
        workspaceId: String,
        surfaceId: String,
        sessionId: String?
    ) {
        switch subtitle {
        case "Permission":
            reportAgentEvent(client: client, provider: provider, eventType: "request.opened", workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
        case "Waiting":
            reportAgentEvent(client: client, provider: provider, eventType: "user-input.requested", workspaceId: workspaceId, surfaceId: surfaceId, sessionId: sessionId)
        default:
            break
        }
    }
}
