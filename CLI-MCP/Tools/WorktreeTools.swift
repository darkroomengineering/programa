import MCP

/// `worktree.*` tools other than `worktree.open` (a focus-stealing tool, see
/// `FocusTools.swift`). Handlers live in `Sources/TerminalController+Worktree.swift`.
enum WorktreeTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "worktree_create",
            socketMethod: V2MethodNames.worktreeCreate,
            description: "Creates a new git worktree for a branch and opens it as a new workspace. Never focuses the app -- worktree.create's underlying `focus` param is intentionally not exposed here, so this tool can never raise/activate the Programa window even if asked; use focus_worktree_open afterward if you need the window brought forward.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "repo": ProgramaToolSchema.string("Path to (or inside) the git repository to create the worktree in."),
                    "branch": ProgramaToolSchema.string("Branch name for the new worktree. Fails if this branch is already checked out elsewhere."),
                    "base": ProgramaToolSchema.string("Optional base ref/branch to create the new branch from."),
                    "layout": ProgramaToolSchema.string("Optional saved layout name (see layout_list) to apply to the new worktree's workspace."),
                    "path": ProgramaToolSchema.string("Optional explicit filesystem path for the new worktree. If omitted, a path is derived from the configured worktree directory, repo name, and branch."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["repo", "branch"]
            ),
            makeParams: { arguments in
                // Deliberately whitelist keys instead of forwarding `arguments` wholesale: this
                // guarantees a `focus` argument can never reach the socket for this tool, even
                // if a caller supplies one (it is not in the schema above, but nothing stops a
                // client from sending it anyway). worktree.create is the one tool where an agent must
                // not be able to move the user's focus.
                var params: [String: Any] = [:]
                for key in ["repo", "branch", "base", "layout", "path", "window_id", "workspace_id", "surface_id"] {
                    guard let value = arguments[key] else { continue }
                    if case .null = value { continue }
                    params[key] = ToolCatalog.valueToAny(value)
                }
                return params
            }
        ),
        ProgramaTool(
            name: "worktree_remove",
            socketMethod: V2MethodNames.worktreeRemove,
            description: "Removes a git worktree by path or branch, closing its workspace if open. Fails if the worktree has uncommitted changes unless force is set.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "repo": ProgramaToolSchema.string("Path to (or inside) the git repository the worktree belongs to."),
                    "path": ProgramaToolSchema.string("Worktree path to remove. Provide path or branch."),
                    "branch": ProgramaToolSchema.string("Worktree branch to remove. Provide path or branch."),
                    "force": ProgramaToolSchema.boolean("If true, remove even if the worktree has uncommitted changes. Defaults to false."),
                ],
                required: ["repo"]
            )
        ),
        ProgramaTool(
            name: "worktree_list",
            socketMethod: V2MethodNames.worktreeList,
            description: "Lists all git worktrees for a repository, with which ones are currently open as workspaces.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "repo": ProgramaToolSchema.string("Path to (or inside) the git repository to list worktrees for."),
                ],
                required: ["repo"]
            )
        ),
    ]
}
