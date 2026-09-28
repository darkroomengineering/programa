import MCP

/// `system.*` tools: health check, capability introspection, caller identity, and the full
/// window/workspace/pane/surface tree in one call. Handlers live in
/// `Sources/TerminalController+System.swift`.
enum SystemTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "system_ping",
            socketMethod: V2MethodNames.systemPing,
            description: "Health check against the running Programa app over its control socket; returns pong.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "system_capabilities",
            socketMethod: V2MethodNames.systemCapabilities,
            description: "Reports the running Programa app's socket protocol capabilities (supported command families and limits).",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "system_identify",
            socketMethod: V2MethodNames.systemIdentify,
            description: "Resolves the socket's own identity: the currently focused window/workspace/pane/surface, and (optionally) validates a caller-supplied location.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "caller": ["type": "object", "description": .string("Optional caller location to validate, e.g. { \"workspace_id\": \"...\", \"surface_id\": \"...\" }.")],
            ])
        ),
        ProgramaTool(
            name: "system_tree",
            socketMethod: V2MethodNames.systemTree,
            description: "Returns the full window -> workspace -> pane -> surface tree (optionally scoped to one workspace or all windows). The primary read tool for understanding current app layout.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "workspace_id": ProgramaToolSchema.string("Optional workspace UUID or short ref to scope the tree to a single workspace (returns just that workspace's window/pane/surface subtree)."),
                "all_windows": ProgramaToolSchema.boolean("If true, include every window's workspaces instead of only the focused/default window. Defaults to false."),
                "caller": ["type": "object", "description": .string("Optional caller location to validate and echo back in the response's \"caller\" field.")],
            ])
        ),
    ]
}
