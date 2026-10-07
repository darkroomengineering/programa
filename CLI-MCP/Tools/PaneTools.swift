import MCP

/// `pane.*` tools other than `pane.focus`/`pane.last` (focus-stealing tools, see
/// `FocusTools.swift`). A "pane" is a split-tree leaf that can hold multiple surfaces as tabs.
/// Handlers live in `Sources/TerminalController+Pane.swift`.
enum PaneTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "pane_list",
            socketMethod: V2MethodNames.paneList,
            description: "Lists every pane in a workspace's split tree, with pixel geometry and terminal grid size.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "pane_surfaces",
            socketMethod: V2MethodNames.paneSurfaces,
            description: "Lists the surfaces (tabs) inside one pane, in display order.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "pane_id": ProgramaToolSchema.string("Pane UUID or short ref. Defaults to the workspace's focused pane."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "pane_create",
            socketMethod: V2MethodNames.paneCreate,
            description: "Splits the workspace's focused surface's pane in the given direction, creating a new pane with a new surface in it.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "direction": ProgramaToolSchema.stringEnum("Direction to split in.", ["left", "right", "up", "down"]),
                    "type": ProgramaToolSchema.stringEnum("Surface type to create in the new pane. Defaults to terminal.", ["terminal"]),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["direction"]
            )
        ),
        ProgramaTool(
            name: "pane_resize",
            socketMethod: V2MethodNames.paneResize,
            description: "Nudges a pane's split divider in one direction by an amount (in split-tree fractional units, clamped 0.1-0.9). Fails if the pane has no split ancestor of the matching orientation.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "direction": ProgramaToolSchema.stringEnum("Direction to grow the pane's border toward.", ["left", "right", "up", "down"]),
                    "amount": ProgramaToolSchema.integer("Resize amount, must be > 0. Defaults to 1."),
                    "pane_id": ProgramaToolSchema.string("Pane UUID or short ref to resize. Defaults to the workspace's focused pane."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["direction"]
            )
        ),
        ProgramaTool(
            name: "pane_swap",
            socketMethod: V2MethodNames.paneSwap,
            description: "Swaps the selected surfaces of two panes (searches all windows/workspaces for pane_id, so no routing context is needed).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "pane_id": ProgramaToolSchema.string("Source pane UUID or short ref."),
                    "target_pane_id": ProgramaToolSchema.string("Target pane UUID or short ref. Must differ from pane_id."),
                    "focus": ProgramaToolSchema.boolean("If true (default), focus the target pane after swapping."),
                ],
                required: ["pane_id", "target_pane_id"]
            )
        ),
        ProgramaTool(
            name: "pane_break",
            socketMethod: V2MethodNames.paneBreak,
            description: "Detaches a surface from its current pane and moves it into a brand-new workspace.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "pane_id": ProgramaToolSchema.string("Source pane UUID or short ref. Defaults to the workspace's focused pane."),
                "surface_id": ProgramaToolSchema.string("Explicit surface UUID or short ref to break out. Defaults to the source pane's selected surface."),
                "focus": ProgramaToolSchema.boolean("If true (default), select the new workspace after breaking out."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "pane_join",
            socketMethod: V2MethodNames.paneJoin,
            description: "Moves a surface into an existing target pane. Provide surface_id directly, or pane_id to use that pane's currently selected surface.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "target_pane_id": ProgramaToolSchema.string("Destination pane UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to move. Provide this or pane_id."),
                    "pane_id": ProgramaToolSchema.string("Source pane UUID or short ref; its currently selected surface is moved. Used only if surface_id is omitted."),
                    "focus": ProgramaToolSchema.boolean("If true, focus the destination after joining."),
                ],
                required: ["target_pane_id"]
            )
        ),
    ]
}
