import AppKit
import Combine
import SwiftUI

@MainActor
final class WindowToolbarController: NSObject, NSToolbarDelegate {
    private let commandItemIdentifier = NSToolbarItem.Identifier("programa.focusedCommand")

    private weak var tabManager: TabManager?

    private var commandLabels: [ObjectIdentifier: NSTextField] = [:]
    private var observers: [NSObjectProtocol] = []
    private let focusedCommandUpdateCoalescer = NotificationBurstCoalescer(delay: 1.0 / 30.0)
    private var lastKnownPresentationMode: WorkspacePresentationModeSettings.Mode = WorkspacePresentationModeSettings.mode()
    private var minimalModeMouseMonitor: Any?

    override init() {
        super.init()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = minimalModeMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start(tabManager: TabManager) {
        self.tabManager = tabManager
        attachToExistingWindows()
        installObservers()
        scheduleFocusedCommandTextUpdate()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: .ghosttyDidFocusTab,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleFocusedCommandTextUpdate()
            }
        })

        observers.append(center.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                self?.attach(to: window)
            }
        })

        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateToolbarVisibilityIfNeeded()
            }
        })
    }

    private func updateToolbarVisibilityIfNeeded() {
        let currentMode = WorkspacePresentationModeSettings.mode()
        guard currentMode != lastKnownPresentationMode else { return }
        lastKnownPresentationMode = currentMode
        let isMinimal = currentMode == .minimal
        for window in NSApp.windows {
            if isMinimal {
                window.toolbar = nil
            } else {
                attach(to: window)
            }
        }
        updateMinimalModeMouseMonitor(isMinimal: isMinimal)
        // After toolbar changes, force titlebar accessories to recalculate.
        // Toolbar removal/re-addition changes the titlebar geometry, and
        // accessories hidden via isHidden need a layout pass to reappear.
        if !isMinimal {
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    for accessory in window.titlebarAccessoryViewControllers {
                        if !accessory.isHidden {
                            accessory.view.needsLayout = true
                            accessory.view.superview?.needsLayout = true
                        }
                    }
                    window.contentView?.needsLayout = true
                    window.contentView?.superview?.needsLayout = true
                    window.invalidateShadow()
                }
            }
        }
    }

    private func attachToExistingWindows() {
        for window in NSApp.windows {
            attach(to: window)
        }
    }

    private func attach(to window: NSWindow) {
        guard window.toolbar == nil else { return }
        guard !WorkspacePresentationModeSettings.isMinimal() else { return }
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("programa.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .small
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.titleVisibility = .hidden
    }

    private func scheduleFocusedCommandTextUpdate() {
        focusedCommandUpdateCoalescer.signal { [weak self] in
            self?.updateFocusedCommandText()
        }
    }

    private func updateFocusedCommandText() {
        guard let tabManager else { return }
        let text: String
        if let selectedId = tabManager.selectedTabId,
           let tab = tabManager.tabs.first(where: { $0.id == selectedId }) {
            let title = tab.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            text = title.isEmpty ? "Cmd: —" : "Cmd: \(title)"
        } else {
            text = "Cmd: —"
        }

        for label in commandLabels.values {
            if label.stringValue != text {
                label.stringValue = text
            }
        }
    }

    // MARK: - Minimal Mode Mouse Pass-Through

    /// In minimal mode the Bonsplit tab bar occupies the native titlebar zone,
    /// but AppKit's NSTitlebarContainerView sits above the SwiftUI hosting view
    /// and consumes mouse events, making tabs non-clickable and non-hoverable (#2633).
    /// Walk the window hierarchy and make the titlebar container pass-through when
    /// minimal mode is enabled, excluding the traffic light buttons themselves.
    private func updateMinimalModeMouseMonitor(isMinimal: Bool) {
        if let monitor = minimalModeMouseMonitor {
            NSEvent.removeMonitor(monitor)
            minimalModeMouseMonitor = nil
        }

        for window in NSApp.windows {
            configureTitlebarPassThrough(window: window, passThrough: isMinimal)
        }

        // Observe new windows becoming main so we configure them too.
        guard isMinimal else { return }
        minimalModeMouseMonitor = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                guard WorkspacePresentationModeSettings.isMinimal() else { return }
                self?.configureTitlebarPassThrough(window: window, passThrough: true)
            }
        }
    }

    private func configureTitlebarPassThrough(window: NSWindow, passThrough: Bool) {
        // Find the titlebar container view by walking the theme frame's subviews.
        // This is the standard view that intercepts mouse events in the titlebar zone.
        guard let themeFrame = window.contentView?.superview else { return }
        for subview in themeFrame.subviews {
            let className = String(describing: type(of: subview))
            if className.contains("NSTitlebarContainerView") {
                // Make the container's non-button subviews transparent to hit testing
                // by installing/removing a pass-through overlay.
                if passThrough {
                    installTitlebarPassThrough(on: subview, window: window)
                } else {
                    removeTitlebarPassThrough(from: subview)
                }
                break
            }
        }
    }

    private func installTitlebarPassThrough(on titlebarContainer: NSView, window: NSWindow) {
        // Already installed?
        guard !titlebarContainer.subviews.contains(where: { $0 is TitlebarHitTestPassThroughView }) else { return }
        let passView = TitlebarHitTestPassThroughView(window: window)
        passView.frame = titlebarContainer.bounds
        passView.autoresizingMask = [.width, .height]
        titlebarContainer.addSubview(passView, positioned: .above, relativeTo: nil)
    }

    private func removeTitlebarPassThrough(from titlebarContainer: NSView) {
        titlebarContainer.subviews
            .compactMap { $0 as? TitlebarHitTestPassThroughView }
            .forEach { $0.removeFromSuperview() }
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [commandItemIdentifier, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == commandItemIdentifier {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let label = NSTextField(labelWithString: "Cmd: —")
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            item.view = label
            commandLabels[ObjectIdentifier(toolbar)] = label
            scheduleFocusedCommandTextUpdate()
            return item
        }


        return nil
    }

}

/// Transparent overlay installed above the NSTitlebarContainerView in minimal mode.
/// Returns `nil` from `hitTest` for all points except the traffic light buttons,
/// allowing clicks to fall through to the SwiftUI-hosted Bonsplit tab bar beneath.
private final class TitlebarHitTestPassThroughView: NSView {
    private weak var targetWindow: NSWindow?

    init(window: NSWindow) {
        self.targetWindow = window
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let traffic light buttons receive their events normally.
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttonTypes {
            guard let button = targetWindow?.standardWindowButton(type) else { continue }
            let pointInButton = button.convert(point, from: self)
            if button.bounds.contains(pointInButton) {
                return button
            }
        }
        // Pass through everything else so the SwiftUI tab bar can receive events.
        return nil
    }
}
