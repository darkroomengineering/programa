import Foundation
import MCP

/// Single registration seam for `programa-mcp`'s MCP resources, mirroring
/// `ToolCatalog.register(on:)`. Installs `ListResources`, `ListResourceTemplates`, and
/// `ReadResource`.
///
/// URI shapes handled:
/// - `programa://tree` -- a concrete resource (`ListResources`), backed by `system.tree`.
/// - `programa://surface/{surface_id}/text` -- a resource template (`ListResourceTemplates`,
///   which SDK 0.12.1 exposes -- `Sources/MCP/Server/Resources.swift`'s `Resource.Template` /
///   `ListResourceTemplates`). Per-surface text is advertised as one template rather than
///   enumerated one-entry-per-live-surface at list time; a caller resolves `{surface_id}` by
///   reading `programa://tree` first.
///
/// Poll-on-read only -- no `resources/subscribe` support. Live push updates would need
/// investigating whether the socket's existing `watch-events` mechanism
/// (`Sources/TerminalController+Subscriptions.swift`) covers "surface text changed"; that's
/// deliberately not attempted (see docs/mcp-server.md, Resources).
enum ResourceCatalog {
    static func register(on server: Server) async {
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: [
                Resource(
                    name: "programa_tree",
                    uri: TreeResource.uri,
                    description: "Full window -> workspace -> pane -> surface tree. Supports workspace_id and all_windows query params.",
                    mimeType: "application/json"
                ),
            ])
        }

        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: [
                Resource.Template(
                    uriTemplate: SurfaceTextResource.uriTemplate,
                    name: "programa_surface_text",
                    description: "Visible + scrollback text for one terminal surface, by id -- read any sibling pane's output without stealing focus. Optional ?lines=N bounds the read.",
                    mimeType: "text/plain"
                ),
            ])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await Self.read(uri: params.uri)
        }
    }

    /// Parses a `programa://...` URI and dispatches to the matching resource. Any malformed
    /// or unrecognized URI throws `MCPError.invalidParams`, which the SDK's dispatcher turns
    /// into a clean JSON-RPC error response (`Sources/MCP/Server/Server.swift`'s
    /// `handleRequest`) rather than crashing or hanging.
    private static func read(uri: String) async throws -> ReadResource.Result {
        guard let components = URLComponents(string: uri), components.scheme == "programa" else {
            throw MCPError.invalidParams("Malformed resource URI: \(uri)")
        }
        let queryItems = components.queryItems ?? []

        switch components.host {
        case "tree":
            return ReadResource.Result(contents: try await TreeResource.read(queryItems: queryItems))
        case "surface":
            let segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard segments.count == 2, segments[1] == "text" else {
                throw MCPError.invalidParams("Unknown surface resource URI: \(uri)")
            }
            return ReadResource.Result(contents: try await SurfaceTextResource.read(surfaceId: segments[0], queryItems: queryItems))
        default:
            throw MCPError.invalidParams("Unknown resource URI: \(uri)")
        }
    }

    /// Encodes a socket `result` dictionary as a JSON text `Resource.Content` at the given
    /// URI. Shared only by `TreeResource` today -- `SurfaceTextResource` returns the surface's
    /// plain text directly rather than JSON-wrapping it, since the content itself (not a
    /// structured envelope) is what a sibling agent reads.
    static func jsonContent(for result: [String: Any], uri: String) throws -> Resource.Content {
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw MCPError.internalError("Failed to encode resource content for \(uri)")
        }
        return .text(text, uri: uri, mimeType: "application/json")
    }
}
