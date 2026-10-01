import AppKit
import Foundation
import os

/// Batched port scanner that replaces per-shell `ps + lsof` scanning.
///
/// Each shell sends a lightweight `report_tty` + `ports_kick` over the socket.
/// PortScanner coalesces kicks across all panels, then runs a single
/// `ps -t <ttys>` + `lsof -p <pids>` covering every panel that needs scanning.
///
/// Kick → coalesce → burst flow:
/// 1. `kick()` adds panel to `pendingKicks` set
/// 2. If no burst is active, starts a 200ms coalesce timer
/// 3. Coalesce fires → snapshots pending set → starts burst of 6 scans
/// 4. New kicks during burst merge into the active burst
/// 5. After last scan, if new kicks arrived, start a new coalesce cycle
final class PortScanner: @unchecked Sendable {
    static let shared = PortScanner()

    typealias AgentScanOverride = @Sendable (
        _ workspaceIds: Set<UUID>,
        _ agentPIDsByWorkspace: [UUID: Set<Int>]
    ) -> [UUID: Set<Int>]
    typealias AgentResultsValidatedHook = @Sendable (_ results: [(UUID, [Int])]) async -> Void
    typealias AgentResultsApplyCompletedHook = @Sendable (_ results: [(UUID, [Int])]) -> Void
    typealias LsofChunkOverride = @Sendable (_ pidsCsv: String) -> [Int: Set<Int>]

    /// Callback delivers `(workspaceId, panelId, ports)` on the main actor.
    var onPortsUpdated: (@MainActor (_ workspaceId: UUID, _ panelId: UUID, _ ports: [Int]) -> Void)?
    /// Callback delivers workspace-scoped ports owned by tracked agents.
    var onAgentPortsUpdated: (@MainActor (_ workspaceId: UUID, _ ports: [Int]) -> Void)?
    /// Provider returns tracked agent root PIDs for the given workspaces.
    var agentPIDsProvider: (@MainActor (_ workspaceIds: Set<UUID>) -> [UUID: Set<Int>])?

    // MARK: - State (guarded by `queue` unless noted)

    private let queue = DispatchQueue(label: "com.darkroom.programa.port-scanner", qos: .utility)

    /// TTY name per (workspace, panel).
    private var ttyNames: [PanelKey: String] = [:]

    /// Monotonic revision per workspace for tracked agent PID changes, guarded by this lock.
    private let agentRevisionByWorkspace = OSAllocatedUnfairLock(initialState: [UUID: UInt64]())

    /// Workspaces with active agent PID tracking that need background rescans.
    private var trackedAgentWorkspaces: Set<UUID> = []

    /// Panels that requested a scan since the last coalesce snapshot.
    private var pendingKicks: Set<PanelKey> = []

    /// Whether a burst sequence is currently running.
    private var burstActive = false

    /// Invalidates burst callbacks and panel results queued before the final
    /// registered panel was removed. This state is owned by `queue`.
    private var burstGeneration: UInt64 = 0
    private var scheduledBurstTimers: [UUID: DispatchSourceTimer] = [:]

    /// Coalesce timer (200ms after first kick).
    private var coalesceTimer: DispatchSourceTimer?

    /// Periodic timer for agent-owned process trees that aren't attached to a TTY.
    private var agentScanTimer: DispatchSourceTimer?

    /// Whether the app has any visible (non-occluded) window. Guarded by `queue`.
    /// Starts `true` so the first tick before the observer reports in isn't skipped.
    private var appVisible = true

    /// Token for the occlusion-state observer registered in `init`.
    private var occlusionObserver: NSObjectProtocol?

    /// Test seams for deterministic agent-port scans and delivery ordering.
    private let agentScanOverride: AgentScanOverride?
    private let agentResultsValidatedHook: AgentResultsValidatedHook?
    private let agentResultsApplyCompletedHook: AgentResultsApplyCompletedHook?
    private let lsofChunkOverride: LsofChunkOverride?

    /// Burst scan offsets in seconds from the start of the burst.
    /// Each scan fires at this absolute offset; the recursive scheduler
    /// converts to relative delays between consecutive scans.
    private static let burstOffsets: [Double] = [0.5, 1.5, 3, 5, 7.5, 10]
    /// Recurring agent-scan cadence. Kept long: the kick/burst path above already
    /// covers the interactive case (any prompt event triggers 6 scans within 10s),
    /// so this timer only exists to catch ports opened mid-command with no prompt
    /// event — 10s latency there is acceptable.
    private static let agentRescanInterval: TimeInterval = 10

