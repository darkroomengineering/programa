import AppKit
import Combine

extension Notification.Name {
    /// Posted with the window as the object after the main window toolbar adds or removes items.
    static let programaMainWindowToolbarDidChange = Notification.Name("programa.mainWindowToolbarDidChange")
}

/// The main window's system toolbar: `[flexible space, (notifications, new tab), toggle,
/// tracking separator]`, with the tracking separator pinned to the sidebar split's divider so
/// the controls sit at the sidebar's trailing edge and follow divider drags.
@MainActor
final class MainWindowToolbar: NSObject, NSToolbarDelegate {
    static let groupID = NSToolbarItem.Identifier("titlebarControl.group")
    static let notificationsID = NSToolbarItem.Identifier("titlebarControl.showNotifications")
    static let newTabID = NSToolbarItem.Identifier("titlebarControl.newTab")
    static let toggleID = NSToolbarItem.Identifier("titlebarControl.toggleSidebar")
    static let trackingID = NSToolbarItem.Identifier("titlebarControl.sidebarTracking")
    private nonisolated static let identifierPrefix = "programa.main.titlebar."
    private static var associationKey: UInt8 = 0

    private weak var window: NSWindow?
    private weak var splitView: NSSplitView?
    private weak var notificationsItem: NSToolbarItem?
    private var unreadCancellable: AnyCancellable?
    private var showsUnreadImage: Bool?

    /// Toolbars that share an identifier sync item removals across windows, so every main
    /// window gets its own.
    nonisolated static func makeIdentifier() -> NSToolbar.Identifier {
        NSToolbar.Identifier(identifierPrefix + UUID().uuidString)
    }

    static func isMainWindowToolbar(_ toolbar: NSToolbar) -> Bool {
        toolbar.identifier.hasPrefix(identifierPrefix)
    }

