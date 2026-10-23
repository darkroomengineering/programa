import AppKit
import Combine
import SwiftUI

enum AgentOverviewFriendlyState: Equatable, Sendable {
    case idle
    case working
    case needsInput
    case done
    case stopped
    case failed

    static func from(taskState: AgentTaskState) -> Self {
        switch taskState {
        case .idle: return .idle
        case .working: return .working
        case .blocked: return .needsInput
        case .completed: return .done
        case .cancelled: return .stopped
        case .failed: return .failed
        }
    }

    static func from(activityState: AgentActivityState?) -> Self {
        switch activityState {
        case .working: return .working
        case .blocked: return .needsInput
        case .idle, nil: return .idle
        }
    }

    static func from(presence: AgentPresence?) -> Self {
        switch presence?.programState {
        case .done: return .done
        case .error: return .failed
        default: return from(activityState: presence?.state)
        }
    }

    var label: String {
        switch self {
        case .idle:
            return String(localized: "agentOverview.state.idle", defaultValue: "Idle")
        case .working:
            return String(localized: "agentOverview.state.working", defaultValue: "Working")
        case .needsInput:
            return String(localized: "agentOverview.state.needsInput", defaultValue: "Needs input")
        case .done:
            return String(localized: "agentOverview.state.done", defaultValue: "Done")
        case .stopped:
            return String(localized: "agentOverview.state.stopped", defaultValue: "Stopped")
        case .failed:
            return String(localized: "agentOverview.state.failed", defaultValue: "Failed")
        }
    }
}

struct AgentOverviewHierarchyNode: Equatable, Sendable {
    let id: UUID
    let worktreeParentId: UUID?
    let agentParentId: UUID?
    let isWorktreeFolder: Bool

    var sidebarParentId: UUID? {
        worktreeParentId ?? agentParentId
    }
}

enum AgentOverviewHierarchy {
    static func scopedIds(_ nodes: [AgentOverviewHierarchyNode], rootId: UUID) -> Set<UUID> {
        guard let root = nodes.first(where: { $0.id == rootId }) else { return [] }
        var included: Set<UUID> = [rootId]
        var pending = [rootId]

        while let parentId = pending.popLast() {
            for node in nodes where !included.contains(node.id) {
                let isAgentChild = node.agentParentId == parentId
                let isWorktreeChild = root.isWorktreeFolder && node.worktreeParentId == parentId
                guard isAgentChild || isWorktreeChild else { continue }
                included.insert(node.id)
                pending.append(node.id)
            }
        }
        return included
    }

}

enum AgentOverviewSelection: Hashable, Sendable {
    case workspace(UUID)
    case terminal(workspaceId: UUID, panelId: UUID)
    case helper(workspaceId: UUID, helperId: UUID, surfaceId: UUID?, hasIndependentOutput: Bool)

    var workspaceId: UUID {
        switch self {
        case .workspace(let workspaceId),
             .terminal(let workspaceId, _),
             .helper(let workspaceId, _, _, _):
            return workspaceId
        }
    }

    var outputSurfaceId: UUID? {
        switch self {
        case .terminal(_, let panelId): return panelId
        case .helper(_, _, let surfaceId, true): return surfaceId
        case .workspace, .helper: return nil
        }
    }

    /// Reported helpers are descriptive only. A host may associate a helper with the wrong
    /// terminal, so terminal-mutating actions stay on the concrete terminal row.
    var allowsTerminalControl: Bool {
        if case .terminal = self { return true }
        return false
    }
}

struct AgentOverviewOutputGate: Equatable, Sendable {
    private(set) var selection: AgentOverviewSelection?
    private(set) var isOutputVisible = false
    var isWindowVisible = false

    mutating func select(_ selection: AgentOverviewSelection?) {
        guard self.selection != selection else { return }
        self.selection = selection
        isOutputVisible = false
    }

    mutating func showOutput() {
        isOutputVisible = selection?.outputSurfaceId != nil
    }

    mutating func hideOutput() {
        isOutputVisible = false
    }

    mutating func reconcile(availableSelections: Set<AgentOverviewSelection>) {
        guard let selection, !availableSelections.contains(selection) else { return }
        self.selection = nil
        isOutputVisible = false
    }

    var readLineLimit: Int? {
        guard isWindowVisible,
              isOutputVisible,
              selection?.outputSurfaceId != nil else { return nil }
        return 200
    }
}

struct AgentOverviewOutputRefreshGate: Equatable, Sendable {
    private(set) var lastReadAt: Date?

    mutating func shouldRead(now: Date, minimumInterval: TimeInterval = 1) -> Bool {
        if let lastReadAt, now.timeIntervalSince(lastReadAt) < minimumInterval {
            return false
        }
        lastReadAt = now
        return true
    }

    mutating func reset() {
        lastReadAt = nil
    }
}

