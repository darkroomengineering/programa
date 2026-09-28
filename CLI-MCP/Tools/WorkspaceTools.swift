import MCP

/// `workspace.*` tools other than the four focus-stealing ones (`workspace.select/next/
/// previous/last`, exposed as `focus_workspace_*` in `FocusTools.swift`). Handlers live in
/// `Sources/TerminalController+Workspace.swift` (CRUD/reorder/action) and
/// `Sources/TerminalController+Telemetry.swift` (status/log/progress/sidebar metadata).
enum WorkspaceTools {
    private static let workspaceActionValues = [
        "pin", "unpin", "rename", "clear_name",
        "set_description", "clear_description",
        "move_up", "move_down", "move_top",
        "close_others", "close_above", "close_below",
        "mark_read", "mark_unread",
        "set_color", "clear_color",
    ]

    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "workspace_list",
            socketMethod: V2MethodNames.workspaceList,
            description: "Lists every workspace (sidebar tab) in a window, in display order, with pin/selection/remote status.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_create",
            socketMethod: V2MethodNames.workspaceCreate,
            description: "Creates a new workspace (sidebar tab) with its own terminal.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "working_directory": ProgramaToolSchema.string("Starting directory for the new workspace's terminal. Takes priority over cwd if both are set."),
                "cwd": ProgramaToolSchema.string("Alias for working_directory, used only if working_directory is omitted."),
                "initial_command": ProgramaToolSchema.string("Shell command to run immediately in the new workspace's terminal."),
                "initial_env": ProgramaToolSchema.stringMap("Extra environment variables to set for the new workspace's terminal."),
                "title": ProgramaToolSchema.string("Custom title for the new workspace."),
                "description": ProgramaToolSchema.string("Custom description for the new workspace."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "agent_spawn",
            socketMethod: V2MethodNames.agentSpawn,
            description: "Starts a helper in a nested workspace that shares the parent folder. Set needs_isolation only when the helper needs its own git worktree.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "parent_workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref that owns the helper."),
                    "parent_agent_id": ProgramaToolSchema.string("Optional parent helper UUID for nested helper tasks."),
                    "host": ProgramaToolSchema.string("Short host name, such as codex or claude."),
                    "session": ProgramaToolSchema.string("Optional host session identifier."),
                    "task": ProgramaToolSchema.string("Short description used as the automatic workspace name."),
                    "role": ProgramaToolSchema.string("Optional helper role, such as reviewer or tester."),
                    "initial_command": ProgramaToolSchema.string("Command to run in the helper terminal."),
                    "initial_env": ProgramaToolSchema.stringMap("Environment variables for a shared-folder helper. Not supported with a separate worktree."),
                    "needs_isolation": ProgramaToolSchema.boolean("Create a separate git worktree. Requires repository_path and branch."),
                    "repository_path": ProgramaToolSchema.string("Path to or inside the repository when a separate worktree is requested."),
                    "branch": ProgramaToolSchema.string("Branch for the separate worktree."),
                    "base": ProgramaToolSchema.string("Optional base ref for a new worktree branch."),
                    "layout": ProgramaToolSchema.string("Optional saved layout for the worktree workspace."),
                ],
                required: ["parent_workspace_id"]
            )
        ),
        ProgramaTool(
            name: "agent_task_start",
            socketMethod: V2MethodNames.agentTaskStart,
            description: "Reports a helper that is already running, including helpers that run inside their parent and share its output.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref that owns the helper."),
                    "agent_id": ProgramaToolSchema.string("Optional stable helper UUID. Programa creates one when omitted."),
                    "parent_id": ProgramaToolSchema.string("Optional parent helper UUID."),
                    "surface_id": ProgramaToolSchema.string("Optional terminal surface UUID owned by the workspace."),
                    "host": ProgramaToolSchema.string("Host name, such as codex or claude."),
                    "session": ProgramaToolSchema.string("Optional host session identifier."),
                    "task": ProgramaToolSchema.string("Short task description."),
                    "role": ProgramaToolSchema.string("Optional helper role."),
                    "state": ProgramaToolSchema.stringEnum("Current helper state.", ["idle", "working", "blocked", "completed", "failed", "cancelled"]),
                    "placement": ProgramaToolSchema.stringEnum("Where the helper runs.", ["nested_workspace", "separate_worktree", "runs_with_parent"]),
                ],
                required: ["workspace_id", "host"]
            )
        ),
        ProgramaTool(
            name: "agent_task_update",
            socketMethod: V2MethodNames.agentTaskUpdate,
            description: "Updates a running helper's state or description.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "agent_id": ProgramaToolSchema.string("Helper UUID to update."),
                    "workspace_id": ProgramaToolSchema.string("Optional new owning workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Optional terminal surface UUID in the owning workspace."),
                    "session": ProgramaToolSchema.string("Optional host session identifier."),
                    "task": ProgramaToolSchema.string("Updated task description."),
                    "role": ProgramaToolSchema.string("Updated helper role."),
                    "state": ProgramaToolSchema.stringEnum("Updated helper state.", ["idle", "working", "blocked", "completed", "failed", "cancelled"]),
                ],
                required: ["agent_id"]
            )
        ),
        ProgramaTool(
            name: "agent_task_finish",
            socketMethod: V2MethodNames.agentTaskFinish,
            description: "Marks a helper as done, failed, or stopped.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "agent_id": ProgramaToolSchema.string("Helper UUID to finish."),
                    "state": ProgramaToolSchema.stringEnum("Final state. Defaults to completed.", ["completed", "failed", "cancelled"]),
                ],
                required: ["agent_id"]
            )
        ),
        ProgramaTool(
            name: "agent_task_finish_session",
            socketMethod: V2MethodNames.agentTaskFinishSession,
            description: "Stops any helpers that are still active when their host session ends.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "host": ProgramaToolSchema.string("Host name, such as codex or claude."),
                    "session": ProgramaToolSchema.string("Host session identifier."),
                    "state": ProgramaToolSchema.stringEnum("Final state. Defaults to cancelled.", ["completed", "failed", "cancelled"]),
                ],
                required: ["host", "session"]
            )
        ),
        ProgramaTool(
            name: "agent_task_list",
            socketMethod: V2MethodNames.agentTaskList,
            description: "Lists helpers and where they run, including whether output is separate or shared with the parent.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "workspace_id": ProgramaToolSchema.string("Optional workspace UUID or short ref to filter by."),
                "parent_id": ProgramaToolSchema.string("Optional parent helper UUID to filter by."),
                "include_finished": ProgramaToolSchema.boolean("Include finished helpers. Defaults to true."),
            ])
        ),
        ProgramaTool(
            name: "workspace_current",
            socketMethod: V2MethodNames.workspaceCurrent,
            description: "Returns the currently selected workspace in a window, with its full summary.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_close",
            socketMethod: V2MethodNames.workspaceClose,
            description: "Closes a workspace (sidebar tab). Fails if the workspace is pinned.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref (e.g. workspace:2) to close."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_move_to_window",
            socketMethod: V2MethodNames.workspaceMoveToWindow,
            description: "Moves a workspace from its current window into a different window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to move."),
                    "window_id": ProgramaToolSchema.string("Destination window UUID or short ref."),
                    "focus": ProgramaToolSchema.boolean("If true, bring the destination window forward and select the moved workspace after moving. Defaults to false."),
                ],
                required: ["workspace_id", "window_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_reorder",
            socketMethod: V2MethodNames.workspaceReorder,
            description: "Reorders a workspace within its window's sidebar. Specify exactly one of index, before_workspace_id, or after_workspace_id.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to reorder."),
                    "index": ProgramaToolSchema.integer("Target zero-based index within the window's workspace list."),
                    "before_workspace_id": ProgramaToolSchema.string("Move this workspace to just before the workspace with this UUID/ref."),
                    "after_workspace_id": ProgramaToolSchema.string("Move this workspace to just after the workspace with this UUID/ref."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_rename",
            socketMethod: V2MethodNames.workspaceRename,
            description: "Sets a workspace's custom display title.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to rename."),
                    "title": ProgramaToolSchema.string("New title for the workspace."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                ],
                required: ["workspace_id", "title"]
            )
        ),
        ProgramaTool(
            name: "workspace_action",
            socketMethod: V2MethodNames.workspaceAction,
            description: "Runs one of a fixed set of workspace-level actions (pin, rename, reorder, close siblings, recolor, mark read/unread, etc). Some actions require extra params: rename needs title, set_description needs description, set_color needs color.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "action": ProgramaToolSchema.stringEnum("The workspace action to run.", workspaceActionValues),
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to act on. Defaults to the active window's selected workspace if omitted."),
                    "title": ProgramaToolSchema.string("New title, required when action is rename."),
                    "description": ProgramaToolSchema.string("New description, required when action is set_description."),
                    "color": ProgramaToolSchema.string("Hex color (#RRGGBB) or named color, required when action is set_color."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["action"]
            )
        ),
        ProgramaTool(
            name: "workspace_equalize_splits",
            socketMethod: V2MethodNames.workspaceEqualizeSplits,
            description: "Proportionally equalizes pane split dividers in a workspace so leaf panes get equal space, optionally scoped to one split orientation.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "orientation": ProgramaToolSchema.stringEnum("Only equalize splits of this orientation. If omitted, equalizes every split.", ["horizontal", "vertical"]),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_set_status",
            socketMethod: V2MethodNames.workspaceSetStatus,
            description: "Sets (or replaces) a single-line key/value status entry shown in a workspace's sidebar.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref to set status on."),
                    "key": ProgramaToolSchema.string("Status entry key. Setting the same key again replaces the entry."),
                    "value": ProgramaToolSchema.string("Status entry value text."),
                    "icon": ProgramaToolSchema.string("Optional SF Symbol name to show next to the entry."),
                    "color": ProgramaToolSchema.string("Optional color for the entry."),
                    "format": ProgramaToolSchema.stringEnum("How to render the value. Defaults to plain.", ["plain", "markdown"]),
                    "priority": ProgramaToolSchema.integer("Sort priority, -9999 to 9999 (higher shows first). Defaults to 0."),
                    "url": ProgramaToolSchema.string("Optional http(s) URL the entry links to."),
                    "pid": ProgramaToolSchema.integer("Optional process id to associate with this status key, for stale-session detection."),
                ],
                required: ["workspace_id", "key", "value"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_status",
            socketMethod: V2MethodNames.workspaceClearStatus,
            description: "Removes a single sidebar status entry by key.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Status entry key to remove."),
                ],
                required: ["workspace_id", "key"]
            )
        ),
        ProgramaTool(
            name: "workspace_list_status",
            socketMethod: V2MethodNames.workspaceListStatus,
            description: "Lists all sidebar status entries for a workspace, in display order.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_log",
            socketMethod: V2MethodNames.workspaceLog,
            description: "Appends one entry to a workspace's sidebar activity log.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "message": ProgramaToolSchema.string("Log message text."),
                    "level": ProgramaToolSchema.stringEnum("Log severity. Defaults to info.", ["info", "progress", "success", "warning", "error"]),
                    "source": ProgramaToolSchema.string("Optional short label for what produced this log entry."),
                ],
                required: ["workspace_id", "message"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_log",
            socketMethod: V2MethodNames.workspaceClearLog,
            description: "Clears a workspace's entire sidebar activity log.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_list_log",
            socketMethod: V2MethodNames.workspaceListLog,
            description: "Lists a workspace's sidebar activity log entries, optionally limited to the most recent N.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "limit": ProgramaToolSchema.integer("Maximum number of most-recent entries to return. Omit for all entries."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_set_progress",
            socketMethod: V2MethodNames.workspaceSetProgress,
            description: "Sets a workspace's sidebar progress indicator.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "value": ProgramaToolSchema.number("Progress value, clamped to 0.0-1.0."),
                    "label": ProgramaToolSchema.string("Optional label shown alongside the progress bar."),
                ],
                required: ["workspace_id", "value"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_progress",
            socketMethod: V2MethodNames.workspaceClearProgress,
            description: "Clears a workspace's sidebar progress indicator.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "workspace_sidebar_state",
            socketMethod: V2MethodNames.workspaceSidebarState,
            description: "Returns a workspace's full sidebar state in one call: color, cwd, git branch, pull request, progress, status entries, metadata blocks, and recent log entries.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_clear_agent_pid",
            socketMethod: V2MethodNames.workspaceClearAgentPid,
            description: "Removes a tracked agent process id from a workspace (used for stale-session detection).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Agent PID entry key to remove."),
                ],
                required: ["workspace_id", "key"]
            )
        ),
        ProgramaTool(
            name: "workspace_set_agent_pid",
            socketMethod: V2MethodNames.workspaceSetAgentPid,
            description: "Registers an agent process id under a key for a workspace (used for stale-session detection and OSC suppression); does not set a visible status entry.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Key to register this PID under."),
                    "pid": ProgramaToolSchema.integer("Process id, must be a positive integer."),
                ],
                required: ["workspace_id", "key", "pid"]
            )
        ),
        ProgramaTool(
            name: "workspace_report_meta_block",
            socketMethod: V2MethodNames.workspaceReportMetaBlock,
            description: "Sets (or replaces) a freeform markdown metadata block in a workspace's sidebar, distinct from the single-line status entries set by workspace_set_status.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "key": ProgramaToolSchema.string("Metadata block key. Setting the same key again replaces the block."),
                    "markdown": ProgramaToolSchema.string("Markdown content for the block."),
                    "priority": ProgramaToolSchema.integer("Sort priority, -9999 to 9999 (higher shows first). Defaults to 0."),
                ],
                required: ["workspace_id", "key", "markdown"]
            )
        ),
        ProgramaTool(
            name: "workspace_clear_meta_block",
            socketMethod: V2MethodNames.workspaceClearMetaBlock,
            description: "Removes a sidebar metadata block by key.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "key": ProgramaToolSchema.string("Metadata block key to remove."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                    "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
                ],
                required: ["key"]
            )
        ),
        ProgramaTool(
            name: "workspace_list_meta_blocks",
            socketMethod: V2MethodNames.workspaceListMetaBlocks,
            description: "Lists all sidebar metadata blocks for a workspace, in display order.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "workspace_reset_sidebar",
            socketMethod: V2MethodNames.workspaceResetSidebar,
            description: "Clears all sidebar context for a workspace: status entries, log, progress, metadata blocks, and agent state.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
    ]
}
