import Foundation

extension TerminalController {
    /// `surface.send_paste`: delivers `text` to a terminal as one paste and never presses Return,
    /// so an agent prompt keeps the text as a draft the user can keep editing. `surface.send_text`
    /// turns each newline into a Return key, which submits in agent TUIs.
    ///
    /// Threading: runs on main like `surface.send_text`. It is a user-initiated input command, not
    /// a telemetry path, and resolving the panel and writing to the Ghostty surface both touch
    /// main-actor UI state.
    nonisolated func v2SurfaceSendPaste(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let text = params["text"] as? String else {
                return .err(code: "invalid_params", message: "Missing text", data: nil)
            }
            guard !text.isEmpty else {
                return .err(code: "invalid_params", message: "text must not be empty", data: nil)
            }
            let ws: Workspace
            let surfaceId: UUID
            let terminalPanel: TerminalPanel
            switch v2ResolveTerminalTarget(params: params, tabManager: tabManager) {
            case .failed(let error):
                return error
            case .resolved(let target):
                (ws, surfaceId, terminalPanel) = target
            }

            let queued = terminalPanel.surface.surface == nil
            terminalPanel.surface.sendPaste(text)
            if !queued {
                terminalPanel.surface.forceRefresh(reason: "terminalController.v2SurfaceSendPaste")
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            var payload: [String: Any] = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ]
            // The surface was not attached: the paste waits in the panel's pending queue.
            if queued { payload["queued"] = true }
            return .ok(payload)
        }
    }
}
