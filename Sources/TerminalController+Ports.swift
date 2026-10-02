import Foundation

extension TerminalController {
    // MARK: - V2 Ports Methods

    /// Synchronous snapshot of listening ports across all windows. Main-thread execution is
    /// required because the hub store and the workspace list are main-actor state, and the
    /// caller expects one consistent view. Never activates the app or changes focus.
    nonisolated func v2PortsList(params: [String: Any]) -> V2CallResult {
        _ = params
        return v2MainSync {
            let hub = PortsHubStore.shared
            hub.revalidateLeftovers()
            let workspaces: [[String: Any]] = hub.workspaceSnapshot().map { workspace in
                let ports: [[String: Any]] = workspace.rows.map { row in
                    [
                        "port": row.port,
                        "pid": row.pid,
                        "command": row.command,
                        "surface_id": v2OrNull(row.panelId?.uuidString),
                        "surface_ref": v2Ref(kind: .surface, uuid: row.panelId),
                    ]
                }
                return [
                    "id": workspace.workspaceId.uuidString,
                    "ref": v2Ref(kind: .workspace, uuid: workspace.workspaceId),
                    "title": workspace.title,
                    "ports": ports,
                ]
            }
            let formatter = ISO8601DateFormatter()
            let leftRunning: [[String: Any]] = hub.leftovers.map { leftover in
                [
                    "pid": leftover.pid,
                    "command": leftover.command,
                    "ports": leftover.ports,
                    "workspace_title": leftover.workspaceTitle,
                    "closed_at": formatter.string(from: leftover.closedAt),
                ]
            }
            return .ok(["workspaces": workspaces, "left_running": leftRunning])
        }
    }

    /// Stops a process the hub tracks (a live workspace listener or a leftover): SIGTERM, then
    /// SIGKILL after 3 seconds. Runs on main because the hub store is main-actor state and the
    /// ownership check must see the same snapshot `ports.list` returned. Arbitrary pids are
    /// refused. Never activates the app or changes focus.
    nonisolated func v2PortsStop(params: [String: Any]) -> V2CallResult {
        guard let pid = v2Int(params, "pid") else { return v2InvalidParam("pid") }
        return v2MainSync {
            switch PortsHubStore.shared.stop(pid: pid) {
            case .signaled:
                return .ok(["pid": pid, "signaled": true])
            case .refused(.invalidPID):
                return v2InvalidParam("pid")
            case .refused(.notTracked), .refused(.processChanged), .refused(.alreadyExited):
                return .err(
                    code: "not_found",
                    message: "No Programa-owned listening process with pid \(pid)",
                    data: nil
                )
            case .refused(.signalFailed):
                return .err(code: "internal_error", message: "Could not signal pid \(pid)", data: nil)
            }
        }
    }
}