struct AgentOverviewTerminalSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let state: AgentOverviewFriendlyState
    let isStale: Bool

    init(id: UUID, title: String, state: AgentOverviewFriendlyState, isStale: Bool = false) {
        self.id = id
        self.title = title
        self.state = state
        self.isStale = isStale
    }
}

struct AgentOverviewHelperSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let state: AgentOverviewFriendlyState
    let surfaceId: UUID?
    let hasIndependentOutput: Bool
    let runsWithParent: Bool
    let depth: Int
    /// The agent type (planner, implementer), shown under a task title that differs from it.
    let role: String?
    let summary: String?
    let startedAt: Date
    let endedAt: Date?

    init(
        id: UUID, title: String, state: AgentOverviewFriendlyState, surfaceId: UUID?,
        hasIndependentOutput: Bool, runsWithParent: Bool, depth: Int,
        role: String? = nil, summary: String? = nil, startedAt: Date = Date(), endedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.surfaceId = surfaceId
        self.hasIndependentOutput = hasIndependentOutput
        self.runsWithParent = runsWithParent
        self.depth = depth
        self.role = role
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Done and stopped helpers fold into one row; failed ones stay visible.
    var isSettled: Bool { state == .done || state == .stopped }

    func duration(now: Date) -> TimeInterval { max(0, (endedAt ?? now).timeIntervalSince(startedAt)) }
}

struct AgentOverviewWorkspaceSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let state: AgentOverviewFriendlyState
    let branchOrPullRequest: String?
    let folder: String
    let depth: Int
    let terminals: [AgentOverviewTerminalSnapshot]
    let helpers: [AgentOverviewHelperSnapshot]
}

struct AgentOverviewWindowSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let index: Int
    let workspaces: [AgentOverviewWorkspaceSnapshot]
}

enum AgentOverviewFormatting {
    static func shortenedFolder(_ path: String, maximumComponents: Int = 2) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let components = URL(fileURLWithPath: trimmed).standardized.pathComponents
            .filter { $0 != "/" }
        guard components.count > maximumComponents else {
            return components.joined(separator: "/")
        }
        return "…/" + components.suffix(maximumComponents).joined(separator: "/")
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func duration(_ interval: TimeInterval) -> String {
        durationFormatter.string(from: interval.rounded(.down)) ?? ""
    }
}

enum AgentOverviewFilter: String, CaseIterable {
    case all, needsInput, failed

    var label: String {
        switch self {
        case .all: return String(localized: "agentOverview.filter.all", defaultValue: "All")
        case .needsInput: return AgentOverviewFriendlyState.needsInput.label
        case .failed: return AgentOverviewFriendlyState.failed.label
        }
    }

    func apply(to windows: [AgentOverviewWindowSnapshot], search: String) -> [AgentOverviewWindowSnapshot] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self != .all || !query.isEmpty else { return windows }
        func matchesState(_ state: AgentOverviewFriendlyState) -> Bool {
            self == .all || (self == .needsInput && state == .needsInput) || (self == .failed && state == .failed)
        }
        func matchesName(_ name: String) -> Bool {
            query.isEmpty || name.localizedCaseInsensitiveContains(query)
        }
        return windows.compactMap { window in
            let workspaces = window.workspaces.compactMap { workspace -> AgentOverviewWorkspaceSnapshot? in
                let workspaceMatches = matchesName(workspace.title)
                let terminals = workspace.terminals.filter {
                    matchesState($0.state) && (workspaceMatches || matchesName($0.title))
                }
                let helpers = workspace.helpers.filter {
                    matchesState($0.state) && (workspaceMatches || matchesName($0.title) || matchesName($0.role ?? ""))
                }
                guard (workspaceMatches && matchesState(workspace.state)) || !terminals.isEmpty || !helpers.isEmpty else { return nil }
                return AgentOverviewWorkspaceSnapshot(
                    id: workspace.id, title: workspace.title, state: workspace.state,
                    branchOrPullRequest: workspace.branchOrPullRequest, folder: workspace.folder,
                    depth: 0, terminals: terminals, helpers: helpers
                )
            }
            guard !workspaces.isEmpty else { return nil }
            return AgentOverviewWindowSnapshot(id: window.id, index: window.index, workspaces: workspaces)
        }
    }
}

@MainActor
final class AgentOverviewViewModel: ObservableObject {
    @Published private(set) var windows: [AgentOverviewWindowSnapshot] = []
    @Published private(set) var scopeTitle: String?
    @Published private(set) var hasScope = false
    @Published private(set) var output = ""
    @Published private(set) var outputGate = AgentOverviewOutputGate()
    @Published var messageText = ""
    @Published var isShowingMessageSheet = false
    @Published var messageSendError: String?
    @Published var filter = AgentOverviewFilter.all { didSet { reconcileVisibleSelection() } }
    @Published var search = "" { didSet { reconcileVisibleSelection() } }
    @Published var expandedSettledHelperWorkspaces: Set<UUID> = []

    var visibleWindows: [AgentOverviewWindowSnapshot] { filter.apply(to: windows, search: search) }

