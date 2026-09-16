import Foundation

enum AgentTaskState: String, Sendable {
    case idle
    case working
    case blocked
    case completed
    case failed
    case cancelled

    var isFinished: Bool {
        switch self {
        case .idle, .working, .blocked:
            return false
        case .completed, .failed, .cancelled:
            return true
        }
    }
}

enum AgentTaskPlacement: String, Sendable {
    case nestedWorkspace = "nested_workspace"
    case separateWorktree = "separate_worktree"
    case runsWithParent = "runs_with_parent"
}

struct AgentTaskRecord: Sendable {
    let id: UUID
    let parentId: UUID?
    let host: String
    let session: String?
    let task: String?
    let role: String?
    let state: AgentTaskState
    let placement: AgentTaskPlacement
    let workspaceId: UUID
    let surfaceId: UUID?
    let startedAt: Date
    let updatedAt: Date
    let endedAt: Date?

    /// Process-less helpers share their parent's terminal and therefore never expose a
    /// separate output stream, even when a host reports a surface identifier.
    var hasIndependentOutput: Bool {
        placement != .runsWithParent && surfaceId != nil
    }

    func payload() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "id": id.uuidString,
            "parent_id": Self.jsonValue(parentId?.uuidString),
            "host": host,
            "session": Self.jsonValue(session),
            "task": Self.jsonValue(task),
            "role": Self.jsonValue(role),
            "state": state.rawValue,
            "placement": placement.rawValue,
            "workspace_id": workspaceId.uuidString,
            "surface_id": Self.jsonValue(surfaceId?.uuidString),
            "has_independent_output": hasIndependentOutput,
            "output_location": outputLocation,
            "started_at": formatter.string(from: startedAt),
            "updated_at": formatter.string(from: updatedAt),
            "ended_at": Self.jsonValue(endedAt.map(formatter.string(from:))),
        ]
    }

    private var outputLocation: String {
        if placement == .runsWithParent { return "runs_with_parent" }
        return hasIndependentOutput ? "workspace_surface" : "unavailable"
    }

    private static func jsonValue(_ value: String?) -> Any {
        if let value { return value }
        return NSNull()
    }

}

enum AgentSupervisionRegistryError: Error, Equatable {
    case duplicate(UUID)
    case missing(UUID)
    case parentMissing(UUID)
    case alreadyFinished(UUID)
    case finishStateRequired
    case capacityReached
}

@MainActor
final class AgentSupervisionRegistry {
    static let shared = AgentSupervisionRegistry()

    let capacity: Int
    private var recordsById: [UUID: AgentTaskRecord] = [:]

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func record(id: UUID) -> AgentTaskRecord? {
        recordsById[id]
    }

