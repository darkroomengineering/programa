import Combine
import Darwin
import Foundation

/// A process that outlived the panel it was started from and still holds listening ports.
struct LeftoverProcess: Equatable, Identifiable {
    let pid: Int
    let command: String
    let ports: [Int]
    let workspaceTitle: String
    let closedAt: Date
    /// Kernel start time recorded while the process was live; nil when it could not be read.
    let startTime: UInt64?

    var id: Int { pid }
}

/// One listening port in the hub, ready for display or serialization.
struct PortsHubRow: Equatable, Identifiable {
    let port: Int
    let pid: Int
    let command: String
    /// The terminal surface that owns the process; nil for agent-owned processes.
    let panelId: UUID?

    var id: String { "\(pid):\(port)" }
}

struct PortsHubWorkspace: Equatable, Identifiable {
    let workspaceId: UUID
    let title: String
    let rows: [PortsHubRow]

    var id: UUID { workspaceId }
}

enum PortsHubStopRefusal: Equatable {
    case invalidPID
    case notTracked
    case processChanged
    case alreadyExited
    case signalFailed
}

enum PortsHubStopResult: Equatable {
    /// SIGTERM was sent; SIGKILL follows if the process is still alive after the grace period.
    case signaled
    case refused(PortsHubStopRefusal)
}

/// Aggregates what is listening on TCP ports across every Programa workspace, plus
/// processes that outlived their panel. It observes `PortScanner` through the dedicated
/// process callbacks and never touches the workspace `[Int]` port fields.
@MainActor
final class PortsHubStore: ObservableObject {
    static let shared = PortsHubStore()

    struct Dependencies {
        /// Sends `signal` to `pid`; false when the signal could not be delivered.
        var sendSignal: (_ pid: Int, _ signal: Int32) -> Bool
        var isAlive: (_ pid: Int) -> Bool
        var processName: (_ pid: Int) -> String?
        var startTime: (_ pid: Int) -> UInt64?
        /// Listening TCP ports of `pid`; nil when they cannot be read.
        var listeningPorts: (_ pid: Int) -> [Int]?
        var now: () -> Date
        var schedule: (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Void
        var rescan: (_ workspaceId: UUID, _ panelId: UUID) -> Void
        /// Every workspace across all windows, in display order.
        var workspaces: @MainActor () -> [(id: UUID, title: String)]
        var panelExists: @MainActor (_ workspaceId: UUID, _ panelId: UUID) -> Bool

        static var live: Dependencies {
            Dependencies(
                sendSignal: { pid, signal in kill(pid_t(pid), signal) == 0 },
                isAlive: { pid in
                    kill(pid_t(pid), 0) == 0 || errno == EPERM
                },
                processName: { pid in
                    var buffer = [CChar](repeating: 0, count: 256)
                    let length = proc_name(Int32(pid), &buffer, UInt32(buffer.count))
                    guard length > 0 else { return nil }
                    return String(cString: buffer)
                },
                startTime: { ProcessInspector.startTime(pid: $0) },
                listeningPorts: { ProcessInspector.listeningTCPPorts(pid: $0) },
                now: { Date() },
                schedule: { delay, work in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated { work() }
                    }
                },
                rescan: { workspaceId, panelId in
                    PortScanner.shared.kick(workspaceId: workspaceId, panelId: panelId)
                },
                workspaces: {
                    guard let contexts = AppDelegate.shared?.mainWindowContexts.values else { return [] }
                    return contexts.flatMap { $0.tabManager.tabs.map { (id: $0.id, title: $0.title) } }
                },
                panelExists: { workspaceId, panelId in
                    AppDelegate.shared?.workspaceFor(tabId: workspaceId)?.panels[panelId] != nil
                }
            )
        }
    }

    static let leftoverCap = 50
    /// Grace period before a closed panel's processes are judged survivors.
    static let leftoverCheckDelay: TimeInterval = 5
    /// Grace period between SIGTERM and SIGKILL.
    static let killEscalationDelay: TimeInterval = 3

    @Published private(set) var livePanelProcesses: [PortScanner.PanelKey: [ListeningProcess]] = [:]
    @Published private(set) var liveAgentProcesses: [UUID: [ListeningProcess]] = [:]
    @Published private(set) var leftovers: [LeftoverProcess] = []
    @Published private(set) var stoppingPIDs: Set<Int> = []
    /// Distinct live listening ports plus leftover processes.
    @Published private(set) var badgeCount = 0

