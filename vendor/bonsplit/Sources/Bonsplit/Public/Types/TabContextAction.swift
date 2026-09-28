import Foundation
import AppKit

/// A single swatch entry for the tab-color context menu, supplied by the host app.
public struct TabColorSwatch {
    public let name: String
    public let hex: String
    public let swatchColor: NSColor

    public init(name: String, hex: String, swatchColor: NSColor) {
        self.name = name
        self.hex = hex
        self.swatchColor = swatchColor
    }
}

/// Context menu actions that can be triggered from a tab item.
public enum TabContextAction: String, CaseIterable, Sendable {
    case rename
    case clearName
    case closeToLeft
    case closeToRight
    case closeOthers
    case move
    case moveToLeftPane
    case moveToRightPane
    case newTerminalToRight
    case newBrowserToRight
    case reload
    case duplicate
    case togglePin
    case markAsRead
    case markAsUnread
    case toggleZoom
    case clearTabColor
    case chooseCustomTabColor
}
