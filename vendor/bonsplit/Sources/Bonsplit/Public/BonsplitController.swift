import Foundation
import SwiftUI

@MainActor
@Observable
public final class BonsplitController {

    public struct ExternalTabDropRequest {
        public enum Destination {
            case insert(targetPane: PaneID, targetIndex: Int?)
            case split(targetPane: PaneID, orientation: SplitOrientation, insertFirst: Bool)
        }

        public let tabId: TabID
        public let sourcePaneId: PaneID
        public let destination: Destination

        public init(tabId: TabID, sourcePaneId: PaneID, destination: Destination) {
            self.tabId = tabId
            self.sourcePaneId = sourcePaneId
            self.destination = destination
        }
    }

    public weak var delegate: BonsplitDelegate?

    public var configuration: BonsplitConfiguration

    /// When false, drop delegates reject all drags. Set to false for inactive workspaces
    /// so their views (kept alive in a ZStack for state preservation) don't intercept drags
    /// meant for the active workspace.
    @ObservationIgnored public var isInteractive: Bool = true {
        didSet { internalController.isInteractive = isInteractive }
    }

    /// Handler for file/URL drops from external apps (e.g., Finder).
    /// Called when files are dropped onto a pane's content area.
    /// Return `true` if the drop was handled.
    @ObservationIgnored public var onFileDrop: ((_ urls: [URL], _ paneId: PaneID) -> Bool)? {
        didSet { internalController.onFileDrop = onFileDrop }
    }

    /// Handler for tab drops originating from another Bonsplit controller (e.g. another workspace/window).
    /// Return `true` when the drop has been handled by the host application.
    @ObservationIgnored public var onExternalTabDrop: ((ExternalTabDropRequest) -> Bool)?

    /// Called when the user explicitly requests to close a tab from the tab strip UI.
    /// Internal host-driven closes should not use this hook.
    @ObservationIgnored public var onTabCloseRequest: ((_ tabId: TabID, _ paneId: PaneID) -> Void)?

    /// Window-owned renderer for native pane chrome. Weak to avoid retaining an NSWindow
    /// through a controller that can outlive its current view hierarchy.
    @ObservationIgnored public private(set) weak var paneChromePortalBridge: (any BonsplitPaneChromePortalBridge)?
    public private(set) var paneChromePortalRevision = 0

    public func setPaneChromePortalBridge(_ bridge: (any BonsplitPaneChromePortalBridge)?) {
        guard paneChromePortalBridge !== bridge else { return }
        paneChromePortalBridge = bridge
        paneChromePortalRevision &+= 1
    }

    /// Forces the pane chrome anchors to re-mount and republish. Split-tree
    /// restructures (pane collapse) can dismantle a surviving pane's anchor with
    /// no replacement ever mounting; bumping the revision re-evaluates the
    /// native-chrome branch and recreates the anchor.
    public func republishPaneChrome() {
        paneChromePortalRevision &+= 1
    }

    internal var internalController: SplitViewController

    public init(configuration: BonsplitConfiguration = .default) {
        self.configuration = configuration
        self.internalController = SplitViewController()
    }

    // MARK: - Tab Operations

