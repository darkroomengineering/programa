// Extracted from TerminalController.swift (nuclear-review #96): workspace.* command handlers (CRUD, remote session, action/tab.action verbs).
import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit
import WebKit

extension TerminalController {
    // MARK: - V2 Workspace Methods

    private func v2WorkspaceSummaryPayload(
        workspace: Workspace,
        index: Int?,
        selected: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": workspace.id.uuidString,
            "ref": v2Ref(kind: .workspace, uuid: workspace.id),
            "title": workspace.title,
            "description": v2OrNull(workspace.customDescription),
            "selected": selected,
            "pinned": workspace.isPinned,
            "listening_ports": workspace.listeningPorts,
            "remote": workspace.remoteStatusPayload(),
            "current_directory": v2OrNull(workspace.currentDirectory),
            "custom_color": v2OrNull(workspace.customColor)
        ]
        if let index {
            payload["index"] = index
        }
        return payload
    }

    func v2WorkspaceList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var workspaces: [[String: Any]] = []
        v2MainSync {
            workspaces = tabManager.tabs.enumerated().map { index, ws in
                v2WorkspaceSummaryPayload(
                    workspace: ws,
                    index: index,
                    selected: ws.id == tabManager.selectedTabId
                )
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspaces": workspaces
        ])
    }
    func v2WorkspaceCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let requestedWorkingDirectory = v2RawString(params, "working_directory")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = (requestedWorkingDirectory?.isEmpty == false) ? requestedWorkingDirectory : nil

        let requestedInitialCommand = v2RawString(params, "initial_command")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCommand = (requestedInitialCommand?.isEmpty == false) ? requestedInitialCommand : nil

        let rawInitialEnv = v2StringMap(params, "initial_env") ?? [:]
        let initialEnv = rawInitialEnv.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = pair.value
        }
        let cwd: String?
        if let workingDirectory {
            cwd = workingDirectory
        } else if let raw = params["cwd"] {
            guard let str = raw as? String else {
                return .err(code: "invalid_params", message: "cwd must be a string", data: nil)
            }
            cwd = str
        } else {
            cwd = nil
        }

        let requestedTitle = v2RawString(params, "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (requestedTitle?.isEmpty == false) ? requestedTitle : nil
        let description = v2RawString(params, "description")

        var newId: UUID?
        let shouldFocus = v2FocusAllowed()
        v2MainSync {
            let ws = tabManager.addWorkspace(
                title: title,
                workingDirectory: cwd,
                initialTerminalCommand: initialCommand,
                initialTerminalEnvironment: initialEnv,
                select: shouldFocus,
                eagerLoadTerminal: !shouldFocus
            )
            ws.setCustomDescription(description)
            newId = ws.id
        }

        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId)
        ])
    }
    func v2WorkspaceSelect(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        var success = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                // If this workspace belongs to another window, bring it forward so focus is visible.
                if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                    _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                    setActiveTabManager(tabManager)
                }
                tabManager.selectWorkspace(ws)
                success = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return success
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }
    func v2WorkspaceCurrent(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        var wsId: UUID?
        var wsPayload: [String: Any]?
        v2MainSync {
            wsId = tabManager.selectedTabId
            if let wsId, let workspace = tabManager.tabs.first(where: { $0.id == wsId }) {
                let index = tabManager.tabs.firstIndex(where: { $0.id == wsId })
                wsPayload = v2WorkspaceSummaryPayload(
                    workspace: workspace,
                    index: index,
                    selected: true
                )
            }
        }
        guard let wsId else {
            return .err(code: "not_found", message: "No workspace selected", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "workspace_id": wsId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
            "workspace": wsPayload ?? NSNull()
        ])
    }
    func v2WorkspaceClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        var found = false
        var protected = false
        v2MainSync {
            if let ws = tabManager.tabs.first(where: { $0.id == wsId }) {
                guard tabManager.canCloseWorkspace(ws) else {
                    protected = true
                    found = true
                    return
                }
                tabManager.closeWorkspace(ws)
                found = true
            }
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        if protected {
            return .err(code: "protected", message: workspaceCloseProtectedMessage(), data: [
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "pinned": true
            ])
        }
        return found
            ? .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
            : .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId)
            ])
    }

    private func workspaceCloseProtectedMessage() -> String {
        String(
            localized: "workspace.closeProtected.message",
            defaultValue: "Pinned workspaces can't be closed while pinned. Unpin the workspace first."
        )
    }

    func v2WorkspaceMoveToWindow(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let windowId = v2UUID(params, "window_id") else {
            return v2InvalidParam("window_id")
        }
        let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? false)

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to move workspace", data: nil)
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId) else {
                result = .err(code: "not_found", message: "Window not found", data: ["window_id": windowId.uuidString])
                return
            }
            guard let ws = srcTM.detachWorkspace(tabId: wsId) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }

            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            result = .ok([
                "workspace_id": wsId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: wsId),
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }
    func v2WorkspaceReorder(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }

        let index = v2Int(params, "index")
        let beforeId = v2UUID(params, "before_workspace_id")
        let afterId = v2UUID(params, "after_workspace_id")

        let targetCount = (index != nil ? 1 : 0) + (beforeId != nil ? 1 : 0) + (afterId != nil ? 1 : 0)
        if targetCount != 1 {
            return .err(
                code: "invalid_params",
                message: "Specify exactly one target: index, before_workspace_id, or after_workspace_id",
                data: nil
            )
        }

        var moved = false
        var newIndex: Int?
        v2MainSync {
            if let index {
                moved = tabManager.reorderWorkspace(tabId: workspaceId, toIndex: index)
            } else {
                moved = tabManager.reorderWorkspace(tabId: workspaceId, before: beforeId, after: afterId)
            }
            newIndex = tabManager.tabs.firstIndex(where: { $0.id == workspaceId })
        }

        guard moved else {
            return .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": workspaceId.uuidString])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "index": v2OrNull(newIndex)
        ])
    }
    func v2WorkspaceRename(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let titleRaw = v2String(params, "title"),
              !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return v2InvalidParam("title")
        }

        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        var renamed = false
        v2MainSync {
            guard tabManager.tabs.contains(where: { $0.id == workspaceId }) else { return }
            tabManager.setCustomTitle(tabId: workspaceId, title: title)
            renamed = true
        }

        guard renamed else {
            return .err(code: "not_found", message: "Workspace not found", data: [
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)
            ])
        }

        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "title": title
        ])
    }
    func v2WorkspaceNext(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.selectNextTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2WorkspacePrevious(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No workspace selected", data: nil)
        v2MainSync {
            guard tabManager.selectedTabId != nil else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.selectPreviousTab()
            guard let workspaceId = tabManager.selectedTabId else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": workspaceId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2WorkspaceLast(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "No previous workspace in history", data: nil)
        v2MainSync {
            guard let before = tabManager.selectedTabId else { return }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            tabManager.navigateBack()
            guard let after = tabManager.selectedTabId, after != before else { return }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            result = .ok([
                "workspace_id": after.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: after),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
        return result
    }

    func v2WorkspaceEqualizeSplits(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let orientationFilter = v2String(params, "orientation")

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let tree = ws.bonsplitController.treeSnapshot()
            let success = v2ProportionalEqualize(node: tree, controller: ws.bonsplitController, orientationFilter: orientationFilter)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "equalized": success
            ])
        }
        return result
    }

    /// Count leaf panes in a tree node.
    private func v2CountLeaves(_ node: ExternalTreeNode) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let s):
            return v2CountLeaves(s.first) + v2CountLeaves(s.second)
        }
    }

    /// Proportionally equalize splits so each leaf pane gets equal space.
    /// For a split with N1 leaves on the left and N2 on the right,
    /// the divider is set to N1/(N1+N2).
    /// When orientationFilter is set (e.g. "vertical"), only splits matching
    /// that orientation are equalized. This lets main-vertical layout equalize
    /// the agent column without squishing the main pane.
    @discardableResult
    private func v2ProportionalEqualize(
        node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String? = nil
    ) -> Bool {
        guard case .split(let s) = node else { return false }
        guard let splitId = UUID(uuidString: s.id) else { return false }

        var didEqualize = false
        if orientationFilter == nil || s.orientation == orientationFilter {
            let leftLeaves = v2CountLeaves(s.first)
            let rightLeaves = v2CountLeaves(s.second)
            let total = leftLeaves + rightLeaves
            let position = CGFloat(leftLeaves) / CGFloat(total)
            controller.setDividerPosition(position, forSplit: splitId, fromExternal: true)
            didEqualize = true
        }

        let l = v2ProportionalEqualize(node: s.first, controller: controller, orientationFilter: orientationFilter)
        let r = v2ProportionalEqualize(node: s.second, controller: controller, orientationFilter: orientationFilter)
        return didEqualize || l || r
    }

    func v2WorkspaceRemoteConfigure(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return v2InvalidParam("workspace_id")
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        guard let destination = v2String(params, "destination") else {
            return .err(code: "invalid_params", message: "Missing destination", data: nil)
        }

        var sshPort: Int?
        if v2HasNonNullParam(params, "port") {
            guard let parsedPort = v2StrictInt(params, "port"),
                  parsedPort > 0,
                  parsedPort <= 65535 else {
                return .err(code: "invalid_params", message: "port must be 1-65535", data: nil)
            }
            sshPort = parsedPort
        }

        // Internal deterministic test hook: pin the local proxy listener port to force bind conflicts.
        var localProxyPort: Int?
        if v2HasNonNullParam(params, "local_proxy_port") {
            guard let parsedLocalProxyPort = v2StrictInt(params, "local_proxy_port"),
                  parsedLocalProxyPort > 0,
                  parsedLocalProxyPort <= 65535 else {
                return .err(code: "invalid_params", message: "local_proxy_port must be 1-65535", data: nil)
            }
            localProxyPort = parsedLocalProxyPort
        }

        let identityFile = v2RawString(params, "identity_file")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sshOptions = v2StringArray(params, "ssh_options") ?? []
        let autoConnect = v2Bool(params, "auto_connect") ?? true
        var relayPort: Int?
        if v2HasNonNullParam(params, "relay_port") {
            guard let parsedRelayPort = v2StrictInt(params, "relay_port"),
                  parsedRelayPort > 0,
                  parsedRelayPort <= 65535 else {
                return .err(code: "invalid_params", message: "relay_port must be 1-65535", data: nil)
            }
            relayPort = parsedRelayPort
        }
        let relayID = v2RawString(params, "relay_id")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayToken = v2RawString(params, "relay_token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let foregroundAuthToken = v2RawString(params, "foreground_auth_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let localSocketPath = v2RawString(params, "local_socket_path")
        let terminalStartupCommand = v2RawString(params, "terminal_startup_command")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if relayPort != nil {
            guard let relayID, !relayID.isEmpty else {
                return .err(code: "invalid_params", message: "relay_id is required when relay_port is set", data: nil)
            }
            guard let relayToken,
                  relayToken.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                return .err(code: "invalid_params", message: "relay_token must be 64 lowercase hex characters when relay_port is set", data: nil)
            }
        }

#if DEBUG
        dlog(
            "workspace.remote.configure.request workspace=\(workspaceId.uuidString.prefix(8)) " +
            "target=\(destination) port=\(sshPort.map(String.init) ?? "nil") " +
            "autoConnect=\(autoConnect ? 1 : 0) relayPort=\(relayPort.map(String.init) ?? "nil") " +
            "localSocket=\(localSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? localSocketPath! : "nil") " +
            "sshOptions=\(sshOptions.joined(separator: "|"))"
        )
#endif
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.configureRemoteConnection mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            let config = WorkspaceRemoteConfiguration(
                destination: destination,
                port: sshPort,
                identityFile: identityFile?.isEmpty == true ? nil : identityFile,
                sshOptions: sshOptions,
                localProxyPort: localProxyPort,
                relayPort: relayPort,
                relayID: relayID?.isEmpty == true ? nil : relayID,
                relayToken: relayToken?.isEmpty == true ? nil : relayToken,
                localSocketPath: localSocketPath,
                terminalStartupCommand: terminalStartupCommand?.isEmpty == true ? nil : terminalStartupCommand,
                foregroundAuthToken: foregroundAuthToken?.isEmpty == true ? nil : foregroundAuthToken
            )
            workspace.configureRemoteConnection(config, autoConnect: autoConnect)

            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteDisconnect(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return v2InvalidParam("workspace_id")
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        let clearConfiguration = v2Bool(params, "clear") ?? false
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because disconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            workspace.disconnectRemoteConnection(clearConfiguration: clearConfiguration)
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteReconnect(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return v2InvalidParam("workspace_id")
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because reconnect mutates TabManager/UI-owned workspace state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            guard workspace.remoteConfiguration != nil else {
                result = .err(code: "invalid_state", message: "Remote workspace is not configured", data: [
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                ])
                return
            }

            workspace.reconnectRemoteConnection()
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteForegroundAuthReady(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return v2InvalidParam("workspace_id")
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        let foregroundAuthToken = v2RawString(params, "foreground_auth_token")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because this may arm a pending connect or start reconnecting immediately.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }

            workspace.notifyRemoteForegroundAuthenticationReady(token: foregroundAuthToken)
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteStatus(params: [String: Any]) -> V2CallResult {
        let requestedWorkspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), requestedWorkspaceId == nil {
            return v2InvalidParam("workspace_id")
        }
        let fallbackTabManager = v2ResolveTabManager(params: params)
        let workspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
        guard let workspaceId else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
        ])

        // Must run on main for v2MainSync because Workspace.remoteStatusPayload reads TabManager/UI-owned state.
        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    func v2WorkspaceRemoteTerminalSessionEnd(params: [String: Any]) -> V2CallResult {
        guard let workspaceId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }
        guard let relayPort = v2StrictInt(params, "relay_port"),
              relayPort > 0,
              relayPort <= 65535 else {
            return v2InvalidParam("relay_port")
        }

        var result: V2CallResult = .err(code: "not_found", message: "Workspace not found", data: [
            "workspace_id": workspaceId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
            "surface_id": surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
            "relay_port": relayPort,
        ])

        v2MainSync {
            guard let owner = AppDelegate.shared?.tabManagerFor(tabId: workspaceId),
                  let workspace = owner.tabs.first(where: { $0.id == workspaceId }) else {
                return
            }
            workspace.markRemoteTerminalSessionEnded(surfaceId: surfaceId, relayPort: relayPort)
            let windowId = v2ResolveWindowId(tabManager: owner)
            result = .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "relay_port": relayPort,
                "remote": workspace.remoteStatusPayload(),
            ])
        }

        return result
    }

    // `surface.report_tty` and `surface.ports_kick` are high-frequency telemetry commands (see
    // CLAUDE.md "Socket command threading policy"): they must not block the calling socket
    // thread with `DispatchQueue.main.sync`. Both handlers now follow the same off-main-parse +
    // main.async-mutate shape as `v2ScheduleTelemetryMutation` callers (e.g. `workspace.set_status`,
    // `workspace.report_meta_block`) — surface resolution and the model mutation happen entirely
    // inside the async block, and the JSON-RPC response is an optimistic `ok` echoing the request
    // params, not the value resolved on main. Refs #82.
    func v2WorkspaceAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "pin", "unpin", "rename", "clear_name",
            "set_description", "clear_description",
            "move_up", "move_down", "move_top",
            "close_others", "close_above", "close_below",
            "mark_read", "mark_unread",
            "set_color", "clear_color"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown workspace action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            let requestedWorkspaceId = v2UUID(params, "workspace_id") ?? tabManager.selectedTabId
            guard let workspaceId = requestedWorkspaceId,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func closeWorkspaces(_ workspaces: [Workspace]) -> Int {
                var closed = 0
                for candidate in workspaces where candidate.id != workspace.id {
                    let existedBefore = tabManager.tabs.contains(where: { $0.id == candidate.id })
                    guard existedBefore else { continue }
                    tabManager.closeWorkspace(candidate)
                    if !tabManager.tabs.contains(where: { $0.id == candidate.id }) {
                        closed += 1
                    }
                }
                return closed
            }

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ]
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            switch action {
            case "pin":
                tabManager.setPinned(workspace, pinned: true)
                finish(["pinned": true])

            case "unpin":
                tabManager.setPinned(workspace, pinned: false)
                finish(["pinned": false])

            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = v2InvalidParam("title")
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                tabManager.setCustomTitle(tabId: workspace.id, title: title)
                finish(["title": title])

            case "clear_name":
                tabManager.clearCustomTitle(tabId: workspace.id)
                finish(["title": workspace.title])

            case "set_description":
                guard let descriptionRaw = v2String(params, "description"),
                      !descriptionRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = v2InvalidParam("description")
                    return
                }
                tabManager.setCustomDescription(tabId: workspace.id, description: descriptionRaw)
                finish(["description": v2OrNull(workspace.customDescription)])

            case "clear_description":
                tabManager.clearCustomDescription(tabId: workspace.id)
                finish(["description": NSNull()])

            case "move_up":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: max(currentIndex - 1, 0))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_down":
                guard let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: min(currentIndex + 1, tabManager.tabs.count - 1))
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "move_top":
                tabManager.moveTabToTop(workspace.id)
                finish(["index": v2OrNull(tabManager.tabs.firstIndex(where: { $0.id == workspace.id }))])

            case "close_others":
                let candidates = tabManager.tabs.filter { $0.id != workspace.id && !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_above":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates = Array(tabManager.tabs.prefix(index)).filter { !$0.isPinned }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "close_below":
                guard let index = tabManager.tabs.firstIndex(where: { $0.id == workspace.id }) else {
                    result = .err(code: "not_found", message: "Workspace not found", data: nil)
                    return
                }
                let candidates: [Workspace]
                if index + 1 < tabManager.tabs.count {
                    candidates = Array(tabManager.tabs.suffix(from: index + 1)).filter { !$0.isPinned }
                } else {
                    candidates = []
                }
                let closed = closeWorkspaces(candidates)
                finish(["closed": closed])

            case "mark_read":
                AppDelegate.shared?.notificationStore?.markRead(forTabId: workspace.id)
                finish()

            case "mark_unread":
                AppDelegate.shared?.notificationStore?.markUnread(forTabId: workspace.id)
                finish()

            case "set_color":
                guard let colorRaw = v2String(params, "color"),
                      !colorRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = v2InvalidParam("color")
                    return
                }
                let colorInput = colorRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                // Resolve named colors from the effective palette, including file-defined additions.
                let effectivePalette = WorkspaceTabColorSettings.palette()
                let hex: String
                if let entry = effectivePalette.first(where: {
                    $0.name.caseInsensitiveCompare(colorInput) == .orderedSame
                }) {
                    hex = entry.hex
                } else if let normalized = WorkspaceTabColorSettings.normalizedHex(colorInput) {
                    hex = normalized
                } else {
                    let colorNames = effectivePalette.map(\.name)
                    result = .err(code: "invalid_params", message: "Invalid color. Use a hex value (#RRGGBB) or a named color.", data: [
                        "named_colors": colorNames
                    ])
                    return
                }
                tabManager.setTabColor(tabId: workspace.id, color: hex)
                finish(["color": hex])

            case "clear_color":
                tabManager.setTabColor(tabId: workspace.id, color: nil)
                finish(["color": NSNull()])

            default:
                result = .err(code: "invalid_params", message: "Unknown workspace action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }

    func v2TabAction(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let action = v2ActionKey(params) else {
            return .err(code: "invalid_params", message: "Missing action", data: nil)
        }

        let supportedActions = [
            "rename", "clear_name",
            "close_left", "close_right", "close_others",
            "new_terminal_right", "new_browser_right",
            "reload", "duplicate",
            "pin", "unpin", "mark_read", "mark_unread"
        ]

        var result: V2CallResult = .err(code: "invalid_params", message: "Unknown tab action", data: [
            "action": action,
            "supported_actions": supportedActions
        ])

        v2MainSync {
            guard let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let surfaceId = v2UUID(params, "surface_id") ?? v2UUID(params, "tab_id") ?? workspace.focusedPanelId
            guard let surfaceId else {
                result = .err(code: "not_found", message: "No focused tab", data: nil)
                return
            }
            guard workspace.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Tab not found", data: [
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ])
                return
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)

            @MainActor
            func finish(_ extras: [String: Any] = [:]) {
                var payload: [String: Any] = [
                    "action": action,
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId),
                    "workspace_id": workspace.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "tab_id": surfaceId.uuidString,
                    "tab_ref": v2TabRef(uuid: surfaceId)
                ]
                if let paneId = workspace.paneId(forPanelId: surfaceId)?.id {
                    payload["pane_id"] = paneId.uuidString
                    payload["pane_ref"] = v2Ref(kind: .pane, uuid: paneId)
                } else {
                    payload["pane_id"] = NSNull()
                    payload["pane_ref"] = NSNull()
                }
                for (key, value) in extras {
                    payload[key] = value
                }
                result = .ok(payload)
            }

            @MainActor
            func insertionIndexToRight(anchorTabId: TabID, inPane paneId: PaneID) -> Int {
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
                let pinnedCount = tabs.reduce(into: 0) { count, tab in
                    if let panelId = workspace.panelIdFromSurfaceId(tab.id),
                       workspace.isPanelPinned(panelId) {
                        count += 1
                    }
                }
                let rawTarget = min(anchorIndex + 1, tabs.count)
                return max(rawTarget, pinnedCount)
            }

            @MainActor
            func closeTabs(_ tabIds: [TabID]) -> (closed: Int, skippedPinned: Int) {
                var closed = 0
                var skippedPinned = 0
                for tabId in tabIds {
                    guard let panelId = workspace.panelIdFromSurfaceId(tabId) else { continue }
                    if workspace.isPanelPinned(panelId) {
                        skippedPinned += 1
                        continue
                    }
                    if workspace.panels.count <= 1 {
                        break
                    }
                    if workspace.closePanel(panelId, force: true) {
                        closed += 1
                    }
                }
                return (closed, skippedPinned)
            }

            switch action {
            case "rename":
                guard let titleRaw = v2String(params, "title"),
                      !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    result = v2InvalidParam("title")
                    return
                }
                let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                workspace.setPanelCustomTitle(panelId: surfaceId, title: title)
                finish(["title": title])

            case "clear_name":
                workspace.setPanelCustomTitle(panelId: surfaceId, title: nil)
                finish()

            case "pin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: true)
                finish(["pinned": true])

            case "unpin":
                workspace.setPanelPinned(panelId: surfaceId, pinned: false)
                finish(["pinned": false])

            case "mark_read":
                workspace.markPanelRead(surfaceId)
                finish()

            case "mark_unread", "mark_as_unread":
                workspace.markPanelUnread(surfaceId)
                finish()

            case "reload", "reload_tab":
                guard let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Reload is only available for browser tabs", data: nil)
                    return
                }
                browserPanel.reload()
                finish()

            case "duplicate", "duplicate_tab":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId),
                      let browserPanel = workspace.browserPanel(for: surfaceId) else {
                    result = .err(code: "invalid_state", message: "Duplicate is only available for browser tabs", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(
                    inPane: paneId,
                    url: browserPanel.currentURL,
                    focus: true
                ) else {
                    result = .err(code: "internal_error", message: "Failed to duplicate tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_terminal_right", "new_terminal_to_right", "new_terminal_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newTerminalSurface(inPane: paneId, focus: true) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "new_browser_right", "new_browser_to_right", "new_browser_tab_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }

                let urlRaw = v2String(params, "url")
                let url = urlRaw.flatMap { URL(string: $0) }
                if urlRaw != nil && url == nil {
                    result = .err(code: "invalid_params", message: "Invalid URL", data: ["url": v2OrNull(urlRaw)])
                    return
                }

                let targetIndex = insertionIndexToRight(anchorTabId: anchorTabId, inPane: paneId)
                guard let newPanel = workspace.newBrowserSurface(inPane: paneId, url: url, focus: true) else {
                    result = .err(code: "internal_error", message: "Failed to create tab", data: nil)
                    return
                }
                _ = workspace.reorderSurface(panelId: newPanel.id, toIndex: targetIndex)
                finish([
                    "created_surface_id": newPanel.id.uuidString,
                    "created_surface_ref": v2Ref(kind: .surface, uuid: newPanel.id),
                    "created_tab_id": newPanel.id.uuidString,
                    "created_tab_ref": v2TabRef(uuid: newPanel.id)
                ])

            case "close_left", "close_to_left":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = Array(tabs.prefix(index).map(\.id))
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_right", "close_to_right":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let tabs = workspace.bonsplitController.tabs(inPane: paneId)
                guard let index = tabs.firstIndex(where: { $0.id == anchorTabId }) else {
                    result = .err(code: "not_found", message: "Tab not found in pane", data: nil)
                    return
                }
                let targetIds = (index + 1 < tabs.count) ? Array(tabs.suffix(from: index + 1).map(\.id)) : []
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            case "close_others", "close_other_tabs":
                guard let anchorTabId = workspace.surfaceIdFromPanelId(surfaceId),
                      let paneId = workspace.paneId(forPanelId: surfaceId) else {
                    result = .err(code: "not_found", message: "Tab pane not found", data: nil)
                    return
                }
                let targetIds = workspace.bonsplitController.tabs(inPane: paneId)
                    .map(\.id)
                    .filter { $0 != anchorTabId }
                let closeResult = closeTabs(targetIds)
                finish(["closed": closeResult.closed, "skipped_pinned": closeResult.skippedPinned])

            default:
                result = .err(code: "invalid_params", message: "Unknown tab action", data: [
                    "action": action,
                    "supported_actions": supportedActions
                ])
            }
        }

        return result
    }
}
