import AppKit
import Bonsplit
import Combine
import SwiftUI

extension Notification.Name {
    static let programaSidebarVisibilityDidChange =
        Notification.Name("programaSidebarVisibilityDidChange")
}

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool {
        didSet {
            guard isVisible != oldValue else { return }
            NotificationCenter.default.post(name: .programaSidebarVisibilityDidChange, object: nil)
        }
    }
    @Published var persistedWidth: CGFloat

    init(isVisible: Bool = true, persistedWidth: CGFloat = CGFloat(SessionPersistencePolicy.defaultSidebarWidth)) {
        self.isVisible = isVisible
        let sanitized = SessionPersistencePolicy.sanitizedSidebarWidth(Double(persistedWidth))
        self.persistedWidth = CGFloat(sanitized)
    }

    func toggle() {
        isVisible.toggle()
    }
}

enum SidebarResizeInteraction {
    // Keep a generous drag target inside the sidebar itself, but make the
    // terminal-side overlap very small so column-0 text selection still wins.
    static let sidebarSideHitWidth: CGFloat = 6
    // 4 pt matches the 4 pt padding used in GhosttySurfaceScrollView drop zone overlays
    // (dropZoneOverlayFrame). This prevents column-0 text near the leading edge from
    // accidentally triggering the sidebar resize when interacting with leftmost content.
    static let contentSideHitWidth: CGFloat = 4

    static var totalHitWidth: CGFloat {
        sidebarSideHitWidth + contentSideHitWidth
    }
}

struct SidebarResizerAccessibilityModifier: ViewModifier {
    let accessibilityIdentifier: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let accessibilityIdentifier {
            content.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            content
        }
    }
}

struct SidebarTabItemSettingsSnapshot: Equatable {
    let sidebarShortcutHintXOffset: Double
    let sidebarShortcutHintYOffset: Double
    let alwaysShowShortcutHints: Bool
    let showsGitBranch: Bool
    let usesVerticalBranchLayout: Bool
    let showsGitBranchIcon: Bool
    let openPullRequestLinksInProgramaBrowser: Bool
    let openPortLinksInProgramaBrowser: Bool
    let showsNotificationMessage: Bool
    let activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle
    let selectionColorHex: String?
    let notificationBadgeColorHex: String?
    let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility

    init(defaults: UserDefaults = .standard) {
        sidebarShortcutHintXOffset = Self.double(
            defaults: defaults,
            key: ShortcutHintDebugSettings.sidebarHintXKey,
            defaultValue: ShortcutHintDebugSettings.defaultSidebarHintX
        )
        sidebarShortcutHintYOffset = Self.double(
            defaults: defaults,
            key: ShortcutHintDebugSettings.sidebarHintYKey,
            defaultValue: ShortcutHintDebugSettings.defaultSidebarHintY
        )
        alwaysShowShortcutHints = Self.bool(
            defaults: defaults,
            key: ShortcutHintDebugSettings.alwaysShowHintsKey,
            defaultValue: ShortcutHintDebugSettings.defaultAlwaysShowHints
        )
        showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        usesVerticalBranchLayout = true
        showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        openPullRequestLinksInProgramaBrowser = true
        openPortLinksInProgramaBrowser = true
        showsNotificationMessage = true
        visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility(
            showsMetadata: true,
            showsLog: true,
            showsProgress: true,
            showsBranchDirectory: true,
            showsPullRequests: true,
            showsPorts: true
        )

        activeTabIndicatorStyle = SidebarActiveTabIndicatorSettings.current(defaults: defaults)
        selectionColorHex = defaults.string(forKey: "sidebarSelectionColorHex")
        notificationBadgeColorHex = defaults.string(forKey: "sidebarNotificationBadgeColorHex")
    }

    private static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static func double(
        defaults: UserDefaults,
        key: String,
        defaultValue: Double
    ) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return defaultValue }
        return value.doubleValue
    }
}

@MainActor
private final class SidebarTabItemSettingsStore: ObservableObject {
    @Published private(set) var snapshot: SidebarTabItemSettingsSnapshot

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshSnapshot()
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    private func refreshSnapshot() {
        let nextSnapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }
}

