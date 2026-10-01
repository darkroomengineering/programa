import Foundation
import MCP

/// Translates `MCPSocketBridge` failures into an MCP tool-call error.
///
/// The v2 socket protocol is NOT JSON-RPC 2.0 (docs/socket-api.md):
/// its errors are a flat `{"code":..., "message":...}` object, and a legacy
/// pre-JSON `ERROR: ...` line can appear before the JSON protocol engages.
/// Neither shape is passed through raw -- both are mapped here onto a
/// `CallTool.Result(isError: true, ...)`, which is how the MCP SDK
/// represents a *tool-call*-level failure (as opposed to `MCPError`, which
/// represents a protocol/transport-level failure such as "method not
/// found" and would be the wrong signal for "the app returned `not_found`
/// for this surface id").
enum MCPErrorMapping {
    /// Builds a well-formed MCP tool-call error result for any bridge
    /// failure. Never throws -- an error mapping itself failing (e.g. an
    /// unrecognized error type) still degrades to a generic, non-crashing
    /// tool result rather than propagating.
    static func toolResult(for error: Error) -> CallTool.Result {
        let (code, message) = classify(error)
        return CallTool.Result(
            content: [.text(text: "\(code): \(message)", annotations: nil, _meta: nil)],
            structuredContent: .object(["code": .string(code), "message": .string(message)]),
            isError: true
        )
    }

    /// Builds an MCP protocol-level error for a resource-read failure.
    ///
    /// `ReadResource` returns `ReadResource.Result` directly -- there is no
    /// `CallTool.Result`-shaped `isError` channel for resources -- so a
    /// bridge failure must be thrown as an `MCPError` instead. The SDK's
    /// dispatcher catches any thrown error and turns it into a clean
    /// JSON-RPC error response (`Sources/MCP/Server/Server.swift`'s
    /// `handleRequest`), so this never needs to build a response envelope
    /// itself. Uses `.serverError` (JSON-RPC's -32000..-32099 range) rather
    /// than reusing one of `MCPError`'s own reserved cases, since none of
    /// them (`.methodNotFound`, `.invalidParams`, etc.) describes "the
    /// backing app returned an application-level error" accurately.
    static func mcpError(for error: Error) -> MCPError {
        let (code, message) = classify(error)
        return .serverError(code: -32010, message: "\(code): \(message)")
    }

    /// Extracts a stable `(code, message)` pair from any error the bridge
    /// can throw, for callers that want the raw values rather than a
    /// pre-built tool result (e.g. tests).
    static func classify(_ error: Error) -> (code: String, message: String) {
        guard let bridgeError = error as? MCPSocketBridgeError else {
            return ("internal_error", String(describing: error))
        }
        switch bridgeError {
        case .legacyError(let message):
            // Pre-JSON connection-level failures (e.g. "ERROR: Access denied
            // ...") don't carry a machine-readable code from the server --
            // see `Sources/TerminalController.swift:1435` and
            // `CLI/programa.swift:1017`.
            return ("connection_denied", message)
        case .v2Error(let code, let message):
            return (code, message)
        case .transport(let message):
            return ("transport_error", message)
        case .invalidResponse(let message):
            return ("invalid_response", message)
        case .authentication(let message):
            return ("authentication_error", message)
        }
    }
}
