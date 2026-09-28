import MCP

/// `snapshot.*` tools: browse and restore archived session snapshots (window/workspace/panel
/// history written on app launch). Handlers live in `Sources/TerminalController+Snapshot.swift`.
enum SnapshotTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "snapshot_list",
            socketMethod: V2MethodNames.snapshotList,
            description: "Lists archived session snapshots (past app sessions) with window/workspace/panel counts and save timestamps.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "snapshot_restore",
            socketMethod: V2MethodNames.snapshotRestore,
            description: "Restores an archived session snapshot by recreating its windows/workspaces/panels. Creates new windows; does not replace the current session.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "id": ProgramaToolSchema.string("Snapshot id to restore, or \"latest\" for the most recent archived snapshot. Defaults to latest if omitted."),
            ])
        ),
    ]
}