struct VerticalTabsSidebar: View {
    @ObservedObject var updateViewModel: UpdateViewModel
    let onSendFeedback: () -> Void
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var sidebarState: SidebarState
    @Binding var selection: SidebarSelection
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    @StateObject private var modifierKeyMonitor = SidebarShortcutHintModifierMonitor()
    @StateObject private var dragAutoScrollController = SidebarDragAutoScrollController()
    @StateObject private var dragFailsafeMonitor = SidebarDragFailsafeMonitor()
    @StateObject private var tabItemSettingsStore = SidebarTabItemSettingsStore()
    @ObservedObject private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var draggedTabId: UUID?
    @State private var dropIndicator: SidebarDropIndicator?
    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    /// Content clearance inside the glass panel for the traffic lights and the
    /// always-visible titlebar controls that share the panel's top strip.
    private let trafficLightPadding: CGFloat = WindowGlassEffect.sidebarHeaderHeight
    @Environment(\.accessibilityReduceTransparency) private var accessibilityReduceTransparency

    /// Inverted layout: sidebar rendered directly on the window glass backdrop.
    private var usesBackdropSidebar: Bool {
        WindowGlassEffect.isAvailable && !accessibilityReduceTransparency
    }
    /// Resolved from `ChromeDensity.sidebarRowSpacing` -- was a fixed `2pt`
    /// constant before density tokens (see `WindowChrome.swift`).
    private var tabRowSpacing: CGFloat { ChromeDensity.sidebarRowSpacing }
    #if DEBUG
    // Subscribing here makes the whole sidebar (rows, spacing, header/panel
    // insets) re-render live when the Density Debug window's sliders change.
    @ObservedObject private var densityStore = ChromeDensityStore.shared
    #endif

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    private var showsSidebarNotificationMessage: Bool {
        tabItemSettingsStore.snapshot.showsNotificationMessage
    }

