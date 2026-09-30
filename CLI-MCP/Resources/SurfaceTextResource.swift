import Foundation
import MCP

/// Resolves `programa://surface/{surface_id}/text` -- the sibling-pane-output resource: any
/// agent reads any other pane's visible + scrollback text by id, discovered from
/// `TreeResource`, without focusing or otherwise touching that pane.
///
/// Always requests `scrollback: true` (the whole point of this resource over a bare screen
/// read); an optional `?lines=N` query param bounds the read the same way `surface_read_text`'s
/// `lines` argument does, so a poll loop isn't forced to pull the entire buffer every time.
enum SurfaceTextResource {
    static let uriTemplate = "programa://surface/{surface_id}/text"

    /// Upper bound on `?lines=N`, applied here rather than relying on the app to
    /// enforce one. A resource read is driven by model-generated input, so an
    /// unbounded request would pull an entire scrollback buffer into an agent's
    /// context in a single call.
    static let maxLines = 10_000

    static func read(surfaceId: String, queryItems: [URLQueryItem]) async throws -> [Resource.Content] {
        guard !surfaceId.isEmpty else {
            throw MCPError.invalidParams("programa://surface/{surface_id}/text requires a non-empty surface_id")
        }

        var params: [String: Any] = ["surface_id": surfaceId, "scrollback": true]
        if let linesValue = queryItems.first(where: { $0.name == "lines" })?.value,
           let lines = Int(linesValue), lines > 0 {
            params["lines"] = min(lines, maxLines)
        }

        let bridge = MCPSocketBridge()
        do {
            let result = try await bridge.sendAsync(method: V2MethodNames.surfaceReadText, params: params)
            let text = (result["text"] as? String) ?? ""
            return [.text(text, uri: "programa://surface/\(surfaceId)/text", mimeType: "text/plain")]
        } catch {
            throw MCPErrorMapping.mcpError(for: error)
        }
    }
}
