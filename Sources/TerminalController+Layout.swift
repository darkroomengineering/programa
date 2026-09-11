// Named layout configs (docs/plans/worktree-and-layouts.md): v2 socket handlers for
// `layout.save/apply/list`. `ProgramaLayoutStore` is `@MainActor` (mirrors `ProgramaConfigStore`,
// which does its small-file JSON I/O on the main thread too) -- every access here goes through
// `v2MainSync`, matching the socket threading policy in CLAUDE.md (parse/validate off-main,
// minimal main-actor mutation only where required).
import Foundation

extension TerminalController {
    // MARK: - V2 Layout Methods

    nonisolated func v2LayoutSave(params: [String: Any]) -> V2CallResult {
        let name = v2String(params, "name")
        let force = v2Bool(params, "force") ?? false

        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let name else { return v2InvalidParam("name") }
            guard let workspace = tabManager.selectedWorkspace else {
                return .err(code: "no_active_workspace", message: "No active workspace with capturable panes to save", data: nil)
            }
            guard let node = workspace.captureCustomLayout() else {
                return .err(code: "no_active_workspace", message: "No active workspace with capturable panes to save", data: nil)
            }

            let saveResult: Result<String, Error> = Result {
                try ProgramaLayoutStore.shared.save(name: name, layout: node, force: force)
            }
            switch saveResult {
            case .success(let path):
                return .ok(["name": name, "path": path])
            case .failure(let error):
                switch error {
                case ProgramaLayoutStoreError.alreadyExists:
                    return .err(code: "already_exists", message: "A layout named '\(name)' already exists", data: nil)
                case ProgramaLayoutStoreError.invalidName:
                    return .err(code: "invalid_name", message: "Layout name must be non-empty and must not contain '/'", data: nil)
                default:
                    return .err(code: "internal_error", message: String(describing: error), data: nil)
                }
            }
        }
    }

    nonisolated func v2LayoutApply(params: [String: Any], layoutStore: ProgramaLayoutStore? = nil) -> V2CallResult {
        let name = v2String(params, "name")
        let cwdParam = v2String(params, "cwd")
        let workspaceId = v2UUID(params, "workspace_id")
        if v2HasNonNullParam(params, "workspace_id"), workspaceId == nil {
            return v2InvalidParam("workspace_id")
        }

        return v2MainSync {
            guard let tabManager = v2ResolveTabManager(params: params) else {
                return .err(code: "unavailable", message: "TabManager not available", data: nil)
            }
            guard let name else { return v2InvalidParam("name") }
            guard let saved = (layoutStore ?? .shared).load(name: name) else {
                return .err(code: "not_found", message: "No saved layout named '\(name)'", data: nil)
            }

            if let workspaceId {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                    return .err(code: "not_found", message: "Workspace not found", data: nil)
                }
                guard workspace.isPristineForCustomLayout else {
                    return .err(
                        code: "invalid_state",
                        message: "An existing layout target must contain one unused terminal. Omit workspace_id to create a new workspace.",
                        data: nil
                    )
                }
                workspace.applyCustomLayout(saved.layout, baseCwd: cwdParam ?? workspace.currentDirectory)
                let windowId = v2ResolveWindowId(tabManager: tabManager)
                return .ok([
                    "workspace_id": workspaceId.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceId),
                    "window_id": v2OrNull(windowId?.uuidString),
                    "window_ref": v2Ref(kind: .window, uuid: windowId)
                ])
            }

            // No target workspace given: create a new one (never focused -- layout.apply is a
            // data operation, not a focus-intent v2 method). Relative `cwd`s in the saved layout
            // resolve against this new workspace's own root, which is what makes
            // `worktree create --layout`'s worktree-relative resolution work the same way.
            let workspace = tabManager.addWorkspace(workingDirectory: cwdParam, select: false, eagerLoadTerminal: true)
            workspace.applyCustomLayout(saved.layout, baseCwd: workspace.currentDirectory)
            let newId = workspace.id
            let windowId = v2ResolveWindowId(tabManager: tabManager)
            return .ok([
                "workspace_id": newId.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
                "window_id": v2OrNull(windowId?.uuidString),
                "window_ref": v2Ref(kind: .window, uuid: windowId)
            ])
        }
    }

    nonisolated func v2LayoutList(params: [String: Any]) -> V2CallResult {
        let summaries = v2MainSync {
            ProgramaLayoutStore.shared.list()
        }
        let isoFormatter = ISO8601DateFormatter()
        let layouts: [[String: Any]] = summaries.map { summary in
            ["name": summary.name, "saved_at": isoFormatter.string(from: summary.savedAt)]
        }
        return .ok(["layouts": layouts])
    }
}
