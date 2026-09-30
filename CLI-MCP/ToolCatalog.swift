import Foundation
import MCP

/// A single entry in the MCP tool catalog: one Programa control-socket method exposed as one
/// MCP tool, with a JSON Schema for its inputs and a closure that turns MCP `tools/call`
/// arguments into the socket `params` dictionary `MCPSocketBridge.send` expects.
///
/// `ToolCatalog.all` is deliberately a flat `[ProgramaTool]` table (mirroring how
/// `Sources/V2CommandCatalog.swift` is the single source of truth for the socket method list)
/// so `ListTools` and `CallTool` are always driven off the exact same data and cannot drift
/// apart -- there is no second list of tool names anywhere in `CLI-MCP/`.
struct ProgramaTool {
    /// The MCP tool name, e.g. `surface_read_text` or `focus_window`. Never contains a `.`.
    let name: String
    /// The Programa v2 socket method this tool calls, e.g. `surface.read_text`.
    let socketMethod: String
    /// Shown to MCP clients in `tools/list`. Focus-stealing tools (see `FocusTools.swift`)
    /// must contain the literal substring "may raise/activate the Programa window".
    let description: String
    /// JSON Schema (as an MCP SDK `Value`) describing this tool's input object.
    let inputSchema: Value
    /// Converts `tools/call` arguments into the socket `params` dictionary. Defaults to a
    /// structural `Value` -> `Any` conversion that drops explicit JSON `null`s (treating them
    /// the same as an omitted key, matching every v2 handler's optional-param convention).
    /// Overridden only where a tool must never forward a particular argument to the socket
    /// even if a caller supplies one -- see `worktree_create` in `WorktreeTools.swift`.
    let makeParams: ([String: Value]) -> [String: Any]

    init(
        name: String,
        socketMethod: String,
        description: String,
        inputSchema: Value,
        makeParams: (([String: Value]) -> [String: Any])? = nil
    ) {
        self.name = name
        self.socketMethod = socketMethod
        self.description = description
        self.inputSchema = inputSchema
        self.makeParams = makeParams ?? ProgramaTool.defaultMakeParams
        precondition(!name.contains("."), "ProgramaTool name must not contain '.': \(name)")
    }

    private static func defaultMakeParams(_ arguments: [String: Value]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in arguments {
            if case .null = value { continue }
            result[key] = ToolCatalog.valueToAny(value)
        }
        return result
    }
}

/// JSON Schema building blocks shared by every `*Tools.swift` file. Kept minimal on purpose --
/// only the shapes this catalog's 187 tools actually need (see the escape hatch in the Phase 3
/// briefing for what to do if a handler needs something richer).
enum ProgramaToolSchema {
    static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    static func stringEnum(_ description: String, _ values: [String]) -> Value {
        ["type": "string", "description": .string(description), "enum": .array(values.map { Value.string($0) })]
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    static func integer(_ description: String) -> Value {
        ["type": "integer", "description": .string(description)]
    }

    static func number(_ description: String) -> Value {
        ["type": "number", "description": .string(description)]
    }

    static func stringArray(_ description: String) -> Value {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    static func integerArray(_ description: String) -> Value {
        ["type": "array", "items": ["type": "integer"], "description": .string(description)]
    }

    static func stringMap(_ description: String) -> Value {
        ["type": "object", "additionalProperties": ["type": "string"], "description": .string(description)]
    }

    /// Builds an `object` JSON Schema from a property table. `required` lists the property
    /// names that must be present -- everything else is optional.
    static func object(properties: [String: Value], required: [String] = []) -> Value {
        var dict: [String: Value] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty {
            dict["required"] = .array(required.map { Value.string($0) })
        }
        return .object(dict)
    }

    /// For tools that take no arguments at all.
    static let empty: Value = ["type": "object", "properties": [:]]

    // MARK: - Shared context-routing properties
    //
    // Most v2 handlers resolve their target `TabManager`/`Workspace` via
    // `v2ResolveTabManager(params:)`/`v2ResolveWorkspace(params:tabManager:)`
    // (`Sources/TerminalController.swift`), which fall back through `window_id` ->
    // `workspace_id` -> `surface_id`/`tab_id` -> the app's currently active window/workspace.
    // These three property definitions are reused verbatim across tools that support that same
    // fallback chain, so the wording (and therefore the model's understanding of it) stays
    // consistent tool to tool.

    static let windowIdProperty = string(
        "Optional window UUID or short ref (e.g. window:1) to route this call to. If omitted, falls back to the workspace's/surface's owning window, then the active window."
    )

    static let workspaceIdProperty = string(
        "Optional workspace UUID or short ref (e.g. workspace:2) to route this call to. If omitted, falls back to the surface's owning workspace, then the active window's selected workspace."
    )

    /// Used only where `surface_id` is a routing fallback (not the tool's primary target).
    static let surfaceRoutingIdProperty = string(
        "Optional surface UUID or short ref (e.g. surface:3) used only to resolve which window/workspace to route this call to, when window_id/workspace_id are omitted."
    )
}

/// Converts an MCP SDK `Value` into the `Any` shape `MCPSocketBridge.send(method:params:)`
/// expects (a plain `[String: Any]` built the same way `JSONSerialization` would decode it).
/// This is the inverse of `jsonObjectToValue` below.
enum ToolCatalog {
    static func valueToAny(_ value: Value) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .bool(let boolValue):
            return boolValue
        case .int(let intValue):
            return intValue
        case .double(let doubleValue):
            return doubleValue
        case .string(let stringValue):
            return stringValue
        case .data(let mimeType, let data):
            // The SDK decodes any `data:` URL string argument (e.g. a browser URL) as `.data`,
            // so re-encode it as a data URL; bare base64 would drop the scheme and MIME type.
            return data.dataURLEncoded(mimeType: mimeType)
        case .array(let array):
            return array.map { valueToAny($0) }
        case .object(let object):
            return object.mapValues { valueToAny($0) }
        }
    }

