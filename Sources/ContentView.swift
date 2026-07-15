import AppKit
import Bonsplit
import Combine
import ImageIO
import SwiftUI
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let windowId: UUID
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @EnvironmentObject var programaConfigStore: ProgramaConfigStore
    @State var sidebarWidth: CGFloat = 200
    @State var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State var isResizerDragging = false
    @State var sidebarDragStartWidth: CGFloat?
    @State private var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State private var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State var observedWindow: NSWindow?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @State private var previousSelectedWorkspaceId: UUID?
    @State private var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State private var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State private var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State var sidebarResizerPointerMonitor: Any?
    @State var isResizerBandActive = false
    @State var isSidebarResizerCursorActive = false
    @State var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @StateObject private var commandPaletteController = CommandPaletteController()
    private var isCommandPalettePresented: Bool {
        get { commandPaletteController.isCommandPalettePresented }
        nonmutating set { commandPaletteController.isCommandPalettePresented = newValue }
    }
    private var commandPaletteQuery: String {
        get { commandPaletteController.commandPaletteQuery }
        nonmutating set { commandPaletteController.commandPaletteQuery = newValue }
    }
    private var commandPaletteMode: CommandPaletteMode {
        get { commandPaletteController.commandPaletteMode }
        nonmutating set { commandPaletteController.commandPaletteMode = newValue }
    }
    private var commandPaletteRenameDraft: String {
        get { commandPaletteController.commandPaletteRenameDraft }
        nonmutating set { commandPaletteController.commandPaletteRenameDraft = newValue }
    }
    private var commandPaletteWorkspaceDescriptionDraft: String {
        get { commandPaletteController.commandPaletteWorkspaceDescriptionDraft }
        nonmutating set { commandPaletteController.commandPaletteWorkspaceDescriptionDraft = newValue }
    }
    private var commandPaletteWorkspaceDescriptionHeight: CGFloat {
        get { commandPaletteController.commandPaletteWorkspaceDescriptionHeight }
        nonmutating set { commandPaletteController.commandPaletteWorkspaceDescriptionHeight = newValue }
    }
    private var commandPaletteSelectedResultIndex: Int {
        get { commandPaletteController.commandPaletteSelectedResultIndex }
        nonmutating set { commandPaletteController.commandPaletteSelectedResultIndex = newValue }
    }
    private var commandPaletteSelectionAnchorCommandID: String? {
        get { commandPaletteController.commandPaletteSelectionAnchorCommandID }
        nonmutating set { commandPaletteController.commandPaletteSelectionAnchorCommandID = newValue }
    }
    private var commandPaletteHoveredResultIndex: Int? {
        get { commandPaletteController.commandPaletteHoveredResultIndex }
        nonmutating set { commandPaletteController.commandPaletteHoveredResultIndex = newValue }
    }
    private var commandPaletteScrollTargetIndex: Int? {
        get { commandPaletteController.commandPaletteScrollTargetIndex }
        nonmutating set { commandPaletteController.commandPaletteScrollTargetIndex = newValue }
    }
    private var commandPaletteScrollTargetAnchor: UnitPoint? {
        get { commandPaletteController.commandPaletteScrollTargetAnchor }
        nonmutating set { commandPaletteController.commandPaletteScrollTargetAnchor = newValue }
    }
    private var commandPaletteRestoreFocusTarget: CommandPaletteRestoreFocusTarget? {
        get { commandPaletteController.commandPaletteRestoreFocusTarget }
        nonmutating set { commandPaletteController.commandPaletteRestoreFocusTarget = newValue }
    }
    private var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] {
        get { commandPaletteController.commandPaletteSearchCorpus }
        nonmutating set { commandPaletteController.commandPaletteSearchCorpus = newValue }
    }
    private var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] {
        get { commandPaletteController.commandPaletteSearchCorpusByID }
        nonmutating set { commandPaletteController.commandPaletteSearchCorpusByID = newValue }
    }
    private var commandPaletteSearchCommandsByID: [String: CommandPaletteCommand] {
        get { commandPaletteController.commandPaletteSearchCommandsByID }
        nonmutating set { commandPaletteController.commandPaletteSearchCommandsByID = newValue }
    }
    private var cachedCommandPaletteResults: [CommandPaletteSearchResult] {
        get { commandPaletteController.cachedCommandPaletteResults }
        nonmutating set { commandPaletteController.cachedCommandPaletteResults = newValue }
    }
    private var commandPaletteVisibleResults: [CommandPaletteSearchResult] {
        get { commandPaletteController.commandPaletteVisibleResults }
        nonmutating set { commandPaletteController.commandPaletteVisibleResults = newValue }
    }
    private var commandPaletteVisibleResultsScope: CommandPaletteListScope? {
        get { commandPaletteController.commandPaletteVisibleResultsScope }
        nonmutating set { commandPaletteController.commandPaletteVisibleResultsScope = newValue }
    }
    private var commandPaletteVisibleResultsFingerprint: Int? {
        get { commandPaletteController.commandPaletteVisibleResultsFingerprint }
        nonmutating set { commandPaletteController.commandPaletteVisibleResultsFingerprint = newValue }
    }
    private var cachedCommandPaletteScope: CommandPaletteListScope? {
        get { commandPaletteController.cachedCommandPaletteScope }
        nonmutating set { commandPaletteController.cachedCommandPaletteScope = newValue }
    }
    private var cachedCommandPaletteFingerprint: Int? {
        get { commandPaletteController.cachedCommandPaletteFingerprint }
        nonmutating set { commandPaletteController.cachedCommandPaletteFingerprint = newValue }
    }
    private var commandPalettePendingDismissFocusTarget: CommandPaletteRestoreFocusTarget? {
        get { commandPaletteController.commandPalettePendingDismissFocusTarget }
        nonmutating set { commandPaletteController.commandPalettePendingDismissFocusTarget = newValue }
    }
    private var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem? {
        get { commandPaletteController.commandPaletteRestoreTimeoutWorkItem }
        nonmutating set { commandPaletteController.commandPaletteRestoreTimeoutWorkItem = newValue }
    }
    private var commandPalettePendingTextSelectionBehavior: CommandPaletteTextSelectionBehavior? {
        get { commandPaletteController.commandPalettePendingTextSelectionBehavior }
        nonmutating set { commandPaletteController.commandPalettePendingTextSelectionBehavior = newValue }
    }
    private var commandPaletteSearchTask: Task<Void, Never>? {
        get { commandPaletteController.commandPaletteSearchTask }
        nonmutating set { commandPaletteController.commandPaletteSearchTask = newValue }
    }
    private var commandPaletteSearchRequestID: UInt64 {
        get { commandPaletteController.commandPaletteSearchRequestID }
        nonmutating set { commandPaletteController.commandPaletteSearchRequestID = newValue }
    }
    private var commandPaletteResolvedSearchRequestID: UInt64 {
        get { commandPaletteController.commandPaletteResolvedSearchRequestID }
        nonmutating set { commandPaletteController.commandPaletteResolvedSearchRequestID = newValue }
    }
    private var commandPaletteResolvedSearchScope: CommandPaletteListScope? {
        get { commandPaletteController.commandPaletteResolvedSearchScope }
        nonmutating set { commandPaletteController.commandPaletteResolvedSearchScope = newValue }
    }
    private var commandPaletteResolvedSearchFingerprint: Int? {
        get { commandPaletteController.commandPaletteResolvedSearchFingerprint }
        nonmutating set { commandPaletteController.commandPaletteResolvedSearchFingerprint = newValue }
    }
    private var commandPaletteResolvedMatchingQuery: String {
        get { commandPaletteController.commandPaletteResolvedMatchingQuery }
        nonmutating set { commandPaletteController.commandPaletteResolvedMatchingQuery = newValue }
    }
    private var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> {
        get { commandPaletteController.commandPaletteTerminalOpenTargetAvailability }
        nonmutating set { commandPaletteController.commandPaletteTerminalOpenTargetAvailability = newValue }
    }
    private var isCommandPaletteSearchPending: Bool {
        get { commandPaletteController.isCommandPaletteSearchPending }
        nonmutating set { commandPaletteController.isCommandPaletteSearchPending = newValue }
    }
    private var commandPalettePendingActivation: CommandPalettePendingActivation? {
        get { commandPaletteController.commandPalettePendingActivation }
        nonmutating set { commandPaletteController.commandPalettePendingActivation = newValue }
    }
    private var commandPaletteResultsRevision: UInt64 {
        get { commandPaletteController.commandPaletteResultsRevision }
        nonmutating set { commandPaletteController.commandPaletteResultsRevision = newValue }
    }
    private var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteUsageEntry] {
        get { commandPaletteController.commandPaletteUsageHistoryByCommandId }
        nonmutating set { commandPaletteController.commandPaletteUsageHistoryByCommandId = newValue }
    }
    private var commandPaletteRenameSelectAllOnFocus: Bool {
        get { commandPaletteController.commandPaletteRenameSelectAllOnFocus }
        nonmutating set { commandPaletteController.commandPaletteRenameSelectAllOnFocus = newValue }
    }
    private var commandPaletteSearchAllSurfaces: Bool {
        get { commandPaletteController.commandPaletteSearchAllSurfaces }
        nonmutating set { commandPaletteController.commandPaletteSearchAllSurfaces = newValue }
    }
    private var commandPaletteShouldFocusWorkspaceDescriptionEditor: Bool {
        get { commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor }
        nonmutating set { commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor = newValue }
    }
    private var commandPaletteQueryBinding: Binding<String> {
        Binding(
            get: { commandPaletteController.commandPaletteQuery },
            set: { commandPaletteController.commandPaletteQuery = $0 }
        )
    }
    private var commandPaletteRenameDraftBinding: Binding<String> {
        Binding(
            get: { commandPaletteController.commandPaletteRenameDraft },
            set: { commandPaletteController.commandPaletteRenameDraft = $0 }
        )
    }
    private var commandPaletteWorkspaceDescriptionDraftBinding: Binding<String> {
        Binding(
            get: { commandPaletteController.commandPaletteWorkspaceDescriptionDraft },
            set: { commandPaletteController.commandPaletteWorkspaceDescriptionDraft = $0 }
        )
    }
    private var commandPaletteWorkspaceDescriptionHeightBinding: Binding<CGFloat> {
        Binding(
            get: { commandPaletteController.commandPaletteWorkspaceDescriptionHeight },
            set: { commandPaletteController.commandPaletteWorkspaceDescriptionHeight = $0 }
        )
    }
    private var commandPaletteShouldFocusWorkspaceDescriptionEditorBinding: Binding<Bool> {
        Binding(
            get: { commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor },
            set: { commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor = $0 }
        )
    }
    @FocusState private var isCommandPaletteSearchFocused: Bool
    @FocusState private var isCommandPaletteRenameFocused: Bool

    enum CommandPaletteMode {
        case commands
        case renameInput(CommandPaletteRenameTarget)
        case renameConfirm(CommandPaletteRenameTarget, proposedName: String)
        case workspaceDescriptionInput(CommandPaletteWorkspaceDescriptionTarget)
    }

    enum CommandPaletteListScope: String {
        case commands
        case switcher
    }

    enum CommandPalettePendingActivation: Equatable {
        case selected(requestID: UInt64, fallbackSelectedIndex: Int, preferredCommandID: String?)
        case command(requestID: UInt64, commandID: String)
    }

    enum CommandPaletteResolvedActivation: Equatable {
        case selected(index: Int)
        case command(commandID: String)
    }

    struct CommandPaletteRenameTarget: Equatable {
        enum Kind: Equatable {
            case workspace(workspaceId: UUID)
            case tab(workspaceId: UUID, panelId: UUID)
        }

        let kind: Kind
        let currentName: String

        var title: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspaceTitle", defaultValue: "Rename Workspace")
            case .tab:
                return String(localized: "commandPalette.rename.tabTitle", defaultValue: "Rename Tab")
            }
        }

        var description: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspaceDescription", defaultValue: "Choose a custom workspace name.")
            case .tab:
                return String(localized: "commandPalette.rename.tabDescription", defaultValue: "Choose a custom tab name.")
            }
        }

        var placeholder: String {
            switch kind {
            case .workspace:
                return String(localized: "commandPalette.rename.workspacePlaceholder", defaultValue: "Workspace name")
            case .tab:
                return String(localized: "commandPalette.rename.tabPlaceholder", defaultValue: "Tab name")
            }
        }
    }

    struct CommandPaletteWorkspaceDescriptionTarget: Equatable {
        let workspaceId: UUID
        let currentDescription: String

        var placeholder: String {
            String(
                localized: "commandPalette.description.workspacePlaceholder",
                defaultValue: "Workspace description"
            )
        }

        var inputHint: String {
            String(
                localized: "commandPalette.description.workspaceInputHint",
                defaultValue: "Press Enter to save. Press Shift-Enter for a new line, or Escape to cancel."
            )
        }
    }

    struct CommandPaletteRestoreFocusTarget {
        let workspaceId: UUID
        let panelId: UUID
        let intent: PanelFocusIntent
    }

    private enum CommandPaletteInputFocusTarget {
        case search
        case rename
    }

    enum CommandPaletteTextSelectionBehavior {
        case caretAtEnd
        case selectAll
    }

    private enum CommandPaletteTrailingLabelStyle {
        case shortcut
        case kind
    }

    private struct CommandPaletteTrailingLabel {
        let text: String
        let style: CommandPaletteTrailingLabelStyle
    }

    private struct CommandPaletteInputFocusPolicy {
        let focusTarget: CommandPaletteInputFocusTarget
        let selectionBehavior: CommandPaletteTextSelectionBehavior

        static let search = CommandPaletteInputFocusPolicy(
            focusTarget: .search,
            selectionBehavior: .caretAtEnd
        )
    }

    struct CommandPaletteCommand: Identifiable {
        let id: String
        let rank: Int
        let title: String
        let subtitle: String
        let shortcutHint: String?
        let kindLabel: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let action: () -> Void

        var searchableTexts: [String] {
            [title, subtitle] + keywords
        }
    }

    struct CommandPaletteUsageEntry: Codable, Sendable {
        var useCount: Int
        var lastUsedAt: TimeInterval
    }

    static func tmuxWorkspacePaneExactRect(
        for panel: any Panel,
        in contentView: NSView
    ) -> CGRect? {
        let targetView: NSView?
        switch panel {
        case let terminal as TerminalPanel:
            targetView = terminal.hostedView
        case let browser as BrowserPanel:
            targetView = browser.webView
        default:
            targetView = nil
        }
        guard let targetView else { return nil }
        return tmuxWorkspacePaneExactRect(for: targetView, in: contentView)
    }

    static func tmuxWorkspacePaneExactRect(
        for targetView: NSView,
        in contentView: NSView
    ) -> CGRect? {
        guard let contentWindow = contentView.window,
              let targetWindow = targetView.window,
              contentWindow === targetWindow,
              targetView.superview != nil else {
            return nil
        }

        let rectInWindow = targetView.convert(targetView.bounds, to: nil)
        let rectInContent = contentView.convert(rectInWindow, from: nil)
        guard rectInContent.width > 1, rectInContent.height > 1 else { return nil }
        return rectInContent
    }

    static func preferredTmuxWorkspacePaneWindowOverlayRect(
        exactRect: CGRect?,
        paneRect: CGRect?
    ) -> CGRect? {
        guard let paneRect else { return exactRect }
        guard let exactRect,
              exactRect.width > 1,
              exactRect.height > 1 else {
            return paneRect
        }

        let tolerance: CGFloat = 0.5
        let exactFitsWithinPane =
            exactRect.minX >= paneRect.minX - tolerance &&
            exactRect.maxX <= paneRect.maxX + tolerance &&
            exactRect.minY >= paneRect.minY - tolerance &&
            exactRect.maxY <= paneRect.maxY + tolerance
        return exactFitsWithinPane ? exactRect : paneRect
    }

    private func tmuxWorkspacePaneWindowOverlayState(for window: NSWindow) -> TmuxWorkspacePaneOverlayRenderState? {
        guard TmuxOverlayExperimentSettings.target().usesWorkspacePaneOverlay,
              let workspace = tabManager.selectedWorkspace else { return nil }
        let layoutSnapshot = WorkspaceContentView.effectiveTmuxLayoutSnapshot(
            cachedSnapshot: workspace.tmuxLayoutSnapshot,
            liveSnapshot: workspace.bonsplitController.layoutSnapshot()
        )
        let contentView = window.contentView

        let unreadRects: [CGRect]
        if let layoutSnapshot, let contentView {
            unreadRects = layoutSnapshot.panes.compactMap { pane in
                guard let selectedTabId = pane.selectedTabId,
                      let tabUUID = UUID(uuidString: selectedTabId),
                      let panelId = workspace.panelIdFromSurfaceId(TabID(uuid: tabUUID)),
                      let panel = workspace.panels[panelId] else {
                    return nil
                }

                let shouldShowUnread = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasVisibleNotificationIndicator(
                        forTabId: workspace.id,
                        surfaceId: panelId
                    ),
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panelId)
                )
                guard shouldShowUnread else { return nil }

                let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                    layoutSnapshot: layoutSnapshot,
                    paneId: workspace.paneId(forPanelId: panelId)
                )
                let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
                return Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                    exactRect: exactRect,
                    paneRect: paneRect
                )
            }
        } else {
            unreadRects = WorkspaceContentView.tmuxWorkspacePaneWindowUnreadRects(
                workspace: workspace,
                notificationStore: notificationStore,
                layoutSnapshot: layoutSnapshot
            )
        }

        let flashRect: CGRect?
        if let panelId = workspace.tmuxWorkspaceFlashPanelId,
           let panel = workspace.panels[panelId],
           let contentView {
            let paneRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.paneId(forPanelId: panelId)
            )
            let exactRect = Self.tmuxWorkspacePaneExactRect(for: panel, in: contentView)
            flashRect = Self.preferredTmuxWorkspacePaneWindowOverlayRect(
                exactRect: exactRect,
                paneRect: paneRect
            )
        } else {
            flashRect = WorkspaceContentView.tmuxWorkspacePaneWindowOverlayRect(
                layoutSnapshot: layoutSnapshot,
                paneId: workspace.tmuxWorkspaceFlashPanelId.flatMap { workspace.paneId(forPanelId: $0) }
            )
        }

        return TmuxWorkspacePaneOverlayRenderState(
            workspaceId: workspace.id,
            unreadRects: unreadRects,
            flashRect: flashRect,
            flashToken: workspace.tmuxWorkspaceFlashToken,
            flashReason: workspace.tmuxWorkspaceFlashReason
        )
    }

    struct CommandPaletteContextSnapshot {
        private var boolValues: [String: Bool] = [:]
        private var stringValues: [String: String] = [:]

        mutating func setBool(_ key: String, _ value: Bool) {
            boolValues[key] = value
        }

        mutating func setString(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else {
                stringValues.removeValue(forKey: key)
                return
            }
            stringValues[key] = value
        }

        func bool(_ key: String) -> Bool {
            boolValues[key] ?? false
        }

        func string(_ key: String) -> String? {
            stringValues[key]
        }

        func fingerprint() -> Int {
            ContentView.commandPaletteContextFingerprint(
                boolValues: boolValues,
                stringValues: stringValues
            )
        }
    }

    struct CommandPaletteCommandsContext {
        let snapshot: CommandPaletteContextSnapshot
    }

    enum CommandPaletteContextKeys {
        static let hasWorkspace = "workspace.hasSelection"
        static let workspaceName = "workspace.name"
        static let workspaceHasCustomName = "workspace.hasCustomName"
        static let workspaceHasCustomDescription = "workspace.hasCustomDescription"
        static let workspaceMinimalModeEnabled = "workspace.minimalModeEnabled"
        static let workspaceShouldPin = "workspace.shouldPin"
        static let workspaceHasPullRequests = "workspace.hasPullRequests"
        static let workspaceHasSplits = "workspace.hasSplits"
        static let workspaceHasPeers = "workspace.hasPeers"
        static let workspaceHasAbove = "workspace.hasAbove"
        static let workspaceHasBelow = "workspace.hasBelow"
        static let workspaceHasUnread = "workspace.hasUnread"
        static let workspaceHasRead = "workspace.hasRead"

        static let hasFocusedPanel = "panel.hasFocus"
        static let panelName = "panel.name"
        static let panelIsBrowser = "panel.isBrowser"
        static let panelIsTerminal = "panel.isTerminal"
        static let panelHasCustomName = "panel.hasCustomName"
        static let panelShouldPin = "panel.shouldPin"
        static let panelHasUnread = "panel.hasUnread"

        static let updateHasAvailable = "update.hasAvailable"
        static let cliInstalledInPATH = "cli.installedInPATH"

        static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> String {
            "terminal.openTarget.\(target.rawValue).available"
        }
    }

    struct CommandPaletteCommandContribution {
        let commandId: String
        let title: (CommandPaletteContextSnapshot) -> String
        let subtitle: (CommandPaletteContextSnapshot) -> String
        let shortcutHint: String?
        let keywords: [String]
        let dismissOnRun: Bool
        let when: (CommandPaletteContextSnapshot) -> Bool
        let enablement: (CommandPaletteContextSnapshot) -> Bool

        init(
            commandId: String,
            title: @escaping (CommandPaletteContextSnapshot) -> String,
            subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
            shortcutHint: String? = nil,
            keywords: [String] = [],
            dismissOnRun: Bool = true,
            when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
            enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
        ) {
            self.commandId = commandId
            self.title = title
            self.subtitle = subtitle
            self.shortcutHint = shortcutHint
            self.keywords = keywords
            self.dismissOnRun = dismissOnRun
            self.when = when
            self.enablement = enablement
        }
    }

    private struct CommandPaletteHandlerRegistry {
        private var handlers: [String: () -> Void] = [:]

        mutating func register(commandId: String, handler: @escaping () -> Void) {
            handlers[commandId] = handler
        }

        func handler(for commandId: String) -> (() -> Void)? {
            handlers[commandId]
        }
    }

    struct CommandPaletteSearchResult: Identifiable {
        let command: CommandPaletteCommand
        let score: Int
        let titleMatchIndices: Set<Int>

        var id: String { command.id }
    }

    struct CommandPaletteResolvedSearchMatch: Sendable {
        let commandID: String
        let score: Int
        let titleMatchIndices: Set<Int>
    }

    struct CommandPaletteSwitcherWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let selectedWorkspaceId: UUID?
        let windowLabel: String?
    }

    struct CommandPaletteSwitcherFingerprintWorkspace: Sendable {
        let id: UUID
        let displayName: String
        let metadata: CommandPaletteSwitcherSearchMetadata
        let surfaces: [CommandPaletteSwitcherFingerprintSurface]
    }

    struct CommandPaletteSwitcherFingerprintSurface: Sendable {
        let id: UUID
        let displayName: String
        let kindLabel: String
        let metadata: CommandPaletteSwitcherSearchMetadata
    }

    struct CommandPaletteSwitcherFingerprintContext: Sendable {
        let windowId: UUID
        let windowLabel: String?
        let selectedWorkspaceId: UUID?
        let workspaces: [CommandPaletteSwitcherFingerprintWorkspace]
    }

    private static let commandPaletteUsageDefaultsKey = "commandPalette.commandUsage.v1"

    private var sidebarView: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            onSendFeedback: presentFeedbackComposer,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        )
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    /// Space at top of content area for the titlebar. This must be at least the actual titlebar
    /// height; otherwise controls like Bonsplit tab dragging can be interpreted as window drags.
    @State private var titlebarPadding: CGFloat = 32
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        if isMinimalMode {
            return isFullScreen ? 0 : -titlebarPadding
        }
        return titlebarPadding
    }

    private var terminalContent: some View {
        let mountedWorkspaceIdSet = Set(mountedWorkspaceIds)
        let mountedWorkspaces = tabManager.tabs.filter { mountedWorkspaceIdSet.contains($0.id) }
        let selectedWorkspaceId = tabManager.selectedTabId
        let retiringWorkspaceId = self.retiringWorkspaceId

        return ZStack {
            ZStack {
                ForEach(mountedWorkspaces) { tab in
                    let isSelectedWorkspace = selectedWorkspaceId == tab.id
                    let isRetiringWorkspace = retiringWorkspaceId == tab.id
                    let shouldPrimeInBackground = tabManager.pendingBackgroundWorkspaceLoadIds.contains(tab.id)
                    let presentation = MountedWorkspacePresentationPolicy.resolve(
                        isSelectedWorkspace: isSelectedWorkspace,
                        isRetiringWorkspace: isRetiringWorkspace,
                        shouldPrimeInBackground: shouldPrimeInBackground
                    )
                    // Keep the retiring workspace visible during handoff, but never input-active.
                    // Allowing both selected+retiring workspaces to be input-active lets the
                    // old workspace steal first responder (notably with WKWebView), which can
                    // delay handoff completion and make browser returns feel laggy.
                    let isInputActive = isSelectedWorkspace
                    let portalPriority = isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0)
                    WorkspaceContentView(
                        workspace: tab,
                        isWorkspaceVisible: presentation.isPanelVisible,
                        isWorkspaceInputActive: isInputActive,
                        isFullScreen: isFullScreen,
                        workspacePortalPriority: portalPriority,
                        onThemeRefreshRequest: { reason, eventId, source, payloadHex in
                            scheduleTitlebarThemeRefreshFromWorkspace(
                                workspaceId: tab.id,
                                reason: reason,
                                backgroundEventId: eventId,
                                backgroundSource: source,
                                notificationPayloadHex: payloadHex
                            )
                        }
                    )
                    .opacity(presentation.renderOpacity)
                    .allowsHitTesting(isSelectedWorkspace)
                    .accessibilityHidden(!presentation.isRenderedVisible)
                    .zIndex(isSelectedWorkspace ? 2 : (isRetiringWorkspace ? 1 : 0))
                    .task(id: shouldPrimeInBackground ? tab.id : nil) {
                        await primeBackgroundWorkspaceIfNeeded(workspaceId: tab.id)
                    }
                }
            }
            .opacity(sidebarSelectionState.selection == .tabs ? 1 : 0)
            .allowsHitTesting(sidebarSelectionState.selection == .tabs)
            .accessibilityHidden(sidebarSelectionState.selection != .tabs)

            NotificationsPage(selection: $sidebarSelectionState.selection)
                .opacity(sidebarSelectionState.selection == .notifications ? 1 : 0)
                .allowsHitTesting(sidebarSelectionState.selection == .notifications)
                .accessibilityHidden(sidebarSelectionState.selection != .notifications)
        }
        .padding(.top, effectiveTitlebarPadding)
        .overlay(alignment: .top) {
            if !isMinimalMode {
                // Titlebar overlay is only over terminal content, not the sidebar.
                customTitlebar
            }
        }
    }

    private var terminalContentWithSidebarDropOverlay: some View {
        terminalContent
            .overlay {
                SidebarExternalDropOverlay(draggedTabId: sidebarDraggedTabId)
            }
    }

    @AppStorage("sidebarBlendMode") private var sidebarBlendMode = SidebarBlendModeOption.withinWindow.rawValue
    @AppStorage("sidebarMatchTerminalBackground") private var sidebarMatchTerminalBackground = false

    // Background glass settings
    @AppStorage("bgGlassTintHex") private var bgGlassTintHex = "#000000"
    @AppStorage("bgGlassTintOpacity") private var bgGlassTintOpacity = 0.03
    @AppStorage("bgGlassEnabled") private var bgGlassEnabled = false
    @AppStorage("debugTitlebarLeadingExtra") private var debugTitlebarLeadingExtra: Double = 0

    @State private var titlebarLeadingInset: CGFloat = 12
    private var windowIdentifier: String { "cmux.main.\(windowId.uuidString)" }
    private var fakeTitlebarTextColor: Color {
        _ = titlebarThemeGeneration
        let ghosttyBackground = GhosttyApp.shared.defaultBackgroundColor
        return ghosttyBackground.isLightColor
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }
    private var fullscreenControls: some View {
        TitlebarControlsView(
            notificationStore: TerminalNotificationStore.shared,
            viewModel: fullscreenControlsViewModel,
            onToggleSidebar: { sidebarState.toggle() },
            onToggleNotifications: { [fullscreenControlsViewModel] in
                AppDelegate.shared?.toggleNotificationsPopover(
                    animated: true,
                    anchorView: fullscreenControlsViewModel.notificationsAnchorView
                )
            },
            onNewTab: { tabManager.addTab() },
            visibilityMode: .alwaysVisible
        )
    }

    private var customTitlebar: some View {
        ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            TitlebarLeadingInsetReader(inset: $titlebarLeadingInset)
                .allowsHitTesting(false)

            HStack(spacing: 8) {
                if isFullScreen && !sidebarState.isVisible {
                    fullscreenControls
                }

                // Draggable folder icon + focused command name
                if let directory = focusedDirectory {
                    DraggableFolderIcon(directory: directory)
                        .padding(.leading, -6)
                }

                Text(titlebarText)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(fakeTitlebarTextColor)
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer()

            }
            .frame(height: 28)
            .padding(.top, 2)
            .padding(.leading, (isFullScreen && !sidebarState.isVisible) ? 8 : (sidebarState.isVisible ? 12 : titlebarLeadingInset + CGFloat(debugTitlebarLeadingExtra)))
            .padding(.trailing, 8)
        }
        .frame(height: titlebarPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(TitlebarDoubleClickMonitorView())
        .background({
            // The terminal background is provided by a single CALayer
            // (backgroundView in GhosttySurfaceScrollView), so the titlebar
            // opacity matches the configured value directly.
            let alpha = CGFloat(GhosttyApp.shared.defaultBackgroundOpacity)
            return TitlebarLayerBackground(
                backgroundColor: GhosttyApp.shared.defaultBackgroundColor,
                opacity: alpha
            )
        }())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    private func syncTrafficLightInset() {
        let inset: CGFloat = (isMinimalMode && !sidebarState.isVisible && !isFullScreen) ? 80 : 0
        for tab in tabManager.tabs {
            if tab.bonsplitController.configuration.appearance.tabBarLeadingInset != inset {
                tab.bonsplitController.configuration.appearance.tabBarLeadingInset = inset
            }
        }
    }

    private func updateTitlebarText() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            if !titlebarText.isEmpty {
                titlebarText = ""
            }
            return
        }
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if titlebarText != title {
            titlebarText = title
        }
    }

    private func scheduleTitlebarTextRefresh() {
        titlebarTextUpdateCoalescer.signal {
            updateTitlebarText()
        }
    }

    private func scheduleTitlebarThemeRefresh(
        reason: String,
        backgroundEventId: UInt64? = nil,
        backgroundSource: String? = nil,
        notificationPayloadHex: String? = nil
    ) {
        let previousGeneration = titlebarThemeGeneration
        titlebarThemeGeneration &+= 1
        if GhosttyApp.shared.backgroundLogEnabled {
            let eventLabel = backgroundEventId.map(String.init) ?? "nil"
            let sourceLabel = backgroundSource ?? "nil"
            let payloadLabel = notificationPayloadHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh scheduled reason=\(reason) event=\(eventLabel) source=\(sourceLabel) payload=\(payloadLabel) previousGeneration=\(previousGeneration) generation=\(titlebarThemeGeneration) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
            )
        }
    }

    private func scheduleTitlebarThemeRefreshFromWorkspace(
        workspaceId: UUID,
        reason: String,
        backgroundEventId: UInt64?,
        backgroundSource: String?,
        notificationPayloadHex: String?
    ) {
        guard tabManager.selectedTabId == workspaceId else {
            guard GhosttyApp.shared.backgroundLogEnabled else { return }
            GhosttyApp.shared.logBackground(
                "titlebar theme refresh skipped workspace=\(workspaceId.uuidString) selected=\(tabManager.selectedTabId?.uuidString ?? "nil") reason=\(reason)"
            )
            return
        }

        scheduleTitlebarThemeRefresh(
            reason: reason,
            backgroundEventId: backgroundEventId,
            backgroundSource: backgroundSource,
            notificationPayloadHex: notificationPayloadHex
        )
    }

    private var focusedDirectory: String? {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            return nil
        }
        // Use focused panel's directory if available
        if let focusedPanelId = tab.focusedPanelId,
           let panelDir = tab.panelDirectories[focusedPanelId] {
            let trimmed = panelDir.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    private var contentAndSidebarLayout: AnyView {
        let layout: AnyView
        // When matching terminal background, use HStack so both sidebar and terminal
        // sit directly on the window background with no intermediate layers.
        let useWithinWindow = sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue
            && !sidebarMatchTerminalBackground
        if useWithinWindow {
            // Overlay mode: terminal extends full width, sidebar on top
            // This allows withinWindow blur to see the terminal content
            layout = AnyView(
                ZStack(alignment: .leading) {
                    terminalContentWithSidebarDropOverlay
                        .padding(.leading, sidebarState.isVisible ? sidebarWidth : 0)
                    if sidebarState.isVisible {
                        sidebarView
                    }
                }
            )
        } else {
            // Standard HStack mode for behindWindow blur
            layout = AnyView(
                HStack(spacing: 0) {
                    if sidebarState.isVisible {
                        sidebarView
                    }
                    terminalContentWithSidebarDropOverlay
                }
            )
        }

        return AnyView(
            layout
                .overlay(alignment: .leading) {
                    if sidebarState.isVisible {
                        sidebarResizerOverlay
                            .zIndex(1000)
                    }
                }
        )
    }

    var body: some View {
        let baseLayout =
            contentAndSidebarLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if isFullScreen && sidebarState.isVisible && !isMinimalMode {
                        fullscreenControls
                            .padding(.leading, 10)
                            .padding(.top, 4)
                    }
                }
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)

        let step1 = attachWorkspaceLifecycleHandlers(to: baseLayout)
        let step2 = attachTerminalAndBrowserFocusHandlers(to: step1)
        let step3 = attachCommandPaletteFocusAndTabsHandlers(to: step2)
        let step4 = attachCommandPaletteRequestHandlers(to: step3)
        let step5 = attachOverlayWindowAccessor(to: step4)
        let step6 = attachWindowGlassAndFullscreenHandlers(to: step5)
        let step7 = attachSidebarSyncHandlers(to: step6)
        let step8 = attachFinalLifecycleHandlers(to: step7)
        let step9 = attachMainWindowAccessor(to: step8)

        return step9
    }

    @ViewBuilder
    private func attachWorkspaceLifecycleHandlers(to view: some View) -> some View {
        view
            .onAppear {
                tabManager.applyWindowBackgroundForSelectedTab()
                reconcileMountedWorkspaceIds()
                previousSelectedWorkspaceId = tabManager.selectedTabId
                installSidebarResizerPointerMonitorIfNeeded()
                let restoredWidth = normalizedSidebarWidth(sidebarState.persistedWidth)
                if abs(sidebarWidth - restoredWidth) > 0.5 {
                    sidebarWidth = restoredWidth
                }
                if abs(sidebarState.persistedWidth - restoredWidth) > 0.5 {
                    sidebarState.persistedWidth = restoredWidth
                }
                if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                }
                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)
                updateTitlebarText()
                syncTrafficLightInset()

                // Startup recovery (#399): if session restore or a race condition leaves the
                // view in a broken state (empty tabs, no selection, unmounted workspaces),
                // detect and recover after a short delay.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak tabManager] in
                    guard let tabManager else { return }
                    var didRecover = false

                    // Ensure there is at least one workspace.
                    if tabManager.tabs.isEmpty {
                        tabManager.addWorkspace()
                        didRecover = true
                    }

                    // Ensure selectedTabId points to an existing workspace.
                    if tabManager.selectedTabId == nil || !tabManager.tabs.contains(where: { $0.id == tabManager.selectedTabId }) {
                        tabManager.selectedTabId = tabManager.tabs.first?.id
                        didRecover = true
                    }

                    // Ensure mountedWorkspaceIds is populated.
                    if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in tabManager.tabs.contains { $0.id == id } }) {
                        reconcileMountedWorkspaceIds()
                        didRecover = true
                    }

                    // Ensure sidebar selection is valid.
                    if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                        selectedTabIds = [selectedId]
                        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
                        didRecover = true
                    }

                    syncSidebarSelectedWorkspaceIds()
                    applyUITestSidebarSelectionIfNeeded(tabs: tabManager.tabs)

                    if didRecover {
    #if DEBUG
                        dlog("startup.recovery tabCount=\(tabManager.tabs.count) selected=\(tabManager.selectedTabId?.uuidString.prefix(8) ?? "nil") mounted=\(mountedWorkspaceIds.count)")
    #endif
                    }
                }
            }
            .onChange(of: tabManager.selectedTabId) { _, newValue in
    #if DEBUG
                if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                    let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                    dlog(
                        "ws.view.selectedChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newValue))"
                    )
                } else {
                    dlog("ws.view.selectedChange id=none selected=\(debugShortWorkspaceId(newValue))")
                }
    #endif
                tabManager.applyWindowBackgroundForSelectedTab()
                startWorkspaceHandoffIfNeeded(newSelectedId: newValue)
                reconcileMountedWorkspaceIds(selectedId: newValue)
                // Kick portal geometry sync so the new workspace's HostContainerView
                // gets a valid frame before the first ghostty_surface_refresh fires.
                // Without this, the double-async deferred sync in scheduleExternalGeometrySynchronize
                // can leave the Metal surface with a zero/stale frame on workspace creation (#2555).
                if let observedWindow {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
                } else {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
                }
                guard let newValue else { return }
                if selectedTabIds.count <= 1 {
                    selectedTabIds = [newValue]
                    lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == newValue }
                }
                updateTitlebarText()
            }
            .onChange(of: selectedTabIds) {
                syncSidebarSelectedWorkspaceIds()
            }
            .onChange(of: tabManager.isWorkspaceCycleHot) {
    #if DEBUG
                if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                    let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                    dlog(
                        "ws.view.hotChange id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
                    )
                } else {
                    dlog("ws.view.hotChange id=none hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)")
                }
    #endif
                reconcileMountedWorkspaceIds()
            }
            .onChange(of: retiringWorkspaceId) {
                reconcileMountedWorkspaceIds()
            }
            .onReceive(tabManager.$pendingBackgroundWorkspaceLoadIds) { _ in
                reconcileMountedWorkspaceIds()
            }
            .onReceive(tabManager.$debugPinnedWorkspaceLoadIds) { _ in
                reconcileMountedWorkspaceIds()
            }
    }

    @ViewBuilder
    private func attachTerminalAndBrowserFocusHandlers(to view: some View) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidSetTitle)) { notification in
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      tabId == tabManager.selectedTabId else { return }
                scheduleTitlebarTextRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusTab)) { _ in
                sidebarSelectionState.selection = .tabs
                scheduleTitlebarTextRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidFocusSurface)) { notification in
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      tabId == tabManager.selectedTabId else { return }
                completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "focus")
                attemptCommandPaletteFocusRestoreIfNeeded()
                scheduleTitlebarTextRefresh()
            }
            .onChange(of: titlebarThemeGeneration) { oldValue, newValue in
                guard GhosttyApp.shared.backgroundLogEnabled else { return }
                GhosttyApp.shared.logBackground(
                    "titlebar theme refresh applied oldGeneration=\(oldValue) generation=\(newValue) appBg=\(GhosttyApp.shared.defaultBackgroundColor.hexString()) appOpacity=\(String(format: "%.3f", GhosttyApp.shared.defaultBackgroundOpacity))"
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDidBecomeFirstResponderSurface)) { notification in
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      tabId == tabManager.selectedTabId else { return }
                completeWorkspaceHandoffIfNeeded(focusedTabId: tabId, reason: "first_responder")
                attemptCommandPaletteFocusRestoreIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserDidBecomeFirstResponderWebView)) { notification in
                guard let webView = notification.object as? WKWebView,
                      let selectedTabId = tabManager.selectedTabId,
                      let selectedWorkspace = tabManager.selectedWorkspace,
                      let focusedPanelId = selectedWorkspace.focusedPanelId,
                      let focusedBrowser = selectedWorkspace.browserPanel(for: focusedPanelId),
                      focusedBrowser.webView === webView else { return }
                completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_first_responder")
                attemptCommandPaletteFocusRestoreIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserDidFocusAddressBar)) { notification in
                guard let panelId = notification.object as? UUID,
                      let selectedTabId = tabManager.selectedTabId,
                      let selectedWorkspace = tabManager.selectedWorkspace,
                      selectedWorkspace.focusedPanelId == panelId,
                      selectedWorkspace.browserPanel(for: panelId) != nil else { return }
                completeWorkspaceHandoffIfNeeded(focusedTabId: selectedTabId, reason: "browser_address_bar")
                attemptCommandPaletteFocusRestoreIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )) { _ in
                attemptCommandPaletteFocusRestoreIfNeeded()
                attemptCommandPaletteTextSelectionIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
                guard commandPalettePendingTextSelectionBehavior != nil else { return }
                guard let editor = notification.object as? NSTextView,
                      editor.isFieldEditor else { return }
                guard let observedWindow else { return }
                guard editor.window === observedWindow else { return }
                attemptCommandPaletteTextSelectionIfNeeded()
            }
    }

    @ViewBuilder
    private func attachCommandPaletteFocusAndTabsHandlers(to view: some View) -> some View {
        view
            .onChange(of: isCommandPaletteSearchFocused) { _, focused in
                if focused {
                    attemptCommandPaletteTextSelectionIfNeeded()
                }
            }
            .onChange(of: isCommandPaletteRenameFocused) { _, focused in
                if focused {
                    attemptCommandPaletteTextSelectionIfNeeded()
                }
            }
            .onReceive(tabManager.$tabs) { tabs in
                let existingIds = Set(tabs.map { $0.id })
                if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                    self.retiringWorkspaceId = nil
                    workspaceHandoffFallbackTask?.cancel()
                    workspaceHandoffFallbackTask = nil
                }
                if let previousSelectedWorkspaceId, !existingIds.contains(previousSelectedWorkspaceId) {
                    self.previousSelectedWorkspaceId = tabManager.selectedTabId
                }
                tabManager.pruneBackgroundWorkspaceLoads(existingIds: existingIds)
                reconcileMountedWorkspaceIds(tabs: tabs)
                selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
                if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
                    selectedTabIds = [selectedId]
                }
                if let lastIndex = lastSidebarSelectionIndex, lastIndex >= tabs.count {
                    if let selectedId = tabManager.selectedTabId {
                        lastSidebarSelectionIndex = tabs.firstIndex { $0.id == selectedId }
                    } else {
                        lastSidebarSelectionIndex = nil
                    }
                }
                syncSidebarSelectedWorkspaceIds()
                applyUITestSidebarSelectionIfNeeded(tabs: tabs)
            }
    }

    @ViewBuilder
    private func attachCommandPaletteRequestHandlers(to view: some View) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
                let tabId = SidebarDragLifecycleNotification.tabId(from: notification)
                sidebarDraggedTabId = tabId
    #if DEBUG
                dlog(
                    "sidebar.dragState.content tab=\(debugShortWorkspaceId(tabId)) " +
                    "reason=\(SidebarDragLifecycleNotification.reason(from: notification))"
                )
    #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                toggleCommandPalette()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                openCommandPaletteCommands()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                openCommandPaletteSwitcher()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
                guard isCommandPalettePresented else { return }
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                handleCommandPaletteSubmitRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
                guard isCommandPalettePresented else { return }
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                dismissCommandPalette()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                openCommandPaletteRenameTabInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                openCommandPaletteRenameWorkspaceInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteEditWorkspaceDescriptionRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                let shouldHandle = Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                )
    #if DEBUG
                dlog(
                    "palette.wsDescription.request observed={\(debugCommandPaletteWindowSummary(observedWindow))} " +
                    "requested={\(debugCommandPaletteWindowSummary(requestedWindow))} " +
                    "shouldHandle=\(shouldHandle ? 1 : 0) presented=\(isCommandPalettePresented ? 1 : 0) " +
                    "mode=\(debugCommandPaletteModeLabel(commandPaletteMode))"
                )
    #endif
                guard shouldHandle else { return }
                openCommandPaletteWorkspaceDescriptionInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
                guard isCommandPalettePresented else { return }
                guard case .commands = commandPaletteMode else { return }
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
                moveCommandPaletteSelection(by: delta)
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
                guard isCommandPalettePresented else { return }
                guard case .renameInput = commandPaletteMode else { return }
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                handleCommandPaletteRenameInputInteraction()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
                guard isCommandPalettePresented else { return }
                guard case .renameInput = commandPaletteMode else { return }
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
            }
            .onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard Self.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                presentFeedbackComposer()
            }
    }

    @ViewBuilder
    private func attachOverlayWindowAccessor(to view: some View) -> some View {
        view
            .background(WindowAccessor(dedupeByWindow: false) { window in
                MainActor.assumeIsolated {
                    let tmuxOverlayController = tmuxWorkspacePaneWindowOverlayController(for: window)
                    tmuxOverlayController.update(state: tmuxWorkspacePaneWindowOverlayState(for: window))
                    let overlayController = commandPaletteWindowOverlayController(for: window)
                    overlayController.update(rootView: AnyView(commandPaletteOverlay), isVisible: isCommandPalettePresented)
                }
            })
    }

    @ViewBuilder
    private func attachWindowGlassAndFullscreenHandlers(to view: some View) -> some View {
        view
            .onChange(of: bgGlassTintHex) {
                updateWindowGlassTint()
            }
            .onChange(of: bgGlassTintOpacity) {
                updateWindowGlassTint()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window === observedWindow else { return }
                isFullScreen = true
                setTitlebarControlsHidden(true, in: window)
                AppDelegate.shared?.fullscreenControlsViewModel = fullscreenControlsViewModel
                syncTrafficLightInset()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window === observedWindow else { return }
                isFullScreen = false
                setTitlebarControlsHidden(false, in: window)
                AppDelegate.shared?.fullscreenControlsViewModel = nil
                syncTrafficLightInset()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window === observedWindow else { return }
                clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
                updateSidebarResizerBandState()
            }
    }

    @ViewBuilder
    private func attachSidebarSyncHandlers(to view: some View) -> some View {
        view
            .onChange(of: sidebarWidth) {
                let sanitized = normalizedSidebarWidth(sidebarWidth)
                if abs(sidebarWidth - sanitized) > 0.5 {
                    sidebarWidth = sanitized
                    return
                }
                if abs(sidebarState.persistedWidth - sanitized) > 0.5 {
                    sidebarState.persistedWidth = sanitized
                }
                // Sidebar width changes are pure SwiftUI layout updates, so portal-hosted
                // terminals need an explicit post-layout geometry resync.
                if let observedWindow {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
                } else {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
                }
                updateSidebarResizerBandState()
            }
            .onChange(of: sidebarState.isVisible) {
                if let observedWindow {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
                } else {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
                }
                updateSidebarResizerBandState()
                syncTrafficLightInset()
            }
            .onChange(of: sidebarMatchTerminalBackground) {
                guard sidebarState.isVisible,
                      sidebarBlendMode == SidebarBlendModeOption.withinWindow.rawValue else { return }
                if let observedWindow {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
                } else {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
                }
            }
            .onChange(of: isMinimalMode) { _, _ in
                syncTrafficLightInset()
            }
            .onChange(of: sidebarState.persistedWidth) { _, newValue in
                let sanitized = normalizedSidebarWidth(newValue)
                if abs(newValue - sanitized) > 0.5 {
                    sidebarState.persistedWidth = sanitized
                    return
                }
                guard !isResizerDragging else { return }
                if abs(sidebarWidth - sanitized) > 0.5 {
                    sidebarWidth = sanitized
                }
            }
    }

    @ViewBuilder
    private func attachFinalLifecycleHandlers(to view: some View) -> some View {
        view
            .ignoresSafeArea()
            .onDisappear {
                if isResizerDragging {
                    TerminalWindowPortalRegistry.endInteractiveGeometryResize()
                    isResizerDragging = false
                    sidebarDragStartWidth = nil
                }
                removeSidebarResizerPointerMonitor()
            }
    }

    @ViewBuilder
    private func attachMainWindowAccessor(to view: some View) -> some View {
        view
            .background(WindowAccessor { [sidebarBlendMode, bgGlassEnabled, bgGlassTintHex, bgGlassTintOpacity] window in
                // AppKit-level window configuration (identifier, titlebar, movability,
                // transparency, glass effect, decorations, registration) lives with the
                // window-context layer; see AppDelegate.configureMainWindow.
                let nextPadding = AppDelegate.shared?.configureMainWindow(
                    window,
                    windowId: windowId,
                    windowIdentifier: windowIdentifier,
                    tabManager: tabManager,
                    sidebarState: sidebarState,
                    sidebarSelectionState: sidebarSelectionState,
                    sidebarBlendMode: sidebarBlendMode,
                    bgGlassEnabled: bgGlassEnabled,
                    bgGlassTintHex: bgGlassTintHex,
                    bgGlassTintOpacity: bgGlassTintOpacity
                ) ?? titlebarPadding

                // Track this window for fullscreen notifications
                if observedWindow !== window {
                    DispatchQueue.main.async {
                        observedWindow = window
                        isFullScreen = window.styleMask.contains(.fullScreen)
                        clampSidebarWidthIfNeeded(availableWidth: window.contentView?.bounds.width ?? window.contentLayoutRect.width)
                        syncCommandPaletteDebugStateForObservedWindow()
                        installSidebarResizerPointerMonitorIfNeeded()
                        updateSidebarResizerBandState()
                    }
                }

                if abs(titlebarPadding - nextPadding) > 0.5 {
                    DispatchQueue.main.async {
                        titlebarPadding = nextPadding
                    }
                }
            })
    }

    private func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
        let currentTabs = tabs ?? tabManager.tabs
        let orderedTabIds = currentTabs.map { $0.id }
        let effectiveSelectedId = selectedId ?? tabManager.selectedTabId
        let handoffPinnedIds = retiringWorkspaceId.map { Set([ $0 ]) } ?? []
        let pinnedIds = handoffPinnedIds
            .union(tabManager.pendingBackgroundWorkspaceLoadIds)
            .union(tabManager.debugPinnedWorkspaceLoadIds)
        let isCycleHot = tabManager.isWorkspaceCycleHot
        let shouldKeepHandoffPair = isCycleHot && !handoffPinnedIds.isEmpty
        let baseMaxMounted = shouldKeepHandoffPair
            ? WorkspaceMountPolicy.maxMountedWorkspacesDuringCycle
            : WorkspaceMountPolicy.maxMountedWorkspaces
        let selectedCount = effectiveSelectedId == nil ? 0 : 1
        let maxMounted = max(baseMaxMounted, selectedCount + pinnedIds.count)
        let previousMountedIds = mountedWorkspaceIds
        mountedWorkspaceIds = WorkspaceMountPolicy.nextMountedWorkspaceIds(
            current: mountedWorkspaceIds,
            selected: effectiveSelectedId,
            pinnedIds: pinnedIds,
            orderedTabIds: orderedTabIds,
            isCycleHot: isCycleHot,
            maxMounted: maxMounted
        )
