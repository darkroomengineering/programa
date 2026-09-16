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
}

struct AgentOverviewHelperSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let state: AgentOverviewFriendlyState
    let surfaceId: UUID?
    let hasIndependentOutput: Bool
    let runsWithParent: Bool
    let depth: Int
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
                    matchesState($0.state) && (workspaceMatches || matchesName($0.title))
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
    @Published var filter = AgentOverviewFilter.all { didSet { reconcileVisibleSelection() } }
    @Published var search = "" { didSet { reconcileVisibleSelection() } }

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
        if selection == nil { output = "" }
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
        isShowingMessageSheet = true
    }

    func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection?.allowsTerminalControl == true,
              !trimmed.isEmpty,
              let panel = resolveTerminalPanel() else { return }
        panel.sendInput(trimmed + "\n")
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
                    return AgentOverviewTerminalSnapshot(
                        id: panel.id,
                        title: workspace.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                        state: AgentOverviewFriendlyState.from(activityState: workspace.panelAgentStates[panel.id])
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
                        depth: helperDepth(record, recordsById: recordsById)
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

        windows = nextWindows
        reconcileVisibleSelection()
    }

    private func scopedWorkspaceIds(
        manager: TabManager,
        nodes: [AgentOverviewHierarchyNode]
    ) -> Set<UUID>? {
        guard let scopedWorkspaceId else {
            scopeTitle = nil
            return nil
        }
        guard manager === requestedTabManager,
              let workspace = manager.workspace(withId: scopedWorkspaceId) else {
            scopeTitle = nil
            return []
        }
        scopeTitle = workspace.title
        return AgentOverviewHierarchy.scopedIds(nodes, rootId: scopedWorkspaceId)
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
        output = TerminalController.shared.readTerminalText(
            terminalPanel: panel,
            includeScrollback: false,
            lineLimit: lineLimit
        ) ?? ""
    }
}

@MainActor
final class AgentOverviewWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AgentOverviewWindowController()

    private let viewModel = AgentOverviewViewModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 420)
        window.title = String(localized: "agentOverview.title", defaultValue: "Agent Overview")
        window.identifier = NSUserInterfaceItemIdentifier("programa.agent-overview")
        window.center()
        window.contentView = NSHostingView(rootView: AgentOverviewRootView(viewModel: viewModel))
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

