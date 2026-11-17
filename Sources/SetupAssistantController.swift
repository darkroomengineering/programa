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

    private static let panelSize = NSSize(width: 580, height: 500)

    private var panel: NSPanel?
    private var firstLaunchObserver: NSObjectProtocol?
    private var parentCloseObserver: NSObjectProtocol?

    /// Called for the first selected workspace while `WelcomeSettings.shownKey` is unset. That
    /// happens inside `TabManager.init`, before the window exists, so presentation waits for the
    /// first main terminal window to become main. It never activates the app.
    func presentOnFirstLaunch(in tabManager: TabManager) {
        guard panel == nil, firstLaunchObserver == nil,
              !AppDelegate.detectRunningUnderXCTest(ProcessInfo.processInfo.environment) else { return }
        if let window = tabManager.window, window.isMainWindow {
            present(attachedTo: window)
            return
        }
        firstLaunchObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                SetupAssistantController.shared.firstLaunchWindowDidBecomeMain(window)
            }
        }
    }

    /// Help menu and command palette entry point.
    func presentFromUserRequest() {
        if let panel {
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
        // there, so hand key focus to the window the assistant is attached to.
        panel?.parent?.makeKeyAndOrderFront(nil)
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
        self.panel = nil
        if let parentCloseObserver {
            NotificationCenter.default.removeObserver(parentCloseObserver)
        }
        parentCloseObserver = nil
    }

    private func firstLaunchWindowDidBecomeMain(_ window: NSWindow) {
        guard AppDelegate.shared?.isMainTerminalWindow(window) == true else { return }
        if let firstLaunchObserver {
            NotificationCenter.default.removeObserver(firstLaunchObserver)
        }
        firstLaunchObserver = nil
        guard panel == nil, !UserDefaults.standard.bool(forKey: WelcomeSettings.shownKey) else { return }
        present(attachedTo: window)
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
        panel.setFrameOrigin(Self.centeredOrigin(for: Self.panelSize, over: parent))

        self.panel = panel
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

    private static func centeredOrigin(for size: NSSize, over parent: NSWindow) -> NSPoint {
        let frame = parent.frame
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        if let visible = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return origin
    }
}
