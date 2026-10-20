import AppKit
import Bonsplit

extension AppDelegate {
    final class MainWindowContext {
        let windowId: UUID
        let tabManager: TabManager
        let sidebarState: SidebarState
        let sidebarSelectionState: SidebarSelectionState
        weak var window: NSWindow?
        weak var observedWindow: NSWindow?
        var willCloseObserver: NSObjectProtocol?
        var willCloseObserverGeneration: UUID?

        init(
            windowId: UUID,
            tabManager: TabManager,
            sidebarState: SidebarState,
            sidebarSelectionState: SidebarSelectionState,
            window: NSWindow?
        ) {
            self.windowId = windowId
            self.tabManager = tabManager
            self.sidebarState = sidebarState
            self.sidebarSelectionState = sidebarSelectionState
            self.window = window
        }
    }

    private func notifyMainWindowContextsDidChange() {
        NotificationCenter.default.post(name: .mainWindowContextsDidChange, object: self)
    }

    private func removeMainWindowCloseObserver(from context: MainWindowContext) {
        if let observer = context.willCloseObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        context.willCloseObserver = nil
        context.willCloseObserverGeneration = nil
        context.observedWindow = nil
    }

    private func installMainWindowCloseObserver(
        for context: MainWindowContext,
        window: NSWindow
    ) {
        if context.observedWindow === window, context.willCloseObserver != nil {
            return
        }

        removeMainWindowCloseObserver(from: context)
        let generation = UUID()
        context.observedWindow = window
        context.willCloseObserverGeneration = generation
        context.willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window, generation] note in
            MainActor.assumeIsolated {
                guard let self,
                      let window,
                      let closing = note.object as? NSWindow,
                      closing === window,
                      let context = self.mainWindowContexts[ObjectIdentifier(window)],
                      context.willCloseObserverGeneration == generation,
                      context.observedWindow === window,
                      context.window === window else {
                    return
                }
                self.unregisterMainWindow(window)
            }
        }
    }

    /// Register a terminal window with the AppDelegate so menu commands and socket control
    /// can target whichever window is currently active.
    func registerMainWindow(
        _ window: NSWindow,
        windowId: UUID,
        tabManager: TabManager,
        sidebarState: SidebarState,
        sidebarSelectionState: SidebarSelectionState
    ) {
        // A window can be deallocated without ever going through the normal
        // close/NSWindow.willCloseNotification teardown path (e.g. released directly
        // by its owner). That leaves its MainWindowContext behind indefinitely, since
        // nothing else proactively sweeps for dead-window contexts. Registering a new
        // main window is a natural, frequent checkpoint to clean those up so they don't
        // linger and skew context-selection/fallback logic for the lifetime of the app.
        discardOrphanedMainWindowContexts()

        tabManager.window = window
        window.programaInstallMainWindowCloseConfirmation()

        let key = ObjectIdentifier(window)
        #if DEBUG
        let priorManagerToken = debugManagerToken(self.tabManager)
        #endif
        let context: MainWindowContext
        if let existing = mainWindowContexts[key], existing.windowId == windowId {
            existing.window = window
            context = existing
        } else if let existing = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            reindexMainWindowContextIfNeeded(existing, for: window)
            context = existing
        } else {
            if let displaced = mainWindowContexts[key] {
                discardOrphanedMainWindowContext(displaced)
            }
            let newContext = MainWindowContext(
                windowId: windowId,
                tabManager: tabManager,
                sidebarState: sidebarState,
                sidebarSelectionState: sidebarSelectionState,
                window: window
            )
            mainWindowContexts[key] = newContext
            context = newContext
        }
        didRegisterAnyMainWindow = true
        installMainWindowCloseObserver(for: context, window: window)
        CommandPaletteController.windowLifecycle.reset(windowId: windowId)

#if DEBUG
        dlog(
            "mainWindow.register windowId=\(String(windowId.uuidString.prefix(8))) window={\(debugWindowToken(window))} manager=\(debugManagerToken(tabManager)) priorActiveMgr=\(priorManagerToken) \(debugShortcutRouteSnapshot())"
        )