#if DEBUG
        if mountedWorkspaceIds != previousMountedIds {
            let added = mountedWorkspaceIds.filter { !previousMountedIds.contains($0) }
            let removed = previousMountedIds.filter { !mountedWorkspaceIds.contains($0) }
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removed))"
                )
            } else {
                dlog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds))"
                )
            }
        }
#endif
    }

    private enum BackgroundWorkspacePrimeState {
        case pending
        case completed(reason: String)
    }

    private enum BackgroundWorkspacePrimePolicy {
        static let timeoutSeconds: TimeInterval = 2.0
    }

    private func primeBackgroundWorkspaceIfNeeded(workspaceId: UUID) async {
        let shouldPrime = await MainActor.run {
            tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId)
        }
        guard shouldPrime else { return }

#if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        dlog("workspace.backgroundPrime.start workspace=\(workspaceId.uuidString.prefix(5))")
#endif

        let initialState = await MainActor.run {
            stepBackgroundWorkspacePrime(workspaceId: workspaceId)
        }
        let completionReason: String
        switch initialState {
        case .completed(let reason):
            completionReason = reason
        case .pending:
            completionReason = await waitForBackgroundWorkspacePrimeCompletion(
                workspaceId: workspaceId,
                timeoutSeconds: BackgroundWorkspacePrimePolicy.timeoutSeconds
            )
        }
