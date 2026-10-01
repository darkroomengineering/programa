import AppKit

/// Strong owner for a main window created by `AppDelegate.createMainWindow`.
/// User-initiated close confirmation lives in the close-button proxy
/// (`NSWindow.programa_mainWindowCloseButtonPressed`, WindowSwizzles.swift) so it also
/// covers the SwiftUI launch window, whose delegate SwiftUI owns.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