    private func reconcileVisibleSelection() {
        var selections: Set<AgentOverviewSelection> = []
        for workspace in visibleWindows.flatMap(\.workspaces) {
            selections.insert(.workspace(workspace.id))
            for terminal in workspace.terminals {
                selections.insert(.terminal(workspaceId: workspace.id, panelId: terminal.id))
            }
            for helper in workspace.helpers {
                selections.insert(.helper(workspaceId: workspace.id, helperId: helper.id,
                                          surfaceId: helper.surfaceId, hasIndependentOutput: helper.hasIndependentOutput))
            }
        }
        outputGate.reconcile(availableSelections: selections)
        if selection == nil, !output.isEmpty { output = "" }
    }

    weak var requestedTabManager: TabManager?
    private var scopedWorkspaceId: UUID?
    private var refreshTimer: Timer?
    private var outputRefreshGate = AgentOverviewOutputRefreshGate()

    var selection: AgentOverviewSelection? { outputGate.selection }
    var isOutputVisible: Bool { outputGate.isOutputVisible }
    var canShowOutput: Bool { selection?.outputSurfaceId != nil && !isOutputVisible }
    var canOpen: Bool { resolveSelection() != nil }
    var canUseTerminalActions: Bool {
        selection?.allowsTerminalControl == true && resolveTerminalPanel() != nil
    }
    var canCopyOutput: Bool { isOutputVisible && !output.isEmpty }

    var selectedWorkspace: AgentOverviewWorkspaceSnapshot? {
        guard let workspaceId = selection?.workspaceId else { return nil }
        return windows.lazy.flatMap(\.workspaces).first { $0.id == workspaceId }
    }

    var selectedHelper: AgentOverviewHelperSnapshot? {
        guard case .helper(_, let helperId, _, _) = selection else { return nil }
        return selectedWorkspace?.helpers.first { $0.id == helperId }
    }

    var selectedTerminal: AgentOverviewTerminalSnapshot? {
        guard case .terminal(_, let panelId) = selection else { return nil }
        return selectedWorkspace?.terminals.first { $0.id == panelId }
    }

    var canCopyReport: Bool { selectedHelper?.summary?.isEmpty == false }

    var settledHelperCount: Int {
        windows.flatMap(\.workspaces).reduce(0) { $0 + $1.helpers.filter(\.isSettled).count }
    }

    func clearSettledHelpers() {
        let workspaceIds = Set(windows.flatMap(\.workspaces).map(\.id))
        AgentSupervisionRegistry.shared.discardSettled(workspaceIds: workspaceIds)
        expandedSettledHelperWorkspaces.removeAll()
        rebuildSnapshot()
    }