#if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        dlog(
            "workspace.backgroundPrime.finish workspace=\(workspaceId.uuidString.prefix(5)) " +
            "reason=\(completionReason) ms=\(String(format: "%.2f", elapsedMs))"
        )
#endif
    }

    @MainActor
    private func stepBackgroundWorkspacePrime(workspaceId: UUID) -> BackgroundWorkspacePrimeState {
        guard tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) else {
            return .completed(reason: "already_cleared")
        }
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
            tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
            return .completed(reason: "workspace_removed")
        }

        workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
        guard workspace.hasLoadedTerminalSurface() else {
            return .pending
        }

        tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
        return .completed(reason: "surface_ready")
    }

    @MainActor
    private func waitForBackgroundWorkspacePrimeCompletion(
        workspaceId: UUID,
        timeoutSeconds: TimeInterval
    ) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var resolved = false
            var workspacePanelsCancellable: AnyCancellable?
            var pendingLoadsCancellable: AnyCancellable?
            var tabsCancellable: AnyCancellable?
            var readyObserver: NSObjectProtocol?
            var hostedViewObserver: NSObjectProtocol?
            var timeoutWorkItem: DispatchWorkItem?

            @MainActor
            func finish(_ reason: String) {
                guard !resolved else { return }
                resolved = true
                workspacePanelsCancellable?.cancel()
                pendingLoadsCancellable?.cancel()
                tabsCancellable?.cancel()
                if let readyObserver {
                    NotificationCenter.default.removeObserver(readyObserver)
                }
                if let hostedViewObserver {
                    NotificationCenter.default.removeObserver(hostedViewObserver)
                }
                timeoutWorkItem?.cancel()
                continuation.resume(returning: reason)
            }

            @MainActor
            func evaluate() {
                switch stepBackgroundWorkspacePrime(workspaceId: workspaceId) {
                case .pending:
                    break
                case .completed(let reason):
                    finish(reason)
                }
            }

            if let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
                workspacePanelsCancellable = workspace.$panels
                    .map { _ in () }
                    .sink { _ in
                        Task { @MainActor in
                            evaluate()
                        }
                    }
            }

            pendingLoadsCancellable = tabManager.$pendingBackgroundWorkspaceLoadIds
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }

            tabsCancellable = tabManager.$tabs
                .map { _ in () }
                .sink { _ in
                    Task { @MainActor in
                        evaluate()
                    }
                }

            readyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { notification in
                guard let readyWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      readyWorkspaceId == workspaceId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            hostedViewObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceHostedViewDidMoveToWindow,
                object: nil,
                queue: .main
            ) { notification in
                guard let hostedWorkspaceId = notification.userInfo?["workspaceId"] as? UUID,
                      hostedWorkspaceId == workspaceId else { return }
                Task { @MainActor in
                    evaluate()
                }
            }

            let timeoutWork = DispatchWorkItem {
                Task { @MainActor in
                    if tabManager.pendingBackgroundWorkspaceLoadIds.contains(workspaceId) {
                        tabManager.completeBackgroundWorkspaceLoad(for: workspaceId)
                    }
                    finish("timeout")
                }
            }
            timeoutWorkItem = timeoutWork
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWork)

            Task { @MainActor in
                evaluate()
            }
        }
    }

    private func addTab() {
        tabManager.addTab()
        sidebarSelectionState.selection = .tabs
    }

    static func makeViewHierarchyTransparent(_ root: NSView) {
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
            view.layer?.isOpaque = false
            stack.append(contentsOf: view.subviews)
        }
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = (NSColor(hex: bgGlassTintHex) ?? .black).withAlphaComponent(bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private func setTitlebarControlsHidden(_ hidden: Bool, in window: NSWindow) {
        let controlsId = NSUserInterfaceItemIdentifier("cmux.titlebarControls")
        for accessory in window.titlebarAccessoryViewControllers {
            if accessory.view.identifier == controlsId {
                accessory.isHidden = hidden
                accessory.view.alphaValue = hidden ? 0 : 1
            }
        }
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            tabManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            retiringWorkspaceId = nil
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoffFallbackTask = nil
            return
        }

        workspaceHandoffGeneration &+= 1
        let generation = workspaceHandoffGeneration
        retiringWorkspaceId = oldSelectedId
        workspaceHandoffFallbackTask?.cancel()

#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.start id=\(snapshot.id) dt=\(debugMsText(dtMs)) old=\(debugShortWorkspaceId(oldSelectedId)) " +
                "new=\(debugShortWorkspaceId(newSelectedId))"
            )
        } else {
            dlog(
                "ws.handoff.start id=none old=\(debugShortWorkspaceId(oldSelectedId)) new=\(debugShortWorkspaceId(newSelectedId))"
            )
        }
