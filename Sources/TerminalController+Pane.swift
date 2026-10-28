// pane.* command handlers.
import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit

extension TerminalController {
    // MARK: - V2 Pane Methods

    nonisolated func v2PaneList(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }

            let focusedPaneId = ws.bonsplitController.focusedPaneId
            let snapshot = ws.bonsplitController.layoutSnapshot()
            let geometryByPaneId = Dictionary(
                snapshot.panes.map { ($0.paneId, $0.frame) },
                uniquingKeysWith: { first, _ in first }
            )

            let panes: [[String: Any]] = ws.bonsplitController.allPaneIds.enumerated().map { index, paneId in
                let tabs = ws.bonsplitController.tabs(inPane: paneId)
                let surfaceUUIDs: [UUID] = tabs.compactMap { ws.panelIdFromSurfaceId($0.id) }
                let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
                let selectedSurfaceUUID = selectedTab.flatMap { ws.panelIdFromSurfaceId($0.id) }

                var dict: [String: Any] = [
                    "id": paneId.id.uuidString,
                    "ref": v2Ref(kind: .pane, uuid: paneId.id),
                    "index": index,
                    "focused": paneId == focusedPaneId,
                    "surface_ids": surfaceUUIDs.map { $0.uuidString },
                    "surface_refs": surfaceUUIDs.map { v2Ref(kind: .surface, uuid: $0) },
                    "selected_surface_id": v2OrNull(selectedSurfaceUUID?.uuidString),
                    "selected_surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceUUID),
                    "surface_count": surfaceUUIDs.count
                ]

                if let frame = geometryByPaneId[paneId.id.uuidString] {
                    dict["pixel_frame"] = [
                        "x": frame.x, "y": frame.y,
                        "width": frame.width, "height": frame.height
                    ]
                }

                // Get terminal grid size from the selected surface
                if let panelUUID = selectedSurfaceUUID,
                   let panel = ws.panels[panelUUID] as? TerminalPanel,
                   panel.surface.hasLiveSurface,
                   let ghosttySurface = panel.surface.surface {
                    let size = ghostty_surface_size(ghosttySurface)
                    if size.columns > 0 && size.rows > 0 {
                        dict["columns"] = Int(size.columns)
                        dict["rows"] = Int(size.rows)
                        dict["cell_width_px"] = Int(size.cell_width_px)
                        dict["cell_height_px"] = Int(size.cell_height_px)
                        // Cell size in layout points, the unit pane.resize takes for `amount`.
                        let scale = max(1, panel.hostedView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
                        dict["cell_width"] = Double(size.cell_width_px) / Double(scale)
                        dict["cell_height"] = Double(size.cell_height_px) / Double(scale)
                    }
                }

                return dict
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "panes": panes,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
            payload["container_frame"] = [
                "x": snapshot.containerFrame.x,
                "y": snapshot.containerFrame.y,
                "width": snapshot.containerFrame.width,
                "height": snapshot.containerFrame.height
            ]
            return .ok(payload)
        }
    }
    nonisolated func v2PaneFocus(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let paneUUID = v2UUID(params, "pane_id") else {
                return v2InvalidParam("pane_id")
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            guard let paneId = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                return .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
            }
            if let windowId = v2ResolveWindowId(tabManager: tabManager) {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(tabManager)
            }
            if tabManager.selectedTabId != ws.id {
                tabManager.selectWorkspace(ws)
            }
            ws.bonsplitController.focusPane(paneId)
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok(["window_id": v2OrNull(windowId?.uuidString), "window_ref": v2Ref(kind: .window, uuid: windowId), "workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "pane_id": paneId.id.uuidString, "pane_ref": v2Ref(kind: .pane, uuid: paneId.id)])
        }
    }

    nonisolated func v2PaneSurfaces(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Pane or workspace not found", data: nil)
            }

            let paneUUID: UUID?
            switch v2TargetPaneId(params, fallback: nil) {
            case .failed(let error): return error
            case .resolved(let id): paneUUID = id
            }
            let paneId: PaneID? = {
                if let paneUUID {
                    return ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID })
                }
                return ws.bonsplitController.focusedPaneId
            }()
            guard let paneId else {
                return .err(code: "not_found", message: "Pane or workspace not found", data: nil)
            }

            let selectedTab = ws.bonsplitController.selectedTab(inPane: paneId)
            let tabs = ws.bonsplitController.tabs(inPane: paneId)

            let surfaces: [[String: Any]] = tabs.enumerated().map { index, tab in
                let panelId = ws.panelIdFromSurfaceId(tab.id)
                let panel = panelId.flatMap { ws.panels[$0] }
                return [
                    "id": v2OrNull(panelId?.uuidString),
                    "ref": v2Ref(kind: .surface, uuid: panelId),
                    "index": index,
                    "title": tab.title,
                    "type": v2OrNull(panel?.panelType.rawValue),
                    "selected": tab.id == selectedTab?.id
                ]
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneId.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneId.id),
                "surfaces": surfaces,
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
    }
    nonisolated func v2PaneCreate(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let directionStr = v2String(params, "direction"),
                  let direction = parseSplitDirection(directionStr) else {
                return v2InvalidParam("direction (left|right|up|down)")
            }

            if params["type"] != nil && v2PanelType(params, "type") == nil {
                return v2InvalidParam("type")
            }

            let orientation = direction.orientation
            let insertFirst = direction.insertFirst

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: ws)
            guard let focusedPanelId = ws.focusedPanelId else {
                return .err(code: "not_found", message: "No focused surface to split", data: nil)
            }
            if let limitError = v2PaneLimitError(for: ws) {
                return limitError
            }

            let newPanelId: UUID?
            newPanelId = ws.newTerminalSplit(
                from: focusedPanelId,
                orientation: orientation,
                insertFirst: insertFirst,
                focus: v2FocusAllowed()
            )?.id

            guard let newPanelId else {
                return .err(code: "internal_error", message: "Failed to create pane", data: nil)
            }
            let paneUUID = ws.paneId(forPanelId: newPanelId)?.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": v2OrNull(paneUUID?.uuidString),
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "surface_id": newPanelId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: newPanelId),
                "type": PanelType.terminal.rawValue
            ])
        }
    }

    nonisolated func v2PaneResize(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }

            let directionRaw = (v2String(params, "direction") ?? "").lowercased()
            let amount: Int
            if v2HasNonNullParam(params, "amount") {
                guard let parsedAmount = v2Int(params, "amount") else {
                    return .err(code: "invalid_params", message: "amount must be an integer", data: nil)
                }
                amount = parsedAmount
            } else {
                amount = 1
            }
            guard let direction = ResizeDirection(rawValue: directionRaw), amount > 0 else {
                return .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }

            let paneTarget = v2TargetPaneId(params, fallback: ws.bonsplitController.focusedPaneId?.id)
            if case .failed(let error) = paneTarget { return error }
            guard case .resolved(let paneUUID?) = paneTarget else {
                return .err(code: "not_found", message: "No focused pane", data: nil)
            }
            let splitId: UUID
            let oldPosition: CGFloat
            let newPosition: CGFloat
            switch TabManager.resizePane(paneUUID, in: ws, direction: direction, amount: amount) {
            case .paneNotFound:
                return .err(code: "not_found", message: "Pane not found", data: ["pane_id": paneUUID.uuidString])
            case .paneNotInTree:
                return .err(code: "not_found", message: "Pane not found in split tree", data: ["pane_id": paneUUID.uuidString])
            case .noSplitAncestor:
                return .err(
                    code: "invalid_state",
                    message: "No \(direction.splitOrientation) split ancestor for pane",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
            case .noAdjacentBorder:
                return .err(
                    code: "invalid_state",
                    message: "Pane has no adjacent border in direction \(direction.rawValue)",
                    data: ["pane_id": paneUUID.uuidString, "direction": direction.rawValue]
                )
            case .setFailed(let failedSplitId):
                return .err(
                    code: "internal_error",
                    message: "Failed to set split divider position",
                    data: ["split_id": failedSplitId.uuidString]
                )
            case .resized(let resizedSplitId, let old, let new):
                (splitId, oldPosition, newPosition) = (resizedSplitId, old, new)
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": paneUUID.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: paneUUID),
                "split_id": splitId.uuidString,
                "direction": direction.rawValue,
                "amount": amount,
                "old_divider_position": oldPosition,
                "new_divider_position": newPosition
            ])
        }
    }

    nonisolated func v2PaneSwap(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let sourcePaneUUID = v2UUID(params, "pane_id") else {
                return v2InvalidParam("pane_id")
            }
            guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
                return v2InvalidParam("target_pane_id")
            }
            if sourcePaneUUID == targetPaneUUID {
                return .err(code: "invalid_params", message: "pane_id and target_pane_id must be different", data: nil)
            }
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

            guard let located = v2LocatePane(sourcePaneUUID) else {
                return .err(code: "not_found", message: "Source pane not found", data: ["pane_id": sourcePaneUUID.uuidString])
            }
            guard let targetPane = located.workspace.bonsplitController.allPaneIds.first(where: { $0.id == targetPaneUUID }) else {
                return .err(code: "not_found", message: "Target pane not found in source workspace", data: ["target_pane_id": targetPaneUUID.uuidString])
            }
            let workspace = located.workspace
            let sourcePane = located.paneId

            guard let selectedSourceTab = workspace.bonsplitController.selectedTab(inPane: sourcePane),
                  let selectedTargetTab = workspace.bonsplitController.selectedTab(inPane: targetPane),
                  let sourceSurfaceId = workspace.panelIdFromSurfaceId(selectedSourceTab.id),
                  let targetSurfaceId = workspace.panelIdFromSurfaceId(selectedTargetTab.id) else {
                return .err(code: "invalid_state", message: "Both panes must have a selected surface", data: nil)
            }

            // Keep pane identities stable during swap when one side has a single surface.
            var sourcePlaceholder: UUID?
            var targetPlaceholder: UUID?
            if workspace.bonsplitController.tabs(inPane: sourcePane).count <= 1 {
                sourcePlaceholder = workspace.newTerminalSurface(inPane: sourcePane, focus: false)?.id
                if sourcePlaceholder == nil {
                    return .err(code: "internal_error", message: "Failed to create source placeholder surface", data: nil)
                }
            }
            if workspace.bonsplitController.tabs(inPane: targetPane).count <= 1 {
                targetPlaceholder = workspace.newTerminalSurface(inPane: targetPane, focus: false)?.id
                if targetPlaceholder == nil {
                    return .err(code: "internal_error", message: "Failed to create target placeholder surface", data: nil)
                }
            }

            guard workspace.moveSurface(panelId: sourceSurfaceId, toPane: targetPane, focus: false) else {
                return .err(code: "internal_error", message: "Failed moving source surface into target pane", data: nil)
            }
            guard workspace.moveSurface(panelId: targetSurfaceId, toPane: sourcePane, focus: false) else {
                return .err(code: "internal_error", message: "Failed moving target surface into source pane", data: nil)
            }

            if let sourcePlaceholder {
                _ = workspace.closePanel(sourcePlaceholder, force: true)
            }
            if let targetPlaceholder {
                _ = workspace.closePanel(targetPlaceholder, force: true)
            }

            if focus {
                workspace.bonsplitController.focusPane(targetPane)
            }
            let windowId = located.windowId
            return .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": workspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: workspace.id),
                "pane_id": sourcePane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: sourcePane.id),
                "target_pane_id": targetPane.id.uuidString,
                "target_pane_ref": v2Ref(kind: .pane, uuid: targetPane.id),
                "source_surface_id": sourceSurfaceId.uuidString,
                "source_surface_ref": v2Ref(kind: .surface, uuid: sourceSurfaceId),
                "target_surface_id": targetSurfaceId.uuidString,
                "target_surface_ref": v2Ref(kind: .surface, uuid: targetSurfaceId)
            ])
        }
    }

    nonisolated func v2PaneBreak(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            let focus = v2FocusAllowed(requested: v2Bool(params, "focus") ?? true)

            guard let sourceWorkspace = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }

            let sourcePaneUUID: UUID?
            switch v2TargetPaneId(params, fallback: nil) {
            case .failed(let error): return error
            case .resolved(let id): sourcePaneUUID = id
            }
            let explicitSurfaceId: UUID?
            switch v2TargetSurfaceId(params, fallback: nil) {
            case .failed(let error): return error
            case .resolved(let id): explicitSurfaceId = id
            }
            let sourcePane: PaneID? = {
                if let sourcePaneUUID {
                    return sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0.id == sourcePaneUUID })
                }
                return sourceWorkspace.bonsplitController.focusedPaneId
            }()

            let surfaceId: UUID? = {
                if let explicitSurfaceId { return explicitSurfaceId }
                if let sourcePane,
                   let selected = sourceWorkspace.bonsplitController.selectedTab(inPane: sourcePane) {
                    return sourceWorkspace.panelIdFromSurfaceId(selected.id)
                }
                return sourceWorkspace.focusedPanelId
            }()
            guard let surfaceId else {
                return .err(code: "not_found", message: "No source surface to break", data: nil)
            }
            guard sourceWorkspace.panels[surfaceId] != nil else {
                return .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
            }
            let sourceIndex = sourceWorkspace.indexInPane(forPanelId: surfaceId)
            let sourcePaneForRollback = sourceWorkspace.paneId(forPanelId: surfaceId)

            guard let detached = sourceWorkspace.detachSurface(panelId: surfaceId) else {
                return .err(code: "internal_error", message: "Failed to detach source surface", data: nil)
            }
            let resolvedRollbackPane = sourcePaneForRollback.flatMap { pane in
                sourceWorkspace.bonsplitController.allPaneIds.first(where: { $0 == pane })
            } ?? sourceWorkspace.bonsplitController.focusedPaneId
                ?? sourceWorkspace.bonsplitController.allPaneIds.first
            let rollbackTarget = resolvedRollbackPane.map {
                Workspace.DetachedSurfaceAttachmentTarget(
                    workspace: sourceWorkspace,
                    paneId: $0,
                    index: sourceIndex,
                    focus: v2FocusAllowed()
                )
            }

            let destinationWorkspace = tabManager.addWorkspace(select: focus)
            guard let destinationPane = destinationWorkspace.bonsplitController.focusedPaneId
                ?? destinationWorkspace.bonsplitController.allPaneIds.first else {
                if let rollbackTarget {
                    _ = detached.resolve(primary: rollbackTarget, rollback: nil)
                } else {
                    detached.finalizePermanently()
                }
                return .err(code: "internal_error", message: "Destination workspace has no pane", data: nil)
            }

            let attachmentResult = detached.resolve(
                primary: Workspace.DetachedSurfaceAttachmentTarget(
                    workspace: destinationWorkspace,
                    paneId: destinationPane,
                    index: nil,
                    focus: focus
                ),
                rollback: rollbackTarget
            )
            guard case .attachedPrimary = attachmentResult else {
                return .err(code: "internal_error", message: "Failed to attach surface to new workspace", data: nil)
            }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": destinationWorkspace.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: destinationWorkspace.id),
                "pane_id": destinationPane.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: destinationPane.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId)
            ])
        }
    }

    nonisolated func v2PaneJoin(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let targetPaneUUID = v2UUID(params, "target_pane_id") else {
                return v2InvalidParam("target_pane_id")
            }

            var surfaceId: UUID?
            switch v2TargetSurfaceId(params, fallback: nil) {
            case .failed(let error): return error
            case .resolved(let id): surfaceId = id
            }
            let sourcePaneUUID: UUID?
            switch v2TargetPaneId(params, fallback: nil) {
            case .failed(let error): return error
            case .resolved(let id): sourcePaneUUID = id
            }
            if surfaceId == nil, let sourcePaneUUID {
                guard let sourceLocated = v2LocatePane(sourcePaneUUID),
                      let selected = sourceLocated.workspace.bonsplitController.selectedTab(inPane: sourceLocated.paneId),
                      let selectedSurface = sourceLocated.workspace.panelIdFromSurfaceId(selected.id) else {
                    return .err(code: "not_found", message: "Unable to resolve selected surface in source pane", data: [
                        "pane_id": sourcePaneUUID.uuidString
                    ])
                }
                surfaceId = selectedSurface
            }
            guard let surfaceId else {
                return .err(code: "invalid_params", message: "Missing surface_id (or pane_id with selected surface)", data: nil)
            }

            var moveParams: [String: Any] = [
                "surface_id": surfaceId.uuidString,
                "pane_id": targetPaneUUID.uuidString
            ]
            if let focus = v2Bool(params, "focus") {
                moveParams["focus"] = focus
            }
            return v2SurfaceMove(params: moveParams)
        }
    }

    nonisolated func v2PaneLast(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            guard let focused = ws.bonsplitController.focusedPaneId else {
                return .err(code: "not_found", message: "No focused pane", data: nil)
            }
            guard let target = ws.bonsplitController.allPaneIds.first(where: { $0.id != focused.id }) else {
                return .err(code: "not_found", message: "No alternate pane available", data: nil)
            }

            ws.bonsplitController.focusPane(target)
            let selectedSurfaceId = ws.bonsplitController.selectedTab(inPane: target).flatMap { ws.panelIdFromSurfaceId($0.id) }
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": target.id.uuidString,
                "pane_ref": v2Ref(kind: .pane, uuid: target.id),
                "surface_id": v2OrNull(selectedSurfaceId?.uuidString),
                "surface_ref": v2Ref(kind: .surface, uuid: selectedSurfaceId)
            ])
        }
    }
}
