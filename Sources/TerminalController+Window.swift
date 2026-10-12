// window.* command handlers.
import AppKit
import Carbon.HIToolbox
import Foundation
import Bonsplit

extension TerminalController {
    // MARK: - V2 Window Methods

    nonisolated func v2WindowList(params _: [String: Any]) -> V2CallResult {
        let windows = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        let payload: [[String: Any]] = windows.enumerated().map { index, item in
            return [
                "id": item.windowId.uuidString,
                "ref": v2Ref(kind: .window, uuid: item.windowId),
                "index": index,
                "key": item.isKeyWindow,
                "visible": item.isVisible,
                "workspace_count": item.workspaceCount,
                "selected_workspace_id": v2OrNull(item.selectedWorkspaceId?.uuidString),
                "selected_workspace_ref": v2Ref(kind: .workspace, uuid: item.selectedWorkspaceId)
            ]
        }
        return .ok(["windows": payload])
    }

    nonisolated func v2WindowCurrent(params _: [String: Any]) -> V2CallResult {
        enum Resolution {
            case unavailable
            case notFound
            case found(UUID)
        }
        let resolution: Resolution = v2MainSync {
            guard let tabManager = self.tabManager else { return .unavailable }
            guard let windowId = self.v2ResolveWindowId(tabManager: tabManager) else { return .notFound }
            return .found(windowId)
        }
        switch resolution {
        case .unavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .notFound:
            return .err(code: "not_found", message: "Current window not found", data: nil)
        case .found(let windowId):
            return .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
    }

    nonisolated func v2WindowFocus(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return v2InvalidParam("window_id")
        }
        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }

    nonisolated func v2WindowCreate(params _: [String: Any]) -> V2CallResult {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return .err(code: "internal_error", message: "Failed to create window", data: nil)
        }
        // The new window should become key, but setActiveTabManager defensively.
        v2MainSync {
            if let tm = AppDelegate.shared?.tabManagerFor(windowId: windowId) {
                self.setActiveTabManager(tm)
            }
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    nonisolated func v2WindowClose(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return v2InvalidParam("window_id")
        }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok
            ? .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
            : .err(code: "not_found", message: "Window not found", data: [
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
    }
}