    /// Create a new tab in the focused pane (or specified pane)
    /// - Parameters:
    ///   - title: The tab title
    ///   - icon: Optional SF Symbol name for the tab icon
    ///   - iconImageData: Optional image data (PNG recommended) for the tab icon. When present, takes precedence over `icon`.
    ///   - iconAsset: Optional asset-catalog image name (host main bundle). Takes precedence over `icon`, below `iconImageData`.
    ///   - kind: Consumer-defined tab kind identifier (e.g. "terminal", "markdown")
    ///   - hasCustomTitle: Whether the tab title came from a custom user override
    ///   - isDirty: Whether the tab shows a dirty indicator
    ///   - showsNotificationBadge: Whether the tab shows an "unread/activity" badge
    ///   - isLoading: Whether the tab shows an activity/loading indicator (e.g. spinning icon)
    ///   - isPinned: Whether the tab should be treated as pinned
    ///   - pane: Optional pane to add the tab to (defaults to focused pane)
    /// - Returns: The TabID of the created tab, or nil if creation was vetoed by delegate
    @discardableResult
    public func createTab(
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        iconAsset: String? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        customColorHex: String? = nil,
        inPane pane: PaneID? = nil
    ) -> TabID? {
        let tabId = TabID()
        let tab = Tab(
            id: tabId,
            title: title,
            hasCustomTitle: hasCustomTitle,
            icon: icon,
            iconImageData: iconImageData,
            iconAsset: iconAsset,
            kind: kind,
            isDirty: isDirty,
            showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading,
            isPinned: isPinned,
            customColorHex: customColorHex
        )
        let targetPane = pane ?? focusedPaneId ?? internalController.rootNode.allPaneIds.first!

        if delegate?.splitTabBar(self, shouldCreateTab: tab, inPane: targetPane) == false {
            return nil
        }

        // Insert after the currently selected tab, or append when nothing is selected.
        let insertIndex: Int?
        if let paneState = internalController.rootNode.findPane(targetPane),
           let selectedTabId = paneState.selectedTabId,
           let currentIndex = paneState.tabs.firstIndex(where: { $0.id == selectedTabId }) {
            insertIndex = currentIndex + 1
        } else {
            insertIndex = nil
        }

        internalController.addTab(TabItem(from: tab), toPane: targetPane, atIndex: insertIndex)

        return tabId
    }

    /// Request the delegate to create a new tab of the given kind in a pane.
    /// The delegate is responsible for the actual creation logic.
    public func requestNewTab(kind: String, inPane pane: PaneID) {
        delegate?.splitTabBar(self, didRequestNewTab: kind, inPane: pane)
    }

    /// Request the delegate to handle a tab context-menu action.
    public func requestTabContextAction(_ action: TabContextAction, for tabId: TabID, inPane pane: PaneID) {
        guard let tab = tab(tabId) else { return }
        delegate?.splitTabBar(self, didRequestTabContextAction: action, for: tab, inPane: pane)
    }

    /// Request the delegate to apply a palette color to a tab.
    public func requestTabColor(_ hex: String, for tabId: TabID, inPane pane: PaneID) {
        guard let tab = tab(tabId) else { return }
        delegate?.splitTabBar(self, didRequestTabColor: hex, for: tab, inPane: pane)
    }

