// Extracted from TerminalController.swift (nuclear-review #96): notification.* command handlers.
import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit
import WebKit

extension TerminalController {
    // MARK: - V2 Notification Methods

    func v2NotificationCreate(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let explicitSurfaceId = v2UUID(params, "surface_id")
        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            if let explicitSurfaceId, ws.panels[explicitSurfaceId] == nil {
                result = .err(
                    code: "not_found",
                    message: "Surface not found",
                    data: ["surface_id": explicitSurfaceId.uuidString]
                )
                return
            }
            let surfaceId = explicitSurfaceId ?? ws.focusedPanelId
            TerminalNotificationStore.shared.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "surface_id": v2OrNull(surfaceId?.uuidString)])
        }
        return result
    }

    func v2NotificationCreateForSurface(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            TerminalNotificationStore.shared.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    func v2NotificationCreateForTarget(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let wsId = v2UUID(params, "workspace_id") else {
            return v2InvalidParam("workspace_id")
        }
        guard let surfaceId = v2UUID(params, "surface_id") else {
            return v2InvalidParam("surface_id")
        }

        let title = (params["title"] as? String) ?? "Notification"
        let subtitle = (params["subtitle"] as? String) ?? ""
        let body = (params["body"] as? String) ?? ""

        var result: V2CallResult = .err(code: "internal_error", message: "Failed to notify", data: nil)
        v2MainSync {
            guard let ws = tabManager.tabs.first(where: { $0.id == wsId }) else {
                result = .err(code: "not_found", message: "Workspace not found", data: ["workspace_id": wsId.uuidString])
                return
            }
            guard ws.panels[surfaceId] != nil else {
                result = .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
                return
            }
            TerminalNotificationStore.shared.addNotification(
                tabId: ws.id,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
            result = .ok(["workspace_id": ws.id.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id), "surface_id": surfaceId.uuidString, "surface_ref": v2Ref(kind: .surface, uuid: surfaceId), "window_id": v2OrNull(v2ResolveWindowId(tabManager: tabManager)?.uuidString), "window_ref": v2Ref(kind: .window, uuid: v2ResolveWindowId(tabManager: tabManager))])
        }
        return result
    }

    func v2NotificationList() -> [String: Any] {
        var items: [[String: Any]] = []
        DispatchQueue.main.sync {
            items = TerminalNotificationStore.shared.notifications.map { n in
                return [
                    "id": n.id.uuidString,
                    "workspace_id": n.tabId.uuidString,
                    "surface_id": v2OrNull(n.surfaceId?.uuidString),
                    "is_read": n.isRead,
                    "title": n.title,
                    "subtitle": n.subtitle,
                    "body": n.body
                ]
            }
        }
        return ["notifications": items]
    }

    /// Mirrors v1's `clear_notifications [--tab=X]`: with a `workspace_id`, scopes the clear
    /// to that workspace's notifications only; without one, clears all notifications globally.
    func v2NotificationClear(params: [String: Any]) -> V2CallResult {
        if let workspaceId = v2UUID(params, "workspace_id") {
            DispatchQueue.main.async {
                TerminalNotificationStore.shared.clearNotifications(forTabId: workspaceId)
            }
            return .ok(["workspace_id": workspaceId.uuidString, "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId)])
        }
        DispatchQueue.main.async {
            TerminalNotificationStore.shared.clearAll()
        }
        return .ok([:])
    }
}
