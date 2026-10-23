import AppKit
import Bonsplit

extension AppDelegate {
    /// Runs one action against an event: nil when the action's configured shortcut does not
    /// match (the walk moves on to the next action), true when the event is consumed, false when
    /// it matched but must continue through the responder chain.
    typealias AppShortcutHandler = @MainActor (
        AppDelegate, KeyboardShortcutSettings.Action, NSEvent, _ commandPaletteTargetWindow: NSWindow?
    ) -> Bool?

    /// For actions that always consume the event once their configured shortcut matches.
    private static func consume(
        _ perform: @escaping @MainActor (AppDelegate, NSEvent, _ commandPaletteTargetWindow: NSWindow?) -> Void
    ) -> AppShortcutHandler {
        { app, action, event, commandPaletteTargetWindow in
            guard app.matchConfiguredShortcut(event: event, action: action) else { return nil }
            perform(app, event, commandPaletteTargetWindow)
            return true
        }
    }

    private static func paletteTargetWindow(_ event: NSEvent, _ commandPaletteTargetWindow: NSWindow?) -> NSWindow? {
        commandPaletteTargetWindow ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    // App-level shortcuts are the lowest-precedence phase of handleCustomShortcut(event:).
    // Precedence is the order of these two tables, split by the two hardcoded Ctrl+Tab checks.
    // Every KeyboardShortcutSettings.Action has exactly one entry, even if only to opt out;
    // DEBUG builds assert it (appShortcutTablesCoverEveryAction). `consume` entries always eat
    // the event on a match; every other entry spells out its own match and return value.
    private static let appShortcutsBeforeLegacyTabNavigation: [(KeyboardShortcutSettings.Action, AppShortcutHandler)] = [
        (.commandPalette, consume { app, event, window in
            app.requestCommandPaletteCommands(preferredWindow: paletteTargetWindow(event, window), source: "shortcut.commandPalette")
        }),
        (.goToWorkspace, consume { app, event, window in
            app.requestCommandPaletteSwitcher(preferredWindow: paletteTargetWindow(event, window), source: "shortcut.goToWorkspace")
        }),
        (.quit, { app, action, event, _ in
            app.matchConfiguredShortcut(event: event, action: action) ? app.handleQuitShortcutWarning() : nil
        }),
        (.openSettings, consume { app, _, _ in app.openPreferencesWindow(debugSource: "shortcut.openSettings") }),
        (.reloadConfiguration, consume { _, _, _ in
            GhosttyApp.shared.reloadConfiguration(source: "shortcut.reloadConfiguration")
        }),
        (.toggleFullScreen, { app, action, event, _ in
            guard app.matchConfiguredShortcut(event: event, action: action) else { return nil }
            guard let targetWindow = app.mainWindowForShortcutEvent(event) else { return false }
            targetWindow.toggleFullScreen(nil)
            return true
        }),
        (.toggleSidebar, consume { app, _, _ in _ = app.toggleSidebarInActiveMainWindow() }),
        (.newTab, consume { app, event, _ in app.performNewWorkspaceShortcut(event: event) }),
        // New Claude Code Workspace: Cmd+Shift+C. Instantly creates a new workspace in the current
        // workspace's working directory and boots Claude Code into it.
        (.newClaudeWorkspace, consume { app, event, _ in
#if DEBUG
            dlog("shortcut.action name=newClaudeWorkspace \(app.debugShortcutRouteSnapshot(event: event))")
#endif
            _ = app.createClaudeWorkspace(event: event, debugSource: "shortcut.cmdShiftC")
        }),
        // New Window (Cmd+Shift+N) and Open Folder (Cmd+O) are handled here rather than through the
        // SwiftUI menu: menu dispatch can consume the key equivalent without firing the action, and
        // a failed dispatch lets NSDocumentController open the Documents folder instead.
        (.newWindow, consume { app, _, _ in app.openNewMainWindow(nil) }),
        (.openFolder, consume { app, _, _ in app.showOpenFolderPanel() }),
        (.showNotifications, consume { app, _, _ in
            app.toggleNotificationsPopover(animated: false, anchorView: app.fullscreenControlsViewModel?.notificationsAnchorView)
        }),
        (.sendFeedback, { app, _, event, _ in app.handleSendFeedbackShortcutAction(event: event) }),
        (.jumpToUnread, consume { app, _, _ in
#if DEBUG
            if ProcessInfo.processInfo.environment["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                app.writeJumpUnreadTestData(["jumpUnreadShortcutHandled": "1"])
            }
#endif
            app.jumpToLatestUnread()
        }),
        (.triggerFlash, consume { app, _, _ in app.tabManager?.triggerFocusFlash() }),
        (.nextSurface, consume { app, _, _ in app.tabManager?.selectNextSurface() }),
        (.prevSurface, consume { app, _, _ in app.tabManager?.selectPreviousSurface() }),
        (.toggleTerminalCopyMode, { app, _, event, _ in app.handleToggleTerminalCopyModeShortcutAction(event: event) }),
        (.nextSidebarTab, consume { app, event, _ in
#if DEBUG
            let selected = app.tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=next repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            app.tabManager?.selectNextTab()
        }),
        (.prevSidebarTab, consume { app, event, _ in
#if DEBUG
            let selected = app.tabManager?.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
            dlog(
                "ws.shortcut dir=prev repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) selected=\(selected)"
            )
#endif
            app.tabManager?.selectPreviousTab()
        }),
        (.renameWorkspace, { app, action, event, window in
            guard app.matchConfiguredShortcut(event: event, action: action) else { return nil }
            return app.requestRenameWorkspaceViaCommandPalette(preferredWindow: paletteTargetWindow(event, window))
        }),
        (.editWorkspaceDescription, { app, action, event, window in
            guard app.matchConfiguredShortcut(event: event, action: action) else { return nil }
#if DEBUG
            dlog(
                "shortcut.editWorkspaceDescription matched target={\(app.debugWindowToken(paletteTargetWindow(event, window)))} " +
                "\(app.debugShortcutRouteSnapshot(event: event))"
            )
#endif
            return app.requestEditWorkspaceDescriptionViaCommandPalette(preferredWindow: paletteTargetWindow(event, window))
        }),
        (.closeOtherTabsInPane, consume { app, event, _ in app.performCloseOtherTabsInPaneShortcut(event: event) }),
        (.closeTab, { app, _, event, _ in app.handleCloseTabShortcutAction(event: event) }),
        (.closeWorkspace, consume { app, _, _ in app.tabManager?.closeCurrentWorkspaceWithConfirmation() }),
        (.closeWindow, consume { app, event, _ in app.performCloseWindowShortcut(event: event) }),
        (.renameTab, consume { app, event, window in
            app.requestCommandPaletteRenameTab(preferredWindow: paletteTargetWindow(event, window), source: "shortcut.renameTab")
        }),
        (.selectWorkspaceByNumber, { app, _, event, _ in app.handleSelectWorkspaceByNumberShortcutAction(event: event) }),
        (.selectSurfaceByNumber, { app, _, event, _ in app.handleSelectSurfaceByNumberShortcutAction(event: event) }),
        (.focusLeft, { app, action, event, _ in
            app.handleDirectionalFocusShortcutAction(
                event: event, action: action, arrowGlyph: "←", arrowKeyCode: 123, direction: .left,
                ghosttyGotoSplitShortcut: app.ghosttyGotoSplitLeftShortcut
            )
        }),
        (.focusRight, { app, action, event, _ in
            app.handleDirectionalFocusShortcutAction(
                event: event, action: action, arrowGlyph: "→", arrowKeyCode: 124, direction: .right,
                ghosttyGotoSplitShortcut: app.ghosttyGotoSplitRightShortcut
            )
        }),
        (.focusUp, { app, action, event, _ in
            app.handleDirectionalFocusShortcutAction(
                event: event, action: action, arrowGlyph: "↑", arrowKeyCode: 126, direction: .up,
                ghosttyGotoSplitShortcut: app.ghosttyGotoSplitUpShortcut
            )
        }),
        (.focusDown, { app, action, event, _ in
            app.handleDirectionalFocusShortcutAction(
                event: event, action: action, arrowGlyph: "↓", arrowKeyCode: 125, direction: .down,
                ghosttyGotoSplitShortcut: app.ghosttyGotoSplitDownShortcut
            )
        }),
        (.toggleSplitZoom, consume { app, _, _ in
            _ = app.tabManager?.toggleFocusedSplitZoom()
#if DEBUG
            app.recordGotoSplitZoomIfNeeded()
#endif
        }),
        (.splitRight, consume { app, event, _ in app.performSplitShortcutAction(event: event, direction: .right, debugActionName: "splitRight") }),
        (.splitDown, consume { app, event, _ in app.performSplitShortcutAction(event: event, direction: .down, debugActionName: "splitDown") }),
    ]

    private static let appShortcutsAfterLegacyTabNavigation: [(KeyboardShortcutSettings.Action, AppShortcutHandler)] = [
        (.newSurface, consume { app, _, _ in app.tabManager?.newSurface() }),
        (.openReview, consume { app, _, _ in
            guard let workspace = app.tabManager?.selectedWorkspace,
                  let focusedPanelId = workspace.focusedPanelId else { return }
            _ = workspace.newReviewSplit(from: focusedPanelId, orientation: .horizontal, focus: true)
        }),
        (.find, consume { app, _, _ in app.tabManager?.startSearch() }),
        (.findNext, consume { app, _, _ in app.tabManager?.findNext() }),
        (.findPrevious, consume { app, _, _ in app.tabManager?.findPrevious() }),
        (.hideFind, consume { app, _, _ in app.tabManager?.hideFind() }),
        (.useSelectionForFind, consume { app, _, _ in app.tabManager?.searchSelection() }),
        (.reopenClosedTerminal, consume { app, _, _ in _ = app.tabManager?.closedTerminalUndoStore.restoreMostRecent() }),
    ]

#if DEBUG
    private static let appShortcutTablesCoverEveryAction: Void = {
        let actions = (appShortcutsBeforeLegacyTabNavigation + appShortcutsAfterLegacyTabNavigation).map { $0.0 }
        assert(
            actions.count == Set(actions).count && Set(actions) == Set(KeyboardShortcutSettings.Action.allCases),
            "every KeyboardShortcutSettings.Action needs exactly one app shortcut table entry"
        )
    }()
#endif

    func handleConfiguredAppShortcutActions(
        event: NSEvent,
        commandPaletteTargetWindow: NSWindow?,
    ) -> Bool {
#if DEBUG
        _ = Self.appShortcutTablesCoverEveryAction
#endif
        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           !eventModifiersCanTriggerAppShortcut(event) {
            return false
        }

        if activeConfiguredShortcutChordPrefixForCurrentEvent == nil,
           armConfiguredShortcutChordIfNeeded(event: event) {
            return true
        }

        for (action, handle) in Self.appShortcutsBeforeLegacyTabNavigation {
            if let result = handle(self, action, event, commandPaletteTargetWindow) {
                return result
            }
        }

        // Surface navigation (legacy Ctrl+Tab support). Not driven by KeyboardShortcutSettings.Action,
        // so it can't live in the tables.
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)) {
            tabManager?.selectNextSurface()
            return true
        }
        if matchTabShortcut(event: event, shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)) {
            tabManager?.selectPreviousSurface()
            return true
        }

        for (action, handle) in Self.appShortcutsAfterLegacyTabNavigation {
            if let result = handle(self, action, event, commandPaletteTargetWindow) {
                return result
            }
        }

        return false
    }

    /// Cheap pre-filter for the precedence walk: false only when the event's modifiers equal no
    /// configured first stroke and no ghostty goto_split stroke, so no matcher in the walk can
    /// accept it. Callers must not use it while a chord prefix is pending (second strokes are
    /// not part of the mask set).
    private func eventModifiersCanTriggerAppShortcut(_ event: NSEvent) -> Bool {
        guard let masks = configuredShortcutTriggerModifierMasks else { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if masks.contains(flags.rawValue) { return true }
        func matches(_ shortcut: StoredShortcut?) -> Bool {
            shortcut?.firstStroke.modifierFlags == flags
        }
        return matches(ghosttyGotoSplitLeftShortcut) || matches(ghosttyGotoSplitRightShortcut)
            || matches(ghosttyGotoSplitUpShortcut) || matches(ghosttyGotoSplitDownShortcut)
    }

    // Cmd+N semantics:
    // - If there are no main windows, create a new window.
    // - Otherwise, create a new workspace in the active window.
    private func performNewWorkspaceShortcut(event: NSEvent) {
#if DEBUG
        dlog("shortcut.action name=newWorkspace \(debugShortcutRouteSnapshot(event: event))")
#endif
        if mainWindowContexts.isEmpty {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: "shortcut.cmdN",
                reason: "no_main_windows",
                event: event,
                chosenContext: nil
            )
            #endif
            openNewMainWindow(nil)
        } else if addWorkspaceInPreferredMainWindow(event: event, debugSource: "shortcut.cmdN") == nil {
            #if DEBUG
            logWorkspaceCreationRouting(
                phase: "fallback_new_window",
                source: "shortcut.cmdN",
                reason: "workspace_creation_returned_nil",
                event: event,
                chosenContext: nil
            )
            #endif
            openNewMainWindow(nil)
        }
    }

    private func handleSendFeedbackShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .sendFeedback) else { return nil }
        guard let targetContext = preferredMainWindowContextForShortcuts(event: event),
              let targetWindow = targetContext.window ?? windowForMainWindowId(targetContext.windowId) else {
            return false
        }
        setActiveMainWindow(targetWindow)
        bringToFront(targetWindow)
        NotificationCenter.default.post(name: .feedbackComposerRequested, object: targetWindow)
        return true
    }

    private func handleToggleTerminalCopyModeShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .toggleTerminalCopyMode) else { return nil }
        let handled = tabManager?.toggleFocusedTerminalCopyMode() ?? false