    private var workspaceNumberShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .selectWorkspaceByNumber)
    }

    var body: some View {
        let tabs = tabManager.tabs
        let hierarchyEntries = tabs.map {
            SidebarWorkspaceHierarchyEntry(
                id: $0.id,
                parentId: $0.worktreeParentWorkspaceId ?? $0.agentParentWorkspaceId,
                isFolder: $0.isWorktreeFolder,
                isCollapsed: $0.isWorktreeFolderCollapsed
            )
        }
        let tabsById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let visibleTabs = SidebarWorkspaceHierarchy.visibleWorkspaceIds(hierarchyEntries).compactMap {
            tabsById[$0]
        }
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let rowMetrics = SidebarRowMetrics.current
        let sidebarContent = VStack(spacing: 0) {
            // Single header row shared with the traffic lights (Maps-style): the
            // lights float over its leading side, controls sit trailing, and the
            // whole strip drags/double-clicks like a titlebar.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                // Right-aligned: the controls view carries its own ~18pt trailing
                // inset (shortcut-hint clearance), which serves as the edge padding.
                HiddenTitlebarSidebarControlsView(
                    notificationStore: notificationStore,
                    sidebarState: sidebarState
                )
            }
            .frame(height: trafficLightPadding)
            // Flush sidebar (no panel inset): keep the header aligned with
            // AppKit's native titlebar controls.
            .padding(.top, usesBackdropSidebar ? WindowGlassEffect.sidebarPanelInset : 0)
            .contentShape(Rectangle())
            .background(
                // onDoubleClick replaces the standard zoom/minimize titlebar
                // action here — double-click on the header strip opens a tab.
                WindowDragHandleView(onDoubleClick: { tabManager.addTab() })
            )

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Workspaces are bounded, so prefer a non-lazy stack here.
                        // LazyVStack + drag-state invalidations can recurse through layout.
                        VStack(spacing: tabRowSpacing) {
                            ForEach(visibleTabs, id: \.id) { tab in
                                let index = tabIndexById[tab.id] ?? 0
                                let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
                                let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
                                    ? selectedContextTargetIds
                                    : [tab.id]
                                let showsWorktreeBadge = tab.worktreeParentWorkspaceId != nil
                                let worktreeChildCount = SidebarWorkspaceHierarchy.childCount(
                                    of: tab.id,
                                    in: hierarchyEntries
                                )
                                TabItemView(
                                    tabManager: tabManager,
                                    notificationStore: notificationStore,
                                    tab: tab,
                                    index: index,
                                    isActive: tabManager.selectedTabId == tab.id,
                                    workspaceShortcutDigit: WorkspaceShortcutMapper.digitForWorkspace(
                                        at: index,
                                        workspaceCount: workspaceCount
                                    ),
                                    workspaceShortcutModifierSymbol: workspaceNumberShortcut.numberedDigitHintPrefix,
                                    canCloseWorkspace: canCloseWorkspace,
                                    accessibilityWorkspaceCount: workspaceCount,
                                    unreadCount: notificationStore.unreadCount(forTabId: tab.id),
                                    latestNotificationText: {
                                        guard showsSidebarNotificationMessage,
                                              let notification = notificationStore.latestNotification(forTabId: tab.id) else {
                                            return nil
                                        }
                                        let text = notification.body.isEmpty ? notification.title : notification.body
                                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                        return trimmed.isEmpty ? nil : trimmed
                                    }(),
                                    rowSpacing: tabRowSpacing,
                                    setSelectionToTabs: { selection = .tabs },
                                    selectedTabIds: $selectedTabIds,
                                    lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                                    showsModifierShortcutHints: modifierKeyMonitor.isModifierPressed,
                                    dragAutoScrollController: dragAutoScrollController,
                                    draggedTabIdSnapshot: draggedTabId,
                                    dropIndicatorSnapshot: dropIndicator,
                                    draggedTabId: $draggedTabId,
                                    dropIndicator: $dropIndicator,
                                    contextMenuWorkspaceIds: contextMenuWorkspaceIds,
                                    settings: tabItemSettings,
                                    showsWorktreeBadge: showsWorktreeBadge,
                                    isWorktreeFolder: tab.isWorktreeFolder,
                                    isWorktreeFolderCollapsed: tab.isWorktreeFolderCollapsed,
                                    worktreeChildCount: worktreeChildCount,
                                    rowMetrics: rowMetrics
                                )
                                .equatable()
                                .padding(
                                    .leading,
                                    CGFloat(SidebarWorkspaceHierarchy.depth(of: tab.id, entries: hierarchyEntries)) * 14
                                )
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        SidebarEmptyArea(
                            tabManager: tabManager,
                            rowSpacing: tabRowSpacing,
                            selection: $selection,
                            selectedTabIds: $selectedTabIds,
                            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
                            dragAutoScrollController: dragAutoScrollController,
                            draggedTabId: $draggedTabId,
                            dropIndicator: $dropIndicator
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .background(
                    SidebarScrollViewResolver { scrollView in
                        dragAutoScrollController.attach(scrollView: scrollView)
                    }
                    .frame(width: 0, height: 0)
                )
                .background(Color.clear)
                .modifier(ClearScrollBackground())
            }
            SidebarFooter(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Clearance from the window's bottom-left corner curve so the last
            // footer row doesn't ride the radius.
            .padding(.bottom, 6)
            // Empty footer space (below/around the help, usage, and feedback controls)
            // drags the window; the buttons/rows above keep their own
            // clicks via the sibling hit-test walk in windowDragHandleShouldCaptureHit.
            .background(WindowDragHandleView())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Sidebar")

        ZStack {
            if usesBackdropSidebar {
                // Inverted (Aside-style): the sidebar sits flush on the window's
                // glass backdrop — no base plane, no panel inset.
                SidebarSurface(content: sidebarContent)
            } else {
                SidebarTerminalBasePlane()
                    .ignoresSafeArea()
                SidebarSurface(content: sidebarContent)
                    .padding(WindowGlassEffect.sidebarPanelInset)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(
                WindowAccessor { window in
                    modifierKeyMonitor.setHostWindow(window)
                }
                .frame(width: 0, height: 0)
            )
        .onAppear {
            modifierKeyMonitor.start()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_appear"
            )
        }
        .onDisappear {
            modifierKeyMonitor.stop()
            dragAutoScrollController.stop()
            dragFailsafeMonitor.stop()
            draggedTabId = nil
            dropIndicator = nil
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: nil,
                reason: "sidebar_disappear"
            )
        }
        .onChange(of: draggedTabId) { _, newDraggedTabId in
            SidebarDragLifecycleNotification.postStateDidChange(
                tabId: newDraggedTabId,
                reason: "drag_state_change"
            )
#if DEBUG
            dlog("sidebar.dragState.sidebar tab=\(debugShortSidebarTabId(newDraggedTabId))")
#endif
            if newDraggedTabId != nil {
                dragFailsafeMonitor.start {
                    SidebarDragLifecycleNotification.postClearRequest(reason: $0)
                }
                return
            }
            dragFailsafeMonitor.stop()
            dragAutoScrollController.stop()
            dropIndicator = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarDragLifecycleNotification.requestClear)) { notification in
            guard draggedTabId != nil else { return }
            let reason = SidebarDragLifecycleNotification.reason(from: notification)
#if DEBUG
            dlog("sidebar.dragClear tab=\(debugShortSidebarTabId(draggedTabId)) reason=\(reason)")
#endif
            draggedTabId = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func debugShortSidebarTabId(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(5))
    }
}
