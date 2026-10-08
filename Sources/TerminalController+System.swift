// system.*/settings.*/feedback.*/app.* command handlers.
import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit

private struct SystemIdentifyInput: Sendable {
    let windowId: UUID?
    let workspaceId: UUID?
    let surfaceId: UUID?
    let callerWorkspaceId: UUID?
    let callerSurfaceId: UUID?
}

private struct SystemIdentifySnapshot {
    let focused: [String: Any]
    let caller: [String: Any]?
    let focusedWindowId: UUID?
}

private struct SystemTreeInput: Sendable {
    let workspaceFilter: UUID?
    let includeAllWindows: Bool
    let identify: SystemIdentifyInput
}

private struct SystemTreeSnapshot {
    let focused: [String: Any]
    let caller: [String: Any]?
    let windows: [[String: Any]]
    let workspaceFound: Bool
}

extension TerminalController {
    nonisolated func v2Identify(params: [String: Any], requestPolicy: SocketRequestPolicy) -> [String: Any] {
        let input = v2SystemIdentifyInput(params: params)
        guard let snapshot = v2MainSync({ self.v2SystemIdentifySnapshot(input: input) }) else {
            return [
                "socket_path": requestPolicy.socketPath,
                "focused": NSNull(),
                "caller": NSNull()
            ]
        }

        return [
            "socket_path": requestPolicy.socketPath,
            "focused": snapshot.focused.isEmpty ? NSNull() : snapshot.focused,
            "caller": v2OrNull(snapshot.caller)
        ]
    }

    nonisolated func v2SystemTree(params: [String: Any], requestPolicy: SocketRequestPolicy) -> V2CallResult {
        let workspaceFilter = v2UUID(params, "workspace_id")
        if params["workspace_id"] != nil && workspaceFilter == nil {
            return v2InvalidParam("workspace_id")
        }
        let includeAllWindows = v2Bool(params, "all_windows") ?? false
        let caller = params["caller"] as? [String: Any]
        let identifyInput = v2SystemIdentifyInput(caller: caller?.isEmpty == false ? caller : nil)
        let snapshot = v2MainSync {
            self.v2SystemTreeSnapshot(input: SystemTreeInput(
                workspaceFilter: workspaceFilter,
                includeAllWindows: includeAllWindows,
                identify: identifyInput
            ))
        }

        if let workspaceFilter, !snapshot.workspaceFound {
            return .err(
                code: "not_found",
                message: "Workspace not found",
                data: [
                    "workspace_id": workspaceFilter.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceFilter)
                ]
            )
        }

