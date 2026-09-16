import AppKit
import Foundation

/// A native menu item exposed to a window-level pane chrome renderer.
public enum BonsplitPaneChromeMenuItem {
    case separator
    case action(title: String, action: TabContextAction, isEnabled: Bool)
}

/// Read-only tab state consumed by the native pane chrome renderer.
public struct BonsplitPaneChromeTabDescriptor {
    public let id: TabID
    public let title: String
    public let icon: String?
    public let iconImageData: Data?
    public let isSelected: Bool
    public let isPinned: Bool
    public let isDirty: Bool
    public let showsNotificationBadge: Bool
    public let accessibilityValue: String
    public let menuItems: [BonsplitPaneChromeMenuItem]

    public init(
        id: TabID,
        title: String,
        icon: String?,
        iconImageData: Data?,
        isSelected: Bool,
        isPinned: Bool,
        isDirty: Bool,
        showsNotificationBadge: Bool,
        accessibilityValue: String,
        menuItems: [BonsplitPaneChromeMenuItem]
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.iconImageData = iconImageData
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.accessibilityValue = accessibilityValue
        self.menuItems = menuItems
    }
}

/// Window-independent pane state and callbacks for a native AppKit tab strip.
public final class BonsplitPaneChromeDescriptor {
    public let paneID: PaneID
    public weak var anchorView: NSView?
    public let tabs: [BonsplitPaneChromeTabDescriptor]
    public let isFocused: Bool
    public let isVisible: Bool
    public let leadingInset: CGFloat
    public let showsSplitButtons: Bool
    public let onSelect: (TabID) -> Void
    public let onClose: (TabID) -> Void
    public let onContextAction: (TabID, TabContextAction) -> Void
    public let dragPasteboardData: (TabID) -> Data?
    public let onDragStateChanged: (TabID, Bool) -> Void
    public let validatedDropIndex: (Int) -> Int?
    public let onDropTab: (Int) -> Bool
    public let onNewTab: () -> Void
    public let onNewBrowserTab: () -> Void
    public let onSplitRight: () -> Void
    public let onSplitDown: () -> Void

    public init(
        paneID: PaneID,
        anchorView: NSView,
        tabs: [BonsplitPaneChromeTabDescriptor],
        isFocused: Bool,
        isVisible: Bool,
        leadingInset: CGFloat,
        showsSplitButtons: Bool,
        onSelect: @escaping (TabID) -> Void,
        onClose: @escaping (TabID) -> Void,
        onContextAction: @escaping (TabID, TabContextAction) -> Void,
        dragPasteboardData: @escaping (TabID) -> Data?,
        onDragStateChanged: @escaping (TabID, Bool) -> Void,
        validatedDropIndex: @escaping (Int) -> Int?,
        onDropTab: @escaping (Int) -> Bool,
        onNewTab: @escaping () -> Void,
        onNewBrowserTab: @escaping () -> Void,
        onSplitRight: @escaping () -> Void,
        onSplitDown: @escaping () -> Void
    ) {
        self.paneID = paneID
        self.anchorView = anchorView
        self.tabs = tabs
        self.isFocused = isFocused
        self.isVisible = isVisible
        self.leadingInset = leadingInset
        self.showsSplitButtons = showsSplitButtons
        self.onSelect = onSelect
        self.onClose = onClose
        self.onContextAction = onContextAction
        self.dragPasteboardData = dragPasteboardData
        self.onDragStateChanged = onDragStateChanged
        self.validatedDropIndex = validatedDropIndex
        self.onDropTab = onDropTab
        self.onNewTab = onNewTab
        self.onNewBrowserTab = onNewBrowserTab
        self.onSplitRight = onSplitRight
        self.onSplitDown = onSplitDown
    }
}

public enum BonsplitPaneChromeAnchorNotifications {
    /// Posted with the anchor NSView as object when it joins or leaves a window.
    /// The anchor's frame does not change on portal reparenting, so frame/bounds
    /// notifications alone leave window-owned chrome stuck in its pre-reparent state.
    public static let anchorDidMoveToWindow = Notification.Name("BonsplitPaneChromeAnchorDidMoveToWindow")

    /// Posted by a chrome bridge after it removes a pane's chrome. Split-tree
    /// churn can leave two anchor instances for one pane, with the dying one
    /// publishing last and then removing the survivor's registration on
    /// dismantle; live anchors respond to this by republishing themselves.
    public static let reassertRequest = Notification.Name("BonsplitPaneChromeAnchorReassertRequest")
}

/// A weak, window-owned bridge that keeps AppKit chrome outside Bonsplit's SwiftUI tree.
@MainActor
public protocol BonsplitPaneChromePortalBridge: AnyObject {
    var supportsNativePaneChrome: Bool { get }
    func updatePaneChrome(_ descriptor: BonsplitPaneChromeDescriptor)
    func removePaneChrome(for paneID: PaneID, anchorView: NSView)
}