    /// Installs the toolbar once the window's sidebar split exists. Called from the split
    /// view reaching the window and from `configureMainWindow`, whichever runs last wins.
    static func installIfNeeded(on window: NSWindow) {
        if window.toolbar?.delegate is MainWindowToolbar { return }
        guard let split = sidebarSplitView(in: window.contentView),
              let controller = split.delegate as? MainSidebarSplitViewController else { return }
        let delegate = MainWindowToolbar()
        delegate.window = window
        delegate.splitView = split
        // NSToolbar.delegate is weak.
        objc_setAssociatedObject(window, &associationKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let toolbar = NSToolbar(identifier: makeIdentifier())
        toolbar.delegate = delegate
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        if window.titleVisibility != .hidden {
            window.titleVisibility = .hidden
        }
        setSidebarCollapsed(controller.isSidebarCollapsed, in: window)
        AppDelegate.syncMainWindowToolbarVisibility(window, inFullScreen: window.styleMask.contains(.fullScreen))
    }

    /// With the sidebar collapsed the group and toggle sit right after the traffic lights.
    /// The flexible space and tracking separator are removed rather than hidden: hidden items
    /// still reserve width and push the controls into the overflow menu.
    static func setSidebarCollapsed(_ collapsed: Bool, in window: NSWindow) {
        guard let toolbar = window.toolbar, toolbar.delegate is MainWindowToolbar else { return }
        if collapsed {
            for index in toolbar.items.indices.reversed()
            where [.flexibleSpace, trackingID].contains(toolbar.items[index].itemIdentifier) {
                toolbar.removeItem(at: index)
            }
        } else {
            if toolbar.items.first?.itemIdentifier != .flexibleSpace {
                toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: 0)
            }
            if !toolbar.items.contains(where: { $0.itemIdentifier == trackingID }) {
                toolbar.insertItem(withItemIdentifier: trackingID, at: toolbar.items.count)
            }
        }
        NotificationCenter.default.post(name: .programaMainWindowToolbarDidChange, object: window)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            identifyButtons(in: window)
        }
    }

    /// Toolbar items have no accessibility identifier of their own and AppKit leaves their
    /// buttons' empty, so UI tests could not find them; tag each button with its item's id.
    private static func identifyButtons(in window: NSWindow) {
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return }
        let identifiers: [Selector: NSToolbarItem.Identifier] = [
            #selector(showNotifications(_:)): notificationsID,
            #selector(newTab(_:)): newTabID,
            #selector(toggleSidebar(_:)): toggleID,
        ]
        func visit(_ view: NSView) {
            if let button = view as? NSButton {
                if button.target is MainWindowToolbar, let action = button.action,
                   let identifier = identifiers[action], button.accessibilityIdentifier() != identifier.rawValue {
                    button.setAccessibilityIdentifier(identifier.rawValue)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(titlebarView.superview ?? titlebarView)
    }

    /// Window x of the trailing edge of the toolbar buttons while the sidebar is collapsed
    /// and they sit right after the traffic lights. Toolbar items expose no frame, so this
    /// reads the titlebar's buttons that target this delegate; nil when the sidebar is
    /// expanded or no button is laid out. Mid-animation the buttons report in-between frames.
    static func collapsedControlsTrailingEdge(in window: NSWindow) -> CGFloat? {
        guard let toolbar = window.toolbar, toolbar.isVisible, toolbar.delegate is MainWindowToolbar,
              !toolbar.items.contains(where: { $0.itemIdentifier == trackingID }),
              let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return nil }
        let container = titlebarView.superview ?? titlebarView
        container.layoutSubtreeIfNeeded()
        var trailingEdge: CGFloat?
        func visit(_ view: NSView) {
            if let button = view as? NSButton {
                if button.target is MainWindowToolbar, !button.isHiddenOrHasHiddenAncestor {
                    let maxX = button.convert(button.bounds, to: nil).maxX
                    trailingEdge = max(trailingEdge ?? maxX, maxX)
                }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(container)
        return trailingEdge
    }

    private static var cachedCollapsedTrailingEdge: CGFloat?

    /// Where the collapsed-sidebar controls end in a windowed main window. Every main window
    /// shares the traffic lights and toolbar, so the first reading is measured once in an
    /// offscreen window with the collapsed item set; a window that has not collapsed yet uses
    /// it so its first collapse does not start from a stale inset.
    static func expectedCollapsedControlsTrailingEdge() -> CGFloat? {
        if let cachedCollapsedTrailingEdge { return cachedCollapsedTrailingEdge }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let delegate = MainWindowToolbar()
        delegate.window = window
        let toolbar = NSToolbar(identifier: makeIdentifier())
        toolbar.delegate = delegate
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        for index in toolbar.items.indices.reversed()
        where [.flexibleSpace, trackingID].contains(toolbar.items[index].itemIdentifier) {
            toolbar.removeItem(at: index)
        }
        let edge = collapsedControlsTrailingEdge(in: window)
        window.toolbar = nil
        window.close()
        cachedCollapsedTrailingEdge = edge
        return edge
    }

    /// The bell of `window`'s toolbar while the toolbar is showing; the notifications
    /// popover anchors to it.
    static func notificationsItem(in window: NSWindow) -> NSToolbarItem? {
        guard let toolbar = window.toolbar, toolbar.isVisible,
              let delegate = toolbar.delegate as? MainWindowToolbar else { return nil }
        return delegate.notificationsItem
    }

    private static func sidebarSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView, split is MainSidebarSplitViewMarker { return split }
        for subview in view.subviews {
            if let found = sidebarSplitView(in: subview) { return found }
        }
        return nil
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.groupID, Self.toggleID, Self.trackingID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.trackingID:
            guard let splitView else { return nil }
            return NSTrackingSeparatorToolbarItem(identifier: itemIdentifier, splitView: splitView, dividerIndex: 0)
        case Self.groupID:
            let notifications = makeItem(
                Self.notificationsID,
                symbol: "bell",
                label: String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"),
                toolTip: KeyboardShortcutSettings.Action.showNotifications.tooltip(
                    String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")
                ),
                action: #selector(showNotifications(_:))
            )
            let newTab = makeItem(
                Self.newTabID,
                symbol: "plus",
                label: String(localized: "titlebar.newWorkspace.accessibilityLabel", defaultValue: "New Workspace"),
                toolTip: KeyboardShortcutSettings.Action.newTab.tooltip(
                    String(localized: "titlebar.newWorkspace.tooltip", defaultValue: "New workspace")
                ),
                action: #selector(newTab(_:))
            )
            let group = NSToolbarItemGroup(itemIdentifier: itemIdentifier)
            group.subitems = [notifications, newTab]
            notificationsItem = notifications
            observeUnreadNotifications()
            return group
        case Self.toggleID:
            return makeItem(
                Self.toggleID,
                symbol: "sidebar.left",
                label: String(localized: "titlebar.sidebar.accessibilityLabel", defaultValue: "Toggle Sidebar"),
                toolTip: KeyboardShortcutSettings.Action.toggleSidebar.tooltip(
                    String(localized: "titlebar.sidebar.tooltip", defaultValue: "Show or hide the sidebar")
                ),
                action: #selector(toggleSidebar(_:))
            )
        default:
            return nil
        }
    }

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        toolTip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip
        item.isBordered = true
        // Explicit target: the focused terminal lives in a portal outside the split view
        // controller's responder chain, so a nil-targeted action could miss.
        item.target = self
        item.action = action
        return item
    }

    /// Unread notifications swap the bell for a filled bell in the accent color.
    private func observeUnreadNotifications() {
        refreshNotificationsImage()
        guard unreadCancellable == nil else { return }
        // `notifications` publishes from willSet; hopping to the next main-queue turn reads
        // the unread count after the store has rebuilt its indexes.
        unreadCancellable = TerminalNotificationStore.shared.$notifications
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshNotificationsImage() }
            }
    }

    private func refreshNotificationsImage() {
        guard let item = notificationsItem else { return }
        let hasUnread = TerminalNotificationStore.shared.unreadCount > 0
        guard showsUnreadImage != hasUnread else { return }
        showsUnreadImage = hasUnread
        if hasUnread {
            let image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: item.label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [programaAccentNSColor()]))
            // Toolbar buttons tint template images with the label color.
            image?.isTemplate = false
            item.image = image
        } else {
            item.image = NSImage(systemSymbolName: "bell", accessibilityDescription: item.label)
        }
    }

    @objc private func showNotifications(_ sender: Any?) {
        AppDelegate.shared?.toggleNotificationsPopover(animated: true, window: window)
    }

    @objc private func newTab(_ sender: Any?) {
        guard let window else { return }
        AppDelegate.shared?.contextForMainTerminalWindow(window)?.tabManager.addTab()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        _ = AppDelegate.shared?.toggleSidebarForWindow(window)
    }
}