#if DEBUG
        dlog(
            "shortcut.action name=toggleTerminalCopyMode handled=\(handled ? 1 : 0) " +
            "\(debugShortcutRouteSnapshot(event: event))"
        )
#endif
        // Only consume when a focused terminal actually handled the toggle.
        // Otherwise allow the event to continue through the responder chain.
        return handled
    }

    private func performCloseOtherTabsInPaneShortcut(event: NSEvent) {
        if let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
           targetWindow.identifier?.rawValue == "programa.settings" {
            targetWindow.performClose(nil)
        } else {
            let targetWindow = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
            if let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow) {
                terminalContext.tabManager.closeOtherTabsInFocusedPaneWithConfirmation()
            } else {
                tabManager?.closeOtherTabsInFocusedPaneWithConfirmation()
            }
        }
    }

    // Unless the window owns Cmd+W, it routes through the workspace model so it closes the
    // focused panel even while first responder lags behind focus.
    private func handleCloseTabShortcutAction(event: NSEvent) -> Bool? {
        guard matchConfiguredShortcut(event: event, action: .closeTab) else { return nil }
        let targetWindow = resolvedShortcutEventWindow(event) ?? NSApp.keyWindow ?? NSApp.mainWindow
        let routedManager = preferredMainWindowContextForShortcutRouting(event: event)?.tabManager ?? tabManager
        if let targetWindow,
           programaWindowShouldOwnCloseShortcut(targetWindow) {
            targetWindow.performClose(nil)
        } else {
            if let routedManager {
#if DEBUG
                let selectedWorkspace = routedManager.selectedWorkspace
                dlog(
                    "shortcut.cmdW route=workspaceModel workspace=\(selectedWorkspace?.id.uuidString.prefix(5) ?? "nil") " +
                    "panel=\(selectedWorkspace?.focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                    "selected=\(routedManager.selectedTabId?.uuidString.prefix(5) ?? "nil")"
                )
#endif
                routedManager.closeCurrentPanelWithConfirmation()
            } else {
#if DEBUG
                dlog("shortcut.cmdW route=noManager")
#endif
                return false
            }
        }
        return true
    }

    private func performCloseWindowShortcut(event: NSEvent) {
        // `event.window` is often nil for synthetic/XCUITest key events that only carry a
        // windowNumber; fall back through the same windowNumber-aware resolver the rest of
        // the shortcut-routing code uses so Cmd+Ctrl+W targets the event's actual window
        // instead of silently no-op'ing when NSApp.keyWindow/mainWindow are stale.
        guard let targetWindow = mainWindowForShortcutEvent(event) ?? event.window ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            NSSound.beep()
            return
        }
        // Same gate as the red button, called directly so it also holds in native full screen.
        targetWindow.programa_mainWindowCloseButtonPressed(nil)
    }

    // Numeric shortcuts for specific workspaces (9 = last workspace)
    // Always consume the event when the digit matches to prevent Ghostty's
    // goto_tab fallback from creating a new window when the index is out of bounds.
    private func handleSelectWorkspaceByNumberShortcutAction(event: NSEvent) -> Bool? {
        guard let digit = numberedConfiguredShortcutDigit(event: event, action: .selectWorkspaceByNumber) else { return nil }
        if let manager = tabManager,
           let targetIndex = WorkspaceShortcutMapper.workspaceIndex(forDigit: digit, workspaceCount: manager.tabs.count) {
#if DEBUG
            dlog(
                "shortcut.action name=workspaceDigit digit=\(digit) targetIndex=\(targetIndex) manager=\(debugManagerToken(manager)) \(debugShortcutRouteSnapshot(event: event))"
            )
#endif
            manager.selectTab(at: targetIndex)
        }
        return true
    }

    // 9 selects the last surface in the focused pane.
    private func handleSelectSurfaceByNumberShortcutAction(event: NSEvent) -> Bool? {
        guard let digit = numberedConfiguredShortcutDigit(event: event, action: .selectSurfaceByNumber) else { return nil }
        if digit == 9 {
            tabManager?.selectLastSurface()
        } else {
            tabManager?.selectSurface(at: digit - 1)
        }
        return true
    }

    // Pane focus navigation (defaults to Cmd+Option+Arrow, but can be customized to letter/number keys).
    // Shared by the four directional focus actions -- they differ only by arrow glyph/key code,
    // NavigationDirection, the configured ghostty goto_split shortcut to also match against, and which
    // direction to record for goto_split debug telemetry.
    private func handleDirectionalFocusShortcutAction(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16,
        direction: NavigationDirection,
        ghosttyGotoSplitShortcut: StoredShortcut?
    ) -> Bool? {
        guard matchConfiguredDirectionalShortcut(
            event: event,
            action: action,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        ) || (ghosttyGotoSplitShortcut.map {
            matchDirectionalShortcut(event: event, shortcut: $0, arrowGlyph: arrowGlyph, arrowKeyCode: arrowKeyCode)
        } ?? false) else { return nil }
        tabManager?.movePaneFocus(direction: direction)
#if DEBUG
        recordGotoSplitMoveIfNeeded(direction: direction)
#endif
        return true
    }

    private func performSplitShortcutAction(event: NSEvent, direction: SplitDirection, debugActionName: String) {
#if DEBUG
        dlog("shortcut.action name=\(debugActionName) \(debugShortcutRouteSnapshot(event: event))")
#endif
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: direction) {
            return
        }
        _ = performSplitShortcut(
            direction: direction,
            preferredWindow: event.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    private func shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: SplitDirection) -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId,
              let terminalPanel = workspace.terminalPanel(for: focusedPanelId) else {
            return false
        }

        let hostedView = terminalPanel.hostedView
        let hostedSize = hostedView.bounds.size
        let hostedHiddenInHierarchy = hostedView.isHiddenOrHasHiddenAncestor
        let hostedAttachedToWindow = hostedView.window != nil
        let firstResponderIsWindow = NSApp.keyWindow?.firstResponder is NSWindow

        let shouldSuppress = shouldSuppressSplitShortcutForTransientTerminalFocusInputs(
            firstResponderIsWindow: firstResponderIsWindow,
            hostedSize: hostedSize,
            hostedHiddenInHierarchy: hostedHiddenInHierarchy,
            hostedAttachedToWindow: hostedAttachedToWindow
        )
        guard shouldSuppress else { return false }

        tabManager.reconcileFocusedPanelFromFirstResponderForKeyboard()

