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
    @State var sidebarWidth: CGFloat = 200
    @State var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    @State var isResizerDragging = false
    @State var sidebarDragStartWidth: CGFloat?
    @State var selectedTabIds: Set<UUID> = []
    @State private var mountedWorkspaceIds: [UUID] = []
    @State var lastSidebarSelectionIndex: Int? = nil
    @State private var titlebarText: String = ""
    @State private var isFullScreen: Bool = false
    @State var observedWindow: NSWindow?
    @StateObject private var fullscreenControlsViewModel = TitlebarControlsViewModel()
    @State var previousSelectedWorkspaceId: UUID?
    @State var retiringWorkspaceId: UUID?
    @State private var workspaceHandoffGeneration: UInt64 = 0
    @State var workspaceHandoffFallbackTask: Task<Void, Never>?
    @State private var didApplyUITestSidebarSelection = false
    @State private var titlebarThemeGeneration: UInt64 = 0
    @State var sidebarDraggedTabId: UUID?
    @State private var titlebarTextUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    @State var sidebarResizerCursorReleaseWorkItem: DispatchWorkItem?
    @State var sidebarResizerPointerMonitor: Any?
    @State var isResizerBandActive = false
    #if DEBUG
    // Makes the content card's inset/radius re-render live when the Density
    // Debug window's sliders change (see WindowChrome.swift ChromeDensity).
    @ObservedObject private var densityStore = ChromeDensityStore.shared
    #endif
    @State var isSidebarResizerCursorActive = false
    @State var sidebarResizerCursorStabilizer: DispatchSourceTimer?
    @StateObject private var commandPaletteController = CommandPaletteController()

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
    var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var effectiveTitlebarPadding: CGFloat {
        // Inverted card layout with the sidebar visible: the strip owns the
        // card's top — the legacy 32pt titlebar band is dead space there. With
        // the sidebar hidden the titlebar accessory controls still need it.
        if cardInsetAmount > 0 && sidebarState.isVisible { return 0 }
        // Minimal mode keeps pane chrome at the window's top edge. The main
        // window's hosting view reports a zero safe area (MainWindowHostingView),
        // so SwiftUI content already starts at the window top; pulling it up by
        // the titlebar height would push the tab strip out of the window.
        if isMinimalMode { return 0 }
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
        .overlay(alignment: .top) {
            // Card layout with the sidebar visible has no titlebar band (see
            // effectiveTitlebarPadding) — the overlay would float over pills.
            if !isMinimalMode && !(cardInsetAmount > 0 && sidebarState.isVisible) {
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

    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    /// Inverted glass layout: the terminal region floats as a rounded card over
    /// the window's glass backdrop, inset from the edges and the sidebar.
    private var cardInsetAmount: CGFloat {
        WindowGlassEffect.isAvailable && !accessibilityReduceTransparency
            ? WindowGlassEffect.contentCardInset : 0
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
                        .padding(cardInsetAmount)
                        // Empty inset chrome drags without covering the tab controls.
                        .background(WindowDragHandleView())
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
                        .padding(cardInsetAmount)
                        .background(WindowDragHandleView())
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
    private func attachSidebarDragAndFeedbackHandlers(to view: some View) -> some View {
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
            // The monitor's closure captures this view (and so the window's TabManager);
            // a closed window's hosting view is not guaranteed an onDisappear, so the
            // window close itself removes it.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard let closing = note.object as? NSWindow, closing === observedWindow else { return }
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
                        commandPaletteController.syncDebugState(observedWindow: window)
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

    private func setTitlebarControlsHidden(_ hidden: Bool, in window: NSWindow) {
        let controlsId = NSUserInterfaceItemIdentifier("programa.titlebarControls")
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
        return workspace.hasLoadedTerminalSurface()
    }

    private func completeWorkspaceHandoff(reason: String) {
        workspaceHandoffFallbackTask?.cancel()
        workspaceHandoffFallbackTask = nil
        let retiring = retiringWorkspaceId

        // Hide portal-hosted views for the retiring workspace BEFORE clearing
        // retiringWorkspaceId. Once cleared, reconcileMountedWorkspaceIds unmounts
        // the workspace — but dismantleNSView intentionally doesn't hide portal views
        // during transient rebuilds. Hiding here prevents stale terminal
        // portals from covering the newly selected workspace.
        if let retiring, let workspace = tabManager.tabs.first(where: { $0.id == retiring }) {
            workspace.hideAllTerminalPortalViews()
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
    func debugShortWorkspaceId(_ id: UUID?) -> String {
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