    private struct PendingCapture {
        let process: ListeningProcess
        let startTime: UInt64?
        let workspaceTitle: String
        let closedAt: Date
    }

    private let dependencies: Dependencies
    /// Listeners of panels that left their workspace without closing yet (undo-staged
    /// close or window move). Finalizing the close captures them; reattaching drops them.
    private var detachedStash: [UUID: (workspaceId: UUID, processes: [ListeningProcess])] = [:]
    /// Kernel start time of each tracked live pid, recorded the first time the scanner reports it.
    private var startTimes: [Int: UInt64] = [:]

    /// The app-wide hub, wired to the shared scanner. Touching it anywhere starts observation.
    private convenience init() {
        self.init(dependencies: .live, scanner: PortScanner.shared)
    }

    init(dependencies: Dependencies, scanner: PortScanner?) {
        self.dependencies = dependencies
        if let scanner { attach(to: scanner) }
    }

    private func attach(to scanner: PortScanner) {
        scanner.onPanelProcessesUpdated = { [weak self] workspaceId, panelId, processes in
            self?.applyPanelProcesses(workspaceId: workspaceId, panelId: panelId, processes: processes)
        }
        scanner.onAgentProcessesUpdated = { [weak self] workspaceId, processes in
            self?.applyAgentProcesses(workspaceId: workspaceId, processes: processes)
        }
    }

    // MARK: - Scanner input

    func applyPanelProcesses(workspaceId: UUID, panelId: UUID, processes: [ListeningProcess]) {
        guard dependencies.panelExists(workspaceId, panelId) else { return }
        detachedStash.removeValue(forKey: panelId)
        let key = PortScanner.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let newValue = processes.isEmpty ? nil : processes
        guard livePanelProcesses[key] != newValue else { return }
        recordStartTimes(processes)
        livePanelProcesses[key] = newValue
        recomputeBadge()
    }

    func applyAgentProcesses(workspaceId: UUID, processes: [ListeningProcess]) {
        guard dependencies.workspaces().contains(where: { $0.id == workspaceId }) else { return }
        let newValue = processes.isEmpty ? nil : processes
        guard liveAgentProcesses[workspaceId] != newValue else { return }
        recordStartTimes(processes)
        liveAgentProcesses[workspaceId] = newValue
        recomputeBadge()
    }

    // MARK: - Lifecycle capture

    /// A panel was permanently closed: its listeners that are still alive shortly after
    /// are leftovers. Called before the scanner forgets the panel.
    func panelClosed(workspaceId: UUID, panelId: UUID) {
        let key = PortScanner.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let processes = livePanelProcesses.removeValue(forKey: key) else { return }
        capture(processes, workspaceId: workspaceId)
        recomputeBadge()
    }

    /// A panel left its workspace but may come back (undo-staged close or window move).
    func panelDetached(workspaceId: UUID, panelId: UUID) {
        let key = PortScanner.PanelKey(workspaceId: workspaceId, panelId: panelId)
        guard let processes = livePanelProcesses.removeValue(forKey: key) else { return }
        detachedStash[panelId] = (workspaceId, processes)
        recomputeBadge()
    }

    /// A detached panel was closed for good (its undo window ended).
    func detachedPanelFinalized(panelId: UUID) {
        guard let stashed = detachedStash.removeValue(forKey: panelId) else { return }
        capture(stashed.processes, workspaceId: stashed.workspaceId)
    }

    /// A workspace is being torn down: capture its agent-owned listeners and drop its entries.
    func workspaceClosed(workspaceId: UUID) {
        var captured: [ListeningProcess] = []
        for key in livePanelProcesses.keys where key.workspaceId == workspaceId {
            captured.append(contentsOf: livePanelProcesses.removeValue(forKey: key) ?? [])
        }
        captured.append(contentsOf: liveAgentProcesses.removeValue(forKey: workspaceId) ?? [])
        capture(captured, workspaceId: workspaceId)
        recomputeBadge()
    }

    private func capture(_ processes: [ListeningProcess], workspaceId: UUID) {
        guard !processes.isEmpty else { return }
        let title = dependencies.workspaces().first(where: { $0.id == workspaceId })?.title ?? ""
        let closedAt = dependencies.now()
        var seen = Set<Int>()
        let pending = processes.filter { seen.insert($0.pid).inserted }.map {
            PendingCapture(process: $0, startTime: startTimes[$0.pid], workspaceTitle: title, closedAt: closedAt)
        }
        dependencies.schedule(Self.leftoverCheckDelay) { [weak self] in
            self?.promoteSurvivors(pending)
        }
    }

