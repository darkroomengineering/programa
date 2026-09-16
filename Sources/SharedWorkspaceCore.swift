import Foundation
import Bonsplit

/// Projects one existing native pane through the same ordering command as WinUI.
/// Panel and terminal objects remain owned by the native workspace during migration.
@MainActor
final class SharedWorkspaceCore {
    struct Surface: Codable, Equatable {
        let id: String
        let session_id: String
        let is_pinned: Bool
    }

    private struct Pane: Codable {
        let id: String
        let selected_surface_id: String?
        let surfaces: [Surface]
    }

    private struct Layout: Codable {
        let type: String
        let pane_id: String
    }

    private struct CoreWorkspace: Codable {
        let id: String
        let selected_pane_id: String
        let panes: [Pane]
        let layout: Layout
    }

    private struct Snapshot: Codable {
        let abi_version: UInt32
        let revision: UInt64
        let selected_workspace_id: String?
        let workspaces: [CoreWorkspace]
    }

    private struct Seed: Encodable {
        let command = "seed_snapshot"
        let snapshot: Snapshot
    }

    private struct Reorder: Encodable {
        let command = "reorder_surface"
        let workspace_id: String
        let pane_id: String
        let surface_id: String
        let before_surface_id: String?
    }

    private struct Response: Decodable {
        let snapshot: Snapshot
    }

    private enum BridgeError: Error {
        case unavailable, invalidResponse, rejected(String)
    }

    private let handle: UnsafeMutableRawPointer?

    init() {
        handle = programa_core_abi_version() == 1 ? programa_core_create() : nil
    }

    deinit {
        if let handle { programa_core_destroy(handle) }
    }

    func reorder(
        workspaceID: UUID,
        paneID: PaneID,
        surfaces: [Surface],
        selectedID: TabID?,
        draggedID: TabID,
        destination: Int
    ) -> [TabID]? {
        let workspace = workspaceID.uuidString
        let pane = paneID.id.uuidString
        let selected = selectedID?.uuid.uuidString
        let target = max(0, min(destination, surfaces.count))
        do {
            let seeded = try dispatch(Seed(snapshot: Snapshot(
                abi_version: 1,
                revision: 0,
                selected_workspace_id: workspace,
                workspaces: [CoreWorkspace(
                    id: workspace,
                    selected_pane_id: pane,
                    panes: [Pane(id: pane, selected_surface_id: selected, surfaces: surfaces)],
                    layout: Layout(type: "pane", pane_id: pane)
                )]
            )))
            let result = try dispatch(Reorder(
                workspace_id: workspace,
                pane_id: pane,
                surface_id: draggedID.uuid.uuidString,
                before_surface_id: target < surfaces.count ? surfaces[target].id : nil
            ))
            guard result.revision == seeded.revision ||
                    (seeded.revision < UInt64.max && result.revision == seeded.revision + 1),
                  result.workspaces.count == 1,
                  let projected = result.workspaces.first,
                  projected.id == workspace,
                  projected.panes.count == 1,
                  let projectedPane = projected.panes.first,
                  projectedPane.id == pane,
                  projectedPane.selected_surface_id == selected,
                  projectedPane.surfaces.count == surfaces.count else {
                throw BridgeError.invalidResponse
            }
            let original = Dictionary(uniqueKeysWithValues: surfaces.map { ($0.id, $0) })
            guard projectedPane.surfaces.allSatisfy({ original[$0.id] == $0 }),
                  Set(projectedPane.surfaces.map(\.id)).count == surfaces.count else {
                throw BridgeError.invalidResponse
            }
            let ids = projectedPane.surfaces.compactMap { UUID(uuidString: $0.id) }
            guard ids.count == surfaces.count else { throw BridgeError.invalidResponse }
            return ids.map { TabID(uuid: $0) }
        } catch {
            NSLog("Shared workspace core rejected tab reorder: %@", String(describing: error))
            return nil
        }
    }

    private func dispatch<Request: Encodable>(_ request: Request) throws -> Snapshot {
        guard let handle else { throw BridgeError.unavailable }
        let data = try JSONEncoder().encode(request)
        var buffer = ProgramaBuffer(data: nil, len: 0, capacity: 0)
        let status = data.withUnsafeBytes { bytes in
            programa_core_dispatch(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &buffer)
        }
        defer { programa_core_buffer_free(buffer) }
        guard let bytes = buffer.data, buffer.len > 0, buffer.len <= 4 * 1024 * 1024 else {
            throw BridgeError.invalidResponse
        }
        let response = Data(bytes: bytes, count: buffer.len)
        guard status == 0 else {
            throw BridgeError.rejected(String(data: response, encoding: .utf8) ?? "invalid UTF-8")
        }
        return try JSONDecoder().decode(Response.self, from: response).snapshot
    }
}
