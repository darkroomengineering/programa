import Combine
import CryptoKit
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

extension AgentTaskState {
    init(_ state: AgentActivityState) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .blocked: self = .blocked
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
    /// The helper's final report, as handed back to its parent.
    let summary: String?
    let state: AgentTaskState
    let placement: AgentTaskPlacement
    let workspaceId: UUID
    let surfaceId: UUID?
    let startedAt: Date
    let updatedAt: Date
    let endedAt: Date?
    /// 0-100 from an OSC 7501 report; nil when the work is indeterminate.
    var progress: Int? = nil

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
            "summary": Self.jsonValue(summary),
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
final class AgentSupervisionRegistry: ObservableObject {
    static let shared = AgentSupervisionRegistry()

    let capacity: Int
    /// Unfinished `runs_with_parent` helpers per workspace, shown on the sidebar row.
    /// Both counts publish together, once, and only when one changes: `updateActiveSurface`
    /// runs on every agent state report, and finishing a helper moves it between the two
    /// counts. Either extra publish re-renders the whole sidebar.
    private(set) var runningHelperCounts: [UUID: Int] = [:]
    /// Finished `runs_with_parent` helpers per workspace, kept so their reports stay
    /// reachable from the sidebar until cleared.
    private(set) var finishedHelperCounts: [UUID: Int] = [:]
    private var recordsById: [UUID: AgentTaskRecord] = [:] {
        didSet { refreshHelperCounts() }
    }
    /// Helpers that programs report as OSC 7501 child records, per terminal surface. They
    /// stay out of `recordsById`: the UI shows their text, but the protocol forbids handing
    /// a record's id, title or message back to programs, and every `recordsById` reader
    /// answers the socket.
    private var terminalHelpersBySurface: [UUID: TerminalHelpers] = [:] {
        didSet { refreshHelperCounts() }
    }