    func records(
        workspaceIds: Set<UUID>? = nil,
        parentId: UUID? = nil,
        includeFinished: Bool = true
    ) -> [AgentTaskRecord] {
        recordsById.values
            .filter { record in
                (workspaceIds == nil || workspaceIds?.contains(record.workspaceId) == true)
                    && (parentId == nil || record.parentId == parentId)
                    && (includeFinished || !record.state.isFinished)
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    @discardableResult
    func start(
        id: UUID = UUID(),
        parentId: UUID? = nil,
        host: String,
        session: String? = nil,
        task: String? = nil,
        role: String? = nil,
        state: AgentTaskState = .working,
        placement: AgentTaskPlacement,
        workspaceId: UUID,
        surfaceId: UUID? = nil,
        now: Date = Date()
    ) throws -> AgentTaskRecord {
        guard recordsById[id] == nil else {
            throw AgentSupervisionRegistryError.duplicate(id)
        }
        if let parentId, recordsById[parentId] == nil {
            throw AgentSupervisionRegistryError.parentMissing(parentId)
        }
        try makeRoomForNewRecord()

        let record = AgentTaskRecord(
            id: id,
            parentId: parentId,
            host: host,
            session: session,
            task: task,
            role: role,
            state: state,
            placement: placement,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            startedAt: now,
            updatedAt: now,
            endedAt: state.isFinished ? now : nil
        )
        recordsById[id] = record
        return record
    }

    @discardableResult
    func update(
        id: UUID,
        state: AgentTaskState? = nil,
        session: String? = nil,
        task: String? = nil,
        role: String? = nil,
        workspaceId: UUID? = nil,
        surfaceId: UUID? = nil,
        now: Date = Date()
    ) throws -> AgentTaskRecord {
        guard let existing = recordsById[id] else {
            throw AgentSupervisionRegistryError.missing(id)
        }
        guard !existing.state.isFinished else {
            throw AgentSupervisionRegistryError.alreadyFinished(id)
        }
        let nextState = state ?? existing.state
        let nextSurfaceId: UUID?
        if let surfaceId {
            nextSurfaceId = surfaceId
        } else if workspaceId == nil {
            nextSurfaceId = existing.surfaceId
        } else {
            // A surface belongs to its workspace. Moving a helper without naming a new
            // surface must not retain a stale terminal from the previous workspace.
            nextSurfaceId = nil
        }
        let record = AgentTaskRecord(
            id: existing.id,
            parentId: existing.parentId,
            host: existing.host,
            session: session ?? existing.session,
            task: task ?? existing.task,
            role: role ?? existing.role,
            state: nextState,
            placement: existing.placement,
            workspaceId: workspaceId ?? existing.workspaceId,
            surfaceId: nextSurfaceId,
            startedAt: existing.startedAt,
            updatedAt: now,
            endedAt: nextState.isFinished ? now : nil
        )
        recordsById[id] = record
        return record
    }

    @discardableResult
    func finish(
        id: UUID,
        state: AgentTaskState = .completed,
        now: Date = Date()
    ) throws -> AgentTaskRecord {
        guard state.isFinished else {
            throw AgentSupervisionRegistryError.finishStateRequired
        }
        return try update(id: id, state: state, now: now)
    }

    func finishSession(
        host: String,
        session: String,
        state: AgentTaskState = .cancelled,
        now: Date = Date()
    ) throws -> [AgentTaskRecord] {
        guard state.isFinished else {
            throw AgentSupervisionRegistryError.finishStateRequired
        }
        let ids = recordsById.values.compactMap { record in
            record.host == host && record.session == session && !record.state.isFinished ? record.id : nil
        }
        return try ids.map { try finish(id: $0, state: state, now: now) }
    }

    func finishActiveSurface(
        workspaceId: UUID,
        surfaceId: UUID,
        state: AgentTaskState = .completed,
        now: Date = Date()
    ) throws -> [AgentTaskRecord] {
        guard state.isFinished else {
            throw AgentSupervisionRegistryError.finishStateRequired
        }
        let ids = activeSurfaceRecordIds(workspaceId: workspaceId, surfaceId: surfaceId)
        return try ids.map { try finish(id: $0, state: state, now: now) }
    }

    func updateActiveSurface(
        workspaceId: UUID,
        surfaceId: UUID,
        state: AgentTaskState,
        now: Date = Date()
    ) throws -> [AgentTaskRecord] {
        guard !state.isFinished else {
            throw AgentSupervisionRegistryError.finishStateRequired
        }
        let ids = activeSurfaceRecordIds(workspaceId: workspaceId, surfaceId: surfaceId)
        return try ids.map { try update(id: $0, state: state, now: now) }
    }

    func removeAll() {
        recordsById.removeAll(keepingCapacity: true)
    }

    func discard(id: UUID) {
        recordsById.removeValue(forKey: id)
    }

    func retainWorkspaces(_ liveWorkspaceIds: Set<UUID>) {
        recordsById = recordsById.filter { liveWorkspaceIds.contains($0.value.workspaceId) }
    }

    private func activeSurfaceRecordIds(workspaceId: UUID, surfaceId: UUID) -> [UUID] {
        recordsById.values.compactMap { record in
            record.workspaceId == workspaceId
                && record.surfaceId == surfaceId
                && record.placement != .runsWithParent
                && !record.state.isFinished
                ? record.id
                : nil
        }
    }

    private func makeRoomForNewRecord() throws {
        guard recordsById.count >= capacity else { return }
        guard let evicted = recordsById.values
            .filter(\.state.isFinished)
            .min(by: {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.startedAt < $1.startedAt
            }) else {
            throw AgentSupervisionRegistryError.capacityReached
        }
        recordsById.removeValue(forKey: evicted.id)
    }
}

@MainActor
enum AgentSupervisionMetadata {
    static func relatedRecords(for workspace: Workspace) -> [AgentTaskRecord] {
        let childWorkspaceIds = Set(workspace.owningTabManager?.tabs.compactMap {
            $0.agentParentWorkspaceId == workspace.id ? $0.id : nil
        } ?? [])
        return AgentSupervisionRegistry.shared.records(
            workspaceIds: childWorkspaceIds.union([workspace.id])
        )
    }

    static func aggregateTaskState(
        for workspace: Workspace,
        records: [AgentTaskRecord],
        core: ProgramaCoreProviding = InProcessCore.shared
    ) -> AgentTaskState? {
        var states = records.map(\.state)
        switch core.agentActivity.aggregateState(for: workspace) {
        case .blocked: states.append(.blocked)
        case .working: states.append(.working)
        case .idle: states.append(.idle)
        case nil: break
        }
        return [.blocked, .working, .failed, .cancelled, .idle, .completed]
            .first(where: states.contains)
    }

    static func aggregateState(
        for workspace: Workspace,
        records: [AgentTaskRecord]
    ) -> String? {
        aggregateTaskState(for: workspace, records: records)?.rawValue
    }

    static func aggregateSource(
        for workspace: Workspace,
        records: [AgentTaskRecord]
    ) -> String? {
        let hasHelpers = !records.isEmpty
        if !workspace.panelAgentStateSources.isEmpty, hasHelpers {
            return "mixed"
        }
        if !workspace.panelAgentStateSources.isEmpty {
            let sources = Set(workspace.panelAgentStateSources.values.map(\.rawValue))
            return sources.count == 1 ? sources.first : "mixed"
        }
        return hasHelpers ? "helpers" : nil
    }
}