#endif

        if canCompleteWorkspaceHandoffImmediately(for: newSelectedId) {
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(debugMsText(dtMs)) selected=\(debugShortWorkspaceId(newSelectedId))"
                )
            } else {
                dlog("ws.handoff.fastReady id=none selected=\(debugShortWorkspaceId(newSelectedId))")
            }
#endif
            completeWorkspaceHandoff(reason: "ready")
            return
        }

        workspaceHandoffFallbackTask = Task { [generation] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard workspaceHandoffGeneration == generation else { return }
                completeWorkspaceHandoff(reason: "timeout")
            }
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedTabId: UUID, reason: String) {
        guard focusedTabId == tabManager.selectedTabId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return true }
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.browserPanel(for: focusedPanelId) != nil {
            return true
        }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Hide portal-hosted views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Hiding here prevents stale terminal/browser
        // portals from covering the newly selected workspace.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
            workspace.hideAllBrowserPortalViews()
        }

        retiringWorkspaceId = nil
        tabManager.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(debugMsText(dtMs)) reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))"
            )
        } else {
            dlog("ws.handoff.complete id=none reason=\(reason) retiring=\(debugShortWorkspaceId(retiring))")
        }
#endif
    }

    private var commandPaletteOverlay: some View {
        GeometryReader { proxy in
            let maxAllowedWidth = max(340, proxy.size.width - 260)
            let targetWidth = min(560, maxAllowedWidth)
            let workspaceDescriptionMaxEditorHeight = max(
                CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight,
                proxy.size.height - 120
            )

            ZStack(alignment: .top) {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                handleCommandPaletteBackdropClick(atContentPoint: value.location)
                            }
                    )

                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("CommandPaletteBackdrop")

                VStack(spacing: 0) {
                    switch commandPaletteMode {
                    case .commands:
                        commandPaletteCommandListView
                    case .renameInput(let target):
                        commandPaletteRenameInputView(target: target)
                    case let .renameConfirm(target, proposedName):
                        commandPaletteRenameConfirmView(target: target, proposedName: proposedName)
                    case .workspaceDescriptionInput(let target):
                        commandPaletteWorkspaceDescriptionInputView(
                            target: target,
                            maxEditorHeight: workspaceDescriptionMaxEditorHeight
                        )
                    }
                }
                .frame(width: targetWidth)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.24), radius: 10, x: 0, y: 5)
                .padding(.top, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand {
            dismissCommandPalette()
        }
        .zIndex(2000)
    }

    private var commandPaletteCommandListView: some View {
        let visibleResults = commandPaletteVisibleResults
        let selectedIndex = commandPaletteSelectedIndex(resultCount: visibleResults.count)
        let commandPaletteListIdentity = "\(commandPaletteListScope.rawValue):\(commandPaletteQuery)"
        let commandPaletteListMaxHeight: CGFloat = 450
        let commandPaletteRowHeight: CGFloat = 24
        let commandPaletteEmptyStateHeight: CGFloat = 44
        let commandPaletteListContentHeight = visibleResults.isEmpty
            ? commandPaletteEmptyStateHeight
            : CGFloat(visibleResults.count) * commandPaletteRowHeight
        let commandPaletteListHeight = min(commandPaletteListMaxHeight, commandPaletteListContentHeight)
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                CommandPaletteSearchFieldRepresentable(
                    placeholder: commandPaletteSearchPlaceholder,
                    text: commandPaletteQueryBinding,
                    isFocused: Binding(
                        get: { isCommandPaletteSearchFocused },
                        set: { isCommandPaletteSearchFocused = $0 }
                    ),
                    onSubmit: runSelectedCommandPaletteResult,
                    onEscape: { dismissCommandPalette() },
                    onMoveSelection: moveCommandPaletteSelection(by:)
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            ScrollView {
                // Rebuild the full results container on scope/query transitions so
                // stale switcher rows cannot linger above command-mode results.
                VStack(spacing: 0) {
                    if visibleResults.isEmpty {
                        if commandPaletteShouldShowEmptyState {
                            Text(commandPaletteEmptyStateText)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 12)
                        } else {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: commandPaletteEmptyStateHeight)
                        }
                    } else {
                        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                            let isSelected = index == selectedIndex
                            let isHovered = commandPaletteHoveredResultIndex == index
                            let trailingLabel = commandPaletteTrailingLabel(for: result.command)
                            let rowBackground: Color = isSelected
                                ? programaAccentColor().opacity(0.12)
                                : (isHovered ? Color.primary.opacity(0.08) : .clear)

                            Button {
                                runCommandPaletteResult(commandID: result.id)
                            } label: {
                                Self.commandPaletteResultLabelContent(
                                    title: result.command.title,
                                    matchedIndices: result.titleMatchIndices,
                                    trailingLabel: trailingLabel
                                )
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(rowBackground)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("CommandPaletteResultRow.\(index)")
                            .accessibilityValue(result.id)
                            .id(index)
                            .onHover { hovering in
                                if hovering {
                                    commandPaletteHoveredResultIndex = index
                                } else if commandPaletteHoveredResultIndex == index {
                                    commandPaletteHoveredResultIndex = nil
                                }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .id(commandPaletteListIdentity)
            .frame(height: commandPaletteListHeight)
            .scrollPosition(
                id: Binding(
                    get: { commandPaletteScrollTargetIndex },
                    // Ignore passive readback so manual scrolling doesn't mutate selection-follow state.
                    set: { _ in }
                ),
                anchor: commandPaletteScrollTargetAnchor
            )
            .onChange(of: commandPaletteSelectedResultIndex) {
                updateCommandPaletteScrollTarget(resultCount: visibleResults.count, animated: true)
            }

            // Keep Esc-to-close behavior without showing footer controls.
            Button(action: { dismissCommandPalette() }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            commandPaletteHoveredResultIndex = nil
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            resetCommandPaletteSearchFocus()
        }
        .onChange(of: commandPaletteQuery) { oldValue, newValue in
            commandPaletteSelectedResultIndex = 0
            commandPaletteSelectionAnchorCommandID = nil
            commandPaletteHoveredResultIndex = nil
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            if Self.commandPaletteShouldResetVisibleResultsForQueryTransition(
                oldQuery: oldValue,
                newQuery: newValue,
                hasVisibleResults: commandPaletteVisibleResultsScope != nil
            ) {
                cachedCommandPaletteResults = []
                commandPaletteVisibleResults = []
                commandPaletteVisibleResultsScope = nil
                commandPaletteVisibleResultsFingerprint = nil
            }
            scheduleCommandPaletteResultsRefresh(query: newValue)
            updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteCurrentSearchFingerprint) {
            Task { @MainActor in
                // Let the query-state transition settle first so the forced corpus refresh
                // cannot rebuild the old command list after deleting the ">" prefix.
                await Task.yield()
                scheduleCommandPaletteResultsRefresh(
                    query: commandPaletteQuery,
                    forceSearchCorpusRefresh: true
                )
                updateCommandPaletteScrollTarget(resultCount: commandPaletteVisibleResults.count, animated: false)
                syncCommandPaletteDebugStateForObservedWindow()
            }
        }
        .onChange(of: commandPaletteResultsRevision) {
            let resultIDs = cachedCommandPaletteResults.map(\.id)
            commandPaletteSelectedResultIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                resultIDs: resultIDs
            )
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            let visibleResultCount = commandPaletteVisibleResults.count
            updateCommandPaletteScrollTarget(resultCount: visibleResultCount, animated: false)
            if let hoveredIndex = commandPaletteHoveredResultIndex, hoveredIndex >= visibleResultCount {
                commandPaletteHoveredResultIndex = nil
            }
            syncCommandPaletteDebugStateForObservedWindow()
        }
        .onChange(of: commandPaletteSelectedResultIndex) {
            syncCommandPaletteDebugStateForObservedWindow()
        }
    }

    private enum CommandPaletteEditorFieldStyle {
        case singleLine(
            accessibilityIdentifier: String,
            focus: FocusState<Bool>.Binding,
            onDeleteBackward: ((EventModifiers) -> BackportKeyPressResult)?
        )
        case multiline(
            accessibilityIdentifier: String,
            accessibilityLabel: String,
            focus: Binding<Bool>,
            measuredHeight: Binding<CGFloat>,
            maxHeight: CGFloat
        )
    }

    @ViewBuilder
    private func commandPaletteEditorField(
        style: CommandPaletteEditorFieldStyle,
        placeholder: String,
        text: Binding<String>,
        onSubmit: @escaping (String) -> Void,
        onEscape: @escaping () -> Void,
        onInteraction: (() -> Void)? = nil
    ) -> some View {
        switch style {
        case .singleLine(let accessibilityIdentifier, let focus, let onDeleteBackward):
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .tint(Color(nsColor: sidebarActiveForegroundNSColor(opacity: 1.0)))
                .focused(focus)
                .accessibilityIdentifier(accessibilityIdentifier)
                .backport.onKeyPress(.delete) { modifiers in
                    onDeleteBackward?(modifiers) ?? .ignored
                }
                .onSubmit {
                    onSubmit(text.wrappedValue)
                }
                .onTapGesture {
                    onInteraction?()
                }
        case .multiline(let accessibilityIdentifier, let accessibilityLabel, let focus, let measuredHeight, let maxHeight):
            CommandPaletteMultilineTextEditorRepresentable(
                placeholder: placeholder,
                accessibilityLabel: accessibilityLabel,
                accessibilityIdentifier: accessibilityIdentifier,
                text: text,
                isFocused: focus,
                measuredHeight: measuredHeight,
                maxHeight: maxHeight,
                onSubmit: onSubmit,
                onEscape: onEscape
            )
            .frame(height: measuredHeight.wrappedValue)
        }
    }

    private func commandPaletteRenameInputView(target: CommandPaletteRenameTarget) -> some View {
        VStack(spacing: 0) {
            commandPaletteEditorField(
                style: .singleLine(
                    accessibilityIdentifier: "CommandPaletteRenameField",
                    focus: $isCommandPaletteRenameFocused,
                    onDeleteBackward: handleCommandPaletteRenameDeleteBackward(modifiers:)
                ),
                placeholder: target.placeholder,
                text: commandPaletteRenameDraftBinding,
                onSubmit: { _ in continueRenameFlow(target: target) },
                onEscape: { dismissCommandPalette() },
                onInteraction: handleCommandPaletteRenameInputInteraction
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(renameInputHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                continueRenameFlow(target: target)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            resetCommandPaletteRenameFocus()
        }
    }

    private func commandPaletteRenameConfirmView(
        target: CommandPaletteRenameTarget,
        proposedName: String
    ) -> some View {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmedName.isEmpty ? String(localized: "commandPalette.rename.clearCustomName", defaultValue: "(clear custom name)") : trimmedName

        return VStack(spacing: 0) {
            Text(nextName)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

            Divider()

            Text(renameConfirmHintText(target: target))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)

            Button(action: {
                applyRenameFlow(target: target, proposedName: proposedName)
            }) {
                EmptyView()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func commandPaletteWorkspaceDescriptionInputView(
        target: CommandPaletteWorkspaceDescriptionTarget,
        maxEditorHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            commandPaletteEditorField(
                style: .multiline(
                    accessibilityIdentifier: "CommandPaletteWorkspaceDescriptionEditor",
                    accessibilityLabel: String(
                        localized: "command.editWorkspaceDescription.title",
                        defaultValue: "Edit Workspace Description…"
                    ),
                    focus: commandPaletteShouldFocusWorkspaceDescriptionEditorBinding,
                    measuredHeight: commandPaletteWorkspaceDescriptionHeightBinding,
                    maxHeight: maxEditorHeight
                ),
                placeholder: target.placeholder,
                text: commandPaletteWorkspaceDescriptionDraftBinding,
                onSubmit: { proposedDescription in
                    applyWorkspaceDescriptionFlow(target: target, proposedDescription: proposedDescription)
                },
                onEscape: { dismissCommandPalette() }
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 7)

            Divider()

            Text(target.inputHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
        }
        .onAppear {
#if DEBUG
            dlog(
                "palette.wsDescription.view.appear workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "height=\(String(format: "%.1f", commandPaletteWorkspaceDescriptionHeight)) " +
                "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
            )
#endif
            resetCommandPaletteWorkspaceDescriptionFocus()
        }
        .onChange(of: commandPaletteShouldFocusWorkspaceDescriptionEditor) { _, newValue in
#if DEBUG
            dlog(
                "palette.wsDescription.focus.binding new=\(newValue ? 1 : 0) " +
                "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    private final class CommandPaletteNativeTextField: NSTextField {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            usesSingleLineMode = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func keyDown(with event: NSEvent) {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                super.keyDown(with: event)
                return
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
                return super.performKeyEquivalent(with: event)
            }
            if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }

    // Keep navigation on the AppKit field editor so deleting the ">" prefix
    // cannot drop the palette's arrow-key handlers during the scope switch.
    private struct CommandPaletteSearchFieldRepresentable: NSViewRepresentable {
        let placeholder: String
        @Binding var text: String
        @Binding var isFocused: Bool
        let onSubmit: () -> Void
        let onEscape: () -> Void
        let onMoveSelection: (Int) -> Void

        final class Coordinator: NSObject, NSTextFieldDelegate {
            var parent: CommandPaletteSearchFieldRepresentable
            var isProgrammaticMutation = false
            weak var parentField: CommandPaletteNativeTextField?
            var pendingFocusRequest: Bool?
            var editorTextDidChangeObserver: NSObjectProtocol?
            weak var observedEditor: NSTextView?

            init(parent: CommandPaletteSearchFieldRepresentable) {
                self.parent = parent
            }

            deinit {
                detachEditorTextDidChangeObserver()
            }

            func controlTextDidChange(_ obj: Notification) {
                guard !isProgrammaticMutation else { return }
                guard let field = obj.object as? NSTextField else { return }
                parent.text = field.stringValue
            }

            func controlTextDidBeginEditing(_ obj: Notification) {
                if let field = obj.object as? NSTextField,
                   let editor = field.currentEditor() as? NSTextView {
                    attachEditorTextDidChangeObserverIfNeeded(editor)
                }
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func controlTextDidEndEditing(_ obj: Notification) {
                detachEditorTextDidChangeObserver()
            }

            func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)):
                    parent.onMoveSelection(1)
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    parent.onMoveSelection(-1)
                    return true
                case #selector(NSResponder.insertNewline(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onSubmit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    guard !textView.hasMarkedText() else { return false }
                    parent.onEscape()
                    return true
                default:
                    return false
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                if let delta = commandPaletteSelectionDeltaForKeyboardNavigation(
                    flags: event.modifierFlags,
                    chars: event.characters ?? event.charactersIgnoringModifiers ?? "",
                    keyCode: event.keyCode
                ) {
                    parent.onMoveSelection(delta)
                    return true
                }

                if shouldSubmitCommandPaletteWithReturn(
                    keyCode: event.keyCode,
                    flags: event.modifierFlags,
                    mode: "single_line"
                ) {
                    parent.onSubmit()
                    return true
                }

                if event.keyCode == 53,
                   event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])
                    .isEmpty {
                    parent.onEscape()
                    return true
                }

                return false
            }

            func attachEditorTextDidChangeObserverIfNeeded(_ editor: NSTextView) {
                if observedEditor !== editor {
                    detachEditorTextDidChangeObserver()
                }
                guard editorTextDidChangeObserver == nil else { return }
                observedEditor = editor
                editorTextDidChangeObserver = NotificationCenter.default.addObserver(
                    forName: NSText.didChangeNotification,
                    object: editor,
                    queue: .main
                ) { [weak self] _ in
                    guard let self, !self.isProgrammaticMutation else { return }
                    self.parent.text = editor.string
                }
            }

            func detachEditorTextDidChangeObserver() {
                if let editorTextDidChangeObserver {
                    NotificationCenter.default.removeObserver(editorTextDidChangeObserver)
                    self.editorTextDidChangeObserver = nil
                }
                observedEditor = nil
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteNativeTextField {
            let field = CommandPaletteNativeTextField(frame: .zero)
            field.font = .systemFont(ofSize: 13)
            field.placeholderString = placeholder
            field.setAccessibilityIdentifier("CommandPaletteSearchField")
            field.delegate = context.coordinator
            field.stringValue = text
            field.isEditable = true
            field.isSelectable = true
            field.isEnabled = true
            field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            context.coordinator.parentField = field
            return field
        }

        func updateNSView(_ nsView: CommandPaletteNativeTextField, context: Context) {
            context.coordinator.parent = self
            context.coordinator.parentField = nsView
            nsView.placeholderString = placeholder

            if let editor = nsView.currentEditor() as? NSTextView {
                context.coordinator.attachEditorTextDidChangeObserverIfNeeded(editor)
                if editor.string != text, !editor.hasMarkedText() {
                    context.coordinator.isProgrammaticMutation = true
                    editor.string = text
                    nsView.stringValue = text
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if nsView.stringValue != text {
                context.coordinator.detachEditorTextDidChangeObserver()
                nsView.stringValue = text
            } else {
                context.coordinator.detachEditorTextDidChangeObserver()
            }

            guard let window = nsView.window else { return }
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView

            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let coordinator, coordinator.parent.isFocused else { return }
                    guard let nsView, let window = nsView.window else { return }
                    let firstResponder = window.firstResponder
                    let alreadyFocused =
                        firstResponder === nsView ||
                        nsView.currentEditor() != nil ||
                        ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard !alreadyFocused else { return }
                    window.makeFirstResponder(nsView)
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteNativeTextField, coordinator: Coordinator) {
            nsView.delegate = nil
            nsView.onHandleKeyEvent = nil
            coordinator.detachEditorTextDidChangeObserver()
            coordinator.parentField = nil
        }
    }

    private final class CommandPalettePassthroughLabel: NSTextField {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class CommandPaletteMultilineTextView: NSTextView {
        var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
        var onDidBecomeFirstResponder: (() -> Void)?

        override func flagsChanged(with event: NSEvent) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.flagsChanged " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            super.flagsChanged(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            let becameFirstResponder = super.becomeFirstResponder()
#if DEBUG
            dlog(
                "palette.wsDescription.editor.textView.becomeFirstResponder success=\(becameFirstResponder ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "fr=\(debugCommandPaletteResponderSummary(window?.firstResponder))"
            )
#endif
            if becameFirstResponder {
                onDidBecomeFirstResponder?()
            }
            return becameFirstResponder
        }

        override func keyDown(with event: NSEvent) {
            if hasMarkedText() {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.keyDown markedText=1 " +
                    "\(debugCommandPaletteKeyEventSummary(event))"
                )
#endif
                super.keyDown(with: event)
                return
            }
            let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
            dlog(
                "palette.wsDescription.editor.keyDown handled=\(handled ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            if handled {
                return
            }
            super.keyDown(with: event)
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if hasMarkedText() {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.performKeyEquivalent markedText=1 " +
                    "\(debugCommandPaletteKeyEventSummary(event))"
                )
#endif
                return super.performKeyEquivalent(with: event)
            }
            let handled = onHandleKeyEvent?(event, self) == true
#if DEBUG
            dlog(
                "palette.wsDescription.editor.performKeyEquivalent handled=\(handled ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            if handled {
                return true
            }
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            dlog(
                "palette.wsDescription.editor.performKeyEquivalent superResult=\(result ? 1 : 0) " +
                "\(debugCommandPaletteKeyEventSummary(event))"
            )
#endif
            return result
        }

        override func doCommand(by commandSelector: Selector) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.doCommand selector=\(NSStringFromSelector(commandSelector)) " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.doCommand(by: commandSelector)
        }

        override func insertNewline(_ sender: Any?) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.insertNewline " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertNewline(sender)
        }

        override func insertLineBreak(_ sender: Any?) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.insertLineBreak " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertLineBreak(sender)
        }

        override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
#if DEBUG
            dlog(
                "palette.wsDescription.editor.insertNewlineIgnoringFieldEditor " +
                "len=\((string as NSString).length) " +
                "sel=\(selectedRange().location):\(selectedRange().length)"
            )
#endif
            super.insertNewlineIgnoringFieldEditor(sender)
        }
    }

    final class CommandPaletteMultilineTextEditorView: NSView {
        private static let font = NSFont.systemFont(ofSize: 13)
        private static let textInset = NSSize(width: 0, height: 2)
        static let defaultMinimumHeight: CGFloat = {
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return lineHeight * 5 + textInset.height * 2
        }()

        private let scrollView = NSScrollView(frame: .zero)
        let textView = CommandPaletteMultilineTextView(frame: .zero)
        private let placeholderField = CommandPalettePassthroughLabel(labelWithString: "")
        var onMeasuredHeightChange: ((CGFloat) -> Void)?
        private var lastReportedHeight: CGFloat?
        var maximumHeight: CGFloat = .greatestFiniteMagnitude {
            didSet {
                refreshMetrics()
            }
        }

        var placeholder: String = "" {
            didSet {
                placeholderField.stringValue = placeholder
                updatePlaceholderVisibility()
            }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.scrollerStyle = .overlay
            addSubview(scrollView)

            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.isEditable = true
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.isHorizontallyResizable = false
            textView.isVerticallyResizable = true
            textView.backgroundColor = .clear
            textView.drawsBackground = false
            textView.font = Self.font
            textView.textColor = .labelColor
            textView.insertionPointColor = .labelColor
            textView.textContainerInset = Self.textInset
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.heightTracksTextView = false
            textView.minSize = NSSize(width: 0, height: Self.defaultMinimumHeight)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            scrollView.documentView = textView

            placeholderField.translatesAutoresizingMaskIntoConstraints = false
            placeholderField.font = Self.font
            placeholderField.textColor = .secondaryLabelColor
            placeholderField.lineBreakMode = .byWordWrapping
            placeholderField.maximumNumberOfLines = 0
            addSubview(placeholderField)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidChange(_:)),
                name: NSText.didChangeNotification,
                object: textView
            )

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

                placeholderField.topAnchor.constraint(equalTo: topAnchor, constant: Self.textInset.height),
                placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textInset.width),
                placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.textInset.width),
            ])

            updatePlaceholderVisibility()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func layout() {
            super.layout()
            updateTextViewLayout()
            reportMeasuredHeightIfNeeded()
        }

        func refreshMetrics() {
            updatePlaceholderVisibility()
            needsLayout = true
            layoutSubtreeIfNeeded()
            reportMeasuredHeightIfNeeded()
        }

        func focusIfNeeded() {
            guard let window else {
#if DEBUG
                dlog("palette.wsDescription.editor.focusIfNeeded window=nil")
#endif
                return
            }
            guard window.firstResponder !== textView else {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.focusIfNeeded alreadyFocused window={\(debugCommandPaletteWindowSummary(window))}"
                )
#endif
                return
            }
