import AppKit
import SwiftUI

/// Owns the setup assistant: a non-modal panel attached as a child of a main terminal window.
/// It is a child window rather than a sheet because the agent installers it opens run in a
/// workspace of that window and wait for a confirmation typed into the terminal, which a
/// window-modal sheet would block.
@MainActor
final class SetupAssistantController: NSObject, NSWindowDelegate {
    static let shared = SetupAssistantController()
    static let windowIdentifier = NSUserInterfaceItemIdentifier("programa.setupAssistant")

    static let panelSize = NSSize(width: 580, height: 500)

    private var panel: NSPanel?
    private var firstLaunchObservers: [NSObjectProtocol] = []
    private weak var firstLaunchTabManager: TabManager?
    private var parentCloseObserver: NSObjectProtocol?
    /// The terminal window the panel belongs to, kept while the panel is detached for an installer.
    private weak var owner: NSWindow?

    /// Called for the first selected workspace while `WelcomeSettings.shownKey` is unset. That
    /// happens inside `TabManager.init`, before its window is registered, so presentation waits
    /// until the window holds a ready terminal (the old `programa welcome` timing) or becomes
    /// main. It never activates the app.
    func presentOnFirstLaunch(in tabManager: TabManager) {
        guard panel == nil, firstLaunchObservers.isEmpty,
              !AppDelegate.detectRunningUnderXCTest(ProcessInfo.processInfo.environment) else { return }
        firstLaunchTabManager = tabManager
        let center = NotificationCenter.default
        for name in [Notification.Name.terminalSurfaceDidBecomeReady, NSWindow.didBecomeMainNotification] {
            firstLaunchObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SetupAssistantController.shared.presentForFirstLaunchIfReady() }
            })
        }
    }

    private func presentForFirstLaunchIfReady() {
        guard let tabManager = firstLaunchTabManager else {
            stopWaitingForFirstLaunch()
            return
        }
        guard let window = tabManager.window, window.isVisible else { return }
        stopWaitingForFirstLaunch()
        guard panel == nil, !UserDefaults.standard.bool(forKey: WelcomeSettings.shownKey) else { return }
        present(attachedTo: window)
    }

    private func stopWaitingForFirstLaunch() {
        for observer in firstLaunchObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        firstLaunchObservers = []
        firstLaunchTabManager = nil
    }

    /// Help menu and command palette entry point.
    func presentFromUserRequest() {
        if let panel {
            reattach(panel)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let candidates = [NSApp.keyWindow, NSApp.mainWindow, AppDelegate.shared?.tabManager?.window]
        guard let appDelegate = AppDelegate.shared,
              let window = candidates.compactMap({ $0 }).first(where: { appDelegate.isMainTerminalWindow($0) }) else {
            NSSound.beep()
            return
        }
        present(attachedTo: window)
    }

    func installIntegration(for agent: AgentIntegrationStatusStore.Agent) {
        // The installer workspace opens in the key terminal window and asks for confirmation
        // there. A child panel always stays above its parent and is larger than a default
        // terminal window, so detach it and bring the terminal in front of it. Clicking the
        // panel or rerunning setup reattaches it.
        if let panel, let parent = panel.parent {
            parent.removeChildWindow(panel)
            parent.makeKeyAndOrderFront(nil)
        }
        let source = "setupAssistant"
        switch agent {
        case .claude: AppDelegate.shared?.openClaudeIntegrationInstaller(debugSource: source)
        case .codex: AppDelegate.shared?.openCodexIntegrationInstaller(debugSource: source)
        case .openCode: AppDelegate.shared?.openOpenCodeIntegrationInstaller(debugSource: source)
        }
    }

    func dismiss() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        UserDefaults.standard.set(true, forKey: WelcomeSettings.shownKey)
        panel.parent?.removeChildWindow(panel)
        panel.delegate = nil
        owner = nil
        self.panel = nil
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
        }
        parentCloseObserver = nil
    }

    private func present(attachedTo parent: NSWindow) {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = Self.windowIdentifier
        panel.title = String(localized: "setupAssistant.windowTitle", defaultValue: "Set Up Programa")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        let hostingView = NSHostingView(rootView: SetupAssistantView())
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
        panel.setFrameOrigin(Self.bottomTrailingOrigin(for: panel.frame.size, over: parent))

        self.panel = panel
        owner = parent
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: parent,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { SetupAssistantController.shared.dismiss() }
        }
        parent.addChildWindow(panel, ordered: .above)
        if NSApp.isActive {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let panel, notification.object as? NSPanel === panel else { return }
        reattach(panel)
    }

    private func reattach(_ panel: NSPanel) {
        guard panel.parent == nil, let owner else { return }
        owner.addChildWindow(panel, ordered: .above)
    }

    /// Installers prompt (y/N) at the top-left of a fresh terminal in the parent window, so the
    /// panel sits in the opposite corner to keep that prompt visible.
    private static func bottomTrailingOrigin(for size: NSSize, over parent: NSWindow) -> NSPoint {
        let frame = parent.frame
        let inset: CGFloat = 24
        var origin = NSPoint(x: frame.maxX - size.width - inset, y: frame.minY + inset)
        if let visible = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return origin
    }
}