    func copyReport() {
        guard let summary = selectedHelper?.summary, !summary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    func configure(tabManager: TabManager, workspaceId: UUID?) {
        requestedTabManager = tabManager
        scopedWorkspaceId = workspaceId
        hasScope = workspaceId != nil
        outputGate.select(nil)
        output = ""
        filter = .all
        search = ""
    }

    func showAllWorkspaces() {
        scopedWorkspaceId = nil
        scopeTitle = nil
        hasScope = false
        outputGate.select(nil)
        output = ""
        refreshMetadataAndOutput()
    }

    func setWindowVisible(_ visible: Bool) {
        outputGate.isWindowVisible = visible
        if visible {
            startRefreshing()
            refreshMetadataAndOutput()
        } else {
            stopRefreshing()
        }
    }

    func startRefreshing() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetadataAndOutput()
            }
        }
    }

    func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func select(_ selection: AgentOverviewSelection) {
        outputGate.select(selection)
        outputRefreshGate.reset()
        output = ""
    }

    func showOutput() {
        outputGate.showOutput()
        outputRefreshGate.reset()
        refreshOutput()
    }

    func hideOutput() {
        outputGate.hideOutput()
        outputRefreshGate.reset()
        output = ""
    }

    func openSelection() {
        guard let resolved = resolveSelection(),
              let appDelegate = AppDelegate.shared,
              let windowState = appDelegate.scriptableMainWindowForTab(resolved.workspace.id) else { return }
        _ = appDelegate.focusScriptableMainWindow(windowId: windowState.windowId, bringToFront: true)
        resolved.manager.selectWorkspace(resolved.workspace)
        if let panel = resolved.panel {
            resolved.workspace.focusPanel(panel.id)
        }
    }

    func beginSendingMessage() {
        guard canUseTerminalActions else { return }
        messageText = ""
        messageSendError = nil
        isShowingMessageSheet = true
    }

    func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard selection?.allowsTerminalControl == true,
              let resolved = resolveSelection(),
              let panel = resolved.panel else {
            // Keep the sheet and the draft so the user can retry once the terminal is back.
            messageSendError = String(
                localized: "workspace.agentOverview.sendMessage.unavailable",
                defaultValue: "This terminal is no longer available. Your message was not sent."
            )
            return
        }
        resolved.workspace.deliverTextToAgent(trimmed, terminalPanel: panel)
        messageSendError = nil
        isShowingMessageSheet = false
        messageText = ""
    }

    func stopTerminal() {
        guard selection?.allowsTerminalControl == true else { return }
        _ = resolveTerminalPanel()?.surface.sendNamedKey("ctrl-c")
    }

    func reviewChanges() {
        guard selection?.allowsTerminalControl == true,
              let resolved = resolveSelection(),
              let panel = resolved.panel else { return }
        _ = resolved.workspace.newReviewSplit(
            from: panel.id,
            orientation: .horizontal,
            focus: true
        )
    }

    func copyOutput() {
        guard canCopyOutput else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    func refreshMetadataAndOutput() {
        rebuildSnapshot()
        refreshOutput()
    }

    private func rebuildSnapshot() {
        let liveWindows = liveWindowStates()
        var nextWindows: [AgentOverviewWindowSnapshot] = []

        for (windowIndex, state) in liveWindows.enumerated() {
            let manager = state.tabManager
            let nodes = manager.tabs.map {
                AgentOverviewHierarchyNode(
                    id: $0.id,
                    worktreeParentId: $0.worktreeParentWorkspaceId,
                    agentParentId: $0.agentParentWorkspaceId,
                    isWorktreeFolder: $0.isWorktreeFolder
                )
            }
            let hierarchyEntries = nodes.map {
                SidebarWorkspaceHierarchyEntry(
                    id: $0.id,
                    parentId: $0.sidebarParentId,
                    isFolder: $0.isWorktreeFolder,
                    isCollapsed: false
                )
            }
            let scopedIds: Set<UUID>? = scopedWorkspaceIds(manager: manager, nodes: nodes)
            let workspaceById = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0) })
            let orderedIds = SidebarWorkspaceHierarchy.visibleWorkspaceIds(hierarchyEntries)
            var workspaceSnapshots: [AgentOverviewWorkspaceSnapshot] = []

            for workspaceId in orderedIds {
                guard scopedIds?.contains(workspaceId) ?? true,
                      let workspace = workspaceById[workspaceId] else { continue }
                let records = AgentSupervisionRegistry.shared.records(workspaceIds: [workspace.id])
                let recordsById = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
                let orderedPanelIds = workspace.sidebarOrderedPanelIds()
                let terminals = orderedPanelIds.compactMap { panelId -> AgentOverviewTerminalSnapshot? in
                    guard let panel = workspace.panels[panelId] as? TerminalPanel else { return nil }
                    let presence = workspace.panelAgentPresence[panel.id]
                    return AgentOverviewTerminalSnapshot(
                        id: panel.id,
                        title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                        state: AgentOverviewFriendlyState.from(presence: presence),
                        isStale: presence?.isStale(now: Date()) ?? false
                    )
                }
                let helpers = records.map { record in
                    return AgentOverviewHelperSnapshot(
                        id: record.id,
                        title: helperTitle(record),
                        state: AgentOverviewFriendlyState.from(taskState: record.state),
                        surfaceId: record.surfaceId,
                        hasIndependentOutput: record.hasIndependentOutput,
                        runsWithParent: record.placement == .runsWithParent,
                        depth: helperDepth(record, recordsById: recordsById),
                        role: record.role,
                        summary: record.summary,
                        startedAt: record.startedAt,
                        endedAt: record.endedAt
                    )
                }
                workspaceSnapshots.append(
                    AgentOverviewWorkspaceSnapshot(
                        id: workspace.id,
                        title: workspace.title,
                        state: AgentOverviewFriendlyState.from(
                            taskState: AgentSupervisionMetadata.aggregateTaskState(
                                for: workspace,
                                records: records
                            ) ?? .idle
                        ),
                        branchOrPullRequest: branchOrPullRequest(workspace),
                        folder: AgentOverviewFormatting.shortenedFolder(workspace.currentDirectory),
                        depth: SidebarWorkspaceHierarchy.depth(
                            of: workspace.id,
                            entries: hierarchyEntries
                        ),
                        terminals: terminals,
                        helpers: helpers
                    )
                )
            }
            guard !workspaceSnapshots.isEmpty else { continue }
            nextWindows.append(
                AgentOverviewWindowSnapshot(
                    id: state.windowId,
                    index: windowIndex,
                    workspaces: workspaceSnapshots
                )
            )
        }

        // The refresh runs every second; reassigning an equal snapshot would still
        // re-render every row and reset hover and scroll state.
        if windows != nextWindows { windows = nextWindows }
        reconcileVisibleSelection()
    }

    private func scopedWorkspaceIds(
        manager: TabManager,
        nodes: [AgentOverviewHierarchyNode]
    ) -> Set<UUID>? {
        guard let scopedWorkspaceId else {
            setScopeTitle(nil)
            return nil
        }
        guard manager === requestedTabManager,
              let workspace = manager.workspace(withId: scopedWorkspaceId) else {
            setScopeTitle(nil)
            return []
        }
        setScopeTitle(workspace.title)
        return AgentOverviewHierarchy.scopedIds(nodes, rootId: scopedWorkspaceId)
    }

    private func setScopeTitle(_ title: String?) {
        if scopeTitle != title { scopeTitle = title }
    }

    private func liveWindowStates() -> [AppDelegate.ScriptableMainWindowState] {
        guard let appDelegate = AppDelegate.shared else { return [] }
        let states = appDelegate.scriptableMainWindows()
        if scopedWorkspaceId == nil { return states }
        return states.filter { $0.tabManager === requestedTabManager }
    }

    private func branchOrPullRequest(_ workspace: Workspace) -> String? {
        if let pullRequest = workspace.sidebarPullRequestsInDisplayOrder().first ?? workspace.pullRequest {
            let format = String(localized: "agentOverview.pullRequest", defaultValue: "PR #%lld")
            return String(format: format, Int64(pullRequest.number))
        }
        return workspace.sidebarGitBranchesInDisplayOrder().first?.branch
            ?? workspace.gitBranch?.branch
            ?? workspace.worktreeBranch
    }

    private func helperTitle(_ record: AgentTaskRecord) -> String {
        for candidate in [record.task, record.role] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return String(localized: "agentOverview.helper", defaultValue: "Helper")
    }

    private func helperDepth(
        _ record: AgentTaskRecord,
        recordsById: [UUID: AgentTaskRecord]
    ) -> Int {
        var depth = 0
        var parentId = record.parentId
        var visited: Set<UUID> = [record.id]
        while let currentId = parentId,
              visited.insert(currentId).inserted,
              let parent = recordsById[currentId] {
            depth += 1
            parentId = parent.parentId
        }
        return depth
    }

    private struct ResolvedSelection {
        let manager: TabManager
        let workspace: Workspace
        let panel: TerminalPanel?
    }

    private func resolveSelection() -> ResolvedSelection? {
        guard let selection else { return nil }
        for state in liveWindowStates() {
            guard let workspace = state.tabManager.workspace(withId: selection.workspaceId) else { continue }
            let panel = selection.outputSurfaceId.flatMap { workspace.panels[$0] as? TerminalPanel }
            return ResolvedSelection(manager: state.tabManager, workspace: workspace, panel: panel)
        }
        return nil
    }

    private func resolveTerminalPanel() -> TerminalPanel? {
        resolveSelection()?.panel
    }

    private func refreshOutput() {
        guard let lineLimit = outputGate.readLineLimit,
              let panel = resolveTerminalPanel(),
              outputRefreshGate.shouldRead(now: Date()) else { return }
        let text = TerminalController.shared.readTerminalText(
            terminalPanel: panel,
            includeScrollback: false,
            lineLimit: lineLimit
        ) ?? ""
        if text != output { output = text }
    }
}