#if DEBUG
            dlog(
                "palette.wsDescription.editor.focusIfNeeded attempt window={\(debugCommandPaletteWindowSummary(window))} " +
                "frBefore=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
            let didFocus = window.makeFirstResponder(textView)
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
#if DEBUG
            dlog(
                "palette.wsDescription.editor.focusIfNeeded result didFocus=\(didFocus ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(window))} " +
                "frAfter=\(debugCommandPaletteResponderSummary(window.firstResponder))"
            )
#endif
        }

        private func cappedMaximumHeight() -> CGFloat {
            max(Self.defaultMinimumHeight, maximumHeight)
        }

        private func naturalHeight(for width: CGFloat) -> CGFloat {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return Self.defaultMinimumHeight
            }
            textContainer.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
            let contentHeight = max(lineHeight, ceil(usedRect.height))
            return max(
                Self.defaultMinimumHeight,
                ceil(contentHeight + Self.textInset.height * 2)
            )
        }

        private func updateTextViewLayout() {
            let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
            let naturalHeight = naturalHeight(for: availableWidth)
            let measuredHeight = min(cappedMaximumHeight(), naturalHeight)
            let documentHeight = max(naturalHeight, measuredHeight)
            textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: documentHeight)
        }

        private func fittingHeight() -> CGFloat {
            let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
            return min(cappedMaximumHeight(), naturalHeight(for: availableWidth))
        }

        private func reportMeasuredHeightIfNeeded() {
            let height = fittingHeight()
            guard lastReportedHeight == nil || abs((lastReportedHeight ?? height) - height) > 0.5 else { return }
            lastReportedHeight = height
            onMeasuredHeightChange?(height)
        }

        @objc
        private func textDidChange(_ notification: Notification) {
            updatePlaceholderVisibility()
            reportMeasuredHeightIfNeeded()
#if DEBUG
            let newlineCount = textView.string.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.editor.textDidChange len=\((textView.string as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
        }

        private func updatePlaceholderVisibility() {
            placeholderField.isHidden = textView.string.isEmpty == false
        }
    }

    struct CommandPaletteMultilineTextEditorRepresentable: NSViewRepresentable {
        static let defaultMinimumHeight = CommandPaletteMultilineTextEditorView.defaultMinimumHeight

        let placeholder: String
        let accessibilityLabel: String
        let accessibilityIdentifier: String
        @Binding var text: String
        @Binding var isFocused: Bool
        @Binding var measuredHeight: CGFloat
        let maxHeight: CGFloat
        let onSubmit: (String) -> Void
        let onEscape: () -> Void

        final class Coordinator: NSObject, NSTextViewDelegate {
            var parent: CommandPaletteMultilineTextEditorRepresentable
            var isProgrammaticMutation = false
            var pendingFocusRequest = false

            init(parent: CommandPaletteMultilineTextEditorRepresentable) {
                self.parent = parent
            }

            func textDidBeginEditing(_ notification: Notification) {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.beginEditing focus=\(parent.isFocused ? 1 : 0) " +
                    "responder=\(debugCommandPaletteResponderSummary(notification.object as? NSResponder))"
                )
#endif
                if !parent.isFocused {
                    DispatchQueue.main.async {
                        self.parent.isFocused = true
                    }
                }
            }

            func textDidChange(_ notification: Notification) {
                guard !isProgrammaticMutation,
                      let textView = notification.object as? NSTextView else { return }
                parent.text = textView.string
            }

            func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.command selector=\(NSStringFromSelector(commandSelector)) " +
                    "len=\((textView.string as NSString).length) " +
                    "sel=\(textView.selectedRange().location):\(textView.selectedRange().length)"
                )
#endif
                return false
            }

            func handleDidBecomeFirstResponder() {
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.didBecomeFirstResponder focus=\(parent.isFocused ? 1 : 0)"
                )
#endif
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }

            func handleMeasuredHeight(_ height: CGFloat) {
                guard abs(parent.measuredHeight - height) > 0.5 else { return }
                DispatchQueue.main.async {
                    self.parent.measuredHeight = height
                }
            }

            func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
                guard !(editor?.hasMarkedText() ?? false) else { return false }

                let normalizedFlags = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock])

#if DEBUG
                dlog(
                    "palette.wsDescription.editor.handleKeyEvent " +
                    "\(debugCommandPaletteKeyEventSummary(event)) " +
                    "normalized=\(debugCommandPaletteModifierFlagsSummary(normalizedFlags))"
                )
#endif

                if event.keyCode == 36 || event.keyCode == 76 {
                    if normalizedFlags.isEmpty {
                        let currentText = editor?.string ?? parent.text
#if DEBUG
                        dlog("palette.wsDescription.editor.handleKeyEvent action=submit")
                        dlog(
                            "palette.wsDescription.editor.handleKeyEvent submitText " +
                            "len=\((currentText as NSString).length) " +
                            "text=\"\(debugCommandPaletteTextPreview(currentText))\""
                        )
#endif
                        if parent.text != currentText {
                            parent.text = currentText
                        }
                        parent.onSubmit(currentText)
                        return true
                    }
                    if normalizedFlags == [.shift] {
#if DEBUG
                        dlog("palette.wsDescription.editor.handleKeyEvent action=allowShiftReturn")
#endif
                        return false
                    }
                }

                if event.keyCode == 53, normalizedFlags.isEmpty {
#if DEBUG
                    dlog("palette.wsDescription.editor.handleKeyEvent action=escape")
#endif
                    parent.onEscape()
                    return true
                }

