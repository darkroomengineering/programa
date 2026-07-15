import AppKit
import Bonsplit
import Combine
import SwiftUI

final class SidebarState: ObservableObject {
    @Published var isVisible: Bool
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
    let showsSSH: Bool
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
        showsSSH = true
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

    /// Space at top of sidebar for traffic light buttons
    private let trafficLightPadding: CGFloat = 28
    private let tabRowSpacing: CGFloat = 2
    private let hiddenTitlebarControlsLeadingInset: CGFloat = 72

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
        let workspaceCount = tabs.count
        let canCloseWorkspace = workspaceCount > 1
        let workspaceNumberShortcut = self.workspaceNumberShortcut
        let tabItemSettings = tabItemSettingsStore.snapshot
        let tabIndexById = Dictionary(uniqueKeysWithValues: tabs.enumerated().map {
            ($0.element.id, $0.offset)
        })
        let orderedSelectedTabs = tabs.filter { selectedTabIds.contains($0.id) }
        let selectedContextTargetIds = orderedSelectedTabs.map(\.id)
        let selectedRemoteContextMenuTargets = orderedSelectedTabs.filter { $0.isRemoteWorkspace }
        let selectedRemoteContextMenuWorkspaceIds = selectedRemoteContextMenuTargets.map(\.id)
        let allSelectedRemoteContextMenuTargetsConnecting = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .connecting }
        let allSelectedRemoteContextMenuTargetsDisconnected = !selectedRemoteContextMenuTargets.isEmpty &&
            selectedRemoteContextMenuTargets.allSatisfy { $0.remoteConnectionState == .disconnected }

        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Space for traffic lights / fullscreen controls
                        Spacer()
                            .frame(height: trafficLightPadding)

                        // Workspaces are bounded, so prefer a non-lazy stack here.
                        // LazyVStack + drag-state invalidations can recurse through layout.
                        VStack(spacing: tabRowSpacing) {
                            ForEach(tabs, id: \.id) { tab in
                                let index = tabIndexById[tab.id] ?? 0
                                let usesSelectedContextMenuTargets = selectedTabIds.contains(tab.id)
                                let contextMenuWorkspaceIds = usesSelectedContextMenuTargets
                                    ? selectedContextTargetIds
                                    : [tab.id]
                                let remoteContextMenuWorkspaceIds = usesSelectedContextMenuTargets
                                    ? selectedRemoteContextMenuWorkspaceIds
                                    : (tab.isRemoteWorkspace ? [tab.id] : [])
                                let allRemoteContextMenuTargetsConnecting = usesSelectedContextMenuTargets
                                    ? allSelectedRemoteContextMenuTargetsConnecting
                                    : (tab.isRemoteWorkspace && tab.remoteConnectionState == .connecting)
                                let allRemoteContextMenuTargetsDisconnected = usesSelectedContextMenuTargets
                                    ? allSelectedRemoteContextMenuTargetsDisconnected
                                    : (tab.isRemoteWorkspace && tab.remoteConnectionState == .disconnected)
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
                                    draggedTabId: $draggedTabId,
                                    dropIndicator: $dropIndicator,
                                    contextMenuWorkspaceIds: contextMenuWorkspaceIds,
                                    remoteContextMenuWorkspaceIds: remoteContextMenuWorkspaceIds,
                                    allRemoteContextMenuTargetsConnecting: allRemoteContextMenuTargetsConnecting,
                                    allRemoteContextMenuTargetsDisconnected: allRemoteContextMenuTargetsDisconnected,
                                    settings: tabItemSettings
                                )
                                .equatable()
                            }
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        SidebarEmptyArea(
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
                .overlay(alignment: .top) {
                    SidebarTopScrim(height: trafficLightPadding + 20)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .top) {
                    // Match native titlebar behavior in the sidebar top strip:
                    // drag-to-move and double-click action (zoom/minimize).
                    WindowDragHandleView()
                        .frame(height: trafficLightPadding)
                        .background(TitlebarDoubleClickMonitorView())
                }
                .overlay(alignment: .topLeading) {
                    if isMinimalMode {
                        HiddenTitlebarSidebarControlsView(notificationStore: notificationStore)
                            .padding(.leading, hiddenTitlebarControlsLeadingInset)
                            .padding(.top, 2)
                    }
                }
                .background(Color.clear)
                .modifier(ClearScrollBackground())
            }
            SidebarFooter(updateViewModel: updateViewModel, onSendFeedback: onSendFeedback)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("Sidebar")
        .ignoresSafeArea()
        .background(SidebarBackdrop().ignoresSafeArea())
        .overlay(alignment: .trailing) {
            SidebarTrailingBorder()
        }
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
