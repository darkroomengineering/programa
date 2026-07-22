// Named layout configs (docs/plans/worktree-and-layouts.md): v2 socket handlers for
// `layout.save/apply/list`. `ProgramaLayoutStore` is `@MainActor` (mirrors `ProgramaConfigStore`,
// which does its small-file JSON I/O on the main thread too) -- every access here goes through
// `v2MainSync`, matching the socket threading policy in CLAUDE.md (parse/validate off-main,
// minimal main-actor mutation only where required).
import Foundation

extension TerminalController {
    // MARK: - V2 Layout Methods

    func v2LayoutSave(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let name = v2String(params, "name") else {
            return v2InvalidParam("name")
        }
        let force = v2Bool(params, "force") ?? false

        let captureResult: Result<ProgramaLayoutNode, ProgramaLayoutStoreError> = v2MainSync {
            guard let workspace = tabManager.selectedWorkspace else {
                return .failure(.noActiveWorkspace)
            }
            guard let node = workspace.captureCustomLayout() else {
                return .failure(.noActiveWorkspace)
            }
            return .success(node)
        }

        let layoutNode: ProgramaLayoutNode
        switch captureResult {
        case .success(let node):
            layoutNode = node
        case .failure:
            return .err(code: "no_active_workspace", message: "No active workspace with capturable panes to save", data: nil)
        }

        let saveResult: Result<String, Error> = v2MainSync {
            Result { try ProgramaLayoutStore.shared.save(name: name, layout: layoutNode, force: force) }
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

    func v2LayoutApply(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let name = v2String(params, "name") else {
            return v2InvalidParam("name")
        }
        guard let saved = v2MainSync({ ProgramaLayoutStore.shared.load(name: name) }) else {
            return .err(code: "not_found", message: "No saved layout named '\(name)'", data: nil)
        }
        let cwdParam = v2String(params, "cwd")

        if let workspaceId = v2UUID(params, "workspace_id") {
            let applied: Bool = v2MainSync {
                guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return false }
                workspace.applyCustomLayout(saved.layout, baseCwd: cwdParam ?? workspace.currentDirectory)
                return true
            }
            guard applied else {
                return .err(code: "not_found", message: "Workspace not found", data: nil)
            }
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
        var newId: UUID?
        v2MainSync {
            let workspace = tabManager.addWorkspace(workingDirectory: cwdParam, select: false, eagerLoadTerminal: true)
            workspace.applyCustomLayout(saved.layout, baseCwd: workspace.currentDirectory)
            newId = workspace.id
        }
        guard let newId else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        let windowId = v2ResolveWindowId(tabManager: tabManager)
        return .ok([
            "workspace_id": newId.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: newId),
            "window_id": v2OrNull(windowId?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowId)
        ])
    }

    func v2LayoutList(params: [String: Any]) -> V2CallResult {
        let isoFormatter = ISO8601DateFormatter()
        let layouts: [[String: Any]] = v2MainSync {
            ProgramaLayoutStore.shared.list().map { summary in
                ["name": summary.name, "saved_at": isoFormatter.string(from: summary.savedAt)]
            }
        }
        return .ok(["layouts": layouts])
    }
}