    /// Converts a `[String: Any]` decoded via `JSONSerialization` (the shape
    /// `MCPSocketBridge.send` returns) into the MCP SDK's `Value` type, by round-tripping
    /// through JSON. `Value` already decodes any JSON document, so this avoids a
    /// hand-written case-by-case `Any` -> `Value` mapping.
    static func jsonObjectToValue(_ object: [String: Any]) throws -> Value {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try JSONDecoder().decode(Value.self, from: data)
    }

    /// The full, ordered tool catalog. `ListTools` and `CallTool` are both driven off this one
    /// table (see `register(on:)`), so they cannot drift apart.
    ///
    /// `browser.*` (85 methods) is exposed via `BrowserTools.swift` (82 tools) plus the three
    /// focus-stealing browser methods in `FocusTools.swift` (`browser.focus_webview`,
    /// `browser.focus`, `browser.tab.switch`).
    ///
    /// Deliberately excludes (see `docs/plans/mcp-server.md` §3 and the Phase 3 briefing for
    /// the authoritative rationale, restated here so a future reader doesn't mistake these for
    /// oversights):
    /// - `debug.*`: DEBUG-build-only test-harness hooks that can simulate keystrokes and
    ///   activate the app.
    /// - `auth.login`, `settings.open`, `feedback.open`, `feedback.submit`, `markdown.open`:
    ///   app chrome, not terminal control.
    /// - `app.*`: app-wide test-harness side effects.
    /// - `agent.detection.*`: deferred for MVP scope only (not a risk exclusion).
    /// - `surface.drag_to_split`: UI gesture simulation.
    static let all: [ProgramaTool] =
        SystemTools.tools
        + WindowTools.tools
        + WorkspaceTools.tools
        + WorktreeTools.tools
        + LayoutTools.tools
        + SnapshotTools.tools
        + SurfaceTools.tools
        + PaneTools.tools
        + NotificationTools.tools
        + ReviewTools.tools
        + FocusTools.tools
        + BrowserTools.tools

    /// Installs both the `ListTools` and `CallTool` method handlers, dispatching every call
    /// through `MCPSocketBridge` by tool name. Both handlers close over the same `all` table
    /// (and the same name -> tool index built from it), so there is exactly one place a new
    /// tool needs to be added for it to show up in both `tools/list` and `tools/call`.
    static func register(on server: Server) async {
        let toolsByName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let mcpTools = all.map { tool in
            Tool(name: tool.name, description: tool.description, inputSchema: tool.inputSchema)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: mcpTools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            guard let tool = toolsByName[params.name] else {
                return CallTool.Result(
                    content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }

            let arguments = params.arguments ?? [:]
            let socketParams = tool.makeParams(arguments)
            let bridge = MCPSocketBridge()
            do {
                let result = try await bridge.sendAsync(method: tool.socketMethod, params: socketParams)
                return Self.successResult(result)
            } catch {
                return MCPErrorMapping.toolResult(for: error)
            }
        }
    }

    /// Builds a `CallTool.Result` for a successful socket round trip: a compact JSON text
    /// summary (so a plain-text MCP client can still read it) plus `structuredContent` with
    /// the full decoded result, mirroring `programa-mcp.swift`'s `handleSystemPing`.
    private static func successResult(_ result: [String: Any]) -> CallTool.Result {
        let structured = try? jsonObjectToValue(result)
        let text: String
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            text = encoded
        } else {
            text = "{}"
        }
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: structured,
            isError: false
        )
    }
}
