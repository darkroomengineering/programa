import Foundation

// Event routes socket API (docs/plans/event-routes.md).
//
// Threading: both methods are declared `main` in the contract. The route engine is main-actor
// state, and `routes.list` must return routes, counters and issues from one consistent snapshot.
// Neither is telemetry: `routes.list` is a user or test query and `debug.routes.load` a test seam.
extension TerminalController {
    nonisolated func v2RoutesList(params: [String: Any]) -> V2CallResult {
        let snapshot = v2MainSync { RouteEngine.shared.snapshot() }
        return .ok([
            "source": Self.v2RouteSourceName(snapshot.source),
            "routes": snapshot.routes.map { route -> [String: Any] in
                [
                    "name": route.name,
                    "on": route.on,
                    "action": route.action,
                    "matched": route.counters.matched,
                    "fired": route.counters.fired,
                    "throttled": route.counters.throttled,
                    "busy": route.counters.busy,
                    "expired": route.counters.expired,
                    "last_error": route.lastError.map { $0 as Any } ?? NSNull(),
                ]
            },
            "issues": Self.v2RouteIssuePayload(snapshot.issues),
        ])
    }

    nonisolated private static func v2RouteSourceName(_ source: RouteSource) -> String {
        switch source {
        case .file: return "file"
        case .debugOverride: return "debug_override"
        }
    }

    nonisolated private static func v2RouteIssuePayload(_ issues: [ProgramaRouteIssue]) -> [[String: Any]] {
        issues.map { issue in
            [
                "index": issue.index.map { $0 as Any } ?? NSNull(),
                "name": issue.name.map { $0 as Any } ?? NSNull(),
                "message": issue.message,
            ]
        }
    }

#if DEBUG
    /// `json` is programa.json text, decoded as the global file would be (JSONC, duplicate keys,
    /// per-route issues); its routes replace the file's until a call with `json: null`.
    nonisolated func v2DebugRoutesLoad(params: [String: Any]) -> V2CallResult {
        guard let json = params["json"] else {
            return .err(code: "invalid_params", message: "Missing json", data: nil)
        }
        if json is NSNull {
            let snapshot = v2MainSync {
                RouteEngine.shared.clearDebugOverride()
                return RouteEngine.shared.snapshot()
            }
            return .ok([
                "source": Self.v2RouteSourceName(snapshot.source),
                "routes": snapshot.routes.map(\.name),
                "issues": Self.v2RouteIssuePayload(snapshot.issues),
            ])
        }
        guard let text = json as? String else {
            return .err(code: "invalid_params", message: "json must be programa.json text or null", data: nil)
        }
        let config: ProgramaConfigFile
        do {
            config = try ProgramaConfigStore.decodeConfig(Data(text.utf8))
        } catch {
            return .err(
                code: "invalid_params",
                message: "json is not a valid programa.json: \(error)",
                data: nil
            )
        }
        v2MainSync {
            RouteEngine.shared.install(routes: config.routes, issues: config.routeIssues, source: .debugOverride)
        }
        return .ok([
            "source": "debug_override",
            "routes": config.routes.map(\.name),
            "issues": Self.v2RouteIssuePayload(config.routeIssues),
        ])
    }
#endif
}