    init(
        observesAppVisibility: Bool = true,
        agentScanOverride: AgentScanOverride? = nil,
        agentResultsValidatedHook: AgentResultsValidatedHook? = nil,
        agentResultsApplyCompletedHook: AgentResultsApplyCompletedHook? = nil,
        lsofChunkOverride: LsofChunkOverride? = nil
    ) {
        self.agentScanOverride = agentScanOverride
        self.agentResultsValidatedHook = agentResultsValidatedHook
        self.agentResultsApplyCompletedHook = agentResultsApplyCompletedHook
        self.lsofChunkOverride = lsofChunkOverride
        if observesAppVisibility {
            registerOcclusionObserver()
        }
    }

    // MARK: - Public API

    struct PanelKey: Hashable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
    }

    func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != ttyName else { return }
            ttyNames[key] = ttyName
        }
    }

    func unregisterPanel(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            ttyNames.removeValue(forKey: key)
            pendingKicks.remove(key)
            if ttyNames.isEmpty {
                burstGeneration &+= 1
                scheduledBurstTimers.values.forEach { $0.cancel() }
                scheduledBurstTimers.removeAll()
                burstActive = false
                coalesceTimer?.cancel()
                coalesceTimer = nil
            } else if !pendingKicks.isEmpty, !burstActive {
                startCoalesce()
            }
        }
    }

    func kick(workspaceId: UUID, panelId: UUID) {
        queue.async { [self] in
            let key = PanelKey(workspaceId: workspaceId, panelId: panelId)
            guard ttyNames[key] != nil else { return }
            pendingKicks.insert(key)

            if !burstActive {
                startCoalesce()
            }
            // If burst is active, the next scan iteration will pick up the new kick.
        }
    }

    @MainActor
    func refreshAgentPorts(workspaceId: UUID, agentPIDs: Set<Int>) {
        let agentRevision = nextAgentRevision(for: workspaceId)
        queue.async { [self] in
            refreshAgentPortsLocked(
                workspaceId: workspaceId,
                agentPIDs: agentPIDs,
                agentRevision: agentRevision
            )
        }
    }

    // MARK: - Coalesce + Burst

    private func startCoalesce() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2)
        timer.setEventHandler { [weak self] in
            self?.coalesceTimerFired()
        }
        coalesceTimer = timer
        timer.resume()
    }

    private func coalesceTimerFired() {
        // Already on `queue`.
        coalesceTimer?.cancel()
        coalesceTimer = nil

        guard !pendingKicks.isEmpty else { return }
        burstActive = true
        runBurst(index: 0, generation: burstGeneration)
    }

    private func runBurst(index: Int, burstStart: DispatchTime? = nil, generation: UInt64) {
        // Already on `queue`.
        guard generation == burstGeneration else { return }
        guard index < Self.burstOffsets.count else {
            burstActive = false
            // If new kicks arrived during the burst, start a new coalesce cycle.
            if !pendingKicks.isEmpty {
                startCoalesce()
            }
            return
        }

        let start = burstStart ?? .now()
        let deadline = start + Self.burstOffsets[index]
        let timerID = UUID()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self, weak timer] in
            guard let self else { return }
            guard generation == self.burstGeneration else { return }
            self.scheduledBurstTimers.removeValue(forKey: timerID)
            timer?.cancel()
            self.runScan(generation: generation)
            self.runBurst(index: index + 1, burstStart: start, generation: generation)
        }
        scheduledBurstTimers[timerID] = timer
        timer.resume()
    }

    // MARK: - Scan

    private func runScan(generation requestedGeneration: UInt64? = nil) {
        // Already on `queue`. Snapshot which panels to scan and their TTYs.
        let generation = requestedGeneration ?? burstGeneration
        // We scan all registered panels, not just pending ones, since ports can
        // appear/disappear on any panel.
        let panelSnapshot = ttyNames

        guard !panelSnapshot.isEmpty else {
            pendingKicks.removeAll()
            return
        }

        // Clear pending kicks — they're accounted for in this scan.
        pendingKicks.removeAll()

        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))
        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        guard let agentPIDsProvider, !workspaceIds.isEmpty else {
            finishScan(
                generation: generation,
                panelSnapshot: panelSnapshot,
                agentPIDsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let agentPIDsByWorkspace = await MainActor.run {
                agentPIDsProvider(workspaceIds)
            }
            self.queue.async { [weak self] in
                self?.finishScan(
                    generation: generation,
                    panelSnapshot: panelSnapshot,
                    agentPIDsByWorkspace: agentPIDsByWorkspace,
                    agentRevisions: agentRevisions
                )
            }
        }
    }

    private func finishScan(
        generation: UInt64,
        panelSnapshot: [PanelKey: String],
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        // Already on `queue`.
        let workspaceIds = Set(panelSnapshot.keys.map(\.workspaceId))

        // Build TTY set (deduplicated).
        let uniqueTTYs = Set(panelSnapshot.values)
        let ttyList = uniqueTTYs.joined(separator: ",")

        // 1. ps -t tty1,tty2,... -o pid=,tty=
        // A nil result means `ps` hung or failed: skip this cycle rather than publish "no
        // ports" for every panel. The next kick or burst tick scans again.
        let pidToTTY: [Int: String]
        if ttyList.isEmpty {
            pidToTTY = [:]
        } else if let scanned = runPS(ttyList: ttyList) {
            pidToTTY = scanned
        } else {
            return
        }
        let agentPidToWorkspaces = expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)

        let allPids = Set(pidToTTY.keys).union(agentPidToWorkspaces.keys)
        guard !allPids.isEmpty else {
            let panelResults = panelSnapshot.map { ($0.key, [Int]()) }
            deliverResults(
                panelResults,
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions,
                applyPanelResults: generation == burstGeneration
            )
            return
        }

        // 2. lsof -nP -a -p <all_pids> -iTCP -sTCP:LISTEN -F pn
        let pidsCsv = allPids.sorted().map(String.init).joined(separator: ",")
        guard let pidToPorts = runLsof(pidsCsv: pidsCsv) else { return }

        // 3. Join: PID→TTY + PID→ports → TTY→ports
        var portsByTTY: [String: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let tty = pidToTTY[pid] else { continue }
            portsByTTY[tty, default: []].formUnion(ports)
        }

        var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let workspaceIdsForPid = agentPidToWorkspaces[pid] else { continue }
            for workspaceId in workspaceIdsForPid {
                agentPortsByWorkspace[workspaceId, default: []].formUnion(ports)
            }
        }

        // 4. Map to per-panel port lists.
        var results: [(PanelKey, [Int])] = []
        for (key, tty) in panelSnapshot {
            let ports = portsByTTY[tty].map { Array($0).sorted() } ?? []
            results.append((key, ports))
        }

        deliverResults(
            results,
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions,
            applyPanelResults: generation == burstGeneration
        )
    }

    private func refreshAgentPortsLocked(
        workspaceId: UUID,
        agentPIDs: Set<Int>,
        agentRevision: UInt64
    ) {
        guard isCurrentAgentRevision(
            workspaceId: workspaceId,
            expected: agentRevision
        ) else { return }
        let normalizedPIDs = Set(agentPIDs.filter { $0 > 0 })
        if normalizedPIDs.isEmpty {
            trackedAgentWorkspaces.remove(workspaceId)
        } else {
            trackedAgentWorkspaces.insert(workspaceId)
        }
        updateAgentScanTimerLocked()

        scanAgentPorts(
            workspaceIds: [workspaceId],
            agentPIDsByWorkspace: normalizedPIDs.isEmpty ? [:] : [workspaceId: normalizedPIDs],
            agentRevisions: [workspaceId: agentRevision]
        )
    }

    private func updateAgentScanTimerLocked() {
        guard !trackedAgentWorkspaces.isEmpty else {
            agentScanTimer?.cancel()
            agentScanTimer = nil
            return
        }
        guard agentScanTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.agentRescanInterval,
            repeating: Self.agentRescanInterval
        )
        timer.setEventHandler { [weak self] in
            self?.runTrackedAgentScan()
        }
        agentScanTimer = timer
        timer.resume()
    }

    /// Registers an observer for app-wide occlusion changes so the recurring
    /// agent scan can skip ticks while no window is visible (fully occluded,
    /// minimized, or hidden). The kick/burst path is unaffected.
    private func registerOcclusionObserver() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let initiallyVisible = NSApp?.occlusionState.contains(.visible) ?? true
            self.queue.async { self.appVisible = initiallyVisible }
            self.occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeOcclusionStateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                let visible = NSApp?.occlusionState.contains(.visible) ?? true
                self.queue.async { self.updateAppVisibilityLocked(visible) }
            }
        }
    }

    private func updateAppVisibilityLocked(_ visible: Bool) {
        // Already on `queue`.
        let wasVisible = appVisible
        appVisible = visible
        guard visible, !wasVisible, !trackedAgentWorkspaces.isEmpty else { return }
        // Became visible again: catch up immediately, then resume the normal cadence.
        runTrackedAgentScan()
    }

    private func runTrackedAgentScan() {
        // Already on `queue`.
        guard appVisible else { return }
        let workspaceIds = trackedAgentWorkspaces
        guard !workspaceIds.isEmpty else {
            updateAgentScanTimerLocked()
            return
        }

        let agentRevisions = agentRevisionSnapshot(for: workspaceIds)
        guard let agentPIDsProvider else {
            trackedAgentWorkspaces.removeAll()
            updateAgentScanTimerLocked()
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let agentPIDsByWorkspace = await MainActor.run {
                agentPIDsProvider(workspaceIds)
            }
            self.queue.async { [weak self] in
                self?.finishTrackedAgentScan(
                    workspaceIds: workspaceIds,
                    agentPIDsByWorkspace: agentPIDsByWorkspace,
                    agentRevisions: agentRevisions
                )
            }
        }
    }

    private func finishTrackedAgentScan(
        workspaceIds: Set<UUID>,
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        let normalizedPIDsByWorkspace = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        let inactiveWorkspaceIds = workspaceIds
            .subtracting(normalizedPIDsByWorkspace.keys)
            .filter { workspaceId in
                guard let expectedRevision = agentRevisions[workspaceId] else { return false }
                return isCurrentAgentRevision(
                    workspaceId: workspaceId,
                    expected: expectedRevision
                )
            }
        if !inactiveWorkspaceIds.isEmpty {
            trackedAgentWorkspaces.subtract(inactiveWorkspaceIds)
            updateAgentScanTimerLocked()
        }

        scanAgentPorts(
            workspaceIds: workspaceIds,
            agentPIDsByWorkspace: normalizedPIDsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func scanAgentPorts(
        workspaceIds: Set<UUID>,
        agentPIDsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        guard !workspaceIds.isEmpty else { return }

        if let agentScanOverride {
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentScanOverride(workspaceIds, agentPIDsByWorkspace),
                agentRevisions: agentRevisions
            )
            return
        }

        let agentPidToWorkspaces = expandAgentProcessTree(agentPIDsByWorkspace: agentPIDsByWorkspace)
        guard !agentPidToWorkspaces.isEmpty else {
            deliverAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: [:],
                agentRevisions: agentRevisions
            )
            return
        }

        let pidsCsv = agentPidToWorkspaces.keys.sorted().map(String.init).joined(separator: ",")
        guard let pidToPorts = runLsof(pidsCsv: pidsCsv) else { return }
        var agentPortsByWorkspace: [UUID: Set<Int>] = [:]
        for (pid, ports) in pidToPorts {
            guard let workspaceIdsForPid = agentPidToWorkspaces[pid] else { continue }
            for targetWorkspaceId in workspaceIdsForPid {
                agentPortsByWorkspace[targetWorkspaceId, default: []].formUnion(ports)
            }
        }

        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func deliverResults(
        _ panelResults: [(PanelKey, [Int])],
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64],
        applyPanelResults: Bool
    ) {
        let panelCallback = applyPanelResults ? onPortsUpdated : nil
        if let panelCallback {
            Task { @MainActor in
                for (key, ports) in panelResults {
                    panelCallback(key.workspaceId, key.panelId, ports)
                }
            }
        }
        deliverAgentResults(
            workspaceIds: workspaceIds,
            agentPortsByWorkspace: agentPortsByWorkspace,
            agentRevisions: agentRevisions
        )
    }

    private func deliverAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) {
        guard let agentCallback = onAgentPortsUpdated else { return }
        Task { [weak self] in
            guard let self else { return }
            let validatedResults = await self.validatedAgentResults(
                workspaceIds: workspaceIds,
                agentPortsByWorkspace: agentPortsByWorkspace,
                agentRevisions: agentRevisions
            )
            guard !validatedResults.isEmpty else { return }
            if let agentResultsValidatedHook {
                await agentResultsValidatedHook(validatedResults.map { ($0.workspaceId, $0.ports) })
            }
            await MainActor.run {
                for result in validatedResults {
                    guard self.isCurrentAgentRevision(
                        workspaceId: result.workspaceId,
                        expected: result.revision
                    ) else { continue }
                    agentCallback(result.workspaceId, result.ports)
                }
            }
            agentResultsApplyCompletedHook?(validatedResults.map { ($0.workspaceId, $0.ports) })
        }
    }

    private func validatedAgentResults(
        workspaceIds: Set<UUID>,
        agentPortsByWorkspace: [UUID: Set<Int>],
        agentRevisions: [UUID: UInt64]
    ) async -> [(workspaceId: UUID, ports: [Int], revision: UInt64)] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var results: [(workspaceId: UUID, ports: [Int], revision: UInt64)] = []
                for workspaceId in workspaceIds.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let expectedRevision = agentRevisions[workspaceId, default: 0]
                    guard isCurrentAgentRevision(
                        workspaceId: workspaceId,
                        expected: expectedRevision
                    ) else { continue }
                    let ports = Array(agentPortsByWorkspace[workspaceId] ?? []).sorted()
                    results.append((workspaceId, ports, expectedRevision))
                }
                continuation.resume(returning: results)
            }
        }
    }

    private func agentRevisionSnapshot(for workspaceIds: Set<UUID>) -> [UUID: UInt64] {
        agentRevisionByWorkspace.withLock { revisions in
            workspaceIds.reduce(into: [UUID: UInt64]()) { partial, workspaceId in
                partial[workspaceId] = revisions[workspaceId, default: 0]
            }
        }
    }

    private func nextAgentRevision(for workspaceId: UUID) -> UInt64 {
        agentRevisionByWorkspace.withLock { revisions in
            let nextRevision = revisions[workspaceId, default: 0] &+ 1
            revisions[workspaceId] = nextRevision
            return nextRevision
        }
    }

    private func isCurrentAgentRevision(workspaceId: UUID, expected: UInt64) -> Bool {
        agentRevisionByWorkspace.withLock { revisions in
            revisions[workspaceId, default: 0] == expected
        }
    }

    // MARK: - Process helpers

    private func expandAgentProcessTree(agentPIDsByWorkspace: [UUID: Set<Int>]) -> [Int: Set<UUID>] {
        let normalizedRoots = agentPIDsByWorkspace.reduce(into: [UUID: Set<Int>]()) { partial, item in
            let valid = Set(item.value.filter { $0 > 0 })
            guard !valid.isEmpty else { return }
            partial[item.key] = valid
        }
        guard !normalizedRoots.isEmpty else { return [:] }

        var pidToWorkspaces: [Int: Set<UUID>] = [:]
        var queue: [(pid: Int, workspaceId: UUID)] = []
        for (workspaceId, roots) in normalizedRoots {
            for pid in roots {
                if pidToWorkspaces[pid, default: []].insert(workspaceId).inserted {
                    queue.append((pid, workspaceId))
                }
            }
        }

        let parentByPid = runAllProcesses()
        guard !parentByPid.isEmpty else { return pidToWorkspaces }

        var childrenByParent: [Int: [Int]] = [:]
        for (pid, parentPid) in parentByPid {
            childrenByParent[parentPid, default: []].append(pid)
        }

        var index = 0
        while index < queue.count {
            let (pid, workspaceId) = queue[index]
            index += 1

            for childPid in childrenByParent[pid] ?? [] {
                if pidToWorkspaces[childPid, default: []].insert(workspaceId).inserted {
                    queue.append((childPid, workspaceId))
                }
            }
        }

        return pidToWorkspaces
    }

    /// Every `ps`/`lsof` run is bounded: a hung `lsof` (for example on a stale network mount)
    /// used to block this serial queue, and with it all port scanning, for the rest of the
    /// session. Returns nil when the tool timed out or could not run; callers skip the cycle.
    private static let subprocessTimeout: TimeInterval = 5
    private static let subprocessStdoutLimit = 16 * 1024 * 1024
    private static let subprocessStderrLimit = 1024 * 1024

    private func runBoundedTool(_ path: String, arguments: [String]) -> String? {
        let result = CanonicalSubprocessRunner.run(
            executable: path,
            arguments: arguments,
            currentDirectory: "/",
            timeout: Self.subprocessTimeout,
            stdoutLimit: Self.subprocessStdoutLimit,
            stderrLimit: Self.subprocessStderrLimit,
            executableURL: URL(fileURLWithPath: path)
        )
        // `ps -t` and `lsof` exit 1 when nothing matched; only a run that did not finish
        // normally is a failure.
        guard result.outcome == .exited else { return nil }
        return result.stdout ?? ""
    }

    private func runPS(ttyList: String) -> [Int: String]? {
        // `ps -t tty1,tty2,... -o pid=,tty=` — targeted scan, much cheaper than -ax.
        guard let output = runBoundedTool("/bin/ps", arguments: ["-t", ttyList, "-o", "pid=,tty="]) else {
            return nil
        }

        var mapping: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int(parts[0]) else { continue }
            mapping[pid] = String(parts[1])
        }
        return mapping
    }

    private func runAllProcesses() -> [Int: Int] {
        guard let output = runBoundedTool("/bin/ps", arguments: ["-ax", "-o", "pid=,ppid="]) else {
            return [:]
        }

        var mapping: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2,
                  let pid = Int(parts[0]),
                  let parentPid = Int(parts[1]) else { continue }
            mapping[pid] = parentPid
        }
        return mapping
    }

    /// Nil when any `lsof` chunk failed to finish: a partial answer would drop ports.
    private func runLsof(pidsCsv: String) -> [Int: Set<Int>]? {
        let pids = pidsCsv.split(separator: ",").compactMap { Int($0) }
        guard pids.count > Self.lsofMaximumPIDsPerInvocation else {
            return runLsofChunk(pidsCsv: pidsCsv)
        }

        var result: [Int: Set<Int>] = [:]
        for chunk in Self.lsofPIDChunks(pids) {
            let csv = chunk.map(String.init).joined(separator: ",")
            guard let chunkResult = runLsofChunk(pidsCsv: csv) else { return nil }
            for (pid, ports) in chunkResult {
                result[pid, default: []].formUnion(ports)
            }
        }
        return result
    }

    private static let lsofMaximumPIDsPerInvocation = 256
    private static let lsofArgumentByteBudget = 32 * 1024
    private static let lsofArgumentOverhead = 256

    private static func lsofPIDChunks(_ pids: [Int]) -> [[Int]] {
        var chunks: [[Int]] = []
        var chunk: [Int] = []
        var chunkBytes = 0

        for pid in pids {
            let pidBytes = String(pid).utf8.count
            let additionalBytes = pidBytes + (chunk.isEmpty ? 0 : 1)
            if !chunk.isEmpty,
               chunk.count >= lsofMaximumPIDsPerInvocation
                || chunkBytes + additionalBytes + lsofArgumentOverhead > lsofArgumentByteBudget
            {
                chunks.append(chunk)
                chunk = []
                chunkBytes = 0
            }
            chunkBytes += pidBytes + (chunk.isEmpty ? 0 : 1)
            chunk.append(pid)
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private func runLsofChunk(pidsCsv: String) -> [Int: Set<Int>]? {
        if let lsofChunkOverride { return lsofChunkOverride(pidsCsv) }
        // `lsof -b -w -nP -a -p <pids> -iTCP -sTCP:LISTEN -F pn`. `-b` avoids kernel calls
        // that can block (stat/lstat/readlink on a dead mount); `-w` drops the warnings `-b`
        // would print.
        guard let output = runBoundedTool(
            "/usr/sbin/lsof",
            arguments: ["-b", "-w", "-nP", "-a", "-p", pidsCsv, "-iTCP", "-sTCP:LISTEN", "-Fpn"]
        ) else {
            return nil
        }

        // Parse lsof -F output: lines starting with 'p' = PID, 'n' = name (host:port).
        var result: [Int: Set<Int>] = [:]
        var currentPid: Int?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            switch first {
            case "p":
                currentPid = Int(line.dropFirst())
            case "n":
                guard let pid = currentPid else { continue }
                var name = String(line.dropFirst())
                // Strip remote endpoint if present.
                if let arrowIdx = name.range(of: "->") {
                    name = String(name[..<arrowIdx.lowerBound])
                }
                // Port is after the last colon.
                if let colonIdx = name.lastIndex(of: ":") {
                    let portStr = name[name.index(after: colonIdx)...]
                    // Strip anything non-numeric.
                    let cleaned = portStr.prefix(while: \.isNumber)
                    if let port = Int(cleaned), port > 0, port <= 65535 {
                        result[pid, default: []].insert(port)
                    }
                }
            default:
                break
            }
        }
        return result
    }
}
