import MCP

/// `review.*` tools other than `review.open` (a focus-stealing tool, see `FocusTools.swift`).
/// The review panel shows a git diff with inline comments an agent can read and act on.
/// Handlers live in `Sources/TerminalController+Review.swift`.
enum ReviewTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "review_refresh",
            socketMethod: V2MethodNames.reviewRefresh,
            description: "Re-computes the diff snapshot shown in an open review panel (e.g. after new commits).",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": ProgramaToolSchema.string("Review panel's surface UUID or short ref. If omitted, uses the workspace's focused review panel, or its only review panel."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "review_comment_add",
            socketMethod: V2MethodNames.reviewCommentAdd,
            description: "Adds an inline review comment on a line range of a file shown in an open review panel.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "file_path": ProgramaToolSchema.string("File path (as shown in the diff) to comment on."),
                    "start_line": ProgramaToolSchema.integer("First line of the comment range (1-based, must be > 0)."),
                    "end_line": ProgramaToolSchema.integer("Last line of the comment range. Defaults to start_line. Must be >= start_line."),
                    "text": ProgramaToolSchema.string("Comment text."),
                    "surface_id": ProgramaToolSchema.string("Review panel's surface UUID or short ref. If omitted, uses the workspace's focused review panel, or its only review panel."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["file_path", "start_line", "text"]
            )
        ),
        ProgramaTool(
            name: "review_comment_remove",
            socketMethod: V2MethodNames.reviewCommentRemove,
            description: "Removes a review comment by id.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "comment_id": ProgramaToolSchema.string("UUID of the comment to remove (returned by review_comment_add or review_comment_list)."),
                    "surface_id": ProgramaToolSchema.string("Review panel's surface UUID or short ref. If omitted, uses the workspace's focused review panel, or its only review panel."),
                    "window_id": ProgramaToolSchema.windowIdProperty,
                    "workspace_id": ProgramaToolSchema.workspaceIdProperty,
                ],
                required: ["comment_id"]
            )
        ),
        ProgramaTool(
            name: "review_comment_list",
            socketMethod: V2MethodNames.reviewCommentList,
            description: "Lists all comments currently on an open review panel.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "surface_id": ProgramaToolSchema.string("Review panel's surface UUID or short ref. If omitted, uses the workspace's focused review panel, or its only review panel."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
        ProgramaTool(
            name: "review_send_comments",
            socketMethod: V2MethodNames.reviewSendComments,
            description: "Sends all pending review comments to the review panel's source surface (e.g. as text into the terminal that started the review), then clears them. Sending zero comments is a no-op, not an error.",
            inputSchema: ProgramaToolSchema.object(properties: [
                "preamble": ProgramaToolSchema.string("Optional text to prepend before the formatted comments."),
                "surface_id": ProgramaToolSchema.string("Review panel's surface UUID or short ref. If omitted, uses the workspace's focused review panel, or its only review panel."),
                "window_id": ProgramaToolSchema.windowIdProperty,
                "workspace_id": ProgramaToolSchema.workspaceIdProperty,
            ])
        ),
    ]
}