@MainActor
final class AgentOverviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentOverviewWindowController()

    private let viewModel = AgentOverviewViewModel()

    private init() {
        let hostingController = NSHostingController(rootView: AgentOverviewRootView(viewModel: viewModel))
        // Puts the SwiftUI title, toolbar and sidebar search field in the window's unified toolbar.
        hostingController.sceneBridgingOptions = [.title, .toolbars]
        // Without this the window snaps to the SwiftUI ideal size whenever content changes.
        hostingController.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 980, height: 640))
        window.isReleasedWhenClosed = false
        window.title = String(localized: "agentOverview.title", defaultValue: "Agent Overview")
        window.identifier = NSUserInterfaceItemIdentifier("programa.agent-overview")
        window.setFrameAutosaveName("programa.agent-overview")
        if !window.setFrameUsingName("programa.agent-overview") { window.center() }
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tabManager: TabManager, workspaceId: UUID?) {
        guard let window else { return }
        viewModel.configure(tabManager: tabManager, workspaceId: workspaceId)
        viewModel.setWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.setWindowVisible(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        viewModel.setWindowVisible(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        viewModel.setWindowVisible(true)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        viewModel.setWindowVisible(window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }
}

private extension AgentOverviewFriendlyState {
    var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .working: return "circle.fill"
        case .needsInput: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .failed: return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .stopped: return .secondary
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .failed: return .red
        }
    }
}

private struct AgentOverviewStateIndicator: View {
    let state: AgentOverviewFriendlyState
    var isStale = false

    var body: some View {
        Image(systemName: state.symbolName)
            .imageScale(.small)
            .foregroundStyle(state.tint)
            .opacity(isStale ? 0.5 : 1)
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

private struct AgentOverviewStateBadge: View {
    let state: AgentOverviewFriendlyState

    var body: some View {
        Label(state.label, systemImage: state.symbolName)
            .font(.callout.weight(.medium))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(state.tint.opacity(0.12), in: Capsule())
    }
}

/// Only running helpers tick, and only this text re-renders each second.
private struct AgentOverviewDurationText: View {
    let startedAt: Date
    let endedAt: Date?

    var body: some View {
        if let endedAt {
            Text(AgentOverviewFormatting.duration(max(0, endedAt.timeIntervalSince(startedAt))))
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(AgentOverviewFormatting.duration(max(0, context.date.timeIntervalSince(startedAt))))
            }
        }
    }
}

private struct AgentOverviewRootView: View {
    @ObservedObject var viewModel: AgentOverviewViewModel