    /// Update an existing tab's metadata
    /// - Parameters:
    ///   - tabId: The tab to update
    ///   - title: New title (pass nil to keep current)
    ///   - icon: New icon (pass nil to keep current, pass .some(nil) to remove icon)
    ///   - iconImageData: New icon image data (pass nil to keep current, pass .some(nil) to remove)
    ///   - iconAsset: New asset-catalog image name (pass nil to keep current, pass .some(nil) to remove)
    ///   - kind: New tab kind (pass nil to keep current, pass .some(nil) to clear)
    ///   - hasCustomTitle: New custom-title state (pass nil to keep current)
    ///   - isDirty: New dirty state (pass nil to keep current)
    ///   - showsNotificationBadge: New badge state (pass nil to keep current)
    ///   - isLoading: New loading/busy state (pass nil to keep current)
    ///   - isPinned: New pinned state (pass nil to keep current)
    public func updateTab(
        _ tabId: TabID,
        title: String? = nil,
        icon: String?? = nil,
        iconImageData: Data?? = nil,
        iconAsset: String?? = nil,
        kind: String?? = nil,
        hasCustomTitle: Bool? = nil,
        isDirty: Bool? = nil,
        showsNotificationBadge: Bool? = nil,
        isLoading: Bool? = nil,
        isPinned: Bool? = nil,
        customColorHex: String?? = nil
    ) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        if let title = title {
            pane.tabs[tabIndex].title = title
        }
        if let icon = icon {
            pane.tabs[tabIndex].icon = icon
        }
        if let iconImageData = iconImageData {
            pane.tabs[tabIndex].iconImageData = iconImageData
        }
        if let iconAsset = iconAsset {
            pane.tabs[tabIndex].iconAsset = iconAsset
        }
        if let kind = kind {
            pane.tabs[tabIndex].kind = kind
        }
        if let hasCustomTitle = hasCustomTitle {
            pane.tabs[tabIndex].hasCustomTitle = hasCustomTitle
        }
        if let isDirty = isDirty {
            pane.tabs[tabIndex].isDirty = isDirty
        }
        if let showsNotificationBadge = showsNotificationBadge {
            pane.tabs[tabIndex].showsNotificationBadge = showsNotificationBadge
        }
        if let isLoading = isLoading {
            pane.tabs[tabIndex].isLoading = isLoading
        }
        if let isPinned = isPinned {
            pane.tabs[tabIndex].isPinned = isPinned
        }
        if let customColorHex = customColorHex {
            pane.tabs[tabIndex].customColorHex = customColorHex
        }
    }

    /// Close a tab by ID
    /// - Parameter tabId: The tab to close
    /// - Returns: true if the tab was closed, false if vetoed by delegate
    @discardableResult
    public func closeTab(_ tabId: TabID) -> Bool {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return false }
        return closeTab(tabId, with: tabIndex, in: pane)
    }
    
    /// Close a tab by ID in a specific pane.
    /// - Parameter tabId: The tab to close
    /// - Parameter paneId: The pane in which to close the tab
    public func closeTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool {
        guard let pane = internalController.rootNode.findPane(paneId),
              let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) else {
            return false
        }
        
        return closeTab(tabId, with: tabIndex, in: pane)
    }
    
    private func closeTab(_ tabId: TabID, with tabIndex: Int, in pane: PaneState) -> Bool {
        let tabItem = pane.tabs[tabIndex]
        let tab = Tab(from: tabItem)
        let paneId = pane.id

        if delegate?.splitTabBar(self, shouldCloseTab: tab, inPane: paneId) == false {
            return false
        }

        internalController.closeTab(tabId.id, inPane: pane.id)

        delegate?.splitTabBar(self, didCloseTab: tabId, fromPane: paneId)
        notifyGeometryChange()

        return true
    }

    /// Select a tab by ID
    /// - Parameter tabId: The tab to select
    public func selectTab(_ tabId: TabID) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        pane.selectTab(tabId.id)
        internalController.focusPane(pane.id)

        let tab = Tab(from: pane.tabs[tabIndex])
        delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
    }

    /// Move a tab to a specific pane (and optional index) inside this controller.
    /// - Parameters:
    ///   - tabId: The tab to move.
    ///   - targetPaneId: Destination pane.
    ///   - index: Optional destination index. When nil, appends at the end.
    /// - Returns: true if moved.
    @discardableResult
    public func moveTab(_ tabId: TabID, toPane targetPaneId: PaneID, atIndex index: Int? = nil) -> Bool {
        guard let (sourcePane, sourceIndex) = findTabInternal(tabId) else { return false }
        guard let targetPane = internalController.rootNode.findPane(targetPaneId) else { return false }

        let tabItem = sourcePane.tabs[sourceIndex]
        let movedTab = Tab(from: tabItem)
        let sourcePaneId = sourcePane.id

        if sourcePaneId == targetPane.id {
            // Reorder within same pane.
            let destinationIndex: Int = {
                if let index { return max(0, min(index, sourcePane.tabs.count)) }
                return sourcePane.tabs.count
            }()
            sourcePane.moveTab(from: sourceIndex, to: destinationIndex)
            sourcePane.selectTab(tabItem.id)
            internalController.focusPane(sourcePane.id)
            delegate?.splitTabBar(self, didSelectTab: movedTab, inPane: sourcePane.id)
            notifyGeometryChange()
            return true
        }

        internalController.moveTab(tabItem, from: sourcePaneId, to: targetPane.id, atIndex: index)
        delegate?.splitTabBar(self, didMoveTab: movedTab, fromPane: sourcePaneId, toPane: targetPane.id)
        notifyGeometryChange()
        return true
    }

    /// Reorder a tab within its pane.
    /// - Parameters:
    ///   - tabId: The tab to reorder.
    ///   - toIndex: Destination index.
    /// - Returns: true if reordered.
    @discardableResult
    public func reorderTab(_ tabId: TabID, toIndex: Int, selectMovedTab: Bool = true) -> Bool {
        guard let (pane, sourceIndex) = findTabInternal(tabId) else { return false }
        let destinationIndex = max(0, min(toIndex, pane.tabs.count))
        pane.moveTab(from: sourceIndex, to: destinationIndex)
        guard selectMovedTab else {
            notifyGeometryChange()
            return true
        }
        pane.selectTab(tabId.id)
        internalController.focusPane(pane.id)
        if let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
            let tab = Tab(from: pane.tabs[tabIndex])
            delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
        }
        notifyGeometryChange()
        return true
    }

    public func selectPreviousTab() {
        internalController.selectPreviousTab()
        notifyTabSelection()
    }

    public func selectNextTab() {
        internalController.selectNextTab()
        notifyTabSelection()
    }

    // MARK: - Split Operations

    /// Split the focused pane (or specified pane)
    /// - Parameters:
    ///   - paneId: Optional pane to split (defaults to focused pane)
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked)
    ///   - tab: Optional tab to add to the new pane
    /// - Returns: The new pane ID, or nil if vetoed by delegate
    @discardableResult
    public func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTab tab: Tab? = nil
    ) -> PaneID? {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        internalController.splitPane(targetPaneId, orientation: orientation, with: tab.map(TabItem.init(from:)))

        // The split focuses the new pane.
        let newPaneId = focusedPaneId!

        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Split a pane and place a specific tab in the newly created pane, choosing which side to insert on.
    ///
    /// This is like `splitPane(_:orientation:withTab:)`, but allows choosing left/top vs right/bottom insertion
    /// without needing to create then move a tab.
    ///
    /// - Parameters:
    ///   - paneId: Optional pane to split (defaults to focused pane).
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked).
    ///   - tab: The tab to add to the new pane.
    ///   - insertFirst: If true, insert the new pane first (left/top). Otherwise insert second (right/bottom).
    /// - Returns: The new pane ID, or nil if vetoed by delegate.
    @discardableResult
    public func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTab tab: Tab,
        insertFirst: Bool
    ) -> PaneID? {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        internalController.splitPane(
            targetPaneId,
            orientation: orientation,
            with: TabItem(from: tab),
            insertFirst: insertFirst
        )

        let newPaneId = focusedPaneId!

        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Split a pane by moving an existing tab into the new pane.
    ///
    /// This mirrors the "drag a tab to a pane edge to create a split" interaction:
    /// the tab is removed from its source pane first, then inserted into the newly
    /// created pane on the chosen edge.
    ///
    /// - Parameters:
    ///   - paneId: Optional target pane to split (defaults to the tab's current pane).
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked).
    ///   - tabId: The existing tab to move into the new pane.
    ///   - insertFirst: If true, the new pane is inserted first (left/top). Otherwise it is inserted second (right/bottom).
    /// - Returns: The new pane ID, or nil if the tab couldn't be found or the split was vetoed.
    @discardableResult
    public func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool
    ) -> PaneID? {
        guard let (sourcePane, tabIndex) = findTabInternal(tabId) else { return nil }
        let tabItem = sourcePane.tabs[tabIndex]

        // Default target to the tab's current pane to match edge-drop behavior on the source pane.
        let targetPaneId = paneId ?? sourcePane.id

        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        sourcePane.removeTab(tabItem.id)

        if sourcePane.tabs.isEmpty {
            if sourcePane.id == targetPaneId {
                // Keep a placeholder tab so the original pane isn't left "tabless".
                // This makes the empty side closable via tab close, and avoids apps
                // needing to special-case empty panes.
                sourcePane.addTab(TabItem(title: BonsplitStrings.emptyTabTitle, icon: nil), select: true)
            } else if internalController.rootNode.allPaneIds.count > 1 {
                internalController.closePane(sourcePane.id)
            }
        }

        internalController.splitPane(
            targetPaneId,
            orientation: orientation,
            with: tabItem,
            insertFirst: insertFirst
        )

        let newPaneId = focusedPaneId!

        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Close a specific pane
    /// - Parameter paneId: The pane to close
    /// - Returns: true if the pane was closed, false if vetoed by delegate
    @discardableResult
    public func closePane(_ paneId: PaneID) -> Bool {
        // The last pane never closes.
        if internalController.rootNode.allPaneIds.count <= 1 {
            return false
        }

        if delegate?.splitTabBar(self, shouldClosePane: paneId) == false {
            return false
        }

        internalController.closePane(paneId)

        delegate?.splitTabBar(self, didClosePane: paneId)

        notifyGeometryChange()

        return true
    }

    // MARK: - Focus Management

    public var focusedPaneId: PaneID? {
        internalController.focusedPaneId
    }

    public func focusPane(_ paneId: PaneID) {
        internalController.focusPane(paneId)
        delegate?.splitTabBar(self, didFocusPane: paneId)
    }

    public func navigateFocus(direction: NavigationDirection) {
        internalController.navigateFocus(direction: direction)
        if let focusedPaneId {
            delegate?.splitTabBar(self, didFocusPane: focusedPaneId)
        }
    }

    /// Find the closest pane in the requested direction from the given pane.
    public func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        internalController.adjacentPane(to: paneId, direction: direction)
    }

    // MARK: - Split Zoom

    public var zoomedPaneId: PaneID? {
        internalController.zoomedPaneId
    }

    public var isSplitZoomed: Bool {
        internalController.zoomedPaneId != nil
    }

    @discardableResult
    public func clearPaneZoom() -> Bool {
        internalController.clearPaneZoom()
    }

    /// Toggle zoom for a pane. When zoomed, only that pane is rendered in the split area.
    /// Passing nil toggles the currently focused pane.
    @discardableResult
    public func togglePaneZoom(inPane paneId: PaneID? = nil) -> Bool {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return false }
        return internalController.togglePaneZoom(targetPaneId)
    }

    // MARK: - Context Menu Shortcut Hints

    /// Keyboard shortcuts to display in tab context menus, keyed by context action.
    /// Set by the host app to sync with its customizable keyboard shortcut settings.
    public var contextMenuShortcuts: [TabContextAction: KeyboardShortcut] = [:]

    // MARK: - Tab Color Palette

    /// Host-provided palette entries for the tab-color context menu. Resolved at menu-build
    /// time (not cached) so it always reflects the host's current colors and appearance.
    @ObservationIgnored public var tabColorPaletteProvider: (() -> [TabColorSwatch])?

    // MARK: - Query Methods

    public var allTabIds: [TabID] {
        internalController.rootNode.allPanes.flatMap { pane in
            pane.tabs.map { TabID(id: $0.id) }
        }
    }

    public var allPaneIds: [PaneID] {
        internalController.rootNode.allPaneIds
    }

    public func tab(_ tabId: TabID) -> Tab? {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return nil }
        return Tab(from: pane.tabs[tabIndex])
    }

    public func tabs(inPane paneId: PaneID) -> [Tab] {
        guard let pane = internalController.rootNode.findPane(paneId) else {
            return []
        }
        return pane.tabs.map { Tab(from: $0) }
    }

    public func selectedTab(inPane paneId: PaneID) -> Tab? {
        guard let pane = internalController.rootNode.findPane(paneId),
              let selected = pane.selectedTab else {
            return nil
        }
        return Tab(from: selected)
    }

    // MARK: - Geometry Query API

    /// Pane geometry in the container's global pixel coordinates.
    public func layoutSnapshot() -> LayoutSnapshot {
        let containerFrame = internalController.containerFrame
        let paneBounds = internalController.rootNode.computePaneBounds()

        let paneGeometries = paneBounds.map { bounds -> PaneGeometry in
            let pane = internalController.rootNode.findPane(bounds.paneId)
            return PaneGeometry(
                paneId: bounds.paneId.id.uuidString,
                frame: Self.pixelRect(for: bounds.bounds, in: containerFrame),
                selectedTabId: pane?.selectedTabId?.uuidString,
                tabIds: pane?.tabs.map { $0.id.uuidString } ?? []
            )
        }

        return LayoutSnapshot(
            containerFrame: PixelRect(from: containerFrame),
            panes: paneGeometries,
            focusedPaneId: focusedPaneId?.id.uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }

    public func treeSnapshot() -> ExternalTreeNode {
        let containerFrame = internalController.containerFrame
        return buildExternalTree(from: internalController.rootNode, containerFrame: containerFrame)
    }

    private static func pixelRect(for normalized: CGRect, in containerFrame: CGRect) -> PixelRect {
        PixelRect(
            x: Double(normalized.minX * containerFrame.width + containerFrame.origin.x),
            y: Double(normalized.minY * containerFrame.height + containerFrame.origin.y),
            width: Double(normalized.width * containerFrame.width),
            height: Double(normalized.height * containerFrame.height)
        )
    }

    private func buildExternalTree(from node: SplitNode, containerFrame: CGRect, bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> ExternalTreeNode {
        switch node {
        case .pane(let paneState):
            let tabs = paneState.tabs.map { ExternalTab(id: $0.id.uuidString, title: $0.title) }
            let paneNode = ExternalPaneNode(
                id: paneState.id.id.uuidString,
                frame: Self.pixelRect(for: bounds, in: containerFrame),
                tabs: tabs,
                selectedTabId: paneState.selectedTabId?.uuidString
            )
            return .pane(paneNode)

        case .split(let splitState):
            let childBounds = splitState.childBounds(in: bounds)
            let splitNode = ExternalSplitNode(
                id: splitState.id.uuidString,
                orientation: splitState.orientation.rawValue,
                dividerPosition: Double(splitState.dividerPosition),
                first: buildExternalTree(from: splitState.first, containerFrame: containerFrame, bounds: childBounds.first),
                second: buildExternalTree(from: splitState.second, containerFrame: containerFrame, bounds: childBounds.second)
            )
            return .split(splitNode)
        }
    }

    // MARK: - Geometry Update API

    /// Set divider position for a split node (0.0-1.0)
    /// - Parameters:
    ///   - position: The new divider position (clamped to 0.1-0.9)
    ///   - splitId: The UUID of the split to update
    ///   - fromExternal: Set to true to suppress outgoing notifications (prevents loops)
    /// - Returns: true if the split was found and updated
    @discardableResult
    public func setDividerPosition(_ position: CGFloat, forSplit splitId: UUID, fromExternal: Bool = false) -> Bool {
        guard let split = internalController.findSplit(splitId) else { return false }

        if fromExternal {
            internalController.isExternalUpdateInProgress = true
        }

        let clampedPosition = min(max(position, 0.1), 0.9)
        split.dividerPosition = clampedPosition

        if fromExternal {
            // Use a slight delay to allow the UI to update before re-enabling notifications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.internalController.isExternalUpdateInProgress = false
            }
        }

        return true
    }

    internal func notifyGeometryChange() {
        guard !internalController.isExternalUpdateInProgress else { return }
        delegate?.splitTabBar(self, didChangeGeometry: layoutSnapshot())
    }

    private func findTabInternal(_ tabId: TabID) -> (PaneState, Int)? {
        for pane in internalController.rootNode.allPanes {
            if let index = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
                return (pane, index)
            }
        }
        return nil
    }

    private func notifyTabSelection() {
        guard let pane = internalController.focusedPane,
              let tabItem = pane.selectedTab else { return }
        let tab = Tab(from: tabItem)
        delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
    }
}
