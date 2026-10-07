import MCP

/// Every focus-stealing v2 socket method exposed as an MCP tool, gathered in one file so the
/// full focus-stealing surface is auditable at a glance (the naming convention -- `focus_`
/// prefix instead of the usual dot-to-underscore method name -- exists for the same reason:
/// the tool name alone should warn an agent before it calls one).
///
/// This is the authoritative `focusIntentV2Methods` set (`Sources/TerminalController.swift:157-
/// 175`) filtered to the in-scope catalog -- exactly 10 methods. `worktree.create` is
/// also in `focusIntentV2Methods` but is deliberately NOT here: it only focuses when its
/// `focus` param is explicitly set to `true` (default `false`, `Sources/TerminalController+
/// Worktree.swift:43`), and `WorktreeTools.swift`'s `worktree_create` tool omits that param
/// from its schema entirely so it can never raise the window -- see the comment there.
enum FocusTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "focus_window",
            socketMethod: V2MethodNames.windowFocus,
            description: "Brings a window to the front and makes it key. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "window_id": ProgramaToolSchema.string("Window UUID or short ref to focus."),
                ],
                required: ["window_id"]
            )
        ),
        ProgramaTool(
            name: "focus_workspace_select",
            socketMethod: V2MethodNames.workspaceSelect,
            description: "Selects a workspace (sidebar tab) and brings its window forward. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to select."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "focus_workspace_next",
            socketMethod: V2MethodNames.workspaceNext,
            description: "Selects the next workspace (sidebar tab) and brings its window forward. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "focus_workspace_previous",
            socketMethod: V2MethodNames.workspacePrevious,
            description: "Selects the previous workspace (sidebar tab) and brings its window forward. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "focus_workspace_last",
            socketMethod: V2MethodNames.workspaceLast,
            description: "Navigates back to the previously selected workspace and brings its window forward. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "focus_surface",
            socketMethod: V2MethodNames.surfaceFocus,
            description: "Focuses a specific surface (pane content), selecting its workspace and bringing its window forward. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to focus."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "focus_pane",
            socketMethod: V2MethodNames.paneFocus,
            description: "Focuses a specific pane, selecting its workspace and bringing its window forward. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "pane_id": ProgramaToolSchema.string("Pane UUID or short ref to focus."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["pane_id"]
            )
        ),
        ProgramaTool(
            name: "focus_pane_last",
            socketMethod: V2MethodNames.paneLast,
            description: "Focuses the workspace's alternate (non-focused) pane. This tool may raise/activate the Programa window.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "focus_review_open",
            socketMethod: V2MethodNames.reviewOpen,
            description: "Opens a diff review panel as a new split next to a surface. This tool may raise/activate the Programa window only if focus is set to true (defaults to false).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "mode": ProgramaToolSchema.stringEnum("What to diff. Defaults to uncommitted.", ["uncommitted", "branch"]),
                "base_branch": ProgramaToolSchema.string("Base branch to diff against when mode is branch. Defaults to origin/main."),
                "direction": ProgramaToolSchema.stringEnum("Which side of the source surface to open the review split on. Defaults to right.", ["left", "right", "up", "down"]),
                "focus": ProgramaToolSchema.boolean("If true, select the workspace and bring its window forward. Defaults to false (this is what makes this tool's window-raising conditional)."),
                "surface_id": ProgramaToolSchema.string("Source surface UUID or short ref to review. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "focus_worktree_open",
            socketMethod: V2MethodNames.worktreeOpen,
            description: "Opens an existing git worktree as a workspace (creating one if it doesn't exist yet, matching worktree_create's defaults). This tool may raise/activate the Programa window only if focus is set to true (defaults to false).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "repo": ProgramaToolSchema.string("Path to (or inside) the git repository the worktree belongs to."),
                    "path": ProgramaToolSchema.string("Worktree path to open. Provide path or branch."),
                    "branch": ProgramaToolSchema.string("Worktree branch to open. Provide path or branch."),
                    "focus": ProgramaToolSchema.boolean("If true, select the workspace and bring its window forward. Defaults to false (this is what makes this tool's window-raising conditional)."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["repo"]
            )
        ),
    ]
}