#endif
        notifyMainWindowContextsDidChange()
        if window.isKeyWindow {
            setActiveMainWindow(window)
        }

        attemptStartupSessionRestoreIfNeeded(primaryWindow: window)
        if !isTerminatingApp {
            saveSessionSnapshot(includeScrollback: false)
        }
    }

    func windowForMainWindowId(_ windowId: UUID) -> NSWindow? {
        if let ctx = mainWindowContexts.values.first(where: { $0.windowId == windowId }),
           let window = ctx.window {
            return window
        }
        let expectedIdentifier = "programa.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
    }

    func resolvedWindow(for context: MainWindowContext) -> NSWindow? {
        if let window = context.window {
            return window
        }
        guard let window = windowForMainWindowId(context.windowId) else {
            return nil
        }
        reindexMainWindowContextIfNeeded(context, for: window)
        return window
    }

    func mainWindowId(from window: NSWindow) -> UUID? {
        guard let raw = window.identifier?.rawValue else { return nil }
        let prefix = "programa.main."
        guard raw.hasPrefix(prefix) else { return nil }
        let suffix = String(raw.dropFirst(prefix.count))
        return UUID(uuidString: suffix)
    }

    private func reindexMainWindowContextIfNeeded(_ context: MainWindowContext, for window: NSWindow) {
        let desiredKey = ObjectIdentifier(window)
        if mainWindowContexts[desiredKey] === context {
            context.window = window
            installMainWindowCloseObserver(for: context, window: window)
            return
        }

        if let displaced = mainWindowContexts[desiredKey], displaced !== context {
            discardOrphanedMainWindowContext(displaced)
        }

        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }

        mainWindowContexts[desiredKey] = context
        context.window = window
        installMainWindowCloseObserver(for: context, window: window)
        notifyMainWindowContextsDidChange()
    }

    func contextForMainTerminalWindow(_ window: NSWindow, reindex: Bool = true) -> MainWindowContext? {
        guard isMainTerminalWindow(window) else { return nil }

        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            context.window = window
            return context
        }

        if let windowId = mainWindowId(from: window),
           let context = mainWindowContexts.values.first(where: { $0.windowId == windowId }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        let windowNumber = window.windowNumber
        if windowNumber >= 0,
           let context = mainWindowContexts.values.first(where: { candidate in
               let candidateWindow = candidate.window ?? windowForMainWindowId(candidate.windowId)
               return candidateWindow?.windowNumber == windowNumber
           }) {
            if reindex {
                reindexMainWindowContextIfNeeded(context, for: window)
            } else {
                context.window = window
            }
            return context
        }

        return nil
    }

    private func unregisterMainWindowContext(for window: NSWindow) -> MainWindowContext? {
        guard let removed = mainWindowContexts[ObjectIdentifier(window)],
              removed.window === window,
              removed.observedWindow === window else {
            return nil
        }
        let removedKeys = mainWindowContexts.compactMap { key, value in
            value === removed ? key : nil
        }
        for key in removedKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        notifyMainWindowContextsDidChange()
        return removed
    }

    private func teardownMainWindowContext(_ context: MainWindowContext) {
        removeMainWindowCloseObserver(from: context)
        context.tabManager.teardownForWindowClose(notifyOwner: !isTerminatingApp)
    }

    func discardOrphanedMainWindowContext(_ context: MainWindowContext) {
        let contextKeys = mainWindowContexts.compactMap { key, value in
            value === context ? key : nil
        }
        for key in contextKeys {
            mainWindowContexts.removeValue(forKey: key)
        }
        notifyMainWindowContextsDidChange()

        teardownCommandPaletteState(for: context.windowId)

        if tabManager === context.tabManager {
            if let nextContext = mainWindowContexts.values.first(where: { resolvedWindow(for: $0) != nil }) {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }
        repointSocketTabManagerIfOrphaned()

        if let store = notificationStore {
            for tab in context.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }
        teardownMainWindowContext(context)
    }

    /// Prune every registered main window context whose window has already been
    /// deallocated. Snapshot into an array first: `discardOrphanedMainWindowContext`
    /// mutates `mainWindowContexts`, and mutating a dictionary while iterating its
    /// `.values` view directly would trap.
    func discardOrphanedMainWindowContexts() {
        let orphans = mainWindowContexts.values.filter { resolvedWindow(for: $0) == nil }
        for orphan in orphans {
            discardOrphanedMainWindowContext(orphan)
        }
    }

    func mainWindowId(for window: NSWindow) -> UUID? {
        if let context = mainWindowContexts[ObjectIdentifier(window)] {
            return context.windowId
        }
        guard let rawIdentifier = window.identifier?.rawValue,
              rawIdentifier.hasPrefix("programa.main.") else { return nil }
        let idPart = String(rawIdentifier.dropFirst("programa.main.".count))
        return UUID(uuidString: idPart)
    }

    func contextForMainWindow(_ window: NSWindow?) -> MainWindowContext? {
        guard let window, isMainTerminalWindow(window) else { return nil }
        return mainWindowContexts[ObjectIdentifier(window)]
    }

    func setActiveMainWindow(_ window: NSWindow) {
        guard let context = contextForMainTerminalWindow(window) else { return }
#if DEBUG
        let beforeManagerToken = debugManagerToken(tabManager)
#endif
        tabManager = context.tabManager
        sidebarState = context.sidebarState
        sidebarSelectionState = context.sidebarSelectionState
        TerminalController.shared.setActiveTabManager(context.tabManager)
#if DEBUG
        dlog(
            "mainWindow.active window={\(debugWindowToken(window))} context={\(debugContextToken(context))} beforeMgr=\(beforeManagerToken) afterMgr=\(debugManagerToken(tabManager)) \(debugShortcutRouteSnapshot())"
        )
#endif
    }

    /// The socket's active manager can belong to a window the app never made active (one
    /// created over the socket without focus), so it is repointed on its own when that goes.
    private func repointSocketTabManagerIfOrphaned() {
        guard let socketManager = TerminalController.shared.tabManager,
              !mainWindowContexts.values.contains(where: { $0.tabManager === socketManager }) else { return }
        TerminalController.shared.setActiveTabManager(tabManager ?? mainWindowContexts.values.first?.tabManager)
    }

    private func unregisterMainWindow(_ window: NSWindow) {
        // Reset cascade point so the next new window appears near the closing
        // window's position, matching upstream Ghostty behavior.
        let frame = window.frame
        lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)

        // Keep geometry available as a fallback even if the full session snapshot
        // is removed when the last window closes.
        persistWindowGeometry(from: window)
        guard let removed = unregisterMainWindowContext(for: window) else { return }
        teardownCommandPaletteState(for: removed.windowId)

        // Avoid stale notifications that can no longer be opened once the owning window is gone.
        if let store = notificationStore {
            for tab in removed.tabManager.tabs {
                store.clearNotifications(forTabId: tab.id)
            }
        }

        if tabManager === removed.tabManager {
            // Repoint "active" pointers to any remaining main terminal window.
            let nextContext: MainWindowContext? = {
                if let keyWindow = NSApp.keyWindow,
                   let ctx = contextForMainTerminalWindow(keyWindow, reindex: false) {
                    return ctx
                }
                return mainWindowContexts.values.first
            }()

            if let nextContext {
                tabManager = nextContext.tabManager
                sidebarState = nextContext.sidebarState
                sidebarSelectionState = nextContext.sidebarSelectionState
                TerminalController.shared.setActiveTabManager(nextContext.tabManager)
            } else {
                tabManager = nil
                sidebarState = nil
                sidebarSelectionState = nil
                TerminalController.shared.setActiveTabManager(nil)
            }
        }
        repointSocketTabManagerIfOrphaned()

        teardownMainWindowContext(removed)
        releaseClosedMainWindowContent(window)

        // During app termination we already persisted a full snapshot (with scrollback)
        // in applicationShouldTerminate/applicationWillTerminate. Saving again here would
        // overwrite it as windows tear down one-by-one, dropping closed windows and replay.
        if Self.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: isTerminatingApp) {
            saveSessionSnapshot(
                includeScrollback: false,
                removeWhenEmpty: Self.shouldRemoveSnapshotWhenNoWindowsRemainOnWindowUnregister(
                    isTerminatingApp: isTerminatingApp
                )
            )
        }
    }

    /// Drops the hosting view of a closed main window so its SwiftUI graph (and the
    /// TabManager, workspaces and bonsplit controllers it observes) is freed even if
    /// AppKit or SwiftUI keeps the NSWindow itself alive a little longer.
    private func releaseClosedMainWindowContent(_ window: NSWindow) {
        guard !isTerminatingApp else { return }
        DispatchQueue.main.async { [weak window] in
            window?.contentView = nil
        }
    }

    func isMainTerminalWindow(_ window: NSWindow) -> Bool {
        if mainWindowContexts[ObjectIdentifier(window)] != nil {
            return true
        }
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "programa.main" || raw.hasPrefix("programa.main.")
    }

    func contextContainingTabId(_ tabId: UUID) -> MainWindowContext? {
        for context in mainWindowContexts.values {
            if context.tabManager.tabs.contains(where: { $0.id == tabId }) {
                return context
            }
        }
        return nil
    }

    /// Returns the `TabManager` that owns `tabId`, if any.
    func tabManagerFor(tabId: UUID) -> TabManager? {
        contextContainingTabId(tabId)?.tabManager
    }

    private func workspaceForMainActor(tabId: UUID) -> Workspace? {
        contextContainingTabId(tabId)?.tabManager.tabs.first(where: { $0.id == tabId })
    }

    /// Returns the `Workspace` that owns `tabId`, if any.
    @MainActor
    func workspaceFor(tabId: UUID) -> Workspace? {
        workspaceForMainActor(tabId: tabId)
    }
}
