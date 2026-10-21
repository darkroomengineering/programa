import Foundation

extension TerminalController {
    /// `surface.send_if_unchanged`: sends `text` and then `keys` only when the fingerprint of the
    /// text `surface.read_text` would return for the same target and `lines`/`scrollback` still
    /// equals `expected_fingerprint`. Otherwise returns `mismatch` and sends nothing.
    ///
    /// Threading: runs on main. It is user-intent input, and the read, the comparison and the
    /// sends must happen in one main-actor pass so no other socket command or terminal update
    /// can interleave between the check and the input it guards.
    nonisolated func v2SurfaceSendIfUnchanged(params: [String: Any]) -> V2CallResult {
        v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let readOptions = v2ReadTextOptions(params) else {
                return .err(code: "invalid_params", message: "lines must be greater than 0", data: nil)
            }
            guard let expected = v2String(params, "expected_fingerprint")?.lowercased() else {
                return .err(code: "invalid_params", message: "Missing expected_fingerprint", data: nil)
            }
            if params["text"] != nil, !(params["text"] is String) {
                return .err(code: "invalid_params", message: "text must be a string", data: nil)
            }
            let text = (params["text"] as? String) ?? ""
            let keys: [String]
            if let rawKeys = params["keys"] {
                guard let parsed = rawKeys as? [String] else {
                    return .err(code: "invalid_params", message: "keys must be an array of key names", data: nil)
                }
                keys = parsed
            } else {
                keys = []
            }
            guard !text.isEmpty || !keys.isEmpty else {
                return .err(code: "invalid_params", message: "Provide text or keys", data: nil)
            }

            guard let ws = v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
            let surfaceId: UUID?
            if params["surface_id"] != nil {
                surfaceId = v2UUID(params, "surface_id")
                guard surfaceId != nil else {
                    return .err(code: "not_found", message: "Surface not found for the given surface_id", data: nil)
                }
            } else {
                surfaceId = ws.focusedPanelId
            }
            guard let surfaceId else {
                return .err(code: "not_found", message: "No focused surface", data: nil)
            }
            guard let panel = ws.panels[surfaceId] else {
                return .err(code: "not_found", message: "Surface not found", data: ["surface_id": surfaceId.uuidString])
            }
            guard let terminalPanel = panel as? TerminalPanel else {
                return .err(code: "invalid_params", message: "Surface is not a terminal", data: ["surface_id": surfaceId.uuidString])
            }
            if let unknown = keys.first(where: { !terminalPanel.surface.isKnownNamedKey($0) }) {
                return .err(code: "invalid_params", message: "Unknown key", data: ["key": unknown])
            }

            let current: String
            switch v2ReadSurfaceText(terminalPanel: terminalPanel, options: readOptions) {
            case .success(let read):
                current = Self.v2TextFingerprint(read.text)
            case .failure(let failure):
                return .err(code: "internal_error", message: failure.message, data: nil)
            }
            guard current == expected else {
                return .err(
                    code: "mismatch",
                    message: "Surface text changed since the fingerprint was read",
                    data: ["current_fingerprint": current, "surface_id": surfaceId.uuidString]
                )
            }

            // The read above succeeds only on an attached surface, so nothing here is queued.
            if !text.isEmpty {
                _ = v2DeliverSocketText(text, to: terminalPanel, reason: "terminalController.v2SurfaceSendIfUnchanged")
            }
            for key in keys {
                _ = v2DeliverNamedKey(key, to: terminalPanel, reason: "terminalController.v2SurfaceSendIfUnchanged")
            }

            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "fingerprint": current,
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
    }
}