        return .ok([
            "active": snapshot.focused.isEmpty ? (NSNull() as Any) : snapshot.focused,
            "caller": v2OrNull(snapshot.caller),
            "windows": snapshot.windows
        ])
    }

    private nonisolated func v2SystemIdentifyInput(
        params: [String: Any] = [:],
        caller: [String: Any]? = nil
    ) -> SystemIdentifyInput {
        let callerObject = caller ?? (params["caller"] as? [String: Any])
        return SystemIdentifyInput(
            windowId: v2UUID(params, "window_id"),
            workspaceId: v2UUID(params, "workspace_id"),
            surfaceId: v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id"),
            callerWorkspaceId: v2UUIDAny(callerObject?["workspace_id"]),
            callerSurfaceId: v2UUIDAny(callerObject?["surface_id"])
                ?? v2UUIDAny(callerObject?["tab_id"])
        )
    }

    @MainActor
    private func v2SystemIdentifySnapshot(input: SystemIdentifyInput) -> SystemIdentifySnapshot? {
        let manager: TabManager?
        if let windowId = input.windowId {
            manager = AppDelegate.shared?.tabManagerFor(windowId: windowId)
        } else {
            var resolvedManager: TabManager?
            if let workspaceId = input.workspaceId {
                resolvedManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)
            }
            if resolvedManager == nil, let surfaceId = input.surfaceId {
                resolvedManager = AppDelegate.shared?.locateSurface(surfaceId: surfaceId)?.tabManager
            }
            manager = resolvedManager ?? tabManager
        }
        guard let manager else { return nil }

        let windowId = AppDelegate.shared?.windowId(for: manager)
        let focused: [String: Any]
        if let workspaceId = manager.selectedTabId,
           let workspace = manager.tabs.first(where: { $0.id == workspaceId }) {
            let paneId = workspace.bonsplitController.focusedPaneId?.id
            let surfaceId = workspace.focusedPanelId
            focused = [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "pane_id": v2OrNull(paneId?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneId),
                "surface_id": v2OrNull(surfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "tab_id": v2OrNull(surfaceId?.uuidString),
                "tab_ref": v2TabRef(uuid: surfaceId),
                "surface_type": v2OrNull(surfaceId.flatMap { workspace.panels[$0]?.panelType.rawValue }),
            ]
        } else {
            focused = [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
        }

        var callerPayload: [String: Any]?
        if let callerWorkspaceId = input.callerWorkspaceId {
            let callerManager = AppDelegate.shared?.tabManagerFor(tabId: callerWorkspaceId) ?? manager
            if let workspace = callerManager.tabs.first(where: { $0.id == callerWorkspaceId }) {
                let callerWindowId = AppDelegate.shared?.windowId(for: callerManager)
                var payload: [String: Any] = [
                    "window_id": v2OrNull(callerWindowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: callerWindowId),
                    "workspace_id": callerWorkspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: callerWorkspaceId)
                ]

                if let callerSurfaceId = input.callerSurfaceId,
                   workspace.panels[callerSurfaceId] != nil {
                    let paneId = workspace.paneId(forPanelId: callerSurfaceId)?.id
                    payload["surface_id"] = callerSurfaceId.uuidString
                    payload["surface_ref"] = v2Ref(kind: .surface, uuid: callerSurfaceId)
                    payload["tab_id"] = callerSurfaceId.uuidString
                    payload["tab_ref"] = v2TabRef(uuid: callerSurfaceId)
                    payload["surface_type"] = v2OrNull(workspace.panels[callerSurfaceId]?.panelType.rawValue)
                    payload["pane_id"] = v2OrNull(paneId?.uuidString)
                    payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneId)
                } else {
                    payload["surface_id"] = NSNull()
                    payload["surface_ref"] = NSNull()
                    payload["tab_id"] = NSNull()
                    payload["tab_ref"] = NSNull()
                    payload["surface_type"] = NSNull()
                    payload["pane_id"] = NSNull()
                    payload["pane_ref"] = NSNull()
                }
                callerPayload = payload
            }
        }

        return SystemIdentifySnapshot(
            focused: focused,
            caller: callerPayload,
            focusedWindowId: windowId
        )
    }

    @MainActor
    private func v2SystemTreeSnapshot(input: SystemTreeInput) -> SystemTreeSnapshot {
        let identifySnapshot = v2SystemIdentifySnapshot(input: input.identify)
        let focused = identifySnapshot?.focused ?? [:]
        let caller = identifySnapshot?.caller
        var windows: [[String: Any]] = []
        var workspaceFound = (input.workspaceFilter == nil)

        if let app = AppDelegate.shared {
            let summaries = app.listMainWindowSummaries()
            let defaultWindowId = identifySnapshot?.focusedWindowId ?? summaries.first?.windowId

            for (windowIndex, summary) in summaries.enumerated() {
                guard let manager = app.tabManagerFor(windowId: summary.windowId) else { continue }

                if let workspaceFilter = input.workspaceFilter {
                    guard let workspaceIndex = manager.tabs.firstIndex(where: { $0.id == workspaceFilter }) else {
                        continue
                    }
                    let workspace = manager.tabs[workspaceIndex]
                    let workspaceNode = v2TreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                    windows = [
                        v2TreeWindowNode(
                            summary: summary,
                            index: windowIndex,
                            workspaceNodes: [workspaceNode]
                        )
                    ]
                    workspaceFound = true
                    break
                }

                if !input.includeAllWindows && summary.windowId != defaultWindowId {
                    continue
                }

                let workspaceNodes = manager.tabs.enumerated().map { workspaceIndex, workspace in
                    v2TreeWorkspaceNode(
                        workspace: workspace,
                        index: workspaceIndex,
                        selected: workspace.id == manager.selectedTabId
                    )
                }
                windows.append(
                    v2TreeWindowNode(
                        summary: summary,
                        index: windowIndex,
                        workspaceNodes: workspaceNodes
                    )
                )
            }
        }

        return SystemTreeSnapshot(
            focused: focused,
            caller: caller,
            windows: windows,
            workspaceFound: workspaceFound
        )
    }

    private func v2TreeWindowNode(
        summary: AppDelegate.MainWindowSummary,
        index: Int,
        workspaceNodes: [[String: Any]]
    ) -> [String: Any] {
        return [
            "id": summary.windowId.uuidString,
            "ref": v2Ref(kind: .window, uuid: summary.windowId),
            "index": index,
            "key": summary.isKeyWindow,
            "visible": summary.isVisible,
            "workspace_count": workspaceNodes.count,
            "selected_workspace_id": v2OrNull(summary.selectedWorkspaceId?.uuidString),
            "selected_workspace_ref": v2Ref(kind: .workspace, uuid: summary.selectedWorkspaceId),
            "workspaces": workspaceNodes
        ]
    }

    private func v2TreeWorkspaceNode(
        workspace: Workspace,
        index: Int,
        selected: Bool
    ) -> [String: Any] {
        let workspaceHelpers = AgentSupervisionMetadata.relatedRecords(for: workspace)
        var paneByPanelId: [UUID: UUID] = [:]
        var indexInPaneByPanelId: [UUID: Int] = [:]
        var selectedInPaneByPanelId: [UUID: Bool] = [:]

        let paneIds = workspace.bonsplitController.allPaneIds
        for paneId in paneIds {
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            for (tabIndex, tab) in tabs.enumerated() {
                guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { continue }
                paneByPanelId[panelId] = paneId.id
                indexInPaneByPanelId[panelId] = tabIndex
                selectedInPaneByPanelId[panelId] = (tab.id == selectedTab?.id)
            }
        }

        var surfacesByPane: [UUID: [[String: Any]]] = [:]
        let focusedSurfaceId = workspace.focusedPanelId
        for (surfaceIndex, panel) in orderedPanels(in: workspace).enumerated() {
            let paneUUID = paneByPanelId[panel.id]
            let selectedInPane = selectedInPaneByPanelId[panel.id] ?? false

            var item: [String: Any] = [
                "id": panel.id.uuidString,
                "ref": v2Ref(kind: .surface, uuid: panel.id),
                "index": surfaceIndex,
                "type": panel.panelType.rawValue,
                "title": workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                "focused": panel.id == focusedSurfaceId,
                "selected": selectedInPane,
                "selected_in_pane": v2OrNull(selectedInPaneByPanelId[panel.id]),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "index_in_pane": v2OrNull(indexInPaneByPanelId[panel.id]),
                "tty": v2OrNull(workspace.surfaceTTYNames[panel.id]),
                "current_directory": v2OrNull(workspace.panelDirectories[panel.id] ?? workspace.currentDirectory),
                "branch": v2OrNull(workspace.panelGitBranches[panel.id]?.branch ?? workspace.gitBranch?.branch ?? workspace.worktreeBranch),
                "agent_state": v2OrNull(workspace.panelAgentStates[panel.id]?.rawValue),
                "agent_state_source": v2OrNull(workspace.panelAgentStateSources[panel.id]?.rawValue),
                "program_status": workspace.programStatusWire(panelId: panel.id),
                "helpers": workspaceHelpers
                    .filter { $0.surfaceId == panel.id }
                    .map { $0.payload() },
            ]

            if let pullRequest = workspace.panelPullRequests[panel.id] ?? workspace.pullRequest {
                item["pull_request"] = [
                    "number": pullRequest.number,
                    "label": pullRequest.label,
                    "url": pullRequest.url.absoluteString,
                    "status": pullRequest.status.rawValue,
                    "branch": v2OrNull(pullRequest.branch),
                    "checks": v2OrNull(pullRequest.checks?.rawValue),
                ] as [String: Any]
            } else {
                item["pull_request"] = NSNull()
            }

            if let paneUUID {
                surfacesByPane[paneUUID, default: []].append(item)
            }
        }

        for paneUUID in surfacesByPane.keys {
            surfacesByPane[paneUUID]?.sort {
                let lhs = ($0["index_in_pane"] as? Int) ?? ($0["index"] as? Int) ?? Int.max
                let rhs = ($1["index_in_pane"] as? Int) ?? ($1["index"] as? Int) ?? Int.max
                return lhs < rhs
            }
        }

        let focusedPaneId = workspace.bonsplitController.focusedPaneId
        let panes: [[String: Any]] = paneIds.enumerated().map { paneIndex, paneId in
            let tabs = workspace.bonsplitController.tabs(inPane: paneId)
            let surfaceUUIDs: [UUID] = tabs.compactMap { workspace.panelIdFromSurfaceId($0.id) }
            let selectedTab = workspace.bonsplitController.selectedTab(inPane: paneId)
            let selectedSurfaceUUID = selectedTab.flatMap { workspace.panelIdFromSurfaceId($0.id) }

            return [
                "id": paneId.id.uuidString,
                "ref": v2Ref(kind: .pane, uuid: paneId.id),
                "index": paneIndex,
                "focused": paneId == focusedPaneId,
                "surface_ids": surfaceUUIDs.map { $0.uuidString },
                "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                "surface_count": surfaceUUIDs.count,
                "surfaces": surfacesByPane[paneId.id] ?? []
            ]
        }

        let pullRequest = workspace.pullRequest.map { pullRequest in
            [
                "number": pullRequest.number,
                "label": pullRequest.label,
                "url": pullRequest.url.absoluteString,
                "status": pullRequest.status.rawValue,
                "branch": v2OrNull(pullRequest.branch),
                "checks": v2OrNull(pullRequest.checks?.rawValue),
            ] as [String: Any]
        }
        return [
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "index": index,
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "current_directory": v2OrNull(workspace.currentDirectory),
            "branch": v2OrNull(workspace.gitBranch?.branch ?? workspace.worktreeBranch),
            "pull_request": v2OrNull(pullRequest),
            "worktree_parent_workspace_id": v2OrNull(workspace.worktreeParentWorkspaceId?.uuidString),
            "worktree_folder_id": v2OrNull(workspace.worktreeFolderId?.uuidString),
            "worktree_folder_repo_root": v2OrNull(workspace.worktreeFolderRepoRoot),
            "is_worktree_folder": workspace.isWorktreeFolder,
            "agent_parent_workspace_id": v2OrNull(workspace.agentParentWorkspaceId?.uuidString),
            "agent_state": v2OrNull(AgentSupervisionMetadata.currentActivityState(
                for: workspace,
                records: workspaceHelpers
            )),
            "helper_outcomes": AgentSupervisionMetadata.helperOutcomes(records: workspaceHelpers),
            "agent_state_source": v2OrNull(AgentSupervisionMetadata.aggregateSource(
                for: workspace,
                records: workspaceHelpers
            )),
            "helpers": workspaceHelpers.map { $0.payload() },
            "helper_count": workspaceHelpers.count,
            "panes": panes
        ]
    }
    nonisolated func v2FeedbackOpen(params: [String: Any]) -> V2CallResult {
        let workspaceId = v2UUID(params, "workspace_id")
        let windowId = v2UUID(params, "window_id")
        let shouldActivate = v2FocusAllowed(requested: v2Bool(params, "activate") ?? false)
        DispatchQueue.main.async { @MainActor in
            if shouldActivate {
                let targetWindow: NSWindow?
                if let windowId, let app = AppDelegate.shared {
                    targetWindow = app.mainWindow(for: windowId)
                } else if let workspaceId, let app = AppDelegate.shared {
                    targetWindow = app.mainWindowContainingWorkspace(workspaceId)
                } else {
                    targetWindow = nil
                }

                if let targetWindow {
                    targetWindow.makeKeyAndOrderFront(nil)
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                } else {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
            }

            NSWorkspace.shared.open(URL(string: "https://github.com/darkroomengineering/programa/issues")!)
        }
        return .ok(["opened": true])
    }

    nonisolated func v2SettingsOpen(params: [String: Any]) -> V2CallResult {
        let targetRaw = v2String(params, "target")
        let shouldActivate = v2FocusAllowed(requested: v2Bool(params, "activate") ?? true)
        let keyboardShortcutsTarget = SettingsNavigationTarget.keyboardShortcuts.rawValue

        switch targetRaw {
        case nil:
            break
        case keyboardShortcutsTarget:
            break
        default:
            return .err(code: "invalid_params", message: "Unknown settings target", data: ["target": targetRaw ?? ""])
        }

        DispatchQueue.main.async { @MainActor in
            let navigationTarget = targetRaw.flatMap { SettingsNavigationTarget(rawValue: $0) }
            if shouldActivate {
                AppDelegate.presentPreferencesWindow(navigationTarget: navigationTarget)
            } else {
                SettingsWindowController.shared.show(navigationTarget: navigationTarget)
            }
        }
        return .ok([
            "opened": true,
            "target": targetRaw ?? "general",
        ])
    }

    nonisolated func v2FeedbackSubmit(params: [String: Any]) -> V2CallResult {
        return .err(
            code: "feedback_disabled",
            message: "feedback submission is disabled; report issues at https://github.com/darkroomengineering/programa/issues",
            data: nil
        )
    }

    // MARK: - V2 App Focus Methods

    nonisolated func v2AppFocusOverride(params: [String: Any]) -> V2CallResult {
        // Accept either:
        // - state: "active" | "inactive" | "clear"
        // - focused: true/false/null
        let requestedOverride: Bool?
        if let state = v2String(params, "state")?.lowercased() {
            switch state {
            case "active":
                requestedOverride = true
            case "inactive":
                requestedOverride = false
            case "clear", "none":
                requestedOverride = nil
            default:
                return .err(code: "invalid_params", message: "Invalid state (active|inactive|clear)", data: ["state": state])
            }
        } else if params.keys.contains("focused") {
            requestedOverride = v2Bool(params, "focused")
        } else {
            return .err(code: "invalid_params", message: "Missing state or focused", data: nil)
        }

        let appliedOverride: Bool? = v2MainSync {
            AppFocusState.overrideIsFocused = requestedOverride
            return AppFocusState.overrideIsFocused
        }
        let overrideVal: Any = v2OrNull(appliedOverride.map { $0 as Any })
        return .ok(["override": overrideVal])
    }

    nonisolated func v2AppSimulateActive() -> V2CallResult {
        v2MainSync {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return .ok([:])
    }

    /// Mirrors v1's `reload_config`: this is a rare, user/agent-triggered configuration
    /// reload rather than high-frequency telemetry, so — matching the v1 handler, which
    /// itself calls `v2MainSync` directly — it is allowed to synchronize with the main actor.
    nonisolated func v2AppReloadConfig(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            GhosttyApp.shared.reloadConfiguration(source: "socket.v2.app.reload_config")
        }
        return .ok(["reloaded": true])
    }

    /// Read-only `NSWorkspace`/filesystem queries, no arguments, no AppKit UI
    /// mutation -- per the socket command threading policy this runs off-main
    /// (no `v2MainSync`), same as other query commands.
    nonisolated func v2AppBrowsers() -> V2CallResult {
        let statuses = BrowserAvailability.detectStatuses()
        let defaultBrowser = BrowserAvailability.resolveDefaultBrowser()
        let browsers: [[String: Any]] = statuses.map { status in
            [
                "key": status.key,
                "name": status.name,
                "bundle_id": status.bundleId,
                "path": v2OrNull(status.path),
                "installed": status.installed,
                "running": status.running
            ]
        }
        return .ok([
            "default": v2OrNull(defaultBrowser?.shortKey),
            "browsers": browsers
        ])
    }
}
