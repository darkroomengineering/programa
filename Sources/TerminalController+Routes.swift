import Foundation

// Event routes socket API (docs/plans/event-routes.md).
//
// Threading: both methods are declared `main` in the contract. The route engine is main-actor
// state, and `routes.list` must return routes, counters and issues from one consistent snapshot.
// Neither is telemetry: `routes.list` is a user or test query and `debug.routes.load` a test seam.
extension TerminalController {
    nonisolated func v2RoutesList(params: [String: Any]) -> V2CallResult {
        .ok(["routes": [Any](), "issues": [Any]()])
    }

#if DEBUG
    nonisolated func v2DebugRoutesLoad(params: [String: Any]) -> V2CallResult {
        .err(code: "unavailable", message: "Event routes are not wired yet", data: nil)
    }
#endif
}
