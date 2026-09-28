import MCP

/// `layout.*` tools: save/apply/list named split-pane layouts. Handlers live in
/// `Sources/TerminalController+Layout.swift`.
enum LayoutTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "layout_save",
            socketMethod: V2MethodNames.layoutSave,
            description: "Saves the current workspace's pane/split layout under a name for later reuse with layout_apply.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "name": ProgramaToolSchema.string("Name to save the layout under."),
                    "force": ProgramaToolSchema.boolean("If true, overwrite an existing layout with the same name. Defaults to false."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["name"]
            )
        ),
        ProgramaTool(
            name: "layout_apply",
            socketMethod: V2MethodNames.layoutApply,
            description: "Applies a previously saved named layout, either to an existing workspace or by creating a new one.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "name": ProgramaToolSchema.string("Name of the saved layout to apply."),
                    "workspace_id": ProgramaToolSchema.string("Existing workspace UUID or short ref to apply the layout to. If omitted, a new workspace is created for it."),
                    "cwd": ProgramaToolSchema.string("Base directory to resolve relative paths in the layout against."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["name"]
            )
        ),
        ProgramaTool(
            name: "layout_list",
            socketMethod: V2MethodNames.layoutList,
            description: "Lists all saved named layouts with their save timestamps.",
            inputSchema: ProgramaToolSchema.empty
        ),
    ]
}
