// Extracted from TerminalController.swift (nuclear-review #96): off-main-parse + main.async-mutate telemetry commands (surface.report_*/ports_kick, workspace.set_status/log/progress/sidebar metadata).
import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit
import WebKit

extension TerminalController {
    // MARK: - V2 Telemetry Scheduling (off-main parse, main.async mutate)
    //
    // Mirrors the socket command threading policy (see CLAUDE.md "Socket command threading
    // policy"): high-frequency telemetry commands (report_*/ports/log/progress/status) must not
    // block their calling thread with `DispatchQueue.main.sync`. These helpers resolve the
    // workspace/surface the same way the v1 explicit-scope fast paths do (`AppDelegate.shared?
    // .tabManagerFor(tabId:)` + linear tab lookup) but dispatch the mutation asynchronously and
    // return an optimistic `ok` result immediately, matching v1's fire-and-forget "OK" semantics.
    private nonisolated func v2ScheduleTelemetryMutation(
        workspaceId: UUID,
        _ mutation: @escaping @MainActor @Sendable (TabManager, Workspace) -> Void
    ) {
        DispatchQueue.main.async { @MainActor [weak self] in
            // Prefer explicit window-routed lookup (mirrors `v2ResolveTabManager`), but fall
            // back to `self.tabManager` — the TabManager registered via `start(tabManager:)`.
            // Without this fallback, a workspace that only exists in the TabManager passed to
            // `start()` (single-window callers, and unit tests that construct a bare
            // `TabManager` without registering it with `AppDelegate`) is invisible to this
            // async hop: `AppDelegate.shared?.tabManagerFor(tabId:)` returns nil and the
            // mutation silently no-ops, losing the fire-and-forget telemetry write.
            guard let resolvedTabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId) ?? self?.tabManager,
                  let tab = resolvedTabManager.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            mutation(resolvedTabManager, tab)
        }
    }

    private nonisolated func v2ScheduleSurfaceTelemetryMutation(
        workspaceId: UUID,
        surfaceId: UUID,
        _ mutation: @escaping @MainActor @Sendable (TabManager, Workspace, UUID) -> Void
    ) {
        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { tabManager, tab in
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tabManager, tab, surfaceId)
        }
    }
    nonisolated func v2SurfaceReportTTY(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        let requestedSurfaceId = v2CachedUUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return v2InvalidParam("surface_id")
        }
        guard let ttyName = v2RawString(params, "tty_name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing tty_name", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(ttyName) <= SidebarTelemetryLimits.maxTTYNameBytes else {
            return .err(
                code: "invalid_params",
                message: "tty_name exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxTTYNameBytes) bytes",
                data: nil
            )
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId = self.resolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceId,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else { return }

            guard tab.setSidebarTTYName(panelId: surfaceId, ttyName: ttyName) else { return }
            PortScanner.shared.registerTTY(workspaceId: workspaceId, panelId: surfaceId, ttyName: ttyName)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
            "tty_name": ttyName,
        ])
    }

    nonisolated func v2SurfacePortsKick(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        let requestedSurfaceId = v2CachedUUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return v2InvalidParam("surface_id")
        }
        guard let reason = Self.normalizedPortScanKickReason(v2RawString(params, "reason") ?? "command") else {
            return .err(
                code: "invalid_params",
                message: "reason must be command or refresh",
                data: nil
            )
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId = self.resolveReportedSurfaceId(
                in: tab,
                requestedSurfaceId: requestedSurfaceId,
                validSurfaceIds: validSurfaceIds
            )
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else { return }

            PortScanner.shared.kick(workspaceId: workspaceId, panelId: surfaceId)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
            "reason": reason,
        ])
    }

    // MARK: - V2 Surface Telemetry (report_*/ports/git/pr) — off-main parse, main.async mutate.
    //
    // These adapt what were v1's explicit-scope ("shell integration always includes explicit
    // workspace/panel IDs") fast paths (report_pwd/report_shell_state/report_git_branch/
    // clear_git_branch/report_pr/clear_pr/report_ports/clear_ports — removed along with the
    // rest of the v1 protocol; see docs/v2-api-migration.md) to the v2 handle-based protocol.
    // v2 always requires explicit workspace_id + surface_id (no implicit "selected tab"
    // fallback), so they always take the async fast path v1 took when both --tab and --panel
    // were supplied explicitly.

    nonisolated func v2SurfaceReportPwd(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let path = v2RawString(params, "path")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(path) <= SidebarTelemetryLimits.maxDirectoryBytes else {
            return .err(
                code: "invalid_params",
                message: "path exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxDirectoryBytes) bytes",
                data: nil
            )
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            tabManager.updateSurfaceDirectory(tabId: workspaceId, surfaceId: sid, directory: path)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "path": path,
        ])
    }

    nonisolated func v2SurfaceReportShellState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let rawState = v2RawString(params, "state"),
              let state = Self.parseReportedShellActivityState(rawState) else {
            return .err(code: "invalid_params", message: "Invalid shell state — expected prompt or running", data: nil)
        }

        let baseResult: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "state": rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ]

        // Fast-path dedup check, mirroring v1's reportShellState: skip dispatch if we
        // already know this state is current. Only READ here; recording happens after
        // the update is confirmed applied on the main thread (see recordShellActivity below).
        guard Self.socketFastPathState.shouldPublishShellActivity(
            workspaceId: workspaceId,
            panelId: surfaceId,
            state: state
        ) else {
            var deduped = baseResult
            deduped["deduped"] = true
            return .ok(deduped)
        }

        let fastPathState = Self.socketFastPathState
        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            let applied = tabManager.updateSurfaceShellActivity(tabId: workspaceId, surfaceId: sid, state: state)
            // Only record in the dedup dict when the update actually applied (panel was
            // registered); otherwise the next identical report must not be suppressed.
            if applied {
                fastPathState.recordShellActivity(workspaceId: workspaceId, panelId: sid, state: state)
            }
        }

        return .ok(baseResult)
    }

    nonisolated func v2SurfaceReportGitBranch(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let branch = v2RawString(params, "branch")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else {
            return .err(code: "invalid_params", message: "Missing branch", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(branch) <= SidebarTelemetryLimits.maxGitBranchBytes else {
            return .err(
                code: "invalid_params",
                message: "branch exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxGitBranchBytes) bytes",
                data: nil
            )
        }
        let isDirty = v2Bool(params, "dirty") ?? false

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            tabManager.updateSurfaceGitBranch(tabId: workspaceId, surfaceId: sid, branch: branch, isDirty: isDirty)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "branch": branch,
            "dirty": isDirty,
        ])
    }

    nonisolated func v2SurfaceClearGitBranch(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            tabManager.clearSurfaceGitBranch(tabId: workspaceId, surfaceId: sid)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    /// Reports a lifecycle-hook-driven agent activity state for a surface (issue #164, v1
    /// hook tier). Called exclusively by the shipped Claude Code/Codex/OpenCode hook
    /// wrappers (CLI+Hooks.swift) — there is no heuristic/screen-rule fallback in this tier.
    nonisolated func v2SurfaceReportAgentState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let rawState = v2RawString(params, "state"),
              let state = AgentActivityState(rawValue: rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .err(code: "invalid_params", message: "Invalid state — use: working, blocked, idle", data: nil)
        }
        // Callers (the shipped hook wrappers) never pass this -- it defaults to `.hooks`, which
        // is what makes hook reports authoritative over the screen-manifest engine's `.inferred`
        // writes (see Workspace.updatePanelAgentState). Accepting it explicitly here (rather than
        // hardcoding `.hooks`) keeps the wire symmetric with the `source` sibling field this
        // response now echoes.
        let source: AgentStateSource
        if let rawSource = v2RawString(params, "source") {
            guard let parsedSource = AgentStateSource(rawValue: rawSource.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                return .err(code: "invalid_params", message: "Invalid source — use: hooks, inferred", data: nil)
            }
            source = parsedSource
        } else {
            source = .hooks
        }

        // Optional session/pid identity, additive per docs/plans/agent-state-unification.md T2:
        // older CLI builds omit these and get `sessionKey == nil`, unchanged from today.
        let provider = v2RawString(params, "provider")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = v2RawString(params, "session_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedPid: pid_t?
        if v2HasNonNullParam(params, "pid") {
            guard let rawPid = v2Int(params, "pid"), (1...Int(pid_t.max)).contains(rawPid) else {
                return .err(code: "invalid_params", message: "pid must be an integer from 1 through \(Int(pid_t.max))", data: nil)
            }
            reportedPid = pid_t(rawPid)
        } else {
            reportedPid = nil
        }
        let sessionKey: AgentSessionKey? = (sessionId != nil || reportedPid != nil)
            ? AgentSessionKey(provider: provider ?? "unknown", sessionId: sessionId, pid: reportedPid)
            : nil

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { [weak self] tabManager, tab, sid in
            tabManager.updateSurfaceAgentState(tabId: workspaceId, surfaceId: sid, state: state, source: source, sessionKey: sessionKey)
            let taskState: AgentTaskState
            switch state {
            case .idle: taskState = .idle
            case .working: taskState = .working
            case .blocked: taskState = .blocked
            }
            _ = try? AgentSupervisionRegistry.shared.updateActiveSurface(
                workspaceId: workspaceId,
                surfaceId: sid,
                state: taskState
            )
            if let reportedPid, let provider, let pidKey = Self.agentPIDKey(forProvider: provider) {
                if tab.setSidebarAgentPID(key: pidKey, pid: reportedPid) {
                    self?.refreshTrackedAgentPorts(for: tab)
                }
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "state": state.rawValue,
            "source": source.rawValue,
        ])
    }

    /// Maps a hook-reported `provider` string to the flat status/PID key
    /// `workspace.set_agent_pid` already uses for that provider (CLI/CLI+Hooks.swift's
    /// `setClaudeStatus`/`setCodexStatus`/`setOpenCodeStatus` keys), so `agent.needs_input`
    /// and `surface.report_agent_state` can register liveness/port-scanning PIDs without a
    /// second round trip. Unknown providers are skipped -- there is no key to write to.
    private static func agentPIDKey(forProvider provider: String) -> String? {
        switch provider {
        case "claude-code": return "claude_code"
        case "codex": return "codex"
        case "opencode": return "opencode"
        default: return nil
        }
    }

    /// Normalized agent lifecycle event (docs/plans/agent-events.md, "Wire path").
    /// Classification happens purely on `event_type` (`AgentEventNormalizer.classify`);
    /// `provider`/`session_id`/`turn_id`/`item_id`/`label`/`resolution` are accepted and
    /// echoed but never used for classification. Reports flow through the same
    /// `source: .hooks` path as `v2SurfaceReportAgentState`, so a structured event always
    /// beats the screen-manifest engine's `.inferred` writes.
    nonisolated func v2AgentEvent(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let rawEventType = v2RawString(params, "event_type")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEventType.isEmpty,
              let outcome = AgentEventNormalizer.classify(eventType: rawEventType) else {
            return .err(
                code: "invalid_params",
                message: "Invalid event_type — use: session.started, session.exited, turn.started, turn.completed, turn.aborted, request.opened, request.resolved, user-input.requested, user-input.resolved, item.started, item.completed",
                data: nil
            )
        }
        let eventType = rawEventType.lowercased()

        // Optional session/pid identity, additive per docs/plans/agent-state-unification.md T2:
        // older CLI builds omit these and get `sessionKey == nil`, unchanged from today.
        let provider = v2RawString(params, "provider")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = v2RawString(params, "session_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedPid: pid_t?
        if v2HasNonNullParam(params, "pid") {
            guard let rawPid = v2Int(params, "pid"), (1...Int(pid_t.max)).contains(rawPid) else {
                return .err(code: "invalid_params", message: "pid must be an integer from 1 through \(Int(pid_t.max))", data: nil)
            }
            reportedPid = pid_t(rawPid)
        } else {
            reportedPid = nil
        }
        let sessionKey: AgentSessionKey? = (sessionId != nil || reportedPid != nil)
            ? AgentSessionKey(provider: provider ?? "unknown", sessionId: sessionId, pid: reportedPid)
            : nil

        var response: [String: Any] = [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "event_type": eventType,
        ]

        switch outcome {
        case .applyState(let state):
            v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { [weak self] tabManager, tab, sid in
                tabManager.updateSurfaceAgentState(tabId: workspaceId, surfaceId: sid, state: state, source: .hooks, sessionKey: sessionKey)
                let taskState: AgentTaskState
                switch state {
                case .idle: taskState = .idle
                case .working: taskState = .working
                case .blocked: taskState = .blocked
                }
                _ = try? AgentSupervisionRegistry.shared.updateActiveSurface(
                    workspaceId: workspaceId,
                    surfaceId: sid,
                    state: taskState
                )
                if let reportedPid, let provider, let pidKey = Self.agentPIDKey(forProvider: provider) {
                    if tab.setSidebarAgentPID(key: pidKey, pid: reportedPid) {
                        self?.refreshTrackedAgentPorts(for: tab)
                    }
                }
            }
            response["state"] = state.rawValue
            response["source"] = AgentStateSource.hooks.rawValue

        case .clearState:
            v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
                tabManager.clearSurfaceAgentState(tabId: workspaceId, surfaceId: sid)
                _ = try? AgentSupervisionRegistry.shared.finishActiveSurface(
                    workspaceId: workspaceId,
                    surfaceId: sid
                )
            }
        }

        return .ok(response)
    }

    /// Atomically reports a surface as blocked on user input and posts the matching
    /// notification (docs/plans/agent-state-unification.md T2): replaces the three
    /// independent socket calls (`notification.create_for_target` +
    /// `workspace.set_status` "Needs input" + `surface.report_agent_state`) a hook used to
    /// make for the same "needs input" moment, any one of which could fail alone. Parses
    /// and validates off-main; hops to main once via `v2ScheduleSurfaceTelemetryMutation`
    /// (notification creation must run on main -- it drives AppKit) and performs the state
    /// write, notification, and supervision update in that single hop.
    nonisolated func v2AgentNeedsInput(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        let rawProvider = v2RawString(params, "provider")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = (rawProvider?.isEmpty == false) ? rawProvider! : "unknown"
        let title = (params["title"] as? String) ?? ""
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""
        let rawSessionId = v2RawString(params, "session_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionId = (rawSessionId?.isEmpty == false) ? rawSessionId : nil

        let reportedPid: pid_t?
        if v2HasNonNullParam(params, "pid") {
            guard let rawPid = v2Int(params, "pid"), (1...Int(pid_t.max)).contains(rawPid) else {
                return .err(code: "invalid_params", message: "pid must be an integer from 1 through \(Int(pid_t.max))", data: nil)
            }
            reportedPid = pid_t(rawPid)
        } else {
            reportedPid = nil
        }

        var kind: String?
        if v2HasNonNullParam(params, "kind") {
            guard let rawKind = v2RawString(params, "kind"),
                  ["permission", "question"].contains(rawKind) else {
                return .err(code: "invalid_params", message: "kind must be permission or question", data: nil)
            }
            kind = rawKind
        }

        let sessionKey = AgentSessionKey(provider: provider, sessionId: sessionId, pid: reportedPid)

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { [weak self] tabManager, tab, sid in
            tabManager.updateSurfaceAgentState(tabId: workspaceId, surfaceId: sid, state: .blocked, source: .hooks, sessionKey: sessionKey)

            let resolvedTitle = TerminalController.v2ResolveNotificationTitle(title: title, workspace: tab, surfaceId: sid)
            TerminalNotificationStore.shared.addNotification(
                tabId: tab.id,
                surfaceId: sid,
                title: resolvedTitle,
                subtitle: subtitle,
                body: body
            )

            _ = try? AgentSupervisionRegistry.shared.updateActiveSurface(
                workspaceId: workspaceId,
                surfaceId: sid,
                state: .blocked
            )

            if let reportedPid, let pidKey = Self.agentPIDKey(forProvider: provider) {
                if tab.setSidebarAgentPID(key: pidKey, pid: reportedPid) {
                    self?.refreshTrackedAgentPorts(for: tab)
                }
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "state": AgentActivityState.blocked.rawValue,
            "source": AgentStateSource.hooks.rawValue,
            "kind": v2OrNull(kind),
        ])
    }

    nonisolated func v2SurfaceClearAgentState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            tabManager.clearSurfaceAgentState(tabId: workspaceId, surfaceId: sid)
            _ = try? AgentSupervisionRegistry.shared.finishActiveSurface(
                workspaceId: workspaceId,
                surfaceId: sid
            )
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    nonisolated func v2SurfaceReportPullRequest(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let number = v2Int(params, "number"), number > 0 else {
            return v2InvalidParam("number")
        }
        guard let rawURL = v2RawString(params, "url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return v2InvalidParam("url")
        }
        guard SidebarTelemetryLimits.utf8ByteCount(url.absoluteString) <= SidebarTelemetryLimits.maxPullRequestURLBytes else {
            return .err(
                code: "invalid_params",
                message: "url exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxPullRequestURLBytes) bytes",
                data: nil
            )
        }
        let statusRaw = (v2String(params, "state") ?? "open").lowercased()
        guard let status = SidebarPullRequestStatus(rawValue: statusRaw) else {
            return .err(code: "invalid_params", message: "Invalid state — use: open, merged, closed", data: nil)
        }
        let branch = v2String(params, "branch")
        guard SidebarTelemetryLimits.isWithinUTF8Limit(
            branch,
            maxBytes: SidebarTelemetryLimits.maxGitBranchBytes
        ) else {
            return .err(
                code: "invalid_params",
                message: "branch exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxGitBranchBytes) bytes",
                data: nil
            )
        }

        var checks: SidebarPullRequestChecksStatus?
        if let rawChecks = v2String(params, "checks") {
            guard let parsedChecks = SidebarPullRequestChecksStatus(rawValue: rawChecks.lowercased()) else {
                return .err(code: "invalid_params", message: "Invalid checks — use: pass, fail, pending", data: nil)
            }
            checks = parsedChecks
        }

        let labelRaw = v2String(params, "label") ?? "PR"
        guard !labelRaw.isEmpty else {
            return .err(code: "invalid_params", message: "Invalid label", data: nil)
        }
        let label = String(labelRaw.prefix(16))
        guard SidebarTelemetryLimits.utf8ByteCount(label) <= SidebarTelemetryLimits.maxPullRequestLabelBytes else {
            return .err(
                code: "invalid_params",
                message: "label exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxPullRequestLabelBytes) bytes",
                data: nil
            )
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { [checks] _, tab, sid in
            guard Self.shouldReplacePullRequest(
                current: tab.panelPullRequests[sid],
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch,
                checks: checks
            ) else {
                return
            }
            tab.updatePanelPullRequest(
                panelId: sid,
                number: number,
                label: label,
                url: url,
                status: status,
                branch: branch,
                checks: checks
            )
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "number": number,
            "url": url.absoluteString,
            "label": label,
            "state": status.rawValue,
            "branch": v2OrNull(branch),
            "checks": v2OrNull(checks?.rawValue),
        ])
    }

    nonisolated func v2SurfaceClearPullRequest(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { _, tab, sid in
            tab.clearPanelPullRequest(panelId: sid)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    nonisolated func v2SurfaceReportPorts(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2CachedUUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        if let rawPortValues = params["ports"] as? [Any],
           rawPortValues.count > SidebarTelemetryLimits.maxReportedPorts {
            return .err(
                code: "invalid_params",
                message: "ports exceeds the limit of 65535 entries",
                data: nil
            )
        }
        guard let rawPorts = v2IntArray(params, "ports"), !rawPorts.isEmpty else {
            return v2InvalidParam("ports")
        }
        guard rawPorts.allSatisfy({ $0 > 0 && $0 <= 65535 }) else {
            return .err(code: "invalid_params", message: "Invalid port — must be 1-65535", data: nil)
        }
        let ports = Array(Set(rawPorts)).sorted()

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { _, tab, sid in
            guard tab.surfaceListeningPorts[sid] != ports else { return }
            tab.surfaceListeningPorts[sid] = ports
            tab.recomputeListeningPorts()
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "ports": ports,
        ])
    }

    nonisolated func v2SurfaceClearPorts(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        let requestedSurfaceId = v2CachedUUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return v2InvalidParam("surface_id")
        }

        if let surfaceId = requestedSurfaceId {
            v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { _, tab, sid in
                tab.surfaceListeningPorts.removeValue(forKey: sid)
                tab.recomputeListeningPorts()
            }
        } else {
            // No surface_id means "clear ALL ports for the workspace" — mirrors v1's
            // clearPorts special case when no --panel is supplied.
            v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
                let validSurfaceIds = Set(tab.panels.keys)
                tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
                tab.surfaceListeningPorts.removeAll()
                tab.recomputeListeningPorts()
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
        ])
    }

    @MainActor
    private func resolveReportedSurfaceId(
        in workspace: Workspace,
        requestedSurfaceId: UUID?,
        validSurfaceIds: Set<UUID>
    ) -> UUID? {
        if let requestedSurfaceId {
            guard validSurfaceIds.contains(requestedSurfaceId) else { return nil }
            return requestedSurfaceId
        }

        if let focusedSurfaceId = workspace.focusedPanelId,
           validSurfaceIds.contains(focusedSurfaceId) {
            return focusedSurfaceId
        }

        return nil
    }

    // MARK: - V2 Workspace Sidebar Metadata (set_status/log/progress/sidebar_state)
    //
    // What were v1's set_status/clear_status/list_status/log/clear_log/list_log/set_progress/
    // clear_progress/sidebar_state verbs were workspace(tab)-scoped, not surface-scoped (their
    // v1 handlers resolved a `Tab` via a helper rather than a specific panel — removed along
    // with the rest of the v1 protocol; see docs/v2-api-migration.md). Mutations follow the same
    // off-main-parse + main.async-mutate telemetry policy as the surface.report_* family;
    // reads (list_status/list_log/sidebar_state) are exact-snapshot queries and use the
    // v2MainSync pattern shared by sibling v2 read methods.

    nonisolated func v2WorkspaceSetStatus(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(key) <= SidebarTelemetryLimits.maxKeyBytes else {
            return .err(
                code: "invalid_params",
                message: "key exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxKeyBytes) bytes",
                data: nil
            )
        }
        guard let value = v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(value) <= SidebarTelemetryLimits.maxStatusValueBytes else {
            return .err(
                code: "invalid_params",
                message: "value exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxStatusValueBytes) bytes",
                data: nil
            )
        }
        let icon = v2String(params, "icon")
        guard SidebarTelemetryLimits.isWithinUTF8Limit(
            icon,
            maxBytes: SidebarTelemetryLimits.maxStatusIconBytes
        ) else {
            return .err(
                code: "invalid_params",
                message: "icon exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxStatusIconBytes) bytes",
                data: nil
            )
        }
        let color = v2String(params, "color")
        guard SidebarTelemetryLimits.isWithinUTF8Limit(
            color,
            maxBytes: SidebarTelemetryLimits.maxStatusColorBytes
        ) else {
            return .err(
                code: "invalid_params",
                message: "color exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxStatusColorBytes) bytes",
                data: nil
            )
        }

        let formatRaw = v2String(params, "format") ?? SidebarMetadataFormat.plain.rawValue
        guard let format = parseSidebarMetadataFormat(formatRaw) else {
            return .err(code: "invalid_params", message: "Invalid format — use: plain, markdown", data: nil)
        }

        var priority = 0
        if v2HasNonNullParam(params, "priority") {
            guard let rawPriority = v2Int(params, "priority") else {
                return .err(code: "invalid_params", message: "Invalid priority — must be an integer", data: nil)
            }
            priority = max(-9999, min(9999, rawPriority))
        }

        var url: URL?
        if let rawURL = v2String(params, "url") {
            guard let candidate = URL(string: rawURL),
                  let scheme = candidate.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .err(code: "invalid_params", message: "Invalid url — expected http(s) URL", data: nil)
            }
            guard SidebarTelemetryLimits.utf8ByteCount(candidate.absoluteString) <= SidebarTelemetryLimits.maxStatusURLBytes else {
                return .err(
                    code: "invalid_params",
                    message: "url exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxStatusURLBytes) bytes",
                    data: nil
                )
            }
            url = candidate
        }

        var pidValue: pid_t?
        if v2HasNonNullParam(params, "pid") {
            guard let rawPid = v2Int(params, "pid"),
                  (1...Int(pid_t.max)).contains(rawPid) else {
                return .err(
                    code: "invalid_params",
                    message: "pid must be an integer from 1 through \(Int(pid_t.max))",
                    data: nil
                )
            }
            pidValue = pid_t(rawPid)
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self, priority, url, pidValue] _, tab in
            guard let self else { return }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: format
            ) else {
                if let pidValue {
                    if tab.setSidebarAgentPID(key: key, pid: pidValue) {
                        self.refreshTrackedAgentPorts(for: tab)
                    }
                }
                return
            }
            let insertion = tab.setSidebarStatusEntry(SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: format,
                timestamp: Date()
            ))
            guard insertion.inserted else { return }
            let agentPIDUpdated = pidValue.map { tab.setSidebarAgentPID(key: key, pid: $0) } ?? false
            if insertion.evictedAgentPID || agentPIDUpdated {
                self.refreshTrackedAgentPorts(for: tab)
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "key": key,
            "value": value,
        ])
    }

    nonisolated func v2WorkspaceClearStatus(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            if tab.statusEntries[key] != nil {
                tab.statusEntries.removeValue(forKey: key)
            }
            if tab.agentPIDs.removeValue(forKey: key) != nil {
                self.refreshTrackedAgentPorts(for: tab)
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "key": key,
        ])
    }

    nonisolated func v2WorkspaceListStatus(params: [String: Any]) -> V2CallResult {
        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let entries: [[String: Any]] = ws.sidebarStatusEntriesInDisplayOrder().map { entry in
                [
                    "key": entry.key,
                    "value": entry.value,
                    "icon": v2OrNull(entry.icon),
                    "color": v2OrNull(entry.color),
                    "url": v2OrNull(entry.url?.absoluteString),
                    "priority": entry.priority,
                    "format": entry.format.rawValue,
                ]
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "entries": entries,
            ])
        }
    }

    nonisolated func v2WorkspaceLog(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let message = v2RawString(params, "message"), !message.isEmpty else {
            return .err(code: "invalid_params", message: "Missing message", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(message) <= SidebarTelemetryLimits.maxLogMessageBytes else {
            return .err(
                code: "invalid_params",
                message: "message exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxLogMessageBytes) bytes",
                data: nil
            )
        }
        let levelRaw = v2String(params, "level") ?? SidebarLogLevel.info.rawValue
        guard let level = SidebarLogLevel(rawValue: levelRaw) else {
            return .err(
                code: "invalid_params",
                message: "Unknown log level — use: info, progress, success, warning, error",
                data: nil
            )
        }
        let source = v2String(params, "source")
        guard SidebarTelemetryLimits.isWithinUTF8Limit(
            source,
            maxBytes: SidebarTelemetryLimits.maxLogSourceBytes
        ) else {
            return .err(
                code: "invalid_params",
                message: "source exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxLogSourceBytes) bytes",
                data: nil
            )
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            _ = tab.appendSidebarLogEntry(
                SidebarLogEntry(message: message, level: level, source: source, timestamp: Date())
            )
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "message": message,
            "level": level.rawValue,
            "source": v2OrNull(source),
        ])
    }

    nonisolated func v2WorkspaceClearLog(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            guard !tab.logEntries.isEmpty else { return }
            tab.logEntries.removeAll()
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])
    }

    nonisolated func v2WorkspaceListLog(params: [String: Any]) -> V2CallResult {
        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }

            var limit: Int?
            if v2HasNonNullParam(params, "limit") {
                guard let parsedLimit = v2Int(params, "limit"), parsedLimit >= 0 else {
                    return .err(code: "invalid_params", message: "Invalid limit — must be >= 0", data: nil)
                }
                limit = parsedLimit
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let source = limit.map { Array(ws.logEntries.suffix($0)) } ?? ws.logEntries
            let entries: [[String: Any]] = source.map { entry in
                [
                    "message": entry.message,
                    "level": entry.level.rawValue,
                    "source": v2OrNull(entry.source),
                    "timestamp": entry.timestamp.timeIntervalSince1970,
                ]
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "entries": entries,
            ])
        }
    }

    nonisolated func v2WorkspaceSetProgress(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let rawValue = v2Double(params, "value"), rawValue.isFinite else {
            return .err(code: "invalid_params", message: "Invalid progress value — must be 0.0 to 1.0", data: nil)
        }
        let clamped = min(1.0, max(0.0, rawValue))
        let label = v2String(params, "label")
        guard SidebarTelemetryLimits.isWithinUTF8Limit(
            label,
            maxBytes: SidebarTelemetryLimits.maxProgressLabelBytes
        ) else {
            return .err(
                code: "invalid_params",
                message: "label exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxProgressLabelBytes) bytes",
                data: nil
            )
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            guard Self.shouldReplaceProgress(current: tab.progress, value: clamped, label: label) else {
                return
            }
            _ = tab.setSidebarProgress(value: clamped, label: label)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "value": clamped,
            "label": v2OrNull(label),
        ])
    }

    nonisolated func v2WorkspaceClearProgress(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            guard tab.progress != nil else { return }
            tab.progress = nil
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])
    }

    nonisolated func v2WorkspaceSidebarState(params: [String: Any]) -> V2CallResult {
        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }

            var focusedCwd: Any = NSNull()
            if let focused = ws.focusedPanelId, let focusedDir = ws.panelDirectories[focused] {
                focusedCwd = focusedDir
            }

            var gitBranchPayload: Any = NSNull()
            if let git = ws.gitBranch {
                gitBranchPayload = ["branch": git.branch, "dirty": git.isDirty]
            }

            var pullRequestPayload: Any = NSNull()
            if let pr = ws.sidebarPullRequestsInDisplayOrder().first {
                pullRequestPayload = [
                    "number": pr.number,
                    "label": pr.label,
                    "url": pr.url.absoluteString,
                    "state": pr.status.rawValue,
                    "branch": v2OrNull(pr.branch),
                    "checks": v2OrNull(pr.checks?.rawValue),
                ]
            }

            var progressPayload: Any = NSNull()
            if let progress = ws.progress {
                progressPayload = ["value": progress.value, "label": v2OrNull(progress.label)]
            }

            let statusEntries: [[String: Any]] = ws.sidebarStatusEntriesInDisplayOrder().map { entry in
                [
                    "key": entry.key,
                    "value": entry.value,
                    "icon": v2OrNull(entry.icon),
                    "color": v2OrNull(entry.color),
                    "url": v2OrNull(entry.url?.absoluteString),
                    "priority": entry.priority,
                    "format": entry.format.rawValue,
                ]
            }

            let metadataBlocks: [[String: Any]] = ws.sidebarMetadataBlocksInDisplayOrder().map { block in
                ["key": block.key, "markdown": block.markdown, "priority": block.priority]
            }

            let recentLogEntries: [[String: Any]] = ws.logEntries.suffix(5).map { entry in
                ["message": entry.message, "level": entry.level.rawValue, "source": v2OrNull(entry.source)]
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "color": v2OrNull(ws.customColor),
                "cwd": ws.currentDirectory,
                "focused_cwd": focusedCwd,
                "focused_surface_id": v2OrNull(ws.focusedPanelId?.uuidString),
                "focused_surface_ref": v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "git_branch": gitBranchPayload,
                "pull_request": pullRequestPayload,
                "ports": ws.listeningPorts,
                "progress": progressPayload,
                "status_entries": statusEntries,
                "metadata_blocks": metadataBlocks,
                "log_count": ws.logEntries.count,
                "recent_log_entries": recentLogEntries,
            ])
        }
    }

    nonisolated func v2WorkspaceClearAgentPID(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(key) <= SidebarTelemetryLimits.maxKeyBytes else {
            return .err(
                code: "invalid_params",
                message: "key exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxKeyBytes) bytes",
                data: nil
            )
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            tab.agentPIDs.removeValue(forKey: key)
            self.refreshTrackedAgentPorts(for: tab)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "key": key,
        ])
    }

    /// Mirrors v1's `set_agent_pid <key> <pid> [--tab=X]`: registers a PID for stale-session
    /// detection/OSC suppression without setting a visible status entry (unlike
    /// `workspace.set_status`, which also accepts an optional `pid`).
    nonisolated func v2WorkspaceSetAgentPID(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(key) <= SidebarTelemetryLimits.maxKeyBytes else {
            return .err(
                code: "invalid_params",
                message: "key exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxKeyBytes) bytes",
                data: nil
            )
        }
        guard let rawPid = v2Int(params, "pid"),
              (1...Int(pid_t.max)).contains(rawPid) else {
            return .err(
                code: "invalid_params",
                message: "pid must be an integer from 1 through \(Int(pid_t.max))",
                data: nil
            )
        }
        let pid = pid_t(rawPid)

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            if tab.setSidebarAgentPID(key: key, pid: pid) {
                self.refreshTrackedAgentPorts(for: tab)
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "key": key,
            "pid": Int(pid),
        ])
    }

    /// Mirrors v1's `report_meta_block <key> [--priority=N] [--tab=X] -- <markdown>`: sets a
    /// freeform sidebar markdown block, distinct from `workspace.set_status`'s single-line
    /// key/value entries.
    nonisolated func v2WorkspaceReportMetaBlock(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2CachedUUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(key) <= SidebarTelemetryLimits.maxKeyBytes else {
            return .err(
                code: "invalid_params",
                message: "key exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxKeyBytes) bytes",
                data: nil
            )
        }
        guard let rawMarkdown = v2RawString(params, "markdown") else {
            return .err(code: "invalid_params", message: "Missing markdown", data: nil)
        }
        let normalizedMarkdown = rawMarkdown
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
        let trimmedMarkdown = normalizedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMarkdown.isEmpty else {
            return .err(code: "invalid_params", message: "Missing markdown", data: nil)
        }
        guard SidebarTelemetryLimits.utf8ByteCount(normalizedMarkdown) <= SidebarTelemetryLimits.maxMetadataMarkdownBytes else {
            return .err(
                code: "invalid_params",
                message: "markdown exceeds the UTF-8 limit of \(SidebarTelemetryLimits.maxMetadataMarkdownBytes) bytes",
                data: nil
            )
        }

        var priority = 0
        if v2HasNonNullParam(params, "priority") {
            guard let rawPriority = v2Int(params, "priority") else {
                return .err(code: "invalid_params", message: "Invalid priority — must be an integer", data: nil)
            }
            priority = max(-9999, min(9999, rawPriority))
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [priority] _, tab in
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: normalizedMarkdown,
                priority: priority
            ) else {
                return
            }
            _ = tab.setSidebarMetadataBlock(SidebarMetadataBlock(
                key: key,
                markdown: normalizedMarkdown,
                priority: priority,
                timestamp: Date()
            ))
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "key": key,
            "markdown": normalizedMarkdown,
            "priority": priority,
        ])
    }

    /// Mirrors v1's `clear_meta_block <key> [--tab=X]`. Unlike the telemetry-mutation family
    /// above, this needs to report whether the key existed, so — like v1's synchronous
    /// `DispatchQueue.main.sync` implementation — it resolves and mutates on the main actor via
    /// `v2MainSync` rather than firing an async `v2ScheduleTelemetryMutation`. This is a rare,
    /// agent/test-triggered command, not a high-frequency telemetry path.
    nonisolated func v2WorkspaceClearMetaBlock(params: [String: Any]) -> V2CallResult {
        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let key = v2String(params, "key") else {
                return .err(code: "invalid_params", message: "Missing key", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let found = ws.metadataBlocks.removeValue(forKey: key) != nil
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "key": key,
                "found": found,
            ])
        }
    }

    /// Mirrors v1's `list_meta_blocks [--tab=X]`.
    nonisolated func v2WorkspaceListMetaBlocks(params: [String: Any]) -> V2CallResult {
        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let blocks: [[String: Any]] = ws.sidebarMetadataBlocksInDisplayOrder().map { block in
                ["key": block.key, "markdown": block.markdown, "priority": block.priority]
            }
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "blocks": blocks,
            ])
        }
    }

    /// Mirrors v1's `reset_sidebar [--tab=X]`.
    nonisolated func v2WorkspaceResetSidebar(params: [String: Any]) -> V2CallResult {
        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            ws.resetSidebarContext(reason: "v2.workspace.reset_sidebar")
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
            ])
        }
    }
    private func refreshTrackedAgentPorts(for tab: Workspace) {
        let agentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
        PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: agentPIDs)
    }
}
