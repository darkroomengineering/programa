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
    private func v2ScheduleTelemetryMutation(
        workspaceId: UUID,
        _ mutation: @escaping (TabManager, Workspace) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
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

    private func v2ScheduleSurfaceTelemetryMutation(
        workspaceId: UUID,
        surfaceId: UUID,
        _ mutation: @escaping (TabManager, Workspace, UUID) -> Void
    ) {
        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { tabManager, tab in
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)
            guard validSurfaceIds.contains(surfaceId) else { return }
            mutation(tabManager, tab, surfaceId)
        }
    }
    func v2SurfaceReportTTY(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        let requestedSurfaceId = v2UUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return v2InvalidParam("surface_id")
        }
        guard let ttyName = v2RawString(params, "tty_name")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ttyName.isEmpty else {
            return .err(code: "invalid_params", message: "Missing tty_name", data: nil)
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
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
                if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                    tab.rememberPendingRemoteSurfaceTTY(ttyName, requestedSurfaceId: requestedSurfaceId)
                }
                return
            }

            tab.surfaceTTYNames[surfaceId] = ttyName
            if tab.isRemoteWorkspace {
                tab.syncRemotePortScanTTYs()
                _ = tab.applyPendingRemoteSurfacePortKickIfNeeded(to: surfaceId)
            } else {
                PortScanner.shared.registerTTY(workspaceId: workspaceId, panelId: surfaceId, ttyName: ttyName)
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
            "tty_name": ttyName,
        ])
    }

    func v2SurfacePortsKick(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        let requestedSurfaceId = v2UUID(params, "surface_id")
        if v2HasNonNullParam(params, "surface_id"), requestedSurfaceId == nil {
            return v2InvalidParam("surface_id")
        }
        let reason: WorkspaceRemoteSessionController.PortScanKickReason
        if let rawReason = v2RawString(params, "reason") {
            guard let parsedReason = Self.parseRemotePortScanKickReason(rawReason) else {
                return .err(
                    code: "invalid_params",
                    message: "reason must be command or refresh",
                    data: nil
                )
            }
            reason = parsedReason
        } else {
            reason = .command
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
            guard let surfaceId, validSurfaceIds.contains(surfaceId) else {
                if tab.isRemoteWorkspace, validSurfaceIds.isEmpty {
                    tab.rememberPendingRemoteSurfacePortKick(
                        reason: reason,
                        requestedSurfaceId: requestedSurfaceId
                    )
                }
                return
            }

            if tab.isRemoteWorkspace {
                tab.kickRemotePortScan(panelId: surfaceId, reason: reason)
            } else {
                PortScanner.shared.kick(workspaceId: workspaceId, panelId: surfaceId)
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": v2OrNull(requestedSurfaceId?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: requestedSurfaceId),
            "reason": reason.rawValue,
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

    func v2SurfaceReportPwd(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let path = v2RawString(params, "path")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return .err(code: "invalid_params", message: "Missing path", data: nil)
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

    func v2SurfaceReportShellState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
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

    func v2SurfaceReportGitBranch(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let branch = v2RawString(params, "branch")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else {
            return .err(code: "invalid_params", message: "Missing branch", data: nil)
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

    func v2SurfaceClearGitBranch(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
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
    func v2SurfaceReportAgentState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let rawState = v2RawString(params, "state"),
              let state = AgentActivityState(rawValue: rawState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return .err(code: "invalid_params", message: "Invalid state — use: working, blocked, idle", data: nil)
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            tabManager.updateSurfaceAgentState(tabId: workspaceId, surfaceId: sid, state: state)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "state": state.rawValue,
        ])
    }

    func v2SurfaceClearAgentState(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { tabManager, _, sid in
            tabManager.clearSurfaceAgentState(tabId: workspaceId, surfaceId: sid)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
        ])
    }

    func v2SurfaceReportPullRequest(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let number = v2Int(params, "number"), number > 0 else {
            return v2InvalidParam("number")
        }
        guard let rawURL = v2RawString(params, "url")?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return v2InvalidParam("url")
        }
        let statusRaw = (v2String(params, "state") ?? "open").lowercased()
        guard let status = SidebarPullRequestStatus(rawValue: statusRaw) else {
            return .err(code: "invalid_params", message: "Invalid state — use: open, merged, closed", data: nil)
        }
        let branch = v2String(params, "branch")

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

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { _, tab, sid in
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

    func v2SurfaceClearPullRequest(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
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

    func v2SurfaceReportPorts(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let rawPorts = v2IntArray(params, "ports"), !rawPorts.isEmpty else {
            return v2InvalidParam("ports")
        }
        guard rawPorts.allSatisfy({ $0 > 0 && $0 <= 65535 }) else {
            return .err(code: "invalid_params", message: "Invalid port — must be 1-65535", data: nil)
        }

        v2ScheduleSurfaceTelemetryMutation(workspaceId: workspaceId, surfaceId: surfaceId) { _, tab, sid in
            tab.surfaceListeningPorts[sid] = rawPorts
            tab.recomputeListeningPorts()
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "ports": rawPorts,
        ])
    }

    func v2SurfaceClearPorts(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        let requestedSurfaceId = v2UUID(params, "surface_id")
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
           validSurfaceIds.contains(focusedSurfaceId),
           (!workspace.isRemoteWorkspace || workspace.isRemoteTerminalSurface(focusedSurfaceId)) {
            return focusedSurfaceId
        }

        guard workspace.isRemoteWorkspace else { return nil }

        let remoteTerminalSurfaceIds = validSurfaceIds.filter { workspace.isRemoteTerminalSurface($0) }
        if remoteTerminalSurfaceIds.count == 1 {
            return remoteTerminalSurfaceIds.first
        }

        if validSurfaceIds.count == 1 {
            return validSurfaceIds.first
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

    func v2WorkspaceSetStatus(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = v2RawString(params, "value") else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }
        let icon = v2String(params, "icon")
        let color = v2String(params, "color")

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
            url = candidate
        }

        var pidValue: pid_t?
        if let rawPid = v2Int(params, "pid"), rawPid > 0 {
            pidValue = pid_t(rawPid)
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
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
                    tab.agentPIDs[key] = pidValue
                    self.refreshTrackedAgentPorts(for: tab)
                }
                return
            }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                url: url,
                priority: priority,
                format: format,
                timestamp: Date()
            )
            if let pidValue {
                tab.agentPIDs[key] = pidValue
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

    func v2WorkspaceClearStatus(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            _ = tab.statusEntries.removeValue(forKey: key)
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

    func v2WorkspaceListStatus(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
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
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "entries": entries,
            ])
        }
        return result
    }

    func v2WorkspaceLog(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let message = v2RawString(params, "message"), !message.isEmpty else {
            return .err(code: "invalid_params", message: "Missing message", data: nil)
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

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
            let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
            let limit = max(1, min(500, configuredLimit))
            if tab.logEntries.count > limit {
                tab.logEntries.removeFirst(tab.logEntries.count - limit)
            }
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "message": message,
            "level": level.rawValue,
            "source": v2OrNull(source),
        ])
    }

    func v2WorkspaceClearLog(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            tab.logEntries.removeAll()
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])
    }

    func v2WorkspaceListLog(params: [String: Any]) -> V2CallResult {
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

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let source = limit.map { Array(ws.logEntries.suffix($0)) } ?? ws.logEntries
            let entries: [[String: Any]] = source.map { entry in
                [
                    "message": entry.message,
                    "level": entry.level.rawValue,
                    "source": v2OrNull(entry.source),
                    "timestamp": entry.timestamp.timeIntervalSince1970,
                ]
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "entries": entries,
            ])
        }
        return result
    }

    func v2WorkspaceSetProgress(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let rawValue = v2Double(params, "value"), rawValue.isFinite else {
            return .err(code: "invalid_params", message: "Invalid progress value — must be 0.0 to 1.0", data: nil)
        }
        let clamped = min(1.0, max(0.0, rawValue))
        let label = v2String(params, "label")

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            tab.progress = SidebarProgressState(value: clamped, label: label)
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "value": clamped,
            "label": v2OrNull(label),
        ])
    }

    func v2WorkspaceClearProgress(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            tab.progress = nil
        }

        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])
    }

    func v2WorkspaceSidebarState(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }

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

            result = .ok([
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
        return result
    }

    func v2WorkspaceClearAgentPID(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
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
    func v2WorkspaceSetAgentPID(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let rawPid = v2Int(params, "pid"), rawPid > 0 else {
            return v2InvalidParam("pid — must be a positive integer")
        }
        let pid = pid_t(rawPid)

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { [weak self] _, tab in
            guard let self else { return }
            tab.agentPIDs[key] = pid
            self.refreshTrackedAgentPorts(for: tab)
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
    func v2WorkspaceReportMetaBlock(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
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

        var priority = 0
        if v2HasNonNullParam(params, "priority") {
            guard let rawPriority = v2Int(params, "priority") else {
                return .err(code: "invalid_params", message: "Invalid priority — must be an integer", data: nil)
            }
            priority = max(-9999, min(9999, rawPriority))
        }

        v2ScheduleTelemetryMutation(workspaceId: workspaceId) { _, tab in
            guard Self.shouldReplaceMetadataBlock(
                current: tab.metadataBlocks[key],
                key: key,
                markdown: normalizedMarkdown,
                priority: priority
            ) else {
                return
            }
            tab.metadataBlocks[key] = SidebarMetadataBlock(
                key: key,
                markdown: normalizedMarkdown,
                priority: priority,
                timestamp: Date()
            )
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
    func v2WorkspaceClearMetaBlock(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let found = ws.metadataBlocks.removeValue(forKey: key) != nil
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "key": key,
                "found": found,
            ])
        }
        return result
    }

    /// Mirrors v1's `list_meta_blocks [--tab=X]`.
    func v2WorkspaceListMetaBlocks(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let blocks: [[String: Any]] = ws.sidebarMetadataBlocksInDisplayOrder().map { block in
                ["key": block.key, "markdown": block.markdown, "priority": block.priority]
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "blocks": blocks,
            ])
        }
        return result
    }

    /// Mirrors v1's `reset_sidebar [--tab=X]`.
    func v2WorkspaceResetSidebar(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            ws.resetSidebarContext(reason: "v2.workspace.reset_sidebar")
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
            ])
        }
        return result
    }
    private func refreshTrackedAgentPorts(for tab: Workspace) {
        let agentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
        PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: agentPIDs)
    }
}
