import AppKit
import Bonsplit
import Combine
import ImageIO
import SwiftUI
import ObjectiveC

struct ContentView: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let windowId: UUID
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var sidebarState: SidebarState
    @EnvironmentObject var sidebarSelectionState: SidebarSelectionState
    @State var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State var observedWindow: NSWindow?
    private struct WorkspaceHandoffContext {
        let token: UUID
        let retiring: UUID
        let fallback: Task<Void, Never>
    }

    private enum WorkspaceHandoff {
        case stable(selected: UUID?)
        case waiting(selected: UUID, context: WorkspaceHandoffContext)
        case awaitingSelection(WorkspaceHandoffContext)

        var pending: WorkspaceHandoffContext? {
            switch self {
            case .stable: return nil
            case .waiting(_, let context), .awaitingSelection(let context): return context
            }
        }
    }

    @State private var workspaceHandoff = WorkspaceHandoff.stable(selected: nil)

    var previousSelectedWorkspaceId: UUID? {
        get {
            switch workspaceHandoff {
            case .stable(let selected): return selected
            case .waiting(let selected, _): return selected
            case .awaitingSelection: return nil
            }
        }
        nonmutating set {
            if let context = workspaceHandoff.pending {
                if let newValue {
                    workspaceHandoff = .waiting(selected: newValue, context: context)
                } else {
                    workspaceHandoff = .awaitingSelection(context)
                }
            } else {
                workspaceHandoff = .stable(selected: newValue)
            }
        }
    }

    var retiringWorkspaceId: UUID? {
        workspaceHandoff.pending?.retiring
    }

    private var workspaceHandoffFallbackTask: Task<Void, Never>? {
        workspaceHandoff.pending?.fallback
    }
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @StateObject private var commandPaletteController = CommandPaletteController()

    private var sidebarView: some View {
        VerticalTabsSidebar(
            updateViewModel: updateViewModel,
            onSendFeedback: presentFeedbackComposer,
            selection: $sidebarSelectionState.selection,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            titlebarHeight: titlebarPadding
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Space at top of content area for the titlebar. This must be at least the actual titlebar
    /// height; otherwise controls like Bonsplit tab dragging can be interpreted as window drags.
    @State private var titlebarPadding: CGFloat = 32
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        // Minimal mode keeps pane chrome at the window's top edge. The main
        // window's hosting view reports a zero safe area (MainWindowHostingView),
        // so SwiftUI content already starts at the window top; pulling it up by
        // the titlebar height would push the tab strip out of the window. In full
        // screen the toolbar is an opaque strip, so the pane chrome starts below it.
        if isMinimalMode && !isFullScreen { return 0 }
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
                    // old workspace steal first responder, which can delay handoff completion.
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
        .background(alignment: .topLeading) {
            // Mounted in both presentation modes: minimal mode's tab strip uses the inset too.
            TitlebarLeadingInsetReader(inset: $titlebarLeadingInset)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
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
    private var windowIdentifier: String { "programa.main.\(windowId.uuidString)" }
    private var fakeTitlebarTextColor: Color {
        _ = titlebarThemeGeneration
        let ghosttyBackground = GhosttyApp.shared.defaultBackgroundColor
        return ghosttyBackground.isLightColor
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.82)
    }
    private var customTitlebar: some View {
        ZStack {
            // Enable window dragging from the titlebar strip without making the entire content
            // view draggable (which breaks drag gestures like tab reordering).
            WindowDragHandleView()

            HStack(spacing: 8) {
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
            .padding(.leading, sidebarState.isVisible ? 12 : titlebarLeadingInset + CGFloat(debugTitlebarLeadingExtra))
            .padding(.trailing, 8)
        }
        .frame(height: titlebarPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
        let inset: CGFloat = (isMinimalMode && !sidebarState.isVisible && !isFullScreen)
            ? titlebarLeadingInset : 0
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

    @EnvironmentObject var programaConfigStore: ProgramaConfigStore

    private func splitColumn(_ view: some View) -> AnyView {
        AnyView(
            view
                .environmentObject(tabManager)
                .environmentObject(TerminalNotificationStore.shared)
                .environmentObject(sidebarState)
                .environmentObject(sidebarSelectionState)
                .environmentObject(programaConfigStore)
        )
    }

    /// `ContentView` values the content column reads outside its own observed objects; see
    /// `MainSidebarSplitRepresentable`. A value read by `terminalContentWithSidebarDropOverlay`
    /// that is missing here leaves the column stale.
    private struct ContentColumnInputs: Hashable {
        let mountedWorkspaceIds: [UUID]
        let tabIds: [UUID]
        let selectedTabId: UUID?
        let retiringWorkspaceId: UUID?
        let pendingBackgroundWorkspaceLoadIds: Set<UUID>
        let selection: SidebarSelection
        let isFullScreen: Bool
        let isMinimalMode: Bool
        let isSidebarVisible: Bool
        let titlebarPadding: CGFloat
        let titlebarLeadingInset: CGFloat
        let debugTitlebarLeadingExtra: Double
        let titlebarText: String
        let titlebarThemeGeneration: UInt64
        let focusedDirectory: String?
        let sidebarDraggedTabId: UUID?
    }

    private struct SidebarColumnInputs: Hashable {
        let selection: SidebarSelection
        let selectedTabIds: Set<UUID>
        let lastSidebarSelectionIndex: Int?
        let titlebarPadding: CGFloat
    }

    private var contentAndSidebarLayout: some View {
        MainSidebarSplitRepresentable(
            sidebar: splitColumn(sidebarView),
            sidebarInputs: SidebarColumnInputs(
                selection: sidebarSelectionState.selection,
                selectedTabIds: selectedTabIds,
                lastSidebarSelectionIndex: lastSidebarSelectionIndex,
                titlebarPadding: titlebarPadding
            ),
            content: splitColumn(terminalContentWithSidebarDropOverlay),
            contentInputs: ContentColumnInputs(
                mountedWorkspaceIds: mountedWorkspaceIds,
                tabIds: tabManager.tabs.map(\.id),
                selectedTabId: tabManager.selectedTabId,
                retiringWorkspaceId: retiringWorkspaceId,
                pendingBackgroundWorkspaceLoadIds: tabManager.pendingBackgroundWorkspaceLoadIds,
                selection: sidebarSelectionState.selection,
                isFullScreen: isFullScreen,
                isMinimalMode: isMinimalMode,
                isSidebarVisible: sidebarState.isVisible,
                titlebarPadding: titlebarPadding,
                titlebarLeadingInset: titlebarLeadingInset,
                debugTitlebarLeadingExtra: debugTitlebarLeadingExtra,
                titlebarText: titlebarText,
                titlebarThemeGeneration: titlebarThemeGeneration,
                focusedDirectory: focusedDirectory,
                sidebarDraggedTabId: sidebarDraggedTabId
            ),
            sidebarState: sidebarState
        )
    }

    var body: some View {
        let baseLayout =
            contentAndSidebarLayout
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .frame(minWidth: CGFloat(SessionPersistencePolicy.minimumWindowWidth), minHeight: CGFloat(SessionPersistencePolicy.minimumWindowHeight))
                .background(Color.clear)

        let step1 = attachWorkspaceLifecycleHandlers(to: baseLayout)
        let step2 = attachTerminalFocusHandlers(to: step1)
        let step3 = attachWorkspaceTabsHandlers(to: step2)
        let step4 = attachSidebarDragAndFeedbackHandlers(to: step3)
        let step5 = attachCommandPalette(to: step4)
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

                    if tabManager.tabs.isEmpty {
                        tabManager.addWorkspace()
                        didRecover = true
                    }

                    if tabManager.selectedTabId == nil || !tabManager.tabs.contains(where: { $0.id == tabManager.selectedTabId }) {
                        tabManager.selectedTabId = tabManager.tabs.first?.id
                        didRecover = true
                    }

                    if mountedWorkspaceIds.isEmpty || !mountedWorkspaceIds.contains(where: { id in tabManager.tabs.contains { $0.id == id } }) {
                        reconcileMountedWorkspaceIds()
                        didRecover = true
                    }

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
                        "ws.view.selectedChange id=\(snapshot.id) dt=\(TabManager.debugMsText(dtMs)) selected=\(TabManager.debugShortWorkspaceId(newValue))"
                    )
                } else {
                    dlog("ws.view.selectedChange id=none selected=\(TabManager.debugShortWorkspaceId(newValue))")
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
                        "ws.view.hotChange id=\(snapshot.id) dt=\(TabManager.debugMsText(dtMs)) hot=\(tabManager.isWorkspaceCycleHot ? 1 : 0)"
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
    private func attachTerminalFocusHandlers(to view: some View) -> some View {
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
                commandPaletteController.attemptFocusRestoreIfNeeded(tabManager: tabManager, observedWindow: observedWindow)
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
                commandPaletteController.attemptFocusRestoreIfNeeded(tabManager: tabManager, observedWindow: observedWindow)
            }
    }

    @ViewBuilder
    private func attachWorkspaceTabsHandlers(to view: some View) -> some View {
        view
            .onReceive(tabManager.$tabs) { tabs in
                let existingIds = Set(tabs.map { $0.id })
                if let retiringWorkspaceId, !existingIds.contains(retiringWorkspaceId) {
                    workspaceHandoffFallbackTask?.cancel()
                    workspaceHandoff = .stable(selected: previousSelectedWorkspaceId)
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
    private func attachSidebarDragAndFeedbackHandlers(to view: some View) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.stateDidChange)) { notification in
                let tabId = SidebarDragLifecycleNotification.tabId(from: notification)
                sidebarDraggedTabId = tabId
    #if DEBUG
                dlog(
                    "sidebar.dragState.content tab=\(TabManager.debugShortWorkspaceId(tabId)) " +
                    "reason=\(SidebarDragLifecycleNotification.reason(from: notification))"
                )
    #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .feedbackComposerRequested)) { notification in
                let requestedWindow = notification.object as? NSWindow
                guard CommandPaletteView.shouldHandleCommandPaletteRequest(
                    observedWindow: observedWindow,
                    requestedWindow: requestedWindow,
                    keyWindow: NSApp.keyWindow,
                    mainWindow: NSApp.mainWindow
                ) else { return }
                presentFeedbackComposer()
            }
    }

    @ViewBuilder
    private func attachCommandPalette(to view: some View) -> some View {
        view
            .background(
                CommandPaletteView(
                    commandPaletteController: commandPaletteController,
                    updateViewModel: updateViewModel,
                    windowId: windowId,
                    observedWindow: observedWindow,
                    onSendFeedback: presentFeedbackComposer
                )
            )
    }

    func presentFeedbackComposer() {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(string: "https://github.com/darkroomengineering/programa/issues")!)
        }
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
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
                // Stock tint derives from the terminal background; track theme changes.
                updateWindowGlassTint()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window === observedWindow else { return }
                isFullScreen = true
                titlebarPadding = AppDelegate.titlebarPadding(for: window)
                syncTrafficLightInset()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
                guard let window = notification.object as? NSWindow,
                      window === observedWindow else { return }
                isFullScreen = false
                titlebarPadding = AppDelegate.titlebarPadding(for: window)
                syncTrafficLightInset()
            }
    }

    @ViewBuilder
    private func attachSidebarSyncHandlers(to view: some View) -> some View {
        view
            .onChange(of: sidebarState.isVisible) {
                if let observedWindow {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
                } else {
                    TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronizeForAllWindows()
                }
                syncTrafficLightInset()
            }
            // The portal stops following the column frame when the collapse animation ends; sync it to the final one.
            .onReceive(NotificationCenter.default.publisher(for: .programaSidebarToggleDidSettle, object: sidebarState)) { _ in
                guard let observedWindow else { return }
                TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: observedWindow)
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
            .onChange(of: titlebarLeadingInset) { _, _ in
                syncTrafficLightInset()
            }
    }

    @ViewBuilder
    private func attachFinalLifecycleHandlers(to view: some View) -> some View {
        view
            .ignoresSafeArea()
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

                if observedWindow !== window {
                    DispatchQueue.main.async {
                        observedWindow = window
                        isFullScreen = window.styleMask.contains(.fullScreen)
                        commandPaletteController.syncDebugState(observedWindow: window)
                    }
                }

                if abs(titlebarPadding - nextPadding) > 0.5 {
                    DispatchQueue.main.async {
                        titlebarPadding = nextPadding
                    }
                }
            })
            // The toolbar can install after the accessor last ran (the sidebar split reaches
            // the window later), which grows the titlebar to the toolbar's height.
            .onReceive(NotificationCenter.default.publisher(for: .programaMainWindowToolbarDidChange)) { notification in
                guard let window = notification.object as? NSWindow,
                      window.identifier?.rawValue == windowIdentifier else { return }
                DispatchQueue.main.async {
                    let nextPadding = AppDelegate.titlebarPadding(for: window)
                    if abs(titlebarPadding - nextPadding) > 0.5 {
                        titlebarPadding = nextPadding
                    }
                }
            }
    }

    func reconcileMountedWorkspaceIds(tabs: [Workspace]? = nil, selectedId: UUID? = nil) {
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
                    "ws.mount.reconcile id=\(snapshot.id) dt=\(TabManager.debugMsText(dtMs)) hot=\(isCycleHot ? 1 : 0) " +
                    "selected=\(TabManager.debugShortWorkspaceId(effectiveSelectedId)) " +
                    "mounted=\(debugShortWorkspaceIds(mountedWorkspaceIds)) " +
                    "added=\(debugShortWorkspaceIds(added)) removed=\(debugShortWorkspaceIds(removed))"
                )
            } else {
                dlog(
                    "ws.mount.reconcile id=none hot=\(isCycleHot ? 1 : 0) selected=\(TabManager.debugShortWorkspaceId(effectiveSelectedId)) " +
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

    static func makeViewHierarchyTransparent(_ root: NSView) {
        // This walk runs on every configureMainWindow call while glass/translucency
        // is active, not just once, so it needs to be safe to re-run cheaply.
        // Skip mutating a view whose layer already matches: repeated writes to
        // wantsLayer/backgroundColor/isOpaque still fire AppKit's layer/KVO
        // machinery even when the value doesn't change, and that repeated firing
        // was part of the safe-area invalidation storm in issue #307. The walk
        // still visits every subview so newly added views are always covered.
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if !view.wantsLayer {
                view.wantsLayer = true
            }
            if let layer = view.layer {
                if layer.backgroundColor != NSColor.clear.cgColor {
                    layer.backgroundColor = NSColor.clear.cgColor
                }
                if layer.isOpaque {
                    layer.isOpaque = false
                }
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    private func updateWindowGlassTint() {
        // Find this view's main window by identifier (keyWindow might be a debug panel/settings).
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == windowIdentifier }) else { return }
        let tintColor = WindowGlassEffect.resolvedWindowTint(hex: bgGlassTintHex, opacity: bgGlassTintOpacity)
        WindowGlassEffect.updateTint(to: window, color: tintColor)
    }

    private func startWorkspaceHandoffIfNeeded(newSelectedId: UUID?) {
        let oldSelectedId = previousSelectedWorkspaceId
        previousSelectedWorkspaceId = newSelectedId

        guard let oldSelectedId, let newSelectedId, oldSelectedId != newSelectedId else {
            tabManager.completePendingWorkspaceUnfocus(reason: "no_handoff")
            workspaceHandoffFallbackTask?.cancel()
            workspaceHandoff = .stable(selected: newSelectedId)
            return
        }

        workspaceHandoffFallbackTask?.cancel()
        let token = UUID()
        let fallback = Task {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            await MainActor.run {
                guard workspaceHandoff.pending?.token == token else { return }
                completeWorkspaceHandoff(reason: "timeout")
            }
        }
        workspaceHandoff = .waiting(
            selected: newSelectedId,
            context: WorkspaceHandoffContext(token: token, retiring: oldSelectedId, fallback: fallback)
        )

#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.start id=\(snapshot.id) dt=\(TabManager.debugMsText(dtMs)) old=\(TabManager.debugShortWorkspaceId(oldSelectedId)) " +
                "new=\(TabManager.debugShortWorkspaceId(newSelectedId))"
            )
        } else {
            dlog(
                "ws.handoff.start id=none old=\(TabManager.debugShortWorkspaceId(oldSelectedId)) new=\(TabManager.debugShortWorkspaceId(newSelectedId))"
            )
        }
#endif

        if canCompleteWorkspaceHandoffImmediately(for: newSelectedId) {
#if DEBUG
            if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
                let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
                dlog(
                    "ws.handoff.fastReady id=\(snapshot.id) dt=\(TabManager.debugMsText(dtMs)) selected=\(TabManager.debugShortWorkspaceId(newSelectedId))"
                )
            } else {
                dlog("ws.handoff.fastReady id=none selected=\(TabManager.debugShortWorkspaceId(newSelectedId))")
            }
#endif
            completeWorkspaceHandoff(reason: "ready")
            return
        }
    }

    private func completeWorkspaceHandoffIfNeeded(focusedTabId: UUID, reason: String) {
        guard focusedTabId == tabManager.selectedTabId else { return }
        guard retiringWorkspaceId != nil else { return }
        completeWorkspaceHandoff(reason: reason)
    }

    private func canCompleteWorkspaceHandoffImmediately(for workspaceId: UUID) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { return true }
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        let retiring = retiringWorkspaceId

        // Hide portal-hosted views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Hiding here prevents stale terminal
        // portals from covering the newly selected workspace.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
        }

        workspaceHandoff = .stable(selected: previousSelectedWorkspaceId)
        tabManager.completePendingWorkspaceUnfocus(reason: reason)
#if DEBUG
        if let snapshot = tabManager.debugCurrentWorkspaceSwitchSnapshot() {
            let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
            dlog(
                "ws.handoff.complete id=\(snapshot.id) dt=\(TabManager.debugMsText(dtMs)) reason=\(reason) retiring=\(TabManager.debugShortWorkspaceId(retiring))"
            )
        } else {
            dlog("ws.handoff.complete id=none reason=\(reason) retiring=\(TabManager.debugShortWorkspaceId(retiring))")
        }
#endif
    }

    func syncSidebarSelectedWorkspaceIds() {
        tabManager.setSidebarSelectedWorkspaceIds(selectedTabIds)
    }

    func applyUITestSidebarSelectionIfNeeded(tabs: [Workspace]) {
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

#if DEBUG
    private func debugShortWorkspaceIds(_ ids: [UUID]) -> String {
        if ids.isEmpty { return "[]" }
        return "[" + ids.map { TabManager.debugShortWorkspaceId($0) }.joined(separator: ",") + "]"
    }
#endif
}