#if DEBUG
        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }
        let firstResponderType = NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "split.shortcut suppressed dir=\(directionLabel) reason=transient_focus_state " +
            "fr=\(firstResponderType) hidden=\(hostedHiddenInHierarchy ? 1 : 0) " +
            "attached=\(hostedAttachedToWindow ? 1 : 0) " +
            "frame=\(String(format: "%.1fx%.1f", hostedSize.width, hostedSize.height))"
        )
#endif
        return true
    }

    @discardableResult
    func performSplitShortcut(direction: SplitDirection, preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow)
        _ = synchronizeActiveMainWindowContext(preferredWindow: targetWindow)

        #if DEBUG
        let splitContext: () -> String = {
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow = (firstResponder as? NSView)?.window?.windowNumber
                ?? (firstResponder as? NSWindow)?.windowNumber
                ?? -1
            return "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
        }
        dlog("split.shortcut dir=\(direction) pre panel=nil \(splitContext())")
        #endif

        let didCreateSplit: Bool = {
            if let terminalContext {
                return terminalContext.tabManager.createSplit(
                    tabId: terminalContext.workspaceId,
                    surfaceId: terminalContext.panelId,
                    direction: direction
                ) != nil
            }
            return tabManager?.createSplit(direction: direction) != nil
        }()
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dlog("split.shortcut dir=\(direction) post panel=nil \(splitContext())")
        }
        recordGotoSplitSplitIfNeeded(direction: direction)
