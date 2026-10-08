// XCUITest-only instrumentation.
import AppKit
@preconcurrency import Dispatch
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Combine
@preconcurrency import ObjectiveC.runtime
import Darwin

#if DEBUG
@MainActor
private final class SocketListenerUITestObservationState {
    var observer: NSObjectProtocol?
    var timeoutWorkItem: DispatchWorkItem?
}
#endif

extension AppDelegate {
#if DEBUG
    func setupJumpUnreadUITestIfNeeded() {
        guard !didSetupJumpUnreadUITest else { return }
        didSetupJumpUnreadUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_JUMP_UNREAD_SETUP"] == "1" else { return }
        guard let notificationStore else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // In UI tests, the initial SwiftUI `WindowGroup` window can lag behind launch. Wait for a
                // registered main terminal window context so notifications can be routed back correctly.
                let deadline = Date().addingTimeInterval(8.0)
                @MainActor func waitForContext(_ completion: @escaping (MainWindowContext) -> Void) {
                    if let context = self.mainWindowContexts.values.first,
                       context.window != nil {
                        completion(context)
                        return
                    }
                    guard Date() < deadline else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        Task { @MainActor in
                            waitForContext(completion)
                        }
                    }
                }

                waitForContext { context in
                    let tabManager = context.tabManager
                    let initialIndex = tabManager.tabs.firstIndex(where: { $0.id == tabManager.selectedTabId }) ?? 0
                    let tab = tabManager.addTab()
                    guard let initialPanelId = tab.focusedPanelId else { return }

                    _ = tabManager.newSplit(tabId: tab.id, surfaceId: initialPanelId, direction: .right)
                    guard let targetPanelId = tab.focusedPanelId else { return }
                    // Find another panel that's not the currently focused one
                    let otherPanelId = tab.panels.keys.first(where: { $0 != targetPanelId })
                    if let otherPanelId {
                        tab.focusPanel(otherPanelId)
                    }

                    // Avoid flakiness in the VM where focus can lag selection by a tick, which would
                    // cause notification suppression to incorrectly drop this UI-test notification.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    notificationStore.addNotification(
                        tabId: tab.id,
                        surfaceId: targetPanelId,
                        title: "JumpToUnread",
                        subtitle: "",
                        body: ""
                    )
                    AppFocusState.overrideIsFocused = prevOverride

                    self.writeJumpUnreadTestData([
                        "expectedTabId": tab.id.uuidString,
                        "expectedSurfaceId": targetPanelId.uuidString
                    ])

