import Foundation

/// User-facing Bonsplit strings. Bonsplit ships its own `en`/`ja` `Localizable.strings`;
/// lookups must go through `Bundle.module` because the host app's catalog does not
/// contain these keys.
enum BonsplitStrings {
    static func localized(_ key: String, defaultValue: String) -> String {
        Bundle.module.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    // MARK: - Tab context menu

    static var renameTab: String { localized("contextMenu.renameTab", defaultValue: "Rename Tab…") }
    static var removeCustomTabName: String { localized("contextMenu.removeCustomTabName", defaultValue: "Remove Custom Tab Name") }
    static var closeTabsToLeft: String { localized("contextMenu.closeTabsToLeft", defaultValue: "Close Tabs to Left") }
    static var closeTabsToRight: String { localized("contextMenu.closeTabsToRight", defaultValue: "Close Tabs to Right") }
    static var closeOtherTabs: String { localized("contextMenu.closeOtherTabs", defaultValue: "Close Other Tabs") }
    static var moveTab: String { localized("contextMenu.moveTab", defaultValue: "Move Tab…") }
    static var moveToLeftPane: String { localized("command.moveTabToLeftPane.title", defaultValue: "Move to Left Pane") }
    static var moveToRightPane: String { localized("command.moveTabToRightPane.title", defaultValue: "Move to Right Pane") }
    static var newTerminalTabToRight: String { localized("contextMenu.newTerminalTabToRight", defaultValue: "New Terminal Tab to Right") }
    static var zoomPane: String { localized("contextMenu.zoomPane", defaultValue: "Zoom Pane") }
    static var exitZoom: String { localized("contextMenu.exitZoom", defaultValue: "Exit Zoom") }
    static var pinTab: String { localized("contextMenu.pinTab", defaultValue: "Pin Tab") }
    static var unpinTab: String { localized("contextMenu.unpinTab", defaultValue: "Unpin Tab") }
    static var markTabAsRead: String { localized("contextMenu.markTabRead", defaultValue: "Mark Tab as Read") }
    static var markTabAsUnread: String { localized("contextMenu.markTabUnread", defaultValue: "Mark Tab as Unread") }
    static var tabColor: String { localized("contextMenu.tabColor", defaultValue: "Tab Color") }
    static var clearColor: String { localized("contextMenu.clearColor", defaultValue: "Clear Color") }
    static var chooseCustomColor: String { localized("contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…") }

    // MARK: - Tab accessibility

    static var tabLoading: String { localized("tab.accessibility.loading", defaultValue: "Loading") }
    static var tabPinned: String { localized("tab.accessibility.pinned", defaultValue: "Pinned") }
    static var tabUnread: String { localized("tab.accessibility.unread", defaultValue: "Unread") }
    static var tabModified: String { localized("tab.accessibility.modified", defaultValue: "Modified") }
    static var tabZoomed: String { localized("tab.accessibility.zoomed", defaultValue: "Zoomed") }
    static var exitZoomButton: String { localized("tab.zoomButton.exitZoom", defaultValue: "Exit Zoom") }

    // MARK: - Tab bar and panes

    static var newTab: String { localized("tabBar.newTab", defaultValue: "New Tab") }
    static var noOpenTabs: String { localized("emptyPane.noOpenTabs", defaultValue: "No Open Tabs") }
    static var welcomeTabTitle: String { localized("tab.placeholder.welcome", defaultValue: "Welcome") }
    static var emptyTabTitle: String { localized("tab.placeholder.empty", defaultValue: "Empty") }
}