#if DEBUG
                dlog("palette.wsDescription.editor.handleKeyEvent action=passThrough")
#endif
                return false
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> CommandPaletteMultilineTextEditorView {
            let view = CommandPaletteMultilineTextEditorView(frame: .zero)
            view.placeholder = placeholder
            view.maximumHeight = maxHeight
            view.textView.string = text
            view.textView.delegate = context.coordinator
            view.textView.setAccessibilityLabel(accessibilityLabel)
            view.textView.setAccessibilityIdentifier(accessibilityIdentifier)
            view.setAccessibilityIdentifier(accessibilityIdentifier)
            view.textView.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
                coordinator?.handleKeyEvent(event, editor: editor) ?? false
            }
            view.textView.onDidBecomeFirstResponder = { [weak coordinator = context.coordinator] in
                coordinator?.handleDidBecomeFirstResponder()
            }
            view.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
                coordinator?.handleMeasuredHeight(height)
            }
            view.refreshMetrics()
#if DEBUG
            dlog(
                "palette.wsDescription.editor.make focus=\(isFocused ? 1 : 0) " +
                "textLen=\((text as NSString).length) " +
                "height=\(String(format: "%.1f", measuredHeight))"
            )
#endif
            return view
        }

        func updateNSView(_ nsView: CommandPaletteMultilineTextEditorView, context: Context) {
            context.coordinator.parent = self
            nsView.placeholder = placeholder
            nsView.maximumHeight = maxHeight
            nsView.textView.setAccessibilityLabel(accessibilityLabel)
            nsView.textView.setAccessibilityIdentifier(accessibilityIdentifier)
            nsView.setAccessibilityIdentifier(accessibilityIdentifier)

            if nsView.textView.string != text {
                context.coordinator.isProgrammaticMutation = true
                nsView.textView.string = text
                context.coordinator.isProgrammaticMutation = false
            }
            nsView.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
                coordinator?.handleMeasuredHeight(height)
            }
            nsView.refreshMetrics()

            guard let window = nsView.window else {
#if DEBUG
                if isFocused {
                    dlog(
                        "palette.wsDescription.editor.update waitingForWindow focus=1 " +
                        "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0)"
                    )
                }
#endif
                return
            }
            let isFirstResponder = window.firstResponder === nsView.textView
#if DEBUG
            if isFocused || context.coordinator.pendingFocusRequest {
                dlog(
                    "palette.wsDescription.editor.update focus=\(isFocused ? 1 : 0) " +
                    "isFirstResponder=\(isFirstResponder ? 1 : 0) " +
                    "pending=\(context.coordinator.pendingFocusRequest ? 1 : 0) " +
                    "window={\(debugCommandPaletteWindowSummary(window))} " +
                    "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
                )
            }
