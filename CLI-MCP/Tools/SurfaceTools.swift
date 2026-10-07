import MCP

/// `surface.*` tools other than `surface.focus` (a focus-stealing tool, see `FocusTools.swift`),
/// plus `tab.action` (an alias dispatch of the same handler as `surface.action`). Handlers live
/// in `Sources/TerminalController+Surface.swift` (CRUD/split/move/text I/O),
/// `Sources/TerminalController+Workspace.swift` (`v2TabAction`, shared by surface.action and
/// tab.action), `Sources/TerminalController+Telemetry.swift` (report_*/ports_kick), and
/// `Sources/TerminalController+SurfaceWait.swift` (`surface.wait`).
enum SurfaceTools {
    private static let tabActionValues = [
        "rename", "clear_name",
        "close_left", "close_right", "close_others",
        "new_terminal_right",
        "pin", "unpin", "mark_read", "mark_unread",
    ]

    private static func tabActionSchema() -> Value {
        ProgramaToolSchema.object(
            properties: [
                "action": ProgramaToolSchema.stringEnum("The tab action to run.", tabActionValues),
                "surface_id": ProgramaToolSchema.string("Surface (tab) UUID or short ref to act on. Also accepts tab_id as an alias. Defaults to the workspace's focused tab if omitted."),
                "tab_id": ProgramaToolSchema.string("Alias for surface_id."),
                "title": ProgramaToolSchema.string("New title, required when action is rename."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ],
            required: ["action"]
        )
    }

    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "surface_list",
            socketMethod: V2MethodNames.surfaceList,
            description: "Lists every surface (pane content) in a workspace, in display order, with type/title/pane/agent-state.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_current",
            socketMethod: V2MethodNames.surfaceCurrent,
            description: "Returns the currently focused surface in a workspace (falls back to the first surface if none is focused).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_split",
            socketMethod: V2MethodNames.surfaceSplit,
            description: "Splits a surface's pane in the given direction, creating a new terminal surface.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "direction": ProgramaToolSchema.stringEnum("Direction to split in, relative to the source surface's pane.", ["left", "right", "up", "down"]),
                    "surface_id": ProgramaToolSchema.string("Source surface UUID or short ref to split from. Defaults to the workspace's focused surface."),
                    "focus": ProgramaToolSchema.boolean("If true (default), select and focus the new surface."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["direction"]
            )
        ),
        ProgramaTool(
            name: "surface_create",
            socketMethod: V2MethodNames.surfaceCreate,
            description: "Creates a new surface (terminal tab) in an existing pane.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "type": ProgramaToolSchema.stringEnum("Surface type to create. Defaults to terminal.", ["terminal"]),
                "pane_id": ProgramaToolSchema.string("Pane UUID or short ref to create the surface in. Defaults to the workspace's focused pane."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_close",
            socketMethod: V2MethodNames.surfaceClose,
            description: "Closes a surface. Terminal surfaces get a brief undo window; fails if it would close the workspace's last surface.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to close. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_move",
            socketMethod: V2MethodNames.surfaceMove,
            description: "Moves a surface to a different pane, workspace, or window. Provide at most one destination selector: pane_id, workspace_id, window_id, before_surface_id, or after_surface_id (before/after also implies the pane and workspace of the anchor surface).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to move."),
                    "pane_id": ProgramaToolSchema.string("Destination pane UUID or short ref."),
                    "workspace_id": ProgramaToolSchema.string("Destination workspace UUID or short ref (moves into its focused pane)."),
                    "window_id": ProgramaToolSchema.string("Destination window UUID or short ref (moves into its selected workspace's focused pane)."),
                    "before_surface_id": ProgramaToolSchema.string("Place the moved surface immediately before this surface (in that surface's pane)."),
                    "after_surface_id": ProgramaToolSchema.string("Place the moved surface immediately after this surface (in that surface's pane)."),
                    "index": ProgramaToolSchema.integer("Explicit index within the destination pane."),
                    "focus": ProgramaToolSchema.boolean("If true, focus the destination window/workspace/surface after moving. Defaults to false."),
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "surface_reorder",
            socketMethod: V2MethodNames.surfaceReorder,
            description: "Reorders a surface within its current pane. Specify exactly one of index, before_surface_id, or after_surface_id (anchors must be in the same pane).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to reorder."),
                    "index": ProgramaToolSchema.integer("Target zero-based index within the surface's current pane."),
                    "before_surface_id": ProgramaToolSchema.string("Reorder to just before this surface (must be in the same pane)."),
                    "after_surface_id": ProgramaToolSchema.string("Reorder to just after this surface (must be in the same pane)."),
                ],
                required: ["surface_id"]
            )
        ),
        ProgramaTool(
            name: "surface_action",
            socketMethod: V2MethodNames.surfaceAction,
            description: "Runs one of a fixed set of tab-level actions on a surface (rename, close siblings, pin, mark read/unread, open a new tab beside it).",
            inputSchema: tabActionSchema()
        ),
        ProgramaTool(
            name: "tab_action",
            socketMethod: V2MethodNames.tabAction,
            description: "Alias of surface_action -- runs the same fixed set of tab-level actions on a surface (rename, close siblings, pin, mark read/unread, open a new tab beside it).",
            inputSchema: tabActionSchema()
        ),
        ProgramaTool(
            name: "surface_refresh",
            socketMethod: V2MethodNames.surfaceRefresh,
            description: "Forces every terminal surface in a workspace to redraw. Rarely needed; a diagnostic/recovery tool, not a normal read/write path.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_health",
            socketMethod: V2MethodNames.surfaceHealth,
            description: "Reports whether each surface in a workspace is actually attached to a live window (diagnostic).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                "surface_id": ProgramaToolSchema.surfaceRoutingIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_send_text",
            socketMethod: V2MethodNames.surfaceSendText,
            description: "Types text into a terminal surface, as if typed at the keyboard (no Enter is sent automatically -- include \\n in text if you want to submit a command).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "text": ProgramaToolSchema.string("Text to type into the terminal."),
                    "surface_id": ProgramaToolSchema.string("Target terminal surface UUID or short ref. Defaults to the workspace's focused surface."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["text"]
            )
        ),
        ProgramaTool(
            name: "surface_send_key",
            socketMethod: V2MethodNames.surfaceSendKey,
            description: "Sends a single named key (e.g. enter, escape, ctrl+c, up, tab) to a terminal surface.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "key": ProgramaToolSchema.string("Named key to send, e.g. enter, escape, tab, up, down, ctrl+c."),
                    "surface_id": ProgramaToolSchema.string("Target terminal surface UUID or short ref. Defaults to the workspace's focused surface."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["key"]
            )
        ),
        ProgramaTool(
            name: "surface_report_tty",
            socketMethod: V2MethodNames.surfaceReportTty,
            description: "Telemetry write: records a surface's TTY device name (used for shell-integration correlation). Not typically called directly by an agent.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "tty_name": ProgramaToolSchema.string("TTY device name to record."),
                ],
                required: ["workspace_id", "tty_name"]
            )
        ),
        ProgramaTool(
            name: "surface_ports_kick",
            socketMethod: V2MethodNames.surfacePortsKick,
            description: "Telemetry write: requests an immediate re-scan of listening ports for a surface, instead of waiting for the next periodic scan.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref. Defaults to the workspace's focused surface."),
                    "reason": ProgramaToolSchema.stringEnum("Why the scan is being requested. Defaults to command.", ["command", "refresh"]),
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "surface_clear_history",
            socketMethod: V2MethodNames.surfaceClearHistory,
            description: "Clears a terminal surface's scrollback (equivalent to the clear_screen binding action).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": ProgramaToolSchema.string("Target terminal surface UUID or short ref. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_trigger_flash",
            socketMethod: V2MethodNames.surfaceTriggerFlash,
            description: "Triggers a brief visual flash highlight on a surface, useful for drawing a human's attention to it.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": ProgramaToolSchema.string("Surface UUID or short ref to flash. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_report_pwd",
            socketMethod: V2MethodNames.surfaceReportPwd,
            description: "Telemetry write: records a surface's current working directory (used by shell-integration hooks).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "path": ProgramaToolSchema.string("Absolute path to record as the surface's current directory."),
                ],
                required: ["workspace_id", "surface_id", "path"]
            )
        ),
        ProgramaTool(
            name: "surface_report_shell_state",
            socketMethod: V2MethodNames.surfaceReportShellState,
            description: "Telemetry write: records whether a surface's shell is at a prompt or running a command (used by shell-integration hooks).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "state": ProgramaToolSchema.stringEnum("Reported shell activity state.", ["prompt", "idle", "running", "busy", "command", "unknown", "clear"]),
                ],
                required: ["workspace_id", "surface_id", "state"]
            )
        ),
        ProgramaTool(
            name: "surface_report_git_branch",
            socketMethod: V2MethodNames.surfaceReportGitBranch,
            description: "Telemetry write: records a surface's current git branch and dirty state (used by shell-integration hooks).",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "branch": ProgramaToolSchema.string("Git branch name."),
                    "dirty": ProgramaToolSchema.boolean("Whether the working tree has uncommitted changes. Defaults to false."),
                ],
                required: ["workspace_id", "surface_id", "branch"]
            )
        ),
        ProgramaTool(
            name: "surface_clear_git_branch",
            socketMethod: V2MethodNames.surfaceClearGitBranch,
            description: "Clears a surface's reported git branch state.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                ],
                required: ["workspace_id", "surface_id"]
            )
        ),
        ProgramaTool(
            name: "surface_report_pr",
            socketMethod: V2MethodNames.surfaceReportPr,
            description: "Telemetry write: attaches a pull request badge to a surface.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "number": ProgramaToolSchema.integer("Pull request number, must be positive."),
                    "url": ProgramaToolSchema.string("http(s) URL to the pull request."),
                    "state": ProgramaToolSchema.stringEnum("Pull request status. Defaults to open.", ["open", "merged", "closed"]),
                    "branch": ProgramaToolSchema.string("Optional branch name for the pull request."),
                    "checks": ProgramaToolSchema.stringEnum("Optional CI checks status.", ["pass", "fail", "pending"]),
                    "label": ProgramaToolSchema.string("Short label for the badge, truncated to 16 characters. Defaults to \"PR\"."),
                ],
                required: ["workspace_id", "surface_id", "number", "url"]
            )
        ),
        ProgramaTool(
            name: "surface_clear_pr",
            socketMethod: V2MethodNames.surfaceClearPr,
            description: "Clears a surface's pull request badge.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                ],
                required: ["workspace_id", "surface_id"]
            )
        ),
        ProgramaTool(
            name: "surface_report_ports",
            socketMethod: V2MethodNames.surfaceReportPorts,
            description: "Telemetry write: records the listening TCP ports for a surface's process.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "ports": ProgramaToolSchema.integerArray("Listening ports (1-65535), must be non-empty."),
                ],
                required: ["workspace_id", "surface_id", "ports"]
            )
        ),
        ProgramaTool(
            name: "surface_clear_ports",
            socketMethod: V2MethodNames.surfaceClearPorts,
            description: "Clears reported listening ports for a surface, or for every surface in the workspace if surface_id is omitted.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref. Omit to clear ports for every surface in the workspace."),
                ],
                required: ["workspace_id"]
            )
        ),
        ProgramaTool(
            name: "surface_report_agent_state",
            socketMethod: V2MethodNames.surfaceReportAgentState,
            description: "Telemetry write: records a surface's agent activity state (working/blocked/idle), as reported by an installed lifecycle hook.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                    "state": ProgramaToolSchema.stringEnum("Reported agent activity state.", ["working", "blocked", "idle"]),
                    "source": ProgramaToolSchema.stringEnum("Which tier is reporting this state. Defaults to hooks.", ["hooks", "inferred"]),
                ],
                required: ["workspace_id", "surface_id", "state"]
            )
        ),
        ProgramaTool(
            name: "surface_clear_agent_state",
            socketMethod: V2MethodNames.surfaceClearAgentState,
            description: "Clears a surface's reported agent activity state.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "workspace_id": ProgramaToolSchema.string("Workspace UUID or short ref."),
                    "surface_id": ProgramaToolSchema.string("Surface UUID or short ref."),
                ],
                required: ["workspace_id", "surface_id"]
            )
        ),
        ProgramaTool(
            name: "surface_read_text",
            socketMethod: V2MethodNames.surfaceReadText,
            description: "Reads a terminal surface's visible screen text, optionally including scrollback history. The primary tool for observing sibling-pane output.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "scrollback": ProgramaToolSchema.boolean("If true, include scrollback history, not just the visible screen. Defaults to false. Forced true if lines is set."),
                "lines": ProgramaToolSchema.integer("Maximum number of lines to read from scrollback (implies scrollback: true). Must be greater than 0."),
                "surface_id": ProgramaToolSchema.string("Target terminal surface UUID or short ref. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "surface_wait",
            socketMethod: V2MethodNames.surfaceWait,
            description: "Blocks (up to timeout_ms) until a terminal surface hits a condition, then returns in one round trip -- avoids polling surface_read_text in a loop. Provide exactly one of pattern, exit, or agent_state.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "pattern": ProgramaToolSchema.string("Regex pattern to wait for in the surface's output (screen + scrollback)."),
                "exit": ProgramaToolSchema.boolean("If true, wait for the surface's child process to exit."),
                "agent_state": ProgramaToolSchema.stringEnum("Wait for the surface's reported agent state to reach this condition.", ["idle", "working", "blocked", "any_change"]),
                "timeout_ms": ProgramaToolSchema.integer("Maximum time to wait, in milliseconds. Defaults to 30000."),
                "lines": ProgramaToolSchema.integer("Maximum scrollback lines to read per check when using pattern. Must be greater than 0."),
                "surface_id": ProgramaToolSchema.string("Target terminal surface UUID or short ref. Defaults to the workspace's focused surface."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
    ]
}