                    tabManager.selectTab(at: initialIndex)
                }
            }
        }
    }

    func recordJumpToUnreadFocus(tabId: UUID, surfaceId: UUID) {
        writeJumpUnreadTestData([
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId.uuidString
        ])
    }

    func armJumpUnreadFocusRecord(tabId: UUID, surfaceId: UUID) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        jumpUnreadFocusExpectation = (tabId: tabId, surfaceId: surfaceId)
        installJumpUnreadFocusObserverIfNeeded()
    }

    func recordJumpUnreadFocusIfExpected(tabId: UUID, surfaceId: UUID) {
        guard let expectation = jumpUnreadFocusExpectation else { return }
        guard expectation.tabId == tabId && expectation.surfaceId == surfaceId else { return }
        jumpUnreadFocusExpectation = nil
        recordJumpToUnreadFocus(tabId: tabId, surfaceId: surfaceId)
        if let jumpUnreadFocusObserver {
            NotificationCenter.default.removeObserver(jumpUnreadFocusObserver)
            self.jumpUnreadFocusObserver = nil
        }
    }

    private func installJumpUnreadFocusObserverIfNeeded() {
        guard jumpUnreadFocusObserver == nil else { return }
        jumpUnreadFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
                guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
                self.recordJumpUnreadFocusIfExpected(tabId: tabId, surfaceId: surfaceId)
            }
        }
    }

    func writeJumpUnreadTestData(_ updates: [String: String]) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_JUMP_UNREAD_PATH"], !path.isEmpty else { return }
        var payload = loadJumpUnreadTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadJumpUnreadTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func setupBonsplitTabDragUITestIfNeeded() {
        guard !didSetupBonsplitTabDragUITest else { return }
        didSetupBonsplitTabDragUITest = true
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1" else { return }
        guard tabManager != nil else { return }
        let startWithHiddenSidebar = env["PROGRAMA_UI_TEST_BONSPLIT_START_WITH_HIDDEN_SIDEBAR"] == "1"

        let deadline = Date().addingTimeInterval(20.0)
        func hasMainTerminalWindow() -> Bool {
            NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "programa.main" || raw.hasPrefix("programa.main.")
            }
        }

        func runSetupWhenWindowReady() {
            guard Date() < deadline else {
                writeBonsplitTabDragUITestData(["setupError": "Timed out waiting for main window"])
                return
            }
            guard hasMainTerminalWindow() else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    runSetupWhenWindowReady()
                }
                return
            }
            if let mainWindow = NSApp.windows.first(where: { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "programa.main" || raw.hasPrefix("programa.main.")
            }) {
                let screenFrame = mainWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
                if let screenFrame {
                    let targetSize = NSSize(width: min(960, screenFrame.width - 80), height: min(720, screenFrame.height - 80))
                    let targetOrigin = NSPoint(
                        x: screenFrame.minX + 40,
                        y: screenFrame.maxY - 40 - targetSize.height
                    )
                    let targetFrame = NSRect(origin: targetOrigin, size: targetSize)
                    if !mainWindow.frame.equalTo(targetFrame) {
                        mainWindow.setFrame(targetFrame, display: true)
                    }
                }
            }
            guard let tabManager = self.tabManager,
                  let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first,
                  let alphaPanelId = workspace.focusedPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Missing initial workspace or panel"])
                return
            }

            let workspaceTitle = "UITest Workspace"
            let alphaTitle = "UITest Alpha"
            let betaTitle = "UITest Beta"
            tabManager.setCustomTitle(tabId: workspace.id, title: workspaceTitle)
            workspace.setPanelCustomTitle(panelId: alphaPanelId, title: alphaTitle)
            tabManager.newSurface()

            guard let betaPanelId = workspace.focusedPanelId, betaPanelId != alphaPanelId else {
                self.writeBonsplitTabDragUITestData(["setupError": "Failed to create second surface"])
                return
            }

            workspace.setPanelCustomTitle(panelId: betaPanelId, title: betaTitle)
            if startWithHiddenSidebar {
                self.sidebarState?.isVisible = false
            }
            self.writeBonsplitTabDragUITestData([
                "ready": "1",
                "sidebarVisible": startWithHiddenSidebar ? "0" : "1",
                "workspaceId": workspace.id.uuidString,
                "workspaceTitle": workspaceTitle,
                "alphaTitle": alphaTitle,
                "betaTitle": betaTitle,
                "alphaPanelId": alphaPanelId.uuidString,
                "betaPanelId": betaPanelId.uuidString,
            ])
            self.startBonsplitTabDragUITestRecorder(
                workspaceId: workspace.id,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self != nil else { return }
            runSetupWhenWindowReady()
        }
    }

    private func bonsplitTabDragUITestDataPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_BONSPLIT_TAB_DRAG_SETUP"] == "1",
              let path = env["PROGRAMA_UI_TEST_BONSPLIT_TAB_DRAG_PATH"],
              !path.isEmpty else {
            return nil
        }
        return path
    }

    private func startBonsplitTabDragUITestRecorder(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        bonsplitTabDragUITestRecorder?.cancel()
        bonsplitTabDragUITestRecorder = nil

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.recordBonsplitTabDragUITestState(
                workspaceId: workspaceId,
                alphaPanelId: alphaPanelId,
                betaPanelId: betaPanelId
            )
        }
        bonsplitTabDragUITestRecorder = timer
        timer.resume()
    }

    private func recordBonsplitTabDragUITestState(
        workspaceId: UUID,
        alphaPanelId: UUID,
        betaPanelId: UUID
    ) {
        guard let tabManager else { return }
        guard let workspace = (tabManager.tabs.first { $0.id == workspaceId } ?? tabManager.selectedWorkspace ?? tabManager.tabs.first) else {
            return
        }

        let trackedPaneId = workspace.paneId(forPanelId: alphaPanelId)
            ?? workspace.paneId(forPanelId: betaPanelId)
            ?? workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first
        guard let trackedPaneId else { return }

        let titles: [String] = workspace.bonsplitController.tabs(inPane: trackedPaneId).compactMap { tab in
            guard let panelId = workspace.panelIdFromSurfaceId(tab.id) else { return nil }
            return workspace.panelTitle(panelId: panelId)
        }
        let selectedTitle = workspace.bonsplitController.selectedTab(inPane: trackedPaneId)
            .flatMap { workspace.panelIdFromSurfaceId($0.id) }
            .flatMap { workspace.panelTitle(panelId: $0) } ?? ""

        writeBonsplitTabDragUITestData([
            "trackedPaneId": trackedPaneId.description,
            "trackedPaneTabTitles": titles.joined(separator: "|"),
            "trackedPaneTabCount": String(titles.count),
            "trackedPaneSelectedTitle": selectedTitle,
        ])
    }

    private func writeBonsplitTabDragUITestData(_ updates: [String: String]) {
        guard let path = bonsplitTabDragUITestDataPath() else { return }
        var payload = loadBonsplitTabDragUITestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadBonsplitTabDragUITestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
    private func isGotoSplitUITestRecordingEnabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["PROGRAMA_UI_TEST_GOTO_SPLIT_SETUP"] == "1" || env["PROGRAMA_UI_TEST_GOTO_SPLIT_RECORD_ONLY"] == "1"
    }

    private func gotoSplitUITestDataPath() -> String? {
        guard isGotoSplitUITestRecordingEnabled() else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_GOTO_SPLIT_PATH"], !path.isEmpty else { return nil }
        return path
    }

    private func gotoSplitFindStateSnapshot(for workspace: Workspace) -> [String: String] {
        var updates: [String: String] = [
            "focusedPaneId": workspace.bonsplitController.focusedPaneId?.description ?? ""
        ]

        if let focusedPanelId = workspace.focusedPanelId {
            updates["focusedPanelId"] = focusedPanelId.uuidString
            if let terminal = workspace.terminalPanel(for: focusedPanelId) {
                updates["focusedPanelKind"] = "terminal"
                updates["focusedTerminalFindNeedle"] = terminal.searchState?.needle ?? ""
            } else {
                updates["focusedPanelKind"] = "other"
                updates["focusedTerminalFindNeedle"] = ""
            }
        } else {
            updates["focusedPanelId"] = ""
            updates["focusedPanelKind"] = "none"
            updates["focusedTerminalFindNeedle"] = ""
        }

        let terminalWithFind = workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .first(where: { $0.searchState != nil })
        updates["terminalFindPanelId"] = terminalWithFind?.id.uuidString ?? ""
        updates["terminalFindNeedle"] = terminalWithFind?.searchState?.needle ?? ""
        updates["terminalFindVisible"] = terminalWithFind == nil ? "false" : "true"

        return updates
    }

    func recordGotoSplitMoveIfNeeded(direction: NavigationDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let tabManager, let workspace = tabManager.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastMoveDirection"] = directionValue
        writeGotoSplitTestData(updates)
    }

    func recordGotoSplitSplitIfNeeded(direction: SplitDirection) {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        let directionValue: String
        switch direction {
        case .left:
            directionValue = "left"
        case .right:
            directionValue = "right"
        case .up:
            directionValue = "up"
        case .down:
            directionValue = "down"
        }

        var updates = gotoSplitFindStateSnapshot(for: workspace)
        updates["lastSplitDirection"] = directionValue
        updates["paneCountAfterSplit"] = String(workspace.bonsplitController.allPaneIds.count)
        writeGotoSplitTestData(updates)
    }

    func recordGotoSplitZoomIfNeeded() {
        guard isGotoSplitUITestRecordingEnabled() else { return }
        guard let workspace = tabManager?.selectedWorkspace else { return }

        func snapshot(for workspace: Workspace) -> ([String: String], Bool) {
            let otherTerminal = workspace.panels.values.compactMap { $0 as? TerminalPanel }.first
            var updates = self.gotoSplitFindStateSnapshot(for: workspace)
            updates["splitZoomedAfterToggle"] = workspace.bonsplitController.isSplitZoomed ? "true" : "false"
            updates["zoomedPaneIdAfterToggle"] = workspace.bonsplitController.zoomedPaneId?.description ?? ""
            updates["otherTerminalPanelIdAfterToggle"] = otherTerminal?.id.uuidString ?? ""
            updates["otherTerminalHostHiddenAfterToggle"] = otherTerminal.map { $0.hostedView.isHidden ? "true" : "false" } ?? ""
            updates["otherTerminalVisibleFlagAfterToggle"] = otherTerminal.map { $0.hostedView.debugPortalVisibleInUI ? "true" : "false" } ?? ""
            updates["otherTerminalFrameAfterToggle"] = otherTerminal.map {
                let frame = $0.hostedView.debugPortalFrameInWindow
                return String(
                    format: "%.1f,%.1f %.1fx%.1f",
                    frame.origin.x,
                    frame.origin.y,
                    frame.size.width,
                    frame.size.height
                )
            } ?? ""

            let settled: Bool = {
                if workspace.bonsplitController.isSplitZoomed {
                    guard let otherTerminal else { return true }
                    return otherTerminal.hostedView.isHidden && !otherTerminal.hostedView.debugPortalVisibleInUI
                }
                let terminalRestored = otherTerminal.map {
                    !$0.hostedView.isHidden && $0.hostedView.debugPortalVisibleInUI
                } ?? true
                return terminalRestored
            }()

            return (updates, settled)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            panelsCancellable?.cancel()
            panelsCancellable = nil
        }

        @MainActor
        func finish(with updates: [String: String]) {
            guard !resolved else { return }
            resolved = true
            cleanup()
            self.writeGotoSplitTestData(updates)
        }

        @MainActor
        func evaluate() {
            guard !resolved, let currentWorkspace = self.tabManager?.selectedWorkspace else { return }
            let (updates, settled) = snapshot(for: currentWorkspace)
            guard settled else { return }
            finish(with: updates)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in evaluate() }
        })
        panelsCancellable = workspace.$panels
            .map { _ in () }
            .sink { _ in
                Task { @MainActor in evaluate() }
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard !resolved, let currentWorkspace = self.tabManager?.selectedWorkspace else { return }
                finish(with: snapshot(for: currentWorkspace).0)
            }
        }
        Task { @MainActor in evaluate() }
    }

    private func writeGotoSplitTestData(_ updates: [String: String]) {
        guard let path = gotoSplitUITestDataPath() else { return }
        var payload = loadGotoSplitTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadGotoSplitTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func setupMultiWindowNotificationsUITestIfNeeded() {
        guard !didSetupMultiWindowNotificationsUITest else { return }
        didSetupMultiWindowNotificationsUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_SETUP"] == "1" else { return }
        guard let path = env["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }

        try? FileManager.default.removeItem(atPath: path)
        let setupStart = Date()
        func stamp(_ key: String) {
            writeMultiWindowNotificationTestData(
                [key: String(format: "%.2f", Date().timeIntervalSince(setupStart))],
                at: path
            )
        }

        func waitForContexts(minCount: Int, _ completion: @escaping () -> Void) {
            let isReady = {
                self.mainWindowContexts.count >= minCount &&
                    self.mainWindowContexts.values.allSatisfy { $0.window != nil }
            }
            guard !isReady() else {
                completion()
                return
            }

            var resolved = false
            var observer: NSObjectProtocol?
            let finish = {
                guard !resolved else { return }
                resolved = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                completion()
            }
            observer = NotificationCenter.default.addObserver(
                forName: .mainWindowContextsDidChange,
                object: self,
                queue: .main
            ) { _ in
                if isReady() {
                    finish()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                if isReady() {
                    finish()
                } else if let observer, !resolved {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }

        func waitForSurfaceId(
            on tabManager: TabManager,
            tabId: UUID,
            timeout: TimeInterval = 8.0,
            _ completion: @escaping (UUID) -> Void
        ) {
            func resolvedSurfaceId() -> UUID? {
                if let surfaceId = tabManager.focusedPanelId(for: tabId) {
                    return surfaceId
                }

                guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                    return nil
                }

                if let terminalPanelId = workspace.focusedTerminalPanel?.id {
                    return terminalPanelId
                }

                if let terminalPanelId = workspace.terminalPanelForConfigInheritance()?.id {
                    return terminalPanelId
                }

                return workspace.panels.values
                    .compactMap { ($0 as? TerminalPanel)?.id }
                    .sorted(by: { $0.uuidString < $1.uuidString })
                    .first
            }

            if let surfaceId = resolvedSurfaceId() {
                completion(surfaceId)
                return
            }

            var resolved = false
            var focusObserver: NSObjectProtocol?
            var surfaceReadyObserver: NSObjectProtocol?
            var tabsCancellable: AnyCancellable?
            var panelsCancellable: AnyCancellable?
            var observedWorkspaceId: UUID?

            func cleanup() {
                if let focusObserver {
                    NotificationCenter.default.removeObserver(focusObserver)
                }
                if let surfaceReadyObserver {
                    NotificationCenter.default.removeObserver(surfaceReadyObserver)
                }
                tabsCancellable?.cancel()
                panelsCancellable?.cancel()
            }

            func attemptResolve() {
                guard !resolved else { return }
                if let workspace = tabManager.tabs.first(where: { $0.id == tabId }),
                   observedWorkspaceId != workspace.id {
                    observedWorkspaceId = workspace.id
                    panelsCancellable?.cancel()
                    panelsCancellable = workspace.$panels
                        .map { _ in () }
                        .sink { _ in MainActor.assumeIsolated { attemptResolve() } }
                }
                if let surfaceId = resolvedSurfaceId() {
                    resolved = true
                    cleanup()
                    completion(surfaceId)
                }
            }

            tabsCancellable = tabManager.$tabs
                .map { _ in () }
                .sink { _ in MainActor.assumeIsolated { attemptResolve() } }
            focusObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyDidFocusSurface,
                object: nil,
                queue: .main
            ) { note in
                guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                      candidateTabId == tabId else { return }
                MainActor.assumeIsolated { attemptResolve() }
            }
            surfaceReadyObserver = NotificationCenter.default.addObserver(
                forName: .terminalSurfaceDidBecomeReady,
                object: nil,
                queue: .main
            ) { note in
                guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                      workspaceId == tabId else { return }
                MainActor.assumeIsolated { attemptResolve() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !resolved {
                    cleanup()
                }
            }
            attemptResolve()
        }

        waitForContexts(minCount: 1) { [weak self] in
            guard let self else { return }
            guard let window1 = self.mainWindowContexts.values.first else { return }
            guard let tabId1 = window1.tabManager.selectedTabId ?? window1.tabManager.tabs.first?.id else { return }

            stamp("t1Window1Ready")
            // Create a second main terminal window.
            self.openNewMainWindow(nil)

            waitForContexts(minCount: 2) { [weak self] in
                guard let self else { return }
                stamp("t2Window2Ready")
                let contexts = Array(self.mainWindowContexts.values)
                guard let window2 = contexts.first(where: { $0.windowId != window1.windowId }) else { return }
                guard let tabId2 = window2.tabManager.selectedTabId ?? window2.tabManager.tabs.first?.id else { return }
                waitForSurfaceId(on: window1.tabManager, tabId: tabId1) { [weak self] surfaceId1 in
                    guard let self else { return }
                    stamp("t3Surface1Ready")
                    waitForSurfaceId(on: window2.tabManager, tabId: tabId2) { [weak self] surfaceId2 in
                    guard let self else { return }
                    stamp("t4Surface2Ready")
                    guard let store = self.notificationStore else { return }

                    // Ensure the target window is currently showing the Notifications overlay,
                    // so opening a notification must switch it back to the terminal UI.
                    window2.sidebarSelectionState.selection = .notifications

                    // Create notifications for both windows. Ensure W2 isn't suppressed just because it's focused.
                    let prevOverride = AppFocusState.overrideIsFocused
                    AppFocusState.overrideIsFocused = false
                    store.addNotification(tabId: tabId2, surfaceId: nil, title: "W2", subtitle: "multiwindow", body: "")
                    AppFocusState.overrideIsFocused = prevOverride

                    // Insert after W2 so it becomes "latest unread" (first in list).
                    store.addNotification(tabId: tabId1, surfaceId: nil, title: "W1", subtitle: "multiwindow", body: "")

                    let notif1 = store.notifications.first(where: { $0.tabId == tabId1 && $0.title == "W1" })
                    let notif2 = store.notifications.first(where: { $0.tabId == tabId2 && $0.title == "W2" })

                    self.writeMultiWindowNotificationTestData([
                        "window1Id": window1.windowId.uuidString,
                        "window2Id": window2.windowId.uuidString,
                        "window2InitialSidebarSelection": "notifications",
                        "tabId1": tabId1.uuidString,
                        "tabId2": tabId2.uuidString,
                        "surfaceId1": surfaceId1.uuidString,
                        "surfaceId2": surfaceId2.uuidString,
                        "notifId1": notif1?.id.uuidString ?? "",
                        "notifId2": notif2?.id.uuidString ?? "",
                        "expectedLatestWindowId": window1.windowId.uuidString,
                        "expectedLatestTabId": tabId1.uuidString,
                    ], at: path)
                    self.prepareMultiWindowNotificationSourceTerminalIfNeeded(
                        at: path,
                        windowId: window1.windowId,
                        tabManager: window1.tabManager,
                        tabId: tabId1,
                        surfaceId: surfaceId1
                    )
                    self.publishMultiWindowNotificationSocketStateIfNeeded(at: path)
                }
                }
            }
        }
    }

    private func prepareMultiWindowNotificationSourceTerminalIfNeeded(
        at path: String,
        windowId: UUID,
        tabManager: TabManager,
        tabId: UUID,
        surfaceId: UUID
    ) {
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_NOTIFY_SOURCE_TERMINAL_READY"] == "1" else { return }

        writeMultiWindowNotificationTestData([
            "sourceTerminalReady": "pending",
            "sourceTerminalFocusFailure": "",
        ], at: path)

        let focusStart = Date()
        let deadline = focusStart.addingTimeInterval(8.0)

        func publish(ready: Bool, failure: String = "") {
            writeMultiWindowNotificationTestData([
                "sourceTerminalReady": ready ? "1" : "0",
                "sourceTerminalFocusFailure": failure,
                "t5SourceFocusSeconds": String(format: "%.2f", Date().timeIntervalSince(focusStart)),
            ], at: path)
        }

        var resolved = false
        var observers: [NSObjectProtocol] = []
        var selectedTabCancellable: AnyCancellable?
        var panelsCancellable: AnyCancellable?

        func cleanup() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            selectedTabCancellable?.cancel()
            panelsCancellable?.cancel()
        }

        func attemptFocus() {
            guard !resolved else { return }
            guard let workspace = tabManager.tabs.first(where: { $0.id == tabId }) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "workspace_missing")
                return
            }
            guard let terminalPanel = workspace.terminalPanel(for: surfaceId) else {
                resolved = true
                cleanup()
                publish(ready: false, failure: "terminal_missing")
                return
            }

            let isWindowFrontmost = {
                guard let window = self.mainWindow(for: windowId) else { return false }
                return NSApp.keyWindow === window || NSApp.mainWindow === window
            }()
            if isWindowFrontmost && terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                resolved = true
                cleanup()
                publish(ready: true)
                return
            }

            guard Date() < deadline else {
                resolved = true
                cleanup()
                publish(
                    ready: false,
                    failure: isWindowFrontmost ? "terminal_not_first_responder" : "window_not_frontmost"
                )
                return
            }

            _ = self.focusMainWindow(windowId: windowId)
            if let tab = tabManager.tabs.first(where: { $0.id == tabId }) {
                tabManager.selectTab(tab)
                tabManager.focusSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .mainWindowContextsDidChange,
            object: self,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { attemptFocus() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            MainActor.assumeIsolated { attemptFocus() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { note in
            guard let candidateTabId = note.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
                  let candidateSurfaceId = note.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID,
                  candidateTabId == tabId,
                  candidateSurfaceId == surfaceId else { return }
            MainActor.assumeIsolated { attemptFocus() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { note in
            guard let workspaceId = note.userInfo?["workspaceId"] as? UUID,
                  let readySurfaceId = note.userInfo?["surfaceId"] as? UUID,
                  workspaceId == tabId,
                  readySurfaceId == surfaceId else { return }
            MainActor.assumeIsolated { attemptFocus() }
        })
        if let workspace = tabManager.tabs.first(where: { $0.id == tabId }) {
            panelsCancellable = workspace.$panels
                .dropFirst()
                .map { _ in () }
                .sink { _ in MainActor.assumeIsolated { attemptFocus() } }
        }
        selectedTabCancellable = tabManager.$selectedTabId
            .removeDuplicates()
            .dropFirst()
            .map { _ in () }
            .sink { _ in MainActor.assumeIsolated { attemptFocus() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            if !resolved {
                attemptFocus()
            }
        }
        attemptFocus()
    }

    private func publishMultiWindowNotificationSocketStateIfNeeded(at path: String) {
        let env = ProcessInfo.processInfo.environment
        guard env["PROGRAMA_UI_TEST_SOCKET_SANITY"] == "1" else { return }

        guard let config = socketListenerConfigurationIfEnabled() else {
            writeMultiWindowNotificationTestData([
                "socketExpectedPath": env["PROGRAMA_SOCKET_PATH"] ?? "",
                "socketMode": "off",
                "socketReady": "0",
                "socketPingResponse": "",
                "socketIsRunning": "0",
                "socketAcceptLoopAlive": "0",
                "socketPathMatches": "0",
                "socketPathExists": "0",
                "socketFailureSignals": "socket_disabled",
            ], at: path)
            return
        }

        writeMultiWindowNotificationTestData([
            "socketExpectedPath": config.path,
            "socketMode": config.mode.rawValue,
            "socketReady": "pending",
            "socketPingResponse": "",
        ], at: path)

        let socketPath = config.path
        let socketMode = config.mode.rawValue
        let observationState = SocketListenerUITestObservationState()

        func publishCurrentState(isTimedOut: Bool) {
            let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: socketPath)
            let dataPath = path
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let pingResponse = health.isHealthy
                    ? TerminalController.probeSocketPing(at: socketPath, timeout: 1.0)
                    : nil
                let isReady = health.isHealthy && pingResponse == "PONG"
                let failureSignals = {
                    var signals = health.failureSignals
                    if health.isHealthy && pingResponse != "PONG" {
                        signals.append("ping_timeout")
                    }
                    return signals.joined(separator: ",")
                }()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.writeMultiWindowNotificationTestData([
                        "socketExpectedPath": socketPath,
                        "socketMode": socketMode,
                        "socketReady": isReady ? "1" : (isTimedOut ? "0" : "pending"),
                        "socketPingResponse": pingResponse ?? "",
                        "socketIsRunning": health.isRunning ? "1" : "0",
                        "socketAcceptLoopAlive": health.acceptLoopAlive ? "1" : "0",
                        "socketPathMatches": health.socketPathMatches ? "1" : "0",
                        "socketPathExists": health.socketPathExists ? "1" : "0",
                        "socketFailureSignals": failureSignals,
                    ], at: dataPath)
                    guard isReady || isTimedOut else { return }
                    observationState.timeoutWorkItem?.cancel()
                    if let observer = observationState.observer {
                        NotificationCenter.default.removeObserver(observer)
                        observationState.observer = nil
                    }
                }
            }
        }

        observationState.observer = NotificationCenter.default.addObserver(
            forName: .socketListenerDidStart,
            object: TerminalController.shared,
            queue: .main
        ) { notification in
            let startedPath = notification.userInfo?["path"] as? String
            guard startedPath == socketPath else { return }
            MainActor.assumeIsolated {
                publishCurrentState(isTimedOut: false)
            }
        }

        let timeout = DispatchWorkItem {
            MainActor.assumeIsolated {
                publishCurrentState(isTimedOut: true)
            }
        }
        observationState.timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0, execute: timeout)

        restartSocketListenerIfEnabled(source: "uiTest.multiWindowNotifications.setup")
        publishCurrentState(isTimedOut: false)
    }

    func writeMultiWindowNotificationTestData(_ updates: [String: String], at path: String) {
        var payload = loadMultiWindowNotificationTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadMultiWindowNotificationTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }

    func recordMultiWindowNotificationFocusIfNeeded(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        sidebarSelection: SidebarSelection
    ) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PROGRAMA_UI_TEST_MULTI_WINDOW_NOTIF_PATH"], !path.isEmpty else { return }
        let sidebarSelectionString: String = {
            switch sidebarSelection {
            case .tabs: return "tabs"
            case .notifications: return "notifications"
            }
        }()
        writeMultiWindowNotificationTestData([
            "focusToken": UUID().uuidString,
            "focusedWindowId": windowId.uuidString,
            "focusedTabId": tabId.uuidString,
            "focusedSurfaceId": surfaceId?.uuidString ?? "",
            "focusedSidebarSelection": sidebarSelectionString,
        ], at: path)
    }
#endif
}