    private func promoteSurvivors(_ pending: [PendingCapture]) {
        var updated = leftovers
        for capture in pending where isSameLiveProcess(
            pid: capture.process.pid,
            command: capture.process.command,
            startTime: capture.startTime
        ) {
            guard !updated.contains(where: { $0.pid == capture.process.pid }) else { continue }
            let ports = currentListeningPorts(pid: capture.process.pid, recorded: capture.process.ports)
            guard !ports.isEmpty else { continue }
            updated.append(LeftoverProcess(
                pid: capture.process.pid,
                command: capture.process.command,
                ports: ports,
                workspaceTitle: capture.workspaceTitle,
                closedAt: capture.closedAt,
                startTime: capture.startTime
            ))
        }
        if updated.count > Self.leftoverCap {
            updated.removeFirst(updated.count - Self.leftoverCap)
        }
        guard updated != leftovers else { return }
        leftovers = updated
        recomputeBadge()
    }

    /// Refreshes leftover ports and drops leftovers that exited, closed every listening
    /// socket, or whose pid now belongs to another process.
    func revalidateLeftovers() {
        let survivors: [LeftoverProcess] = leftovers.compactMap { leftover in
            guard isSameLiveProcess(pid: leftover.pid, command: leftover.command, startTime: leftover.startTime) else {
                return nil
            }
            let ports = currentListeningPorts(pid: leftover.pid, recorded: leftover.ports)
            guard !ports.isEmpty else { return nil }
            guard ports != leftover.ports else { return leftover }
            return LeftoverProcess(
                pid: leftover.pid,
                command: leftover.command,
                ports: ports,
                workspaceTitle: leftover.workspaceTitle,
                closedAt: leftover.closedAt,
                startTime: leftover.startTime
            )
        }
        guard survivors != leftovers else { return }
        leftovers = survivors
        recomputeBadge()
    }

    // MARK: - Stop

    func stop(pid: Int) -> PortsHubStopResult {
        guard pid > 1, pid != Int(getpid()) else { return .refused(.invalidPID) }
        guard let tracked = trackedIdentity(for: pid) else { return .refused(.notTracked) }
        guard dependencies.isAlive(pid) else {
            forget(pid: pid)
            return .refused(.alreadyExited)
        }
        guard isSameLiveProcess(pid: pid, command: tracked.command, startTime: tracked.startTime) else {
            forget(pid: pid)
            return .refused(.processChanged)
        }
        guard dependencies.sendSignal(pid, SIGTERM) else { return .refused(.signalFailed) }

        stoppingPIDs.insert(pid)
        let affectedPanels = panelKeys(containing: pid)
        rescan(affectedPanels)
        dependencies.schedule(Self.killEscalationDelay) { [weak self] in
            guard let self else { return }
            if self.isSameLiveProcess(pid: pid, command: tracked.command, startTime: tracked.startTime) {
                _ = self.dependencies.sendSignal(pid, SIGKILL)
            }
            self.stoppingPIDs.remove(pid)
            self.leftovers.removeAll { $0.pid == pid }
            self.recomputeBadge()
            self.rescan(affectedPanels)
        }
        return .signaled
    }

    /// The command and start time recorded for `pid` when it is a live listener or a leftover.
    private func trackedIdentity(for pid: Int) -> (command: String, startTime: UInt64?)? {
        for processes in livePanelProcesses.values {
            if let match = processes.first(where: { $0.pid == pid }) { return (match.command, startTimes[pid]) }
        }
        for processes in liveAgentProcesses.values {
            if let match = processes.first(where: { $0.pid == pid }) { return (match.command, startTimes[pid]) }
        }
        guard let leftover = leftovers.first(where: { $0.pid == pid }) else { return nil }
        return (leftover.command, leftover.startTime)
    }

    private func forget(pid: Int) {
        for (key, processes) in livePanelProcesses where processes.contains(where: { $0.pid == pid }) {
            let remaining = processes.filter { $0.pid != pid }
            livePanelProcesses[key] = remaining.isEmpty ? nil : remaining
        }
        for (workspaceId, processes) in liveAgentProcesses where processes.contains(where: { $0.pid == pid }) {
            let remaining = processes.filter { $0.pid != pid }
            liveAgentProcesses[workspaceId] = remaining.isEmpty ? nil : remaining
        }
        leftovers.removeAll { $0.pid == pid }
        recomputeBadge()
    }