    private struct TerminalHelpers {
        var workspaceId: UUID
        var records: [AgentTaskRecord]
    }

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
        summary: String? = nil,
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
            summary: summary,
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
        summary: String? = nil,
        workspaceId: UUID? = nil,
        surfaceId: UUID? = nil,
        progress: Int?? = .none,
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
            summary: summary ?? existing.summary,
            state: nextState,
            placement: existing.placement,
            workspaceId: workspaceId ?? existing.workspaceId,
            surfaceId: nextSurfaceId,
            startedAt: existing.startedAt,
            updatedAt: now,
            endedAt: nextState.isFinished ? now : nil,
            progress: nextState.isFinished ? nil : (progress ?? existing.progress)
        )
        recordsById[id] = record
        return record
    }

    @discardableResult
    func finish(
        id: UUID,
        state: AgentTaskState = .completed,
        task: String? = nil,
        summary: String? = nil,
        now: Date = Date()
    ) throws -> AgentTaskRecord {
        guard state.isFinished else {
            throw AgentSupervisionRegistryError.finishStateRequired
        }
        return try update(id: id, state: state, task: task, summary: summary, now: now)
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

    /// Finishes the workspace's in-process helpers whose parent agent exited without a
    /// SessionEnd hook (crash, kill), so `runningHelperCounts` cannot stick.
    @discardableResult
    func finishRunningHelpers(
        workspaceId: UUID,
        state: AgentTaskState = .cancelled,
        now: Date = Date(),
        where matches: (AgentTaskRecord) -> Bool
    ) -> [AgentTaskRecord] {
        let ids = recordsById.values.compactMap { record in
            record.workspaceId == workspaceId
                && record.placement == .runsWithParent
                && !record.state.isFinished
                && matches(record)
                ? record.id
                : nil
        }
        return ids.compactMap { try? finish(id: $0, state: state, now: now) }
    }

    func removeAll() {
        recordsById.removeAll(keepingCapacity: true)
    }

    func discard(id: UUID) {
        recordsById.removeValue(forKey: id)
    }

    /// Removes the workspace's finished in-process helpers.
    @discardableResult
    func discardFinishedHelpers(workspaceId: UUID) -> Int {
        let ids = recordsById.values.compactMap { record in
            record.workspaceId == workspaceId
                && record.placement == .runsWithParent
                && record.state.isFinished
                ? record.id
                : nil
        }
        let terminalCount = discardFinishedTerminalHelpers(workspaceId: workspaceId)
        guard !ids.isEmpty else { return terminalCount }
        recordsById = recordsById.filter { !ids.contains($0.key) }
        return ids.count + terminalCount
    }

    func retainWorkspaces(_ liveWorkspaceIds: Set<UUID>) {
        recordsById = recordsById.filter { liveWorkspaceIds.contains($0.value.workspaceId) }
        terminalHelpersBySurface = terminalHelpersBySurface.filter { liveWorkspaceIds.contains($0.value.workspaceId) }
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

    private func refreshHelperCounts() {
        var running: [UUID: Int] = [:]
        var finished: [UUID: Int] = [:]
        let terminalRecords = terminalHelpersBySurface.values.flatMap(\.records)
        for record in Array(recordsById.values) + terminalRecords where record.placement == .runsWithParent {
            if record.state.isFinished {
                finished[record.workspaceId, default: 0] += 1
            } else {
                running[record.workspaceId, default: 0] += 1
            }
        }
        guard running != runningHelperCounts || finished != finishedHelperCounts else { return }
        objectWillChange.send()
        runningHelperCounts = running
        finishedHelperCounts = finished
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

    /// Socket `agent_state` (DECISION D3): what the workspace is doing now. Only unfinished
    /// helpers count, so one failed helper does not pin the workspace to `failed` forever;
    /// finished helpers are reported separately by `helperOutcomes`. Values: idle|working|blocked.
    static func currentActivityState(
        for workspace: Workspace,
        records: [AgentTaskRecord]
    ) -> String? {
        aggregateTaskState(for: workspace, records: records.filter { !$0.state.isFinished })?.rawValue
    }

    /// Finished-helper counts for `workspace.list` / `system.tree` (`helper_outcomes`).
    static func helperOutcomes(records: [AgentTaskRecord]) -> [String: Int] {
        var outcomes: [String: Int] = ["failed": 0, "completed": 0, "cancelled": 0]
        for record in records where record.state.isFinished {
            outcomes[record.state.rawValue, default: 0] += 1
        }
        return outcomes
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

extension AgentSupervisionRegistry {
    /// One workspace's helpers for the popover: in-process helpers reported over the socket,
    /// then child records from the workspace's terminals.
    func helperRecords(workspaceId: UUID, surfaceIds: some Sequence<UUID>) -> [AgentTaskRecord] {
        records(workspaceIds: [workspaceId]).filter { $0.placement == .runsWithParent }
            + surfaceIds.flatMap { terminalHelpersBySurface[$0]?.records ?? [] }
    }

    /// Mirrors one terminal's OSC 7501 child records. A child whose last id segment is the
    /// UUID of a socket-reported helper updates that helper's live state instead, since the
    /// Claude Code hooks report each subagent both ways. Returns the terminal-only helpers
    /// that just entered `blocked`.
    @discardableResult
    func syncTerminalHelpers(
        workspaceId: UUID,
        surfaceId: UUID,
        children: [ProgramStatusRecord],
        now: Date = Date()
    ) -> [AgentTaskRecord] {
        let previous = Dictionary(
            (terminalHelpersBySurface[surfaceId]?.records ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var next: [AgentTaskRecord] = []
        var newlyBlocked: [AgentTaskRecord] = []
        for child in children {
            let lastSegment = child.id.split(separator: "/").last.map(String.init) ?? child.id
            let namedId = Self.uuid(fromSegment: lastSegment)
            if let namedId, let socketRecord = record(id: namedId), socketRecord.workspaceId == workspaceId {
                applyLiveState(child, to: socketRecord, now: now)
                continue
            }
            let id = namedId ?? Self.terminalHelperId(surfaceId: surfaceId, recordId: child.id)
            let state = Self.taskState(child.state)
            let existing = previous[id]
            let helper = AgentTaskRecord(
                id: id,
                parentId: nil,
                host: child.app ?? "program",
                session: nil,
                task: child.title ?? lastSegment,
                role: child.app,
                summary: child.msg,
                state: state,
                placement: .runsWithParent,
                workspaceId: workspaceId,
                surfaceId: surfaceId,
                startedAt: existing?.startedAt ?? child.updatedAt,
                updatedAt: child.updatedAt,
                endedAt: state.isFinished ? (existing?.endedAt ?? child.updatedAt) : nil,
                progress: state.isFinished ? nil : child.progress
            )
            if state == .blocked, existing?.state != .blocked { newlyBlocked.append(helper) }
            next.append(helper)
        }
        if next.isEmpty {
            if terminalHelpersBySurface[surfaceId] != nil { terminalHelpersBySurface.removeValue(forKey: surfaceId) }
        } else {
            terminalHelpersBySurface[surfaceId] = TerminalHelpers(workspaceId: workspaceId, records: next)
        }
        return newlyBlocked
    }

    /// Drops terminal helpers of `workspaces` whose surface closed or moved to another
    /// workspace; the next report from a moved surface re-adds them under its new workspace.
    func retainTerminalSurfaces(of workspaces: [Workspace]) {
        let workspaceIdBySurface = Dictionary(
            workspaces.flatMap { workspace in workspace.panels.keys.map { ($0, workspace.id) } },
            uniquingKeysWith: { first, _ in first }
        )
        let workspaceIds = Set(workspaces.map(\.id))
        let stale = terminalHelpersBySurface.filter {
            workspaceIds.contains($0.value.workspaceId) && workspaceIdBySurface[$0.key] != $0.value.workspaceId
        }
        guard !stale.isEmpty else { return }
        terminalHelpersBySurface = terminalHelpersBySurface.filter { stale[$0.key] == nil }
    }

    private func discardFinishedTerminalHelpers(workspaceId: UUID) -> Int {
        var removed = 0
        var next = terminalHelpersBySurface
        for (surfaceId, var helpers) in next where helpers.workspaceId == workspaceId {
            let kept = helpers.records.filter { !$0.state.isFinished }
            removed += helpers.records.count - kept.count
            helpers.records = kept
            next[surfaceId] = kept.isEmpty ? nil : helpers
        }
        if removed > 0 { terminalHelpersBySurface = next }
        return removed
    }

    private func applyLiveState(_ child: ProgramStatusRecord, to record: AgentTaskRecord, now: Date) {
        guard child.state.isActive, !record.state.isFinished else { return }
        let state: AgentTaskState = child.state == .blocked ? .blocked : .working
        guard state != record.state || child.progress != record.progress else { return }
        _ = try? update(id: record.id, state: state, progress: .some(child.progress), now: now)
    }

    private static func taskState(_ state: ProgramStatusState) -> AgentTaskState {
        switch state {
        case .idle: return .idle
        case .working: return .working
        case .blocked: return .blocked
        case .done: return .completed
        case .error: return .failed
        }
    }

    /// An id segment holds at most 32 characters, so a UUID arrives as 32 hex digits.
    private static func uuid(fromSegment segment: String) -> UUID? {
        guard segment.utf8.count == 32, segment.allSatisfy(\.isHexDigit) else { return UUID(uuidString: segment) }
        var text = segment
        for offset in [8, 13, 18, 23] {
            text.insert("-", at: text.index(text.startIndex, offsetBy: offset))
        }
        return UUID(uuidString: text)
    }

    private static func terminalHelperId(surfaceId: UUID, recordId: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(surfaceId.uuidString)/\(recordId)".utf8))
        return digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