    private var separator: String {
        String(localized: "agentOverview.metadataSeparator", defaultValue: " · ")
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 460)
        } detail: {
            detail
        }
        .navigationTitle(String(localized: "agentOverview.title", defaultValue: "Agent Overview"))
        .navigationSubtitle(viewModel.scopeTitle
            ?? String(localized: "agentOverview.allWorkspaces", defaultValue: "All Workspaces"))
        .searchable(
            text: $viewModel.search,
            placement: .sidebar,
            prompt: Text(String(localized: "agentOverview.search", defaultValue: "Search workspaces and agents"))
        )
        .toolbar { toolbarContent }
        .frame(minWidth: 760, minHeight: 440)
        .sheet(isPresented: $viewModel.isShowingMessageSheet) {
            sendMessageSheet
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if viewModel.hasScope {
                Button {
                    viewModel.showAllWorkspaces()
                } label: {
                    Label(String(localized: "agentOverview.allWorkspaces", defaultValue: "All Workspaces"),
                          systemImage: "rectangle.stack")
                }
                .help(String(localized: "agentOverview.allWorkspaces", defaultValue: "All Workspaces"))
            }
            Picker(String(localized: "agentOverview.filter", defaultValue: "Agent state"), selection: $viewModel.filter) {
                ForEach(AgentOverviewFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .help(String(localized: "agentOverview.filter", defaultValue: "Agent state"))
            Button {
                viewModel.openSelection()
            } label: {
                Label(String(localized: "agentOverview.showInWorkspace", defaultValue: "Show in Workspace"),
                      systemImage: "arrow.up.forward.app")
            }
            .disabled(!viewModel.canOpen)
            .help(String(localized: "agentOverview.showInWorkspace", defaultValue: "Show in Workspace"))
            Button {
                viewModel.clearSettledHelpers()
            } label: {
                Label(String(localized: "agentOverview.clearDone", defaultValue: "Clear Done"), systemImage: "eraser")
            }
            .disabled(viewModel.settledHelperCount == 0)
            .help(String(localized: "agentOverview.clearDone.help", defaultValue: "Remove done and stopped helpers from the list"))
        }
    }

    // MARK: Sidebar

    private var selectionBinding: Binding<AgentOverviewSelection?> {
        Binding(
            get: { viewModel.selection },
            set: { selection in
                if let selection { viewModel.select(selection) }
            }
        )
    }

    private var visibleWorkspaces: [AgentOverviewWorkspaceSnapshot] {
        viewModel.visibleWindows.flatMap(\.workspaces)
    }

    private var sidebar: some View {
        List(selection: selectionBinding) {
            ForEach(visibleWorkspaces) { workspace in
                Section {
                    workspaceRows(workspace)
                } header: {
                    workspaceHeader(workspace)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: AgentOverviewSelection.self) { selections in
            if let selection = selections.first {
                rowMenu(selection)
            }
        } primaryAction: { selections in
            guard let selection = selections.first else { return }
            viewModel.select(selection)
            viewModel.openSelection()
        }
        .overlay {
            if visibleWorkspaces.isEmpty {
                if viewModel.windows.isEmpty {
                    ContentUnavailableView(
                        String(localized: "agentOverview.empty.title", defaultValue: "No workspaces to show"),
                        systemImage: "rectangle.stack",
                        description: Text(String(localized: "agentOverview.empty.message", defaultValue: "Open a workspace in Programa, then check again."))
                    )
                } else {
                    ContentUnavailableView(
                        String(localized: "agentOverview.empty.title", defaultValue: "No workspaces to show"),
                        systemImage: "magnifyingglass",
                        description: Text(String(localized: "agentOverview.empty.filtered", defaultValue: "Try a different search or agent state."))
                    )
                }
            }
        }
    }

    private func workspaceHeader(_ workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        HStack(spacing: 6) {
            Text(workspace.title)
                .lineLimit(1)
            if let branch = workspace.branchOrPullRequest, !branch.isEmpty {
                Text(branch)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            AgentOverviewStateIndicator(state: workspace.state)
        }
        .padding(.leading, CGFloat(workspace.depth) * 10)
        .contextMenu {
            Button(String(localized: "agentOverview.openWorkspace", defaultValue: "Open Workspace")) {
                viewModel.select(.workspace(workspace.id))
                viewModel.openSelection()
            }
            Button(String(localized: "agentOverview.workspaceDetails", defaultValue: "Show Details")) {
                viewModel.select(.workspace(workspace.id))
            }
        }
    }

    @ViewBuilder
    private func workspaceRows(_ workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        ForEach(workspace.terminals) { terminal in
            sidebarRow(
                title: terminal.title,
                subtitle: String(localized: "agentOverview.terminal", defaultValue: "Terminal"),
                icon: "terminal",
                state: terminal.state,
                isStale: terminal.isStale
            )
            .tag(AgentOverviewSelection.terminal(workspaceId: workspace.id, panelId: terminal.id))
        }

        let foldsSettled = viewModel.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let settled = foldsSettled ? workspace.helpers.filter(\.isSettled) : []
        ForEach(workspace.helpers.filter { !foldsSettled || !$0.isSettled }) { helper in
            helperRow(helper, workspace: workspace)
        }
        if !settled.isEmpty {
            DisclosureGroup(isExpanded: settledExpansion(workspace.id)) {
                ForEach(settled) { helper in
                    helperRow(helper, workspace: workspace)
                }
            } label: {
                Text(String(
                    format: String(localized: "agentOverview.finishedHelpers", defaultValue: "%lld finished"),
                    Int64(settled.count)
                ))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func settledExpansion(_ workspaceId: UUID) -> Binding<Bool> {
        Binding(
            get: { viewModel.expandedSettledHelperWorkspaces.contains(workspaceId) },
            set: { expanded in
                if expanded {
                    viewModel.expandedSettledHelperWorkspaces.insert(workspaceId)
                } else {
                    viewModel.expandedSettledHelperWorkspaces.remove(workspaceId)
                }
            }
        )
    }

    private func helperRow(_ helper: AgentOverviewHelperSnapshot, workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        let role = helper.role.flatMap { $0 == helper.title ? nil : $0 }
        return sidebarRow(
            title: helper.title,
            subtitle: role ?? String(localized: "agentOverview.helper", defaultValue: "Helper"),
            icon: helper.summary == nil ? "person.2" : "text.bubble",
            state: helper.state,
            startedAt: helper.startedAt,
            endedAt: helper.endedAt
        )
        .tag(AgentOverviewSelection.helper(
            workspaceId: workspace.id,
            helperId: helper.id,
            surfaceId: helper.surfaceId,
            hasIndependentOutput: helper.hasIndependentOutput
        ))
    }

    private func sidebarRow(
        title: String,
        subtitle: String,
        icon: String,
        state: AgentOverviewFriendlyState,
        isStale: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let startedAt {
                AgentOverviewDurationText(startedAt: startedAt, endedAt: endedAt)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            AgentOverviewStateIndicator(state: state, isStale: isStale)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func rowMenu(_ selection: AgentOverviewSelection) -> some View {
        Button(String(localized: "agentOverview.open", defaultValue: "Open")) {
            viewModel.select(selection)
            viewModel.openSelection()
        }
        if selection.allowsTerminalControl {
            Divider()
            Button(String(localized: "agentOverview.sendMessage", defaultValue: "Send Message…")) {
                viewModel.select(selection)
                viewModel.beginSendingMessage()
            }
            Button(String(localized: "agentOverview.reviewChanges", defaultValue: "Review Changes")) {
                viewModel.select(selection)
                viewModel.reviewChanges()
            }
            Button(String(localized: "agentOverview.stop", defaultValue: "Stop")) {
                viewModel.select(selection)
                viewModel.stopTerminal()
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let workspace = viewModel.selectedWorkspace {
            if let helper = viewModel.selectedHelper {
                helperDetail(helper, workspace: workspace)
            } else if let terminal = viewModel.selectedTerminal {
                terminalDetail(terminal, workspace: workspace)
            } else if case .workspace = viewModel.selection {
                workspaceDetail(workspace)
            } else {
                noSelection
            }
        } else {
            noSelection
        }
    }

    private var noSelection: some View {
        ContentUnavailableView(
            String(localized: "agentOverview.noSelection.title", defaultValue: "No Selection"),
            systemImage: "sidebar.left",
            description: Text(String(localized: "agentOverview.noSelection.message", defaultValue: "Select a terminal or helper to see its details.")
            )
        )
    }

    private func detailHeader(title: String, subtitle: String, icon: String, state: AgentOverviewFriendlyState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentOverviewStateBadge(state: state)
        }
        .padding(.vertical, 4)
    }

    private func helperDetail(_ helper: AgentOverviewHelperSnapshot, workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        Form {
            Section {
                detailHeader(
                    title: helper.title,
                    subtitle: workspace.title,
                    icon: helper.summary == nil ? "person.2" : "text.bubble",
                    state: helper.state
                )
            }
            Section {
                if let role = helper.role {
                    LabeledContent(String(localized: "agentOverview.field.agent", defaultValue: "Agent"), value: role)
                }
                LabeledContent(String(localized: "agentOverview.field.started", defaultValue: "Started")) {
                    Text(helper.startedAt, format: .dateTime.hour().minute().second())
                }
                LabeledContent(helper.endedAt == nil
                    ? String(localized: "agentOverview.field.runningFor", defaultValue: "Running for")
                    : String(localized: "agentOverview.field.ranFor", defaultValue: "Ran for")) {
                    AgentOverviewDurationText(startedAt: helper.startedAt, endedAt: helper.endedAt)
                        .monospacedDigit()
                }
            }
            Section {
                if let summary = helper.summary, !summary.isEmpty {
                    Text(Self.inlineMarkdown(summary))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(helper.endedAt == nil
                        ? String(localized: "agentOverview.helper.report.pending", defaultValue: "The report appears here when this helper finishes.")
                        : String(localized: "agentOverview.helper.report.none", defaultValue: "This helper finished without a report."))
                        .foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text(String(localized: "agentOverview.report", defaultValue: "Report"))
                    Spacer()
                    if viewModel.canCopyReport {
                        Button(String(localized: "agentOverview.copy", defaultValue: "Copy")) {
                            viewModel.copyReport()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func terminalDetail(_ terminal: AgentOverviewTerminalSnapshot, workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        Form {
            Section {
                detailHeader(
                    title: terminal.title,
                    subtitle: workspace.title,
                    icon: "terminal",
                    state: terminal.state
                )
                HStack(spacing: 8) {
                    Button(String(localized: "agentOverview.open", defaultValue: "Open")) {
                        viewModel.openSelection()
                    }
                    .disabled(!viewModel.canOpen)
                    Button(String(localized: "agentOverview.sendMessage", defaultValue: "Send Message…")) {
                        viewModel.beginSendingMessage()
                    }
                    Button(String(localized: "agentOverview.reviewChanges", defaultValue: "Review Changes")) {
                        viewModel.reviewChanges()
                    }
                    Spacer()
                    Button(String(localized: "agentOverview.stop", defaultValue: "Stop"), role: .destructive) {
                        viewModel.stopTerminal()
                    }
                }
                .disabled(!viewModel.canUseTerminalActions)
            }
            Section {
                if viewModel.isOutputVisible {
                    Text(viewModel.output.isEmpty
                        ? String(localized: "agentOverview.output.empty", defaultValue: "No output yet.")
                        : viewModel.output)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(viewModel.output.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button(String(localized: "agentOverview.showOutput", defaultValue: "Show Output")) {
                        viewModel.showOutput()
                    }
                    .disabled(!viewModel.canShowOutput)
                }
            } header: {
                HStack {
                    Text(String(localized: "agentOverview.output", defaultValue: "Output"))
                    Spacer()
                    if viewModel.isOutputVisible {
                        Button(String(localized: "agentOverview.copy", defaultValue: "Copy")) {
                            viewModel.copyOutput()
                        }
                        .disabled(!viewModel.canCopyOutput)
                        Button(String(localized: "agentOverview.hideOutput", defaultValue: "Hide Output")) {
                            viewModel.hideOutput()
                        }
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private func workspaceDetail(_ workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        let running = workspace.helpers.filter { !$0.isSettled && $0.state != .failed }.count
        return Form {
            Section {
                detailHeader(
                    title: workspace.title,
                    subtitle: [workspace.branchOrPullRequest, workspace.folder]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: separator),
                    icon: "rectangle.stack",
                    state: workspace.state
                )
            }
            Section {
                LabeledContent(String(localized: "agentOverview.field.terminals", defaultValue: "Terminals"),
                               value: workspace.terminals.count.formatted())
                LabeledContent(String(localized: "agentOverview.field.runningHelpers", defaultValue: "Running helpers"),
                               value: running.formatted())
                LabeledContent(String(localized: "agentOverview.field.finishedHelpers", defaultValue: "Finished helpers"),
                               value: (workspace.helpers.count - running).formatted())
            }
            Section {
                Button(String(localized: "agentOverview.openWorkspace", defaultValue: "Open Workspace")) {
                    viewModel.openSelection()
                }
                .disabled(!viewModel.canOpen)
            }
        }
        .formStyle(.grouped)
    }

    /// Reports are markdown; render inline styling, show headings as bold lines, and keep
    /// the line structure as written.
    private static func inlineMarkdown(_ text: String) -> AttributedString {
        let source = text.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]+(.+?)[ \\t#]*$",
            with: "**$1**",
            options: .regularExpression
        )
        return (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private var sendMessageSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "agentOverview.sendMessage.title", defaultValue: "Send a Message"))
                .font(.headline)
            TextField(
                String(localized: "agentOverview.sendMessage.placeholder", defaultValue: "Type a message"),
                text: $viewModel.messageText,
                axis: .vertical
            )
            .lineLimit(3...8)
            .textFieldStyle(.roundedBorder)
            if let error = viewModel.messageSendError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(String(localized: "agentOverview.cancel", defaultValue: "Cancel")) {
                    viewModel.isShowingMessageSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Button(String(localized: "agentOverview.send", defaultValue: "Send")) {
                    viewModel.sendMessage()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