private struct AgentOverviewRootView: View {
    @ObservedObject var viewModel: AgentOverviewViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack {
                TextField(String(localized: "agentOverview.search", defaultValue: "Search workspaces and agents"), text: $viewModel.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(String(localized: "agentOverview.search", defaultValue: "Search workspaces and agents"))
                Picker(String(localized: "agentOverview.filter", defaultValue: "Agent state"), selection: $viewModel.filter) {
                    ForEach(AgentOverviewFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Divider()
            HSplitView {
                workspaceList
                    .frame(minWidth: 420, idealWidth: 520)
                if viewModel.isOutputVisible {
                    outputView
                        .frame(minWidth: 280)
                }
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 820, minHeight: 420)
        .sheet(isPresented: $viewModel.isShowingMessageSheet) {
            sendMessageSheet
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "agentOverview.title", defaultValue: "Agent Overview"))
                    .font(.title2.weight(.semibold))
                if let scopeTitle = viewModel.scopeTitle {
                    Text(scopeTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "agentOverview.allWorkspaces", defaultValue: "All Workspaces"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "agentOverview.allWorkspaces", defaultValue: "All Workspaces")) {
                viewModel.showAllWorkspaces()
            }
            .disabled(!viewModel.hasScope)
        }
        .padding(16)
    }

    private var workspaceList: some View {
        List {
            if viewModel.visibleWindows.isEmpty {
                ContentUnavailableView(
                    String(localized: "agentOverview.empty.title", defaultValue: "No workspaces to show"),
                    systemImage: "rectangle.stack",
                    description: Text(viewModel.windows.isEmpty
                        ? String(localized: "agentOverview.empty.message", defaultValue: "Open a workspace in Programa, then check again.")
                        : String(localized: "agentOverview.empty.filtered", defaultValue: "Try a different search or agent state."))
                )
            }
            ForEach(viewModel.visibleWindows) { window in
                Section {
                    ForEach(window.workspaces) { workspace in
                        workspaceRows(workspace)
                    }
                } header: {
                    Text(String(
                        format: String(localized: "agentOverview.window", defaultValue: "Window %lld"),
                        Int64(window.index + 1)
                    ))
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func workspaceRows(_ workspace: AgentOverviewWorkspaceSnapshot) -> some View {
        Button {
            viewModel.select(.workspace(workspace.id))
        } label: {
            overviewRow(
                title: workspace.title,
                subtitle: [workspace.branchOrPullRequest, workspace.folder]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: String(localized: "agentOverview.metadataSeparator", defaultValue: " · ")),
                state: workspace.state,
                icon: "rectangle.stack.fill",
                selected: viewModel.selection == .workspace(workspace.id)
            )
            .padding(.leading, CGFloat(workspace.depth) * 14)
        }
        .buttonStyle(.plain)

        ForEach(workspace.terminals) { terminal in
            let selection = AgentOverviewSelection.terminal(workspaceId: workspace.id, panelId: terminal.id)
            Button {
                viewModel.select(selection)
            } label: {
                overviewRow(
                    title: terminal.title,
                    subtitle: String(localized: "agentOverview.terminal", defaultValue: "Terminal"),
                    state: terminal.state,
                    icon: "terminal",
                    selected: viewModel.selection == selection
                )
                .padding(.leading, CGFloat(workspace.depth) * 14 + 22)
            }
            .buttonStyle(.plain)
        }

        ForEach(workspace.helpers) { helper in
            let selection = AgentOverviewSelection.helper(
                workspaceId: workspace.id,
                helperId: helper.id,
                surfaceId: helper.surfaceId,
                hasIndependentOutput: helper.hasIndependentOutput
            )
            Button {
                viewModel.select(selection)
            } label: {
                overviewRow(
                    title: helper.title,
                    subtitle: helper.runsWithParent
                        ? String(localized: "agentOverview.runsWithParent", defaultValue: "Runs with parent — output is shared.")
                        : String(localized: "agentOverview.helper", defaultValue: "Helper"),
                    state: helper.state,
                    icon: "person.2",
                    selected: viewModel.selection == selection
                )
                .padding(.leading, CGFloat(workspace.depth + helper.depth) * 14 + 22)
            }
            .buttonStyle(.plain)
        }
    }

    private func overviewRow(
        title: String,
        subtitle: String,
        state: AgentOverviewFriendlyState,
        icon: String,
        selected: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(state.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor(state))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .frame(minHeight: 44)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func stateColor(_ state: AgentOverviewFriendlyState) -> Color {
        switch state {
        case .idle: return .secondary
        case .working: return .blue
        case .needsInput: return .orange
        case .done: return .green
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var outputView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "agentOverview.output", defaultValue: "Output"))
                    .font(.headline)
                Spacer()
                Button(String(localized: "agentOverview.hideOutput", defaultValue: "Hide Output")) {
                    viewModel.hideOutput()
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(viewModel.output.isEmpty
                    ? String(localized: "agentOverview.output.empty", defaultValue: "No output yet.")
                    : viewModel.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Text(String(localized: "agentOverview.programaOnly", defaultValue: "Shows Programa workspaces and helpers only."))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(String(localized: "agentOverview.open", defaultValue: "Open")) {
                viewModel.openSelection()
            }
            .disabled(!viewModel.canOpen)
            Button(String(localized: "agentOverview.sendMessage", defaultValue: "Send Message…")) {
                viewModel.beginSendingMessage()
            }
            .disabled(!viewModel.canUseTerminalActions)
            Button(String(localized: "agentOverview.stop", defaultValue: "Stop")) {
                viewModel.stopTerminal()
            }
            .disabled(!viewModel.canUseTerminalActions)
            Button(String(localized: "agentOverview.reviewChanges", defaultValue: "Review Changes")) {
                viewModel.reviewChanges()
            }
            .disabled(!viewModel.canUseTerminalActions)
            if viewModel.canShowOutput {
                Button(String(localized: "agentOverview.showOutput", defaultValue: "Show Output")) {
                    viewModel.showOutput()
                }
            }
            Button(String(localized: "agentOverview.copyOutput", defaultValue: "Copy Output")) {
                viewModel.copyOutput()
            }
            .disabled(!viewModel.canCopyOutput)
        }
        .padding(12)
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
            HStack {
                Spacer()
                Button(String(localized: "agentOverview.cancel", defaultValue: "Cancel")) {
                    viewModel.isShowingMessageSheet = false
                }
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
