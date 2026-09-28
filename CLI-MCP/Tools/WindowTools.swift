import MCP

/// `window.*` tools other than `window.focus` (a focus-stealing tool, see `FocusTools.swift`).
/// Handlers live in `Sources/TerminalController+Window.swift`.
enum WindowTools {
    static let tools: [ProgramaTool] = [
        ProgramaTool(
            name: "window_list",
            socketMethod: V2MethodNames.windowList,
            description: "Lists every open Programa main window with its key/visible state and selected workspace.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "window_current",
            socketMethod: V2MethodNames.windowCurrent,
            description: "Returns the currently active Programa window's id.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "window_create",
            socketMethod: V2MethodNames.windowCreate,
            description: "Creates a new, empty Programa main window.",
            inputSchema: ProgramaToolSchema.empty
        ),
        ProgramaTool(
            name: "window_close",
            socketMethod: V2MethodNames.windowClose,
            description: "Closes a Programa main window.",
            inputSchema: ProgramaToolSchema.object(
                properties: [
                    "window_id": ProgramaToolSchema.string("Window UUID or short ref (e.g. window:1) to close."),
                ],
                required: ["window_id"]
            )
        ),
    ]
}