#endif
            if isFocused, !isFirstResponder, !context.coordinator.pendingFocusRequest {
                context.coordinator.pendingFocusRequest = true
#if DEBUG
                dlog(
                    "palette.wsDescription.editor.update scheduleFocus window={\(debugCommandPaletteWindowSummary(window))} " +
                    "fr=\(debugCommandPaletteResponderSummary(window.firstResponder))"
                )
#endif
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    guard let coordinator else { return }
                    coordinator.pendingFocusRequest = false
                    guard coordinator.parent.isFocused, let nsView else { return }
                    nsView.focusIfNeeded()
                }
            }
        }

        static func dismantleNSView(_ nsView: CommandPaletteMultilineTextEditorView, coordinator: Coordinator) {
            nsView.textView.delegate = nil
            nsView.textView.onHandleKeyEvent = nil
            nsView.textView.onDidBecomeFirstResponder = nil
            nsView.onMeasuredHeightChange = nil
        }
    }

    private func renameInputHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceInputHint", defaultValue: "Enter a workspace name. Press Enter to rename, Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabInputHint", defaultValue: "Enter a tab name. Press Enter to rename, Escape to cancel.")
        }
    }

    private func renameConfirmHintText(target: CommandPaletteRenameTarget) -> String {
        switch target.kind {
        case .workspace:
            return String(localized: "commandPalette.rename.workspaceConfirmHint", defaultValue: "Press Enter to apply this workspace name, or Escape to cancel.")
        case .tab:
            return String(localized: "commandPalette.rename.tabConfirmHint", defaultValue: "Press Enter to apply this tab name, or Escape to cancel.")
        }
    }

    private var commandPaletteListScope: CommandPaletteListScope {
        Self.commandPaletteListScope(for: commandPaletteQuery)
    }

    private var commandPaletteCurrentSearchFingerprint: Int {
        let scope = commandPaletteListScope
        return commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries,
            commandsContext: scope == .commands ? commandPaletteCachedCommandsContext() : nil
        )
    }

    var commandPaletteSwitcherIncludesSurfaceEntries: Bool {
        Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: commandPaletteQuery
        )
    }

    private var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherPlaceholderAllSurfaces", defaultValue: "Search workspaces and surfaces")
                : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        }
    }

    private var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
        case .switcher:
            return commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherEmptyAllSurfaces", defaultValue: "No workspaces or surfaces match your search.")
                : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search.")
        }
    }

    private var commandPaletteQueryForMatching: String {
        Self.commandPaletteQueryForMatching(
            query: commandPaletteQuery,
            scope: commandPaletteListScope
        )
    }

    private func refreshCommandPaletteSearchCorpus(
        force: Bool = false,
        query: String? = nil
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let includeSurfaces = Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteSearchAllSurfaces,
            query: effectiveQuery
        )
        let terminalOpenTargets = resolveCommandPaletteTerminalOpenTargets(for: scope)
        if commandPaletteTerminalOpenTargetAvailability != terminalOpenTargets {
            commandPaletteTerminalOpenTargetAvailability = terminalOpenTargets
        }
        let commandsContext = scope == .commands
            ? commandPaletteCommandsContext(terminalOpenTargets: terminalOpenTargets)
            : nil
        let fingerprint = commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        guard force || cachedCommandPaletteScope != scope || cachedCommandPaletteFingerprint != fingerprint else {
            return
        }

        let entries = commandPaletteEntries(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        commandPaletteSearchCommandsByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let searchCorpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        commandPaletteSearchCorpus = searchCorpus
        commandPaletteSearchCorpusByID = Dictionary(uniqueKeysWithValues: searchCorpus.map { ($0.payload, $0) })
        cachedCommandPaletteScope = scope
        cachedCommandPaletteFingerprint = fingerprint
    }

    private func cancelCommandPaletteSearch() {
        commandPaletteSearchTask?.cancel()
        commandPaletteSearchTask = nil
    }

    private func setCommandPaletteVisibleResults(
        _ results: [CommandPaletteSearchResult],
        scope: CommandPaletteListScope,
        fingerprint: Int?
    ) {
        commandPaletteVisibleResults = results
        commandPaletteVisibleResultsScope = scope
        commandPaletteVisibleResultsFingerprint = fingerprint
    }

    private func refreshPendingCommandPaletteVisibleResults(
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval
    ) {
        let candidateCommandIDs: [String]
        if commandPaletteVisibleResultsScope == scope,
           commandPaletteVisibleResultsFingerprint == fingerprint {
            candidateCommandIDs = Self.commandPalettePreviewCandidateCommandIDs(
                resultIDs: commandPaletteVisibleResults.map(\.id),
                limit: Self.commandPaletteVisiblePreviewCandidateLimit
            )
        } else {
            candidateCommandIDs = []
        }

        let previewMatches = Self.commandPalettePreviewSearchMatches(
            scope: scope,
            searchCorpus: commandPaletteSearchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: commandPaletteSearchCorpusByID,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp,
            resultLimit: Self.commandPaletteVisiblePreviewResultLimit
        )
        let previewResults = Self.commandPaletteMaterializedSearchResults(
            matches: previewMatches,
            commandsByID: commandPaletteSearchCommandsByID
        )
        setCommandPaletteVisibleResults(
            previewResults,
            scope: scope,
            fingerprint: fingerprint
        )
    }

    private func scheduleCommandPaletteResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let matchingQuery = Self.commandPaletteQueryForMatching(
            query: effectiveQuery,
            scope: scope
        )

        refreshCommandPaletteSearchCorpus(
            force: forceSearchCorpusRefresh,
            query: effectiveQuery
        )

        commandPaletteSearchRequestID &+= 1
        let requestID = commandPaletteSearchRequestID
        let fingerprint = cachedCommandPaletteFingerprint
        let searchCorpus = commandPaletteSearchCorpus
        let commandsByID = commandPaletteSearchCommandsByID
        let usageHistory = commandPaletteUsageHistoryByCommandId
        let queryIsEmpty = CommandPaletteFuzzyMatcher.preparedQuery(matchingQuery).isEmpty
        let historyTimestamp = Date().timeIntervalSince1970
        commandPalettePendingActivation = nil
        cancelCommandPaletteSearch()
        if Self.commandPaletteShouldSynchronouslySeedResults(
            hasVisibleResultsForScope: commandPaletteVisibleResultsScope == scope
        ) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp
            )
            cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                matches: matches,
                commandsByID: commandsByID
            )
            commandPaletteResolvedSearchRequestID = requestID
            commandPaletteResolvedSearchScope = scope
            commandPaletteResolvedSearchFingerprint = fingerprint
            commandPaletteResolvedMatchingQuery = matchingQuery
            isCommandPaletteSearchPending = false
            setCommandPaletteVisibleResults(
                cachedCommandPaletteResults,
                scope: scope,
                fingerprint: fingerprint
            )
            commandPaletteResultsRevision &+= 1
            return
        }
        refreshPendingCommandPaletteVisibleResults(
            scope: scope,
            fingerprint: fingerprint,
            query: matchingQuery,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp
        )
        isCommandPaletteSearchPending = true

        commandPaletteSearchTask = Task.detached(priority: .userInitiated) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                shouldCancel: { Task.isCancelled }
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = Self.commandPaletteListScope(for: commandPaletteQuery)
                guard commandPaletteSearchRequestID == requestID,
                      isCommandPalettePresented,
                      currentScope == scope,
                      Self.commandPaletteQueryForMatching(
                          query: commandPaletteQuery,
                          scope: currentScope
                      ) == matchingQuery,
                      cachedCommandPaletteFingerprint == fingerprint else {
                    return
                }

                cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                    matches: matches,
                    commandsByID: commandPaletteSearchCommandsByID
                )
                let resultIDs = cachedCommandPaletteResults.map(\.id)
                let pendingActivation = commandPalettePendingActivation
                let resolvedActivation = Self.commandPaletteResolvedPendingActivation(
                    pendingActivation,
                    requestID: requestID,
                    resultIDs: resultIDs
                )
                commandPaletteResolvedSearchRequestID = requestID
                commandPaletteResolvedSearchScope = scope
                commandPaletteResolvedSearchFingerprint = fingerprint
                commandPaletteResolvedMatchingQuery = matchingQuery
                isCommandPaletteSearchPending = false
                setCommandPaletteVisibleResults(
                    cachedCommandPaletteResults,
                    scope: scope,
                    fingerprint: fingerprint
                )
                if Self.commandPalettePendingActivationRequestID(pendingActivation) == requestID {
                    commandPalettePendingActivation = nil
                }
                commandPaletteResultsRevision &+= 1
                if commandPaletteSearchRequestID == requestID {
                    commandPaletteSearchTask = nil
                }
                if let resolvedActivation {
                    runCommandPaletteResolvedActivation(resolvedActivation)
                }
            }
        }
    }

    private static func commandPaletteHighlightedTitleText(_ title: String, matchedIndices: Set<Int>) -> Text {
        guard !matchedIndices.isEmpty else {
            return Text(title).foregroundColor(.primary)
        }

        let chars = Array(title)
        var index = 0
        var result = Text("")

        while index < chars.count {
            let isMatched = matchedIndices.contains(index)
            var end = index + 1
            while end < chars.count, matchedIndices.contains(end) == isMatched {
                end += 1
            }

            let segment = String(chars[index..<end])
            if isMatched {
                result = result + Text(segment).foregroundColor(.blue)
            } else {
                result = result + Text(segment).foregroundColor(.primary)
            }
            index = end
        }

        return result
    }

    @ViewBuilder
    private static func commandPaletteTrailingLabelView(_ trailingLabel: CommandPaletteTrailingLabel?) -> some View {
        if let trailingLabel {
            switch trailingLabel.style {
            case .shortcut:
                Text(trailingLabel.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Color.primary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
            case .kind:
                Text(trailingLabel.text)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private static func commandPaletteResultLabelContent(
        title: String,
        matchedIndices: Set<Int>,
        trailingLabel: CommandPaletteTrailingLabel?
    ) -> some View {
        HStack(spacing: 8) {
            commandPaletteHighlightedTitleText(
                title,
                matchedIndices: matchedIndices
            )
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
            Spacer()
            commandPaletteTrailingLabelView(trailingLabel)
        }
    }

    private func commandPaletteTrailingLabel(for command: CommandPaletteCommand) -> CommandPaletteTrailingLabel? {
        if let shortcutHint = command.shortcutHint {
            return CommandPaletteTrailingLabel(text: shortcutHint, style: .shortcut)
        }

        if let kindLabel = command.kindLabel {
            return CommandPaletteTrailingLabel(text: kindLabel, style: .kind)
        }
        return nil
    }

    func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        // Defer focus mutation one turn so browser omnibar autofocus can run
        // without being blocked by the palette-visibility guard.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(workspaceId, suppressFlash: true)
        }
    }

    func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(workspaceId, surfaceId: panelId, suppressFlash: true)
        }
    }

    func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteTerminalOpenTargetAvailability
        )
    }

    func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: contribution.title(context),
                    subtitle: contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution, context: context),
                    kindLabel: nil,
                    keywords: contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
            return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
        }

        func browserPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.browserWithName", defaultValue: "Browser • \(name)")
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")),
                subtitle: constant(String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(String(localized: "command.newWindow.title", defaultValue: "New Window")),
                subtitle: constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window")),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'programa' in PATH")),
                subtitle: constant(String(localized: "command.installCLI.subtitle", defaultValue: "CLI")),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'programa' from PATH")),
                subtitle: constant(String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(String(localized: "command.openFolder.title", defaultValue: "Open Folder…")),
                subtitle: constant(String(localized: "command.openFolder.subtitle", defaultValue: "Workspace")),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolderInVSCodeInline",
                title: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.title",
                        defaultValue: "Open Folder in VS Code (Inline)…"
                    )
                ),
                subtitle: constant(
                    String(
                        localized: "command.openFolderInVSCodeInline.subtitle",
                        defaultValue: "VS Code Inline"
                    )
                ),
                keywords: ["open", "folder", "directory", "project", "vs", "code", "inline", "editor", "browser"],
                when: { _ in TerminalDirectoryOpenTarget.vscodeInline.isAvailable() }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)")),
                subtitle: constant(String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘T",
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newBrowserTab",
                title: constant(String(localized: "command.newBrowserTab.title", defaultValue: "New Tab (Browser)")),
                subtitle: constant(String(localized: "command.newBrowserTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘⇧L",
                keywords: ["new", "browser", "tab", "web"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(String(localized: "command.closeTab.title", defaultValue: "Close Tab")),
                subtitle: constant(String(localized: "command.closeTab.subtitle", defaultValue: "Tab")),
                shortcutHint: "⌘W",
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace")),
                subtitle: constant(String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace")),
                shortcutHint: "⌘⇧W",
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(String(localized: "command.closeWindow.title", defaultValue: "Close Window")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")),
                subtitle: constant(String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window")),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reopenClosedBrowserTab",
                title: constant(String(localized: "command.reopenClosedBrowserTab.title", defaultValue: "Reopen Closed Browser Tab")),
                subtitle: constant(String(localized: "command.reopenClosedBrowserTab.subtitle", defaultValue: "Browser")),
                shortcutHint: "⌘⇧T",
                keywords: ["reopen", "closed", "browser"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(String(localized: "command.toggleSidebar.title", defaultValue: "Toggle Sidebar")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["toggle", "sidebar", "layout"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(String(localized: "command.showNotifications.title", defaultValue: "Show Notifications")),
                subtitle: constant(String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications")),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(String(localized: "command.openSettings.title", defaultValue: "Open Settings")),
                subtitle: constant(String(localized: "command.openSettings.subtitle", defaultValue: "Global")),
                shortcutHint: "⌘,",
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")),
                subtitle: constant(String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global")),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)")),
                subtitle: constant(String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global")),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update")),
                subtitle: constant(String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener")),
                subtitle: constant(String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global")),
                keywords: ["restart", "socket", "listener", "cli", "cmux", "control"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant(String(localized: "command.renameWorkspace.title", defaultValue: "Rename Workspace…")),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.editWorkspaceDescription",
                title: constant(String(localized: "command.editWorkspaceDescription.title", defaultValue: "Edit Workspace Description…")),
                subtitle: workspaceSubtitle,
                keywords: ["edit", "workspace", "description", "notes", "markdown"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant(String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceDescription",
                title: constant(String(localized: "command.clearWorkspaceDescription.title", defaultValue: "Clear Workspace Description")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "description", "notes"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomDescription)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? String(localized: "command.pinWorkspace.title", defaultValue: "Pin Workspace") : String(localized: "command.unpinWorkspace.title", defaultValue: "Unpin Workspace")
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant(String(localized: "command.nextWorkspace.title", defaultValue: "Next Workspace")),
                subtitle: constant(String(localized: "command.nextWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant(String(localized: "command.previousWorkspace.title", defaultValue: "Previous Workspace")),
                subtitle: constant(String(localized: "command.previousWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceUp",
                title: constant(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "up", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceDown",
                title: constant(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "down", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceToTop",
                title: constant(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "top", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeOtherWorkspaces",
                title: constant(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "other", "workspaces", "reset", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasPeers) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesBelow",
                title: constant(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "below", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesAbove",
                title: constant(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "above", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceRead",
                title: constant(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "read", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasUnread) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceUnread",
                title: constant(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "unread", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasRead) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant(String(localized: "command.renameTab.title", defaultValue: "Rename Tab…")),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant(String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name")),
                subtitle: panelSubtitle,
                keywords: ["clear", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? String(localized: "command.pinTab.title", defaultValue: "Pin Tab") : String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read") : String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(String(localized: "command.nextTabInPane.title", defaultValue: "Next Tab in Pane")),
                subtitle: constant(String(localized: "command.nextTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(String(localized: "command.previousTabInPane.title", defaultValue: "Previous Tab in Pane")),
                subtitle: constant(String(localized: "command.previousTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant(String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links")),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    $0.bool(CommandPaletteContextKeys.workspaceHasPullRequests)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserBack",
                title: constant(String(localized: "command.browserBack.title", defaultValue: "Back")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘[",
                keywords: ["browser", "back", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserForward",
                title: constant(String(localized: "command.browserForward.title", defaultValue: "Forward")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘]",
                keywords: ["browser", "forward", "history"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReload",
                title: constant(String(localized: "command.browserReload.title", defaultValue: "Reload Page")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘R",
                keywords: ["browser", "reload", "refresh"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserOpenDefault",
                title: constant(String(localized: "command.browserOpenDefault.title", defaultValue: "Open Current Page in Default Browser")),
                subtitle: browserPanelSubtitle,
                keywords: ["open", "default", "external", "browser"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserFocusAddressBar",
                title: constant(String(localized: "command.browserFocusAddressBar.title", defaultValue: "Focus Address Bar")),
                subtitle: browserPanelSubtitle,
                shortcutHint: "⌘L",
                keywords: ["browser", "address", "omnibar", "url"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserToggleDevTools",
                title: constant(String(localized: "command.browserToggleDevTools.title", defaultValue: "Toggle Developer Tools")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "devtools", "inspector"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserConsole",
                title: constant(String(localized: "command.browserConsole.title", defaultValue: "Show JavaScript Console")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "console", "javascript"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserReactGrab",
                title: constant(String(localized: "command.browserReactGrab.title", defaultValue: "Toggle React Grab")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "react", "grab", "inspect", "element"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomIn",
                title: constant(String(localized: "command.browserZoomIn.title", defaultValue: "Zoom In")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "in"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomOut",
                title: constant(String(localized: "command.browserZoomOut.title", defaultValue: "Zoom Out")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "out"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserZoomReset",
                title: constant(String(localized: "command.browserZoomReset.title", defaultValue: "Actual Size")),
                subtitle: browserPanelSubtitle,
                keywords: ["browser", "zoom", "reset", "actual size"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserClearHistory",
                title: constant(String(localized: "command.browserClearHistory.title", defaultValue: "Clear Browser History")),
                subtitle: constant(String(localized: "command.browserClearHistory.subtitle", defaultValue: "Browser")),
                keywords: ["browser", "history", "clear"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitRight",
                title: constant(String(localized: "command.browserSplitRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.browserSplitRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserSplitDown",
                title: constant(String(localized: "command.browserSplitDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.browserSplitDown.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.browserDuplicateRight",
                title: constant(String(localized: "command.browserDuplicateRight.title", defaultValue: "Duplicate Browser to the Right")),
                subtitle: constant(String(localized: "command.browserDuplicateRight.subtitle", defaultValue: "Browser Layout")),
                keywords: ["browser", "duplicate", "clone", "split"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsBrowser) }
            )
        )

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebStop",
                title: constant(String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "stop", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.vscodeServeWebRestart",
                title: constant(String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server")),
                subtitle: terminalPanelSubtitle,
                keywords: ["vscode", "inline", "serve-web", "restart", "server"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal)
                        && context.bool(CommandPaletteContextKeys.terminalOpenTargetAvailable(.vscodeInline))
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(String(localized: "command.terminalFind.title", defaultValue: "Find…")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘F",
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(String(localized: "command.terminalFindNext.title", defaultValue: "Find Next")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘G",
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌥⌘G",
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar")),
                subtitle: terminalPanelSubtitle,
                shortcutHint: "⌘⇧F",
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")),
                subtitle: constant(String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")),
                subtitle: constant(String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserRight",
                title: constant(String(localized: "command.terminalSplitBrowserRight.title", defaultValue: "Split Browser Right")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitBrowserDown",
                title: constant(String(localized: "command.terminalSplitBrowserDown.title", defaultValue: "Split Browser Down")),
                subtitle: constant(String(localized: "command.terminalSplitBrowserDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "browser", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )

        let programaConfigDefaultSubtitle = constant(String(localized: "command.cmuxConfig.subtitle", defaultValue: "programa.json"))
        for command in programaConfigStore.loadedCommands {
            let commandName = sanitizeProgramaConfigPaletteText(command.name)
            let subtitle = command.description
                .map { sanitizeProgramaConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : constant($0) }
                ?? programaConfigDefaultSubtitle
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: command.id,
                    title: constant(String(localized: "command.cmuxConfig.customTitle", defaultValue: "Custom: \(commandName)")),
                    subtitle: subtitle,
                    keywords: command.keywords ?? []
                )
            )
        }

        return contributions
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            tabManager.addWorkspace()
        }
        registry.register(commandId: "palette.openFolder") {
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                panel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
            }
        }
        registry.register(commandId: "palette.openFolderInVSCodeInline") {
            DispatchQueue.main.async {
                AppDelegate.shared?.showOpenFolderInInlineVSCodePanel(tabManager: tabManager)
            }
        }
        registry.register(commandId: "palette.newWindow") {
            AppDelegate.shared?.openNewMainWindow(nil)
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installProgramaCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallProgramaCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            tabManager.newSurface()
        }
        registry.register(commandId: "palette.newBrowserTab") {
            // Let command-palette dismissal complete first so omnibar focus
            // is not blocked by the palette visibility guard.
            DispatchQueue.main.async {
                _ = AppDelegate.shared?.openBrowserAndFocusAddressBar()
            }
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            if let appDelegate = AppDelegate.shared {
                appDelegate.closeWindowWithConfirmation(window)
            } else {
                window.performClose(nil)
            }
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.reopenClosedBrowserTab") {
            _ = tabManager.reopenMostRecentlyClosedBrowserPanel()
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            dlog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                dlog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.editWorkspaceDescription") {
            beginWorkspaceDescriptionFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.clearWorkspaceDescription") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomDescription(tabId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.setPinned(workspace, pinned: !workspace.isPinned)
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }
        registry.register(commandId: "palette.moveWorkspaceUp") {
            moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        registry.register(commandId: "palette.closeOtherWorkspaces") {
            closeOtherSelectedWorkspaces()
        }
        registry.register(commandId: "palette.closeWorkspacesBelow") {
            closeSelectedWorkspacesBelow()
        }
        registry.register(commandId: "palette.closeWorkspacesAbove") {
            closeSelectedWorkspacesAbove()
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forTabId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forTabId: workspaceId)
        }

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId)
                || notificationStore.hasUnreadNotification(forTabId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequestsInConfiguredBrowser() {
                    NSSound.beep()
                }
            }
        }

        registry.register(commandId: "palette.browserBack") {
            tabManager.focusedBrowserPanel?.goBack()
        }
        registry.register(commandId: "palette.browserForward") {
            tabManager.focusedBrowserPanel?.goForward()
        }
        registry.register(commandId: "palette.browserReload") {
            tabManager.focusedBrowserPanel?.reload()
        }
        registry.register(commandId: "palette.browserOpenDefault") {
            if !openFocusedBrowserInDefaultBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserFocusAddressBar") {
            if !focusFocusedBrowserAddressBar() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserToggleDevTools") {
            if !tabManager.toggleDeveloperToolsFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserConsole") {
            if !tabManager.showJavaScriptConsoleFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserReactGrab") {
            if !tabManager.toggleReactGrabFromCurrentFocus() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomIn") {
            if !tabManager.zoomInFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomOut") {
            if !tabManager.zoomOutFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserZoomReset") {
            if !tabManager.resetZoomFocusedBrowser() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.browserClearHistory") {
            BrowserHistoryStore.shared.clearHistory()
        }
        registry.register(commandId: "palette.browserSplitRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.browserSplitDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.browserDuplicateRight") {
            let url = tabManager.focusedBrowserPanel?.preferredURLStringForOmnibar().flatMap(URL.init(string:))
            _ = tabManager.createBrowserSplit(direction: .right, url: url)
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.vscodeServeWebStop") {
            stopInlineVSCodeServeWeb()
        }
        registry.register(commandId: "palette.vscodeServeWebRestart") {
            if !restartInlineVSCodeServeWeb() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            tabManager.createSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            tabManager.createSplit(direction: .down)
        }
        registry.register(commandId: "palette.terminalSplitBrowserRight") {
            _ = tabManager.createBrowserSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitBrowserDown") {
            _ = tabManager.createBrowserSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !tabManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            guard let workspace = tabManager.selectedWorkspace,
                  tabManager.equalizeSplits(tabId: workspace.id) else {
                NSSound.beep()
                return
            }
        }

        for command in programaConfigStore.loadedCommands {
            let captured = command
            let sourcePath = programaConfigStore.commandSourcePaths[command.id]
            let globalPath = programaConfigStore.globalConfigPath
            registry.register(commandId: command.id) {
                let rawCwd = tabManager.selectedWorkspace?.currentDirectory
                let baseCwd = (rawCwd?.isEmpty == false) ? rawCwd!
                    : FileManager.default.homeDirectoryForCurrentUser.path
                ProgramaConfigExecutor.execute(
                    command: captured,
                    tabManager: tabManager,
                    baseCwd: baseCwd,
                    configSourcePath: sourcePath,
                    globalConfigPath: globalPath
                )
            }
        }
    }

    var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    func workspaceDisplayName(_ workspace: Workspace) -> String {
        Self.commandPaletteWorkspaceDisplayName(workspace)
    }

    func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Tab") : trimmedFallback
    }

    private func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    private func updateCommandPaletteScrollTarget(resultCount: Int, animated: Bool) {
        guard resultCount > 0 else {
            commandPaletteScrollTargetIndex = nil
            commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        let assignTarget = {
            commandPaletteScrollTargetIndex = selectedIndex
        }
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                assignTarget()
            }
        } else {
            assignTarget()
        }
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteSelectionAnchorCommandID = Self.commandPaletteSelectionAnchorCommandID(
            selectedIndex: commandPaletteSelectedResultIndex,
            resultIDs: resultIDs
        )
    }

    private func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: cachedCommandPaletteResults.map(\.id))
    }

    private func syncCommandPaletteSelectionAnchorFromVisibleResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: commandPaletteVisibleResults.map(\.id))
    }

    private func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteVisibleResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let current = commandPaletteSelectedIndex(resultCount: count)
        commandPaletteSelectedResultIndex = min(max(current + delta, 0), count - 1)
        if commandPaletteHasCurrentResolvedResults {
            syncCommandPaletteSelectionAnchorFromCurrentResults()
        } else {
            syncCommandPaletteSelectionAnchorFromVisibleResults()
        }
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteRenameDraft = editor.string
        } else if !commandPaletteRenameDraft.isEmpty {
            commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private var commandPaletteHasCurrentResolvedResults: Bool {
        !isCommandPaletteSearchPending && commandPaletteResolvedSearchRequestID == commandPaletteSearchRequestID
    }

    private var commandPaletteShouldShowEmptyState: Bool {
        guard commandPaletteVisibleResults.isEmpty else { return false }
        if commandPaletteHasCurrentResolvedResults {
            return true
        }

        return Self.commandPaletteShouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: isCommandPaletteSearchPending,
            visibleResultsScopeMatches: commandPaletteVisibleResultsScope == commandPaletteListScope,
            resolvedSearchScopeMatches: commandPaletteResolvedSearchScope == commandPaletteListScope,
            resolvedSearchFingerprintMatches: commandPaletteResolvedSearchFingerprint == commandPaletteVisibleResultsFingerprint,
            resolvedResultsAreEmpty: cachedCommandPaletteResults.isEmpty,
            currentMatchingQuery: commandPaletteQueryForMatching,
            resolvedMatchingQuery: commandPaletteResolvedMatchingQuery
        )
    }

    private func runCommandPaletteResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        switch activation {
        case .command(let commandID):
            guard let command = cachedCommandPaletteResults.first(where: { $0.id == commandID })?.command else {
                return
            }
            runCommandPaletteCommand(command)
        case .selected(let fallbackIndex):
            guard !cachedCommandPaletteResults.isEmpty else {
                NSSound.beep()
                return
            }
            let resolvedIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: fallbackIndex,
                resultIDs: cachedCommandPaletteResults.map(\.id)
            )
            commandPaletteSelectedResultIndex = resolvedIndex
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            runCommandPaletteCommand(cachedCommandPaletteResults[resolvedIndex].command)
        }
    }

    private func runCommandPaletteResult(commandID: String) {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .command(
                    requestID: commandPaletteSearchRequestID,
                    commandID: commandID
                )
            }
            return
        }
        runCommandPaletteResolvedActivation(.command(commandID: commandID))
    }

    private func runSelectedCommandPaletteResult() {
        guard commandPaletteHasCurrentResolvedResults else {
            if isCommandPalettePresented {
                commandPalettePendingActivation = .selected(
                    requestID: commandPaletteSearchRequestID,
                    fallbackSelectedIndex: commandPaletteSelectedResultIndex,
                    preferredCommandID: commandPaletteSelectionAnchorCommandID
                )
            }
            return
        }

        runCommandPaletteResolvedActivation(.selected(index: commandPaletteSelectedResultIndex))
    }

    private func handleCommandPaletteSubmitRequest() {
        switch commandPaletteMode {
        case .commands:
            runSelectedCommandPaletteResult()
        case .renameInput(let target):
            continueRenameFlow(target: target)
        case .renameConfirm(let target, let proposedName):
            applyRenameFlow(target: target, proposedName: proposedName)
        case .workspaceDescriptionInput(let target):
#if DEBUG
            let newlineCount = commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.submit.request workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
            applyWorkspaceDescriptionFlow(
                target: target,
                proposedDescription: commandPaletteWorkspaceDescriptionDraft
            )
        }
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
#if DEBUG
        dlog("palette.run commandId=\(command.id) dismissOnRun=\(command.dismissOnRun ? 1 : 0)")
#endif
        recordCommandPaletteUsage(command.id)
        command.action()
        if command.dismissOnRun {
            dismissCommandPalette(restoreFocus: false)
        }
    }

    private func toggleCommandPalette() {
        if isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
    }

    private func openCommandPaletteCommands() {
        handleCommandPaletteListRequest(scope: .commands)
    }

    private func openCommandPaletteSwitcher() {
        handleCommandPaletteListRequest(scope: .switcher)
    }

    private func handleCommandPaletteListRequest(scope: CommandPaletteListScope) {
        let initialQuery = (scope == .commands) ? Self.commandPaletteCommandsPrefix : ""
        guard isCommandPalettePresented else {
            presentCommandPalette(initialQuery: initialQuery)
            return
        }

        if case .commands = commandPaletteMode,
           commandPaletteListScope == scope {
            dismissCommandPalette()
            return
        }

        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func openCommandPaletteRenameTabInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameTabFlow()
    }

    private func openCommandPaletteRenameWorkspaceInput() {
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameWorkspaceFlow()
    }

    private func openCommandPaletteWorkspaceDescriptionInput() {
#if DEBUG
        dlog(
            "palette.wsDescription.open begin presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
        )
#endif
        if !isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginWorkspaceDescriptionFlow()
#if DEBUG
        dlog(
            "palette.wsDescription.open end presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
    }

    private func presentFeedbackComposer() {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(string: "https://github.com/darkroomengineering/programa/issues")!)
        }
    }

    private func syncCommandPaletteDebugStateForObservedWindow() {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteVisibleResults.count
        let selectedIndex = isCommandPalettePresented ? commandPaletteSelectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(commandPaletteDebugSnapshot(), for: window)
    }

    private func commandPaletteDebugSnapshot() -> CommandPaletteDebugSnapshot {
        guard isCommandPalettePresented else { return .empty }

        let mode: String
        switch commandPaletteMode {
        case .commands:
            mode = commandPaletteListScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .renameConfirm:
            mode = "rename_confirm"
        case .workspaceDescriptionInput:
            mode = "workspace_description_input"
        }

        let rows = Array(commandPaletteVisibleResults.prefix(20)).map { result in
                CommandPaletteDebugResultRow(
                    commandId: result.command.id,
                    title: result.command.title,
                    shortcutHint: result.command.shortcutHint,
                    trailingLabel: commandPaletteTrailingLabel(for: result.command)?.text,
                    score: result.score
                )
        }

        return CommandPaletteDebugSnapshot(
            query: commandPaletteQueryForMatching,
            mode: mode,
            results: rows
        )
    }

    private func presentCommandPalette(initialQuery: String) {
        if let panelContext = focusedPanelContext {
            commandPaletteRestoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: panelContext.panel.captureFocusIntent(in: observedWindow)
            )
        } else {
            commandPaletteRestoreFocusTarget = nil
        }
        isCommandPalettePresented = true
        refreshCommandPaletteUsageHistory()
        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteMode = .commands
        commandPaletteQuery = initialQuery
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true)
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func dismissCommandPalette(restoreFocus: Bool = true) {
        dismissCommandPalette(restoreFocus: restoreFocus, preferredFocusTarget: nil)
    }

    private func dismissCommandPalette(
        restoreFocus: Bool,
        preferredFocusTarget: CommandPaletteRestoreFocusTarget?
    ) {
        let focusTarget = preferredFocusTarget ?? commandPaletteRestoreFocusTarget
#if DEBUG
        if case .workspaceDescriptionInput(let target) = commandPaletteMode {
            let newlineCount = commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.dismiss workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "restoreFocus=\(restoreFocus ? 1 : 0) " +
                "draftLen=\((commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
            )
        }
#endif
        cancelCommandPaletteSearch()
        commandPaletteSearchRequestID &+= 1
        isCommandPalettePresented = false
        commandPaletteMode = .commands
        commandPaletteQuery = ""
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        commandPaletteRestoreFocusTarget = nil
        commandPaletteSearchCorpus = []
        commandPaletteSearchCorpusByID = [:]
        commandPaletteSearchCommandsByID = [:]
        cachedCommandPaletteResults = []
        commandPaletteVisibleResults = []
        commandPaletteVisibleResultsScope = nil
        commandPaletteVisibleResultsFingerprint = nil
        cachedCommandPaletteScope = nil
        cachedCommandPaletteFingerprint = nil
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteResolvedSearchRequestID = commandPaletteSearchRequestID
        commandPaletteResolvedSearchScope = nil
        commandPaletteResolvedSearchFingerprint = nil
        commandPaletteTerminalOpenTargetAvailability = []
        isCommandPaletteSearchPending = false
        commandPalettePendingActivation = nil
        commandPaletteResultsRevision &+= 1
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        requestCommandPaletteFocusRestore(target: focusTarget)
    }

    private func handleCommandPaletteBackdropClick(atContentPoint contentPoint: CGPoint) {
        let clickedFocusTarget = commandPaletteBackdropFocusTarget(atContentPoint: contentPoint)
#if DEBUG
        if let clickedFocusTarget {
            dlog(
                "palette.dismiss.backdrop focusTarget panel=\(clickedFocusTarget.panelId.uuidString.prefix(5)) " +
                "workspace=\(clickedFocusTarget.workspaceId.uuidString.prefix(5)) intent=\(debugCommandPaletteFocusIntent(clickedFocusTarget.intent))"
            )
        } else {
            dlog("palette.dismiss.backdrop focusTarget=nil")
        }
#endif
        dismissCommandPalette(restoreFocus: true, preferredFocusTarget: clickedFocusTarget)
    }

    private func commandPaletteBackdropFocusTarget(atContentPoint contentPoint: CGPoint) -> CommandPaletteRestoreFocusTarget? {
        guard let window = observedWindow,
              let contentView = window.contentView else {
            return nil
        }

        let nsContentPoint = NSPoint(x: contentPoint.x, y: contentPoint.y)
        let windowPoint = contentView.convert(nsContentPoint, to: nil)
        return commandPaletteBackdropFocusTarget(atWindowPoint: windowPoint, in: window)
    }

    private func commandPaletteBackdropFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        let overlayController = commandPaletteWindowOverlayController(for: window)
        if let responder = overlayController.underlyingResponder(atWindowPoint: windowPoint),
           let target = commandPaletteBackdropFocusTarget(for: responder) {
            return target
        }

        if let webView = BrowserWindowPortalRegistry.webViewAtWindowPoint(windowPoint, in: window),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: window
            )
        }

        return nil
    }

    private func commandPaletteBackdropFocusTarget(for responder: NSResponder) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = cmuxOwningGhosttyView(for: responder),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return commandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: observedWindow
            )
        }

        if let webView = commandPaletteOwningWebView(for: responder),
           let target = commandPaletteBrowserFocusTarget(for: webView) {
            return target
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(for webView: WKWebView) -> CommandPaletteRestoreFocusTarget? {
        if let selectedWorkspace = tabManager.selectedWorkspace,
           let target = commandPaletteBrowserFocusTarget(in: selectedWorkspace, for: webView) {
            return target
        }

        let selectedWorkspaceId = tabManager.selectedTabId
        for workspace in tabManager.tabs where workspace.id != selectedWorkspaceId {
            if let target = commandPaletteBrowserFocusTarget(in: workspace, for: webView) {
                return target
            }
        }

        return nil
    }

    private func commandPaletteBrowserFocusTarget(
        in workspace: Workspace,
        for webView: WKWebView
    ) -> CommandPaletteRestoreFocusTarget? {
        for (panelId, panel) in workspace.panels {
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.webView === webView else {
                continue
            }

            return commandPaletteRestoreFocusTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                fallbackIntent: .browser(.webView),
                in: observedWindow
            )
        }

        return nil
    }

    private func commandPaletteRestoreFocusTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent,
        in window: NSWindow?
    ) -> CommandPaletteRestoreFocusTarget {
        let intent = tabManager.tabs
            .first(where: { $0.id == workspaceId })?
            .panels[panelId]?
            .captureFocusIntent(in: window) ?? fallbackIntent

        return CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        commandPalettePendingDismissFocusTarget = target
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        let timeoutWork = DispatchWorkItem {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem = nil
        }
        commandPaletteRestoreTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutWork)
        attemptCommandPaletteFocusRestoreIfNeeded()
    }

    private func attemptCommandPaletteFocusRestoreIfNeeded() {
        guard !isCommandPalettePresented else { return }
        guard let target = commandPalettePendingDismissFocusTarget else { return }
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem?.cancel()
            commandPaletteRestoreTimeoutWorkItem = nil
            return
        }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(target.workspaceId, surfaceId: target.panelId, suppressFlash: true)

        guard let context = focusedPanelContext,
              context.workspace.id == target.workspaceId,
              context.panelId == target.panelId else {
            return
        }
        guard context.panel.restoreFocusIntent(target.intent) else { return }
        commandPalettePendingDismissFocusTarget = nil
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        commandPaletteRestoreTimeoutWorkItem = nil
    }

#if DEBUG
    private func debugCommandPaletteFocusIntent(_ intent: PanelFocusIntent) -> String {
        switch intent {
        case .panel:
            return "panel"
        case .terminal(.surface):
            return "terminal.surface"
        case .terminal(.findField):
            return "terminal.findField"
        case .browser(.webView):
            return "browser.webView"
        case .browser(.addressBar):
            return "browser.addressBar"
        case .browser(.findField):
            return "browser.findField"
        }
    }

    private func debugCommandPaletteModeLabel(_ mode: CommandPaletteMode) -> String {
        switch mode {
        case .commands:
            return "commands"
        case .renameInput:
            return "renameInput"
        case .renameConfirm:
            return "renameConfirm"
        case .workspaceDescriptionInput:
            return "workspaceDescriptionInput"
        }
    }
#endif

    private func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    private func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func resetCommandPaletteWorkspaceDescriptionFocus() {
#if DEBUG
        dlog(
            "palette.wsDescription.focus.reset schedule presented=\(isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteMode)) " +
            "focusFlag=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
        DispatchQueue.main.async {
#if DEBUG
            dlog(
                "palette.wsDescription.focus.reset apply.before search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
            isCommandPaletteSearchFocused = false
            isCommandPaletteRenameFocused = false
            commandPaletteShouldFocusWorkspaceDescriptionEditor = true
            commandPalettePendingTextSelectionBehavior = nil
#if DEBUG
            dlog(
                "palette.wsDescription.focus.reset apply.after search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    private func handleCommandPaletteRenameInputInteraction() {
        guard isCommandPalettePresented else { return }
        guard case .renameInput = commandPaletteMode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        let selectAllOnFocus = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        let selectionBehavior: CommandPaletteTextSelectionBehavior = selectAllOnFocus
            ? .selectAll
            : .caretAtEnd
        return CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: selectionBehavior
        )
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            commandPaletteShouldFocusWorkspaceDescriptionEditor = false
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(_ behavior: CommandPaletteTextSelectionBehavior) {
        commandPalettePendingTextSelectionBehavior = behavior
        attemptCommandPaletteTextSelectionIfNeeded()
    }

    private func attemptCommandPaletteTextSelectionIfNeeded() {
        guard isCommandPalettePresented else {
            commandPalettePendingTextSelectionBehavior = nil
            return
        }
        guard let behavior = commandPalettePendingTextSelectionBehavior else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteMode {
            case .commands, .renameInput:
                break
            case .renameConfirm:
                return
            case .workspaceDescriptionInput:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else {
            return
        }
        let length = (editor.string as NSString).length
        switch behavior {
        case .selectAll:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .caretAtEnd:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        commandPalettePendingTextSelectionBehavior = nil
    }

    private func refreshCommandPaletteUsageHistory() {
        commandPaletteUsageHistoryByCommandId = loadCommandPaletteUsageHistory()
    }

    private func loadCommandPaletteUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.commandPaletteUsageDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistCommandPaletteUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandPaletteUsageDefaultsKey)
    }

    private func recordCommandPaletteUsage(_ commandId: String) {
        var history = commandPaletteUsageHistoryByCommandId
        var entry = history[commandId] ?? CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = Date().timeIntervalSince1970
        history[commandId] = entry
        commandPaletteUsageHistoryByCommandId = history
        persistCommandPaletteUsageHistory(history)
    }

    private func commandPaletteHistoryBoost(for commandId: String, queryIsEmpty: Bool) -> Int {
        Self.commandPaletteHistoryBoost(
            for: commandId,
            queryIsEmpty: queryIsEmpty,
            history: commandPaletteUsageHistoryByCommandId,
            now: Date().timeIntervalSince1970
        )
    }

    private func selectedWorkspaceIndex() -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return tabManager.tabs.firstIndex { $0.id == workspace.id }
    }

    private func moveSelectedWorkspace(by delta: Int) {
        guard let workspace = tabManager.selectedWorkspace,
              let currentIndex = selectedWorkspaceIndex() else { return }
        let targetIndex = currentIndex + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        _ = tabManager.reorderWorkspace(tabId: workspace.id, toIndex: targetIndex)
        tabManager.selectWorkspace(workspace)
    }

    private func closeWorkspaceIds(_ workspaceIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    private func closeOtherSelectedWorkspaces() {
        guard let workspace = tabManager.selectedWorkspace else { return }
        let workspaceIds = tabManager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesBelow() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func closeSelectedWorkspacesAbove() {
        guard tabManager.selectedWorkspace != nil,
              let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    private func syncSidebarSelectedWorkspaceIds() {
        tabManager.setSidebarSelectedWorkspaceIds(selectedTabIds)
    }

    private func applyUITestSidebarSelectionIfNeeded(tabs: [Workspace]) {
#if DEBUG
        guard !didApplyUITestSidebarSelection else { return }
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env["PROGRAMA_UI_TEST_SIDEBAR_SELECTED_WORKSPACE_INDICES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return
        }

        var indices: [Int] = []
        for token in rawValue.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = Int(trimmed), index >= 0 else { return }
            if !indices.contains(index) {
                indices.append(index)
            }
        }

        guard let lastIndex = indices.last, !indices.isEmpty, lastIndex < tabs.count else { return }

        let selectedIds = Set(indices.map { tabs[$0].id })
        selectedTabIds = selectedIds
        lastSidebarSelectionIndex = lastIndex
        tabManager.selectWorkspace(tabs[lastIndex])
        sidebarSelectionState.selection = .tabs
        didApplyUITestSidebarSelection = true
#endif
    }

    private func beginRenameWorkspaceFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        startRenameFlow(target)
    }

    private func beginWorkspaceDescriptionFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspace.id,
            currentDescription: workspace.customDescription ?? ""
        )
        startWorkspaceDescriptionFlow(target)
    }

    private func beginRenameTabFlow() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
        startRenameFlow(target)
    }

    private func startRenameFlow(_ target: CommandPaletteRenameTarget) {
        commandPaletteRenameDraft = target.currentName
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func startWorkspaceDescriptionFlow(_ target: CommandPaletteWorkspaceDescriptionTarget) {
#if DEBUG
        dlog(
            "palette.wsDescription.flow.start workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "descLen=\((target.currentDescription as NSString).length) " +
            "presented=\(isCommandPalettePresented ? 1 : 0) " +
            "modeBefore=\(debugCommandPaletteModeLabel(commandPaletteMode))"
        )
#endif
        commandPaletteWorkspaceDescriptionDraft = target.currentDescription
        commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteMode = .workspaceDescriptionInput(target)
        resetCommandPaletteWorkspaceDescriptionFocus()
#if DEBUG
        dlog(
            "palette.wsDescription.flow.armed workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "height=\(String(format: "%.1f", commandPaletteWorkspaceDescriptionHeight)) " +
            "modeAfter=\(debugCommandPaletteModeLabel(commandPaletteMode))"
        )
#endif
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func continueRenameFlow(target: CommandPaletteRenameTarget) {
        guard case .renameInput(let activeTarget) = commandPaletteMode,
              activeTarget == target else { return }
        applyRenameFlow(target: target, proposedName: commandPaletteRenameDraft)
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            tabManager.setCustomTitle(tabId: workspaceId, title: normalizedName)
        case .tab(let workspaceId, let panelId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalizedName)
        }

        dismissCommandPalette()
    }

    private func applyWorkspaceDescriptionFlow(
        target: CommandPaletteWorkspaceDescriptionTarget,
        proposedDescription: String
    ) {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            NSSound.beep()
            return
        }
#if DEBUG
        let newlineCount = proposedDescription.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        dlog(
            "palette.wsDescription.apply.begin workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "proposedLen=\((proposedDescription as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\(debugCommandPaletteTextPreview(proposedDescription))\""
        )
#endif
        tabManager.setCustomDescription(tabId: target.workspaceId, description: proposedDescription)
#if DEBUG
        if let updatedWorkspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }) {
            let persisted = updatedWorkspace.customDescription ?? ""
            let persistedNewlineCount = persisted.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.apply.end workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "persistedLen=\((persisted as NSString).length) " +
                "persistedNewlines=\(persistedNewlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(persisted))\""
            )
        }
#endif
        dismissCommandPalette()
    }

    private func focusFocusedBrowserAddressBar() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel else { return false }
        _ = panel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
        return true
    }

    private func openFocusedBrowserInDefaultBrowser() -> Bool {
        guard let panel = tabManager.focusedBrowserPanel,
              let rawURL = panel.preferredURLStringForOmnibar(),
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func openWorkspacePullRequestsInConfiguredBrowser() -> Bool {
        guard let workspace = tabManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }

        var openedCount = 0
        for pullRequest in pullRequests {
            if tabManager.openBrowser(url: pullRequest.url, insertAtEnd: true) != nil {
                openedCount += 1
            } else if NSWorkspace.shared.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    private func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    private func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        case .vscodeInline:
            return openFocusedDirectoryInInlineVSCode(directoryURL)
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func openFocusedDirectoryInInlineVSCode(_ directoryURL: URL) -> Bool {
        AppDelegate.shared?.openDirectoryInInlineVSCode(directoryURL, tabManager: tabManager) ?? false
    }

    private func stopInlineVSCodeServeWeb() {
        VSCodeServeWebController.shared.stop()
    }

    private func restartInlineVSCodeServeWeb() -> Bool {
        guard let vscodeApplicationURL = TerminalDirectoryOpenTarget.vscodeInline.applicationURL() else {
            return false
        }
        VSCodeServeWebController.shared.restart(vscodeApplicationURL: vscodeApplicationURL) { serveWebURL in
            if serveWebURL == nil {
                NSSound.beep()
            }
        }
        return true
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String = {
            if let focusedPanelId = workspace.focusedPanelId,
               let directory = workspace.panelDirectories[focusedPanelId] {
                return directory
            }
            return workspace.currentDirectory
        }()
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

#if DEBUG
    private func debugShortWorkspaceId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }

    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { String($0.uuidString.prefix(5)) }.joined(separator: ",") + "]"
    }

    private func debugMsText(_ ms: Double) -> String {
        String(format: "%.2fms", ms)
    }
#endif
}