    private func panelKeys(containing pid: Int) -> [PortScanner.PanelKey] {
        livePanelProcesses.filter { $0.value.contains(where: { $0.pid == pid }) }.map(\.key)
    }

    private func rescan(_ keys: [PortScanner.PanelKey]) {
        for key in keys {
            dependencies.rescan(key.workspaceId, key.panelId)
        }
    }

    // MARK: - Identity checks

    /// True only when `pid` is alive and is provably the process recorded earlier: same
    /// kernel start time and a matching name. An unknown start time never verifies.
    private func isSameLiveProcess(pid: Int, command: String, startTime: UInt64?) -> Bool {
        guard let startTime, dependencies.isAlive(pid), dependencies.startTime(pid) == startTime else { return false }
        return Self.namesMatch(recorded: command, current: dependencies.processName(pid))
    }

    private func recordStartTimes(_ processes: [ListeningProcess]) {
        for process in processes where startTimes[process.pid] == nil {
            if let startTime = dependencies.startTime(process.pid) {
                startTimes[process.pid] = startTime
            }
        }
    }

    /// The live listening ports of `pid`, or `recorded` when they cannot be read.
    private func currentListeningPorts(pid: Int, recorded: [Int]) -> [Int] {
        dependencies.listeningPorts(pid) ?? recorded
    }

    /// Guards against pid reuse. The scanner and `proc_name` can report the same program
    /// with different truncation, so one name being a prefix of the other counts as a match.
    /// An unknown recorded name (empty) matches any live process.
    static func namesMatch(recorded: String, current: String?) -> Bool {
        let recordedKey = normalizedName(recorded)
        guard !recordedKey.isEmpty else { return true }
        guard let current else { return false }
        let currentKey = normalizedName(current)
        guard !currentKey.isEmpty else { return false }
        return recordedKey.hasPrefix(currentKey) || currentKey.hasPrefix(recordedKey)
    }

    private static func normalizedName(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Snapshots

    private func recomputeBadge() {
        var ports = Set<Int>()
        for processes in livePanelProcesses.values {
            for process in processes { ports.formUnion(process.ports) }
        }
        for processes in liveAgentProcesses.values {
            for process in processes { ports.formUnion(process.ports) }
        }
        let count = ports.count + leftovers.count
        if badgeCount != count { badgeCount = count }
        pruneStartTimes()
    }

    /// Start times are only needed while a pid is live or stashed; leftovers and pending
    /// captures carry their own copy.
    private func pruneStartTimes() {
        var tracked = Set<Int>()
        for processes in livePanelProcesses.values { tracked.formUnion(processes.map(\.pid)) }
        for processes in liveAgentProcesses.values { tracked.formUnion(processes.map(\.pid)) }
        for stashed in detachedStash.values { tracked.formUnion(stashed.processes.map(\.pid)) }
        startTimes = startTimes.filter { tracked.contains($0.key) }
    }

    /// Live listeners grouped by workspace in display order. Agent-owned processes
    /// already listed under a terminal surface are not repeated.
    func workspaceSnapshot() -> [PortsHubWorkspace] {
        var result: [PortsHubWorkspace] = []
        for workspace in dependencies.workspaces() {
            var rows: [PortsHubRow] = []
            var seenPIDs = Set<Int>()
            let panelEntries = livePanelProcesses
                .filter { $0.key.workspaceId == workspace.id }
                .sorted { $0.key.panelId.uuidString < $1.key.panelId.uuidString }
            for (key, processes) in panelEntries {
                for process in processes {
                    seenPIDs.insert(process.pid)
                    rows.append(contentsOf: Self.rows(for: process, panelId: key.panelId))
                }
            }
            for process in liveAgentProcesses[workspace.id] ?? [] where !seenPIDs.contains(process.pid) {
                rows.append(contentsOf: Self.rows(for: process, panelId: nil))
            }
            guard !rows.isEmpty else { continue }
            rows.sort { ($0.port, $0.pid) < ($1.port, $1.pid) }
            result.append(PortsHubWorkspace(workspaceId: workspace.id, title: workspace.title, rows: rows))
        }
        return result
    }

    private static func rows(for process: ListeningProcess, panelId: UUID?) -> [PortsHubRow] {
        process.ports.map {
            PortsHubRow(port: $0, pid: process.pid, command: process.command, panelId: panelId)
        }
    }
}