#endif
        return didCreateSplit
    }

    @discardableResult
    func requestRenameWorkspaceViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        requestCommandPaletteRenameWorkspace(
            preferredWindow: targetWindow,
            source: "shortcut.renameWorkspace"
        )
        return true
    }

    @discardableResult
    func requestEditWorkspaceDescriptionViaCommandPalette(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
#if DEBUG
        dlog(
            "shortcut.editWorkspaceDescription request target={\(debugWindowToken(targetWindow))} " +
            "fr=\(targetWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        )
#endif
        requestCommandPaletteEditWorkspaceDescription(
            preferredWindow: targetWindow,
            source: "shortcut.editWorkspaceDescription"
        )
        return true
    }

    func matchConfiguredShortcut(event: NSEvent, action: KeyboardShortcutSettings.Action) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchShortcutStroke(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return false }
        return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
    }

    private func numberedConfiguredShortcutDigit(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action
    ) -> Int? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return nil
            }
            return numberedShortcutDigit(event: event, stroke: secondStroke)
        }
        guard !shortcut.hasChord else { return nil }
        return numberedShortcutDigit(event: event, stroke: shortcut.firstStroke)
    }

    private func matchConfiguredDirectionalShortcut(
        event: NSEvent,
        action: KeyboardShortcutSettings.Action,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        let shortcut = KeyboardShortcutSettings.shortcut(for: action)
        if let prefix = activeConfiguredShortcutChordPrefixForCurrentEvent {
            guard let secondStroke = shortcut.secondStroke,
                  shortcut.firstStroke == prefix else {
                return false
            }
            return matchDirectionalShortcut(
                event: event,
                stroke: secondStroke,
                arrowGlyph: arrowGlyph,
                arrowKeyCode: arrowKeyCode
            )
        }
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }

    func configuredShortcutChordWindowNumber(for event: NSEvent) -> Int? {
        if let window = mainWindowForShortcutEvent(event) {
            return window.windowNumber
        }
        if let window = event.window {
            return window.windowNumber
        }
        return event.windowNumber > 0 ? event.windowNumber : nil
    }

    func armConfiguredShortcutChordIfNeeded(
        event: NSEvent,
        actions: [KeyboardShortcutSettings.Action]? = nil
    ) -> Bool {
        for action in actions ?? configuredShortcutChordActions {
            let shortcut = KeyboardShortcutSettings.shortcut(for: action)
            guard shortcut.hasChord else { continue }
            if matchShortcutStroke(event: event, stroke: shortcut.firstStroke) {
                pendingConfiguredShortcutChord = PendingConfiguredShortcutChord(
                    firstStroke: shortcut.firstStroke,
                    windowNumber: configuredShortcutChordWindowNumber(for: event)
                )
                return true
            }
        }
        return false
    }

    /// The matching logic lives in `ShortcutRouting.matchStroke`, a pure function over an
    /// explicit `layoutCharacterProvider` so it can be table-tested without AppKit.
    func matchShortcutStroke(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        ShortcutRouting.matchStroke(
            event: event,
            stroke: stroke,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        )
    }

    func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        ShortcutRouting.match(
            event: event,
            shortcut: shortcut,
            layoutCharacterProvider: shortcutLayoutCharacterProvider
        )
    }

    private func numberedShortcutDigit(event: NSEvent, stroke: ShortcutStroke) -> Int? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == stroke.modifierFlags else { return nil }
        let numberKeyDigit = Self.digitForNumberKeyCode(event.keyCode)

        if let digit = numberedShortcutDigit(
            eventCharacter: event.charactersIgnoringModifiers,
            applyShiftSymbolNormalization: flags.contains(.shift),
            eventKeyCode: event.keyCode
        ) {
            return digit
        }

        let eventCharsIgnoringModifiers = event.charactersIgnoringModifiers
        let hasUsableASCIIEventChars = !(eventCharsIgnoringModifiers?.isEmpty ?? true)
            && (eventCharsIgnoringModifiers?.allSatisfy(\.isASCII) ?? true)
        if !hasUsableASCIIEventChars || numberKeyDigit != nil {
            let layoutCharacter = shortcutLayoutCharacterProvider(event.keyCode, event.modifierFlags)
            if let digit = numberedShortcutDigit(
                eventCharacter: layoutCharacter,
                applyShiftSymbolNormalization: false,
                eventKeyCode: event.keyCode
            ) {
                return digit
            }
        }

        return numberKeyDigit
    }

    private func numberedShortcutDigit(
        eventCharacter: String?,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> Int? {
        guard let eventCharacter, !eventCharacter.isEmpty else { return nil }
        let normalized = Self.normalizedShortcutEventCharacter(
            eventCharacter,
            applyShiftSymbolNormalization: applyShiftSymbolNormalization,
            eventKeyCode: eventKeyCode
        )
        guard let digit = Int(normalized), (1...9).contains(digit) else { return nil }
        return digit
    }

    /// Shared by `ShortcutRouting.matchStroke` and `numberedShortcutDigit`; `nonisolated static`
    /// because it reads no instance state.
    nonisolated static func normalizedShortcutEventCharacter(
        _ eventCharacter: String,
        applyShiftSymbolNormalization: Bool,
        eventKeyCode: UInt16
    ) -> String {
        let lowered = eventCharacter.lowercased()
        guard applyShiftSymbolNormalization else { return lowered }

        switch lowered {
        case "{": return "["
        case "}": return "]"
        case "<": return eventKeyCode == 43 ? "," : lowered // kVK_ANSI_Comma
        case ">": return eventKeyCode == 47 ? "." : lowered // kVK_ANSI_Period
        case "?": return "/"
        case ":": return ";"
        case "\"": return "'"
        case "|": return "\\"
        case "~": return "`"
        case "+": return "="
        case "_": return "-"
        case "!": return eventKeyCode == 18 ? "1" : lowered // kVK_ANSI_1
        case "@": return eventKeyCode == 19 ? "2" : lowered // kVK_ANSI_2
        case "#": return eventKeyCode == 20 ? "3" : lowered // kVK_ANSI_3
        case "$": return eventKeyCode == 21 ? "4" : lowered // kVK_ANSI_4
        case "%": return eventKeyCode == 23 ? "5" : lowered // kVK_ANSI_5
        case "^": return eventKeyCode == 22 ? "6" : lowered // kVK_ANSI_6
        case "&": return eventKeyCode == 26 ? "7" : lowered // kVK_ANSI_7
        case "*": return eventKeyCode == 28 ? "8" : lowered // kVK_ANSI_8
        case "(": return eventKeyCode == 25 ? "9" : lowered // kVK_ANSI_9
        case ")": return eventKeyCode == 29 ? "0" : lowered // kVK_ANSI_0
        default: return lowered
        }
    }

    /// Shared by `ShortcutRouting.matchStroke` and `numberedShortcutDigit`; `nonisolated static`
    /// because it reads no instance state.
    nonisolated static func digitForNumberKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 1 // kVK_ANSI_1
        case 19: return 2 // kVK_ANSI_2
        case 20: return 3 // kVK_ANSI_3
        case 21: return 4 // kVK_ANSI_4
        case 23: return 5 // kVK_ANSI_5
        case 22: return 6 // kVK_ANSI_6
        case 26: return 7 // kVK_ANSI_7
        case 28: return 8 // kVK_ANSI_8
        case 25: return 9 // kVK_ANSI_9
        default:
            return nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    private func matchArrowShortcut(event: NSEvent, stroke: ShortcutStroke, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == stroke.modifierFlags
    }

    /// keyCode 48 is kVK_Tab.
    private func matchTabShortcut(event: NSEvent, stroke: ShortcutStroke) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == stroke.modifierFlags
    }

    private func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchTabShortcut(event: event, stroke: shortcut.firstStroke)
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    private func matchDirectionalShortcut(
        event: NSEvent,
        stroke: ShortcutStroke,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if stroke.key == arrowGlyph {
            return matchArrowShortcut(event: event, stroke: stroke, keyCode: arrowKeyCode)
        }
        return matchShortcutStroke(event: event, stroke: stroke)
    }

    private func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        guard !shortcut.hasChord else { return false }
        return matchDirectionalShortcut(
            event: event,
            stroke: shortcut.firstStroke,
            arrowGlyph: arrowGlyph,
            arrowKeyCode: arrowKeyCode
        )
    }
}
