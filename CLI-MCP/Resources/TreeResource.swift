import Foundation
import MCP

/// Resolves `programa://tree` by proxying `system.tree` over the control socket. Full
/// window -> workspace -> pane -> surface tree -- the map an agent reads before picking a
/// `surface_id` to hand to `SurfaceTextResource`.
///
/// `workspace_id` and `all_windows` are the only query params, mapped straight onto
/// `system.tree`'s existing params (`Sources/TerminalController+System.swift`'s
/// `v2SystemTree`); no new socket-side behavior.
enum TreeResource {
    static let uri = "programa://tree"

    static func read(queryItems: [URLQueryItem]) throws -> [Resource.Content] {
        var params: [String: Any] = [:]
        for item in queryItems {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name {
            case "workspace_id":
                params["workspace_id"] = value
            case "all_windows":
                // Matches the truthy strings the app's own `v2Bool` query-string callers
                // accept elsewhere in this catalog -- anything else is treated as absent
                // rather than coerced to false.
                params["all_windows"] = ["true", "1", "yes"].contains(value.lowercased())
            default:
                continue
            }
        }

        let bridge = MCPSocketBridge()
        do {
            let result = try bridge.send(method: V2MethodNames.systemTree, params: params)
            return [try ResourceCatalog.jsonContent(for: result, uri: uri)]
        } catch {
            throw MCPErrorMapping.mcpError(for: error)
        }
    }
}
