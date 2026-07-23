// Extracted from Workspace.swift (nuclear-review #98): BonsplitDelegate conformance.

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

extension Workspace: @preconcurrency BonsplitDelegate {
    @MainActor
    private func shouldCloseWorkspaceOnLastSurface(for tabId: TabID) -> Bool {
        let manager = owningTabManager ?? AppDelegate.shared?.tabManagerFor(tabId: id) ?? AppDelegate.shared?.tabManager
        guard panels.count <= 1,
              panelIdFromSurfaceId(tabId) != nil,
              let manager,
              manager.tabs.contains(where: { $0.id == id }) else {
            return false
        }
        return true
    }

    @MainActor
    private func confirmClosePanel(for tabId: TabID) async -> Bool {
        let alert = NSAlert()

        alert.messageText = String(localized: "dialog.closeTab.title", defaultValue: "Close tab?")

        let panelName: String? = {
            guard let panelId = panelIdFromSurfaceId(tabId) else { return nil }
            if let custom = panelCustomTitles[panelId], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return custom
            }
            if let title = panelTitles[panelId], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            if let dir = panelDirectories[panelId], !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return (dir as NSString).lastPathComponent
            }
            return nil
        }()

        if let panelName {
            alert.informativeText = String(localized: "dialog.closeTab.messageNamed", defaultValue: "This will close \"\(panelName)\".")
        } else {
            alert.informativeText = String(localized: "dialog.closeTab.message", defaultValue: "This will close the current tab.")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "dialog.closeTab.close", defaultValue: "Close"))
        alert.addButton(withTitle: String(localized: "dialog.closeTab.cancel", defaultValue: "Cancel"))

        if let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "\r"
            closeButton.keyEquivalentModifierMask = []
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
            alert.window.initialFirstResponder = closeButton
        }
        if let cancelButton = alert.buttons.dropFirst().first {
            cancelButton.keyEquivalent = "\u{1b}"
        }

        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    func applyTabSelection(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool = true,
        focusIntent: PanelFocusIntent? = nil,
        previousTerminalHostedView: GhosttySurfaceScrollView? = nil
    ) {
        pendingTabSelection = PendingTabSelectionRequest(
            tabId: tabId,
            pane: pane,
            reassertAppKitFocus: reassertAppKitFocus,
            focusIntent: focusIntent,
            previousTerminalHostedView: previousTerminalHostedView
        )
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(
                tabId: request.tabId,
                inPane: request.pane,
                reassertAppKitFocus: request.reassertAppKitFocus,
                focusIntent: request.focusIntent,
                previousTerminalHostedView: request.previousTerminalHostedView
            )
        }
    }

    /// Hide browser portals for tabs that are no longer selected in the given pane.
    private func hideBrowserPortalsForDeselectedTabs(inPane pane: PaneID, selectedTabId: TabID) {
        for tab in bonsplitController.tabs(inPane: pane) {
            guard tab.id != selectedTabId else { continue }
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browserPanel = panels[panelId] as? BrowserPanel else { continue }
            browserPanel.hideBrowserPortalView(source: "tabDeselected")
        }
    }

    private func applyTabSelectionNow(
        tabId: TabID,
        inPane pane: PaneID,
        reassertAppKitFocus: Bool,
        focusIntent: PanelFocusIntent?,
        previousTerminalHostedView: GhosttySurfaceScrollView?
    ) {
        let previousFocusedPanelId = focusedPanelId
#if DEBUG
        let focusedPaneBefore = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabBefore = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.split.apply.begin workspace=\(id.uuidString.prefix(5)) " +
            "pane=\(pane.id.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5)) " +
            "focusedPane=\(focusedPaneBefore) selectedTab=\(selectedTabBefore) " +
            "reassert=\(reassertAppKitFocus ? 1 : 0)"
        )
#endif
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel, but keep the previously focused terminal active while a
        // newly created split terminal is still unattached.
        guard let selectedPanelId = panelIdFromSurfaceId(selectedTabId) else {
            return
        }
        let effectiveFocusedPanelId = effectiveSelectedPanelId(inPane: focusedPane) ?? selectedPanelId
        guard let panel = panels[effectiveFocusedPanelId] else {
            return
        }

        if debugStressPreloadSelectionDepth > 0 {
            if let terminalPanel = panel as? TerminalPanel {
                terminalPanel.requestViewReattach()
                scheduleTerminalGeometryReconcile()
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            return
        }

        if shouldTreatCurrentEventAsExplicitFocusIntent() {
            markExplicitFocusIntent(on: effectiveFocusedPanelId)
        }
        let activationIntent = focusIntent ?? panel.preferredFocusIntentForActivation()
        panel.prepareFocusIntentForActivation(activationIntent)
        let panelId = effectiveFocusedPanelId

        syncPinnedStateForTab(selectedTabId, panelId: selectedPanelId)
        syncUnreadBadgeStateForPanel(selectedPanelId)

        // Unfocus all other panels
        for (id, p) in panels where id != effectiveFocusedPanelId {
            p.unfocus()
        }

        // Explicitly hide browser portals for deselected tabs in this pane.
        // Bonsplit's keepAllAlive mode hides non-selected tabs via SwiftUI .opacity(0),
        // but portal-hosted WKWebViews render at the window level in AppKit and are not
        // affected by SwiftUI opacity. Without an explicit hide, the deselected browser's
        // portal layer can remain visible above the newly selected tab.
        hideBrowserPortalsForDeselectedTabs(inPane: focusedPane, selectedTabId: selectedTabId)

        if let focusWindow = activationWindow(for: panel) {
            yieldForeignOwnedFocusIfNeeded(
                in: focusWindow,
                targetPanelId: panelId,
                targetIntent: activationIntent
            )
        }

        activatePanel(
            panel,
            focusIntent: activationIntent,
            reassertAppKitFocus: reassertAppKitFocus
        )
        let focusIntentAllowsBrowserOmnibarAutofocus =
            shouldTreatCurrentEventAsExplicitFocusIntent() ||
            TerminalController.socketCommandAllowsInAppFocusMutations()
        if let browserPanel = panel as? BrowserPanel,
           shouldAllowBrowserOmnibarAutofocus(for: activationIntent),
           previousFocusedPanelId != panelId || focusIntentAllowsBrowserOmnibarAutofocus {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: .standard)
        }
        if let terminalPanel = panel as? TerminalPanel {
            rememberTerminalConfigInheritanceSource(terminalPanel)
        }
        // Unconditional: focus routes like Workspace.focusPanel move bonsplit focus
        // before this runs, so previousFocusedPanelId already equals panelId here.
        refreshWorkspaceTitleFromFocusedPanel()
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let markedAt = manualUnreadMarkedAt[panelId]
        if Self.shouldClearManualUnread(
            previousFocusedPanelId: previousFocusedPanelId,
            nextFocusedPanelId: panelId,
            isManuallyUnread: isManuallyUnread,
            markedAt: markedAt
        ) {
            triggerFocusFlash(panelId: panelId)
            let clearDelay = Self.manualUnreadClearDelayAfterFocusFlash
            if clearDelay <= 0 {
                clearManualUnread(panelId: panelId)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay) { [weak self] in
                    self?.clearManualUnread(panelId: panelId)
                }
            }
        }

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if reassertAppKitFocus, let terminalPanel = panel as? TerminalPanel {
            if shouldMoveTerminalSurfaceFocus(for: activationIntent),
               !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
#if DEBUG
                let previousExists = previousTerminalHostedView != nil ? 1 : 0
                dlog(
                    "focus.split.moveFocus workspace=\(id.uuidString.prefix(5)) " +
                    "panel=\(panelId.uuidString.prefix(5)) previousExists=\(previousExists) " +
                    "to=\(panelId.uuidString.prefix(5))"
                )
#endif
                terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
            }
#if DEBUG
            dlog(
                "focus.split.ensureFocus workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(focusedPane.id.uuidString.prefix(5)) " +
                "tab=\(selectedTabId.uuid.uuidString.prefix(5)) intent=\(String(describing: activationIntent))"
            )
#endif
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }

        if shouldRestoreFocusIntentAfterActivation(activationIntent) {
            _ = panel.restoreFocusIntent(activationIntent)
        }

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[panelId]
        pullRequest = panelPullRequests[panelId]

        // Post notification
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: self.id,
                GhosttyNotificationKey.surfaceId: panelId
            ]
        )
#if DEBUG
        let prevPanelShort = previousFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.split.apply.end workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) type=\(String(describing: type(of: panel))) " +
            "focusedPane=\(focusedPane.id.uuidString.prefix(5)) selectedTab=\(selectedTabId.uuid.uuidString.prefix(5)) " +
            "prevPanel=\(prevPanelShort)"
        )
#endif
    }

    private func activatePanel(
        _ panel: any Panel,
        focusIntent: PanelFocusIntent,
        reassertAppKitFocus: Bool
    ) {
        if let terminalPanel = panel as? TerminalPanel {
            let shouldFocusTerminalSurface = reassertAppKitFocus && shouldMoveTerminalSurfaceFocus(for: focusIntent)
            terminalPanel.surface.setFocus(shouldFocusTerminalSurface)
            terminalPanel.hostedView.setActive(true)
            if reassertAppKitFocus && shouldFocusTerminalSurface {
                terminalPanel.focus()
            }
            return
        }

        if let browserPanel = panel as? BrowserPanel {
            guard reassertAppKitFocus,
                  shouldFocusBrowserWebView(for: focusIntent) else { return }
            browserPanel.focus()
            return
        }

        if reassertAppKitFocus {
            panel.focus()
        }
    }

    private func activationWindow(for panel: any Panel) -> NSWindow? {
        if let terminalPanel = panel as? TerminalPanel {
            return terminalPanel.hostedView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        if let browserPanel = panel as? BrowserPanel {
            return browserPanel.webView.window ?? browserPanel.portalAnchorView.window ?? NSApp.keyWindow ?? NSApp.mainWindow
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    private func yieldForeignOwnedFocusIfNeeded(
        in window: NSWindow,
        targetPanelId: UUID,
        targetIntent: PanelFocusIntent
    ) {
        guard let firstResponder = window.firstResponder else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            guard let ownedIntent = panel.ownedFocusIntent(for: firstResponder, in: window) else { continue }
#if DEBUG
            dlog(
                "focus.handoff.begin workspace=\(id.uuidString.prefix(5)) " +
                "fromPanel=\(panelId.uuidString.prefix(5)) toPanel=\(targetPanelId.uuidString.prefix(5)) " +
                "fromIntent=\(String(describing: ownedIntent)) toIntent=\(String(describing: targetIntent))"
            )
#endif
            _ = panel.yieldFocusIntent(ownedIntent, in: window)
            return
        }
    }

    private func shouldMoveTerminalSurfaceFocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .terminal(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldFocusBrowserWebView(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField):
            return false
        default:
            return true
        }
    }

    private func shouldAllowBrowserOmnibarAutofocus(for intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.webView), .panel:
            return true
        default:
            return false
        }
    }

    private func shouldRestoreFocusIntentAfterActivation(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .browser(.addressBar), .browser(.findField), .terminal(.findField):
            return true
        case .panel, .browser(.webView), .terminal(.surface):
            return false
        }
    }

    func beginNonFocusSplitFocusReassert(
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> UInt64 {
        nonFocusSplitFocusReassertGeneration &+= 1
        let generation = nonFocusSplitFocusReassertGeneration
        pendingNonFocusSplitFocusReassert = PendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        return generation
    }

    func matchesPendingNonFocusSplitFocusReassert(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID
    ) -> Bool {
        guard let pending = pendingNonFocusSplitFocusReassert else { return false }
        return pending.generation == generation &&
            pending.preferredPanelId == preferredPanelId &&
            pending.splitPanelId == splitPanelId
    }

    func clearNonFocusSplitFocusReassert(generation: UInt64? = nil) {
        guard let pending = pendingNonFocusSplitFocusReassert else { return }
        if let generation, pending.generation != generation { return }
        pendingNonFocusSplitFocusReassert = nil
    }

    private func shouldTreatCurrentEventAsExplicitFocusIntent() -> Bool {
        guard let eventType = NSApp.currentEvent?.type else { return false }
        switch eventType {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel,
             .gesture, .magnify, .rotate, .swipe:
            return true
        default:
            return false
        }
    }

    func markExplicitFocusIntent(on panelId: UUID) {
        guard let pending = pendingNonFocusSplitFocusReassert,
              pending.splitPanelId == panelId else {
            return
        }
        pendingNonFocusSplitFocusReassert = nil
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseSelection() {
            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        let explicitUserClose = explicitUserCloseTabIds.remove(tab.id) != nil

        if forceCloseTabIds.contains(tab.id) {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        if let panelId = panelIdFromSurfaceId(tab.id),
           pinnedPanelIds.contains(panelId) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            NSSound.beep()
            return false
        }

        if explicitUserClose && shouldCloseWorkspaceOnLastSurface(for: tab.id) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            owningTabManager?.closeWorkspaceWithConfirmation(self)
            return false
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            stageClosedBrowserRestoreSnapshotIfNeeded(for: tab, inPane: pane)
            recordPostCloseSelection()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        if panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
            clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.pendingCloseConfirmTabIds.remove(tabId) }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else { return }

                    self.forceCloseTabIds.insert(tabId)
                    self.markTerminalCloseForUndoStagingIfEligible(tabId: tabId, panelId: panelId, paneId: pane)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        clearStagedClosedBrowserRestoreSnapshot(for: tab.id)
        recordPostCloseSelection()
        markTerminalCloseForUndoStagingIfEligible(tabId: tab.id, panelId: panelId, paneId: pane)
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)
        let closedBrowserRestoreSnapshot = pendingClosedBrowserRestoreSnapshots.removeValue(forKey: tabId)
        let undoStageOriginalIndex = pendingUndoStageOriginalIndex.removeValue(forKey: tabId)
        let isUndoStaging = undoStageOriginalIndex != nil
        let isDetaching = detachingTabIds.remove(tabId) != nil || isDetachingCloseTransaction || isUndoStaging

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            if !isDetaching {
                scheduleFocusReconcile()
            }
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let panel = panels[panelId]
        let transferredRemoteCleanupConfiguration = transferredRemoteCleanupConfigurationsByPanelId.removeValue(forKey: panelId)

        if isDetaching, let panel {
            let browserPanel = panel as? BrowserPanel
            let cachedTitle = panelTitles[panelId]
            let transferFallbackTitle = cachedTitle ?? panel.displayTitle
            pendingDetachedSurfaces[tabId] = DetachedSurfaceTransfer(
                panelId: panelId,
                panel: panel,
                title: resolvedPanelTitle(panelId: panelId, fallback: transferFallbackTitle),
                icon: panel.displayIcon,
                iconImageData: browserPanel?.faviconPNGData,
                kind: surfaceKind(for: panel),
                isLoading: browserPanel?.isLoading ?? false,
                isPinned: pinnedPanelIds.contains(panelId),
                directory: panelDirectories[panelId],
                ttyName: surfaceTTYNames[panelId],
                cachedTitle: cachedTitle,
                customTitle: panelCustomTitles[panelId],
                manuallyUnread: manualUnreadPanelIds.contains(panelId),
                isRemoteTerminal: activeRemoteTerminalSurfaceIds.contains(panelId),
                remoteRelayPort: activeRemoteTerminalSurfaceIds.contains(panelId)
                    ? remoteConfiguration?.relayPort
                    : nil,
                remoteCleanupConfiguration: transferredRemoteCleanupConfiguration
            )
            if isUndoStaging, let originalIndex = undoStageOriginalIndex,
               let staged = pendingDetachedSurfaces.removeValue(forKey: tabId) {
                onTerminalCloseStagedForUndo?(staged, pane, originalIndex)
            }
        } else {
            if let closedBrowserRestoreSnapshot {
                onClosedBrowserPanel?(closedBrowserRestoreSnapshot)
            }
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        untrackRemoteTerminalSurface(panelId)
        pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        removeSurfaceMetadata(panelId: panelId)
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        if !isDetaching, let transferredRemoteCleanupConfiguration {
            Self.requestSSHControlMasterCleanupIfNeeded(configuration: transferredRemoteCleanupConfiguration)
        }

        // Keep the workspace invariant for normal close paths.
        // Detach/move flows intentionally allow a temporary empty workspace so AppDelegate can
        // prune the source workspace/window after the tab is attached elsewhere.
        if panels.isEmpty {
            if isDetaching {
                scheduleTerminalGeometryReconcile()
                return
            }

            let replacement = createReplacementTerminalPanel()
            if let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        } else if let focusedPane = bonsplitController.focusedPaneId,
                  let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
            // When closing the last tab in a pane, Bonsplit may focus a different pane and skip
            // emitting didSelectTab. Re-apply the focused selection so sidebar state stays in sync.
            applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
        }

        if bonsplitController.allPaneIds.contains(pane) {
            normalizePinnedTabs(in: pane)
        }
        scheduleTerminalGeometryReconcile()
        if !isDetaching {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let sincePrev: String
        if debugLastDidMoveTabTimestamp > 0 {
            sincePrev = String(format: "%.2f", (now - debugLastDidMoveTabTimestamp) * 1000)
        } else {
            sincePrev = "first"
        }
        debugLastDidMoveTabTimestamp = now
        debugDidMoveTabEventCount += 1
        let movedPanelId = panelIdFromSurfaceId(tab.id)
        let movedPanel = movedPanelId?.uuidString.prefix(5) ?? "unknown"
        let selectedBefore = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneBefore = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelBefore = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        dlog(
            "split.moveTab idx=\(debugDidMoveTabEventCount) dtSincePrevMs=\(sincePrev) panel=\(movedPanel) " +
            "from=\(source.id.uuidString.prefix(5)) to=\(destination.id.uuidString.prefix(5)) " +
            "sourceTabs=\(controller.tabs(inPane: source).count) destTabs=\(controller.tabs(inPane: destination).count)"
        )
        dlog(
            "split.moveTab.state.before idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedBefore) focusedPane=\(focusedPaneBefore) focusedPanel=\(focusedPanelBefore)"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: destination)
#if DEBUG
        let movedPanelIdAfter = panelIdFromSurfaceId(tab.id)
#endif
        if let movedPanelId = panelIdFromSurfaceId(tab.id) {
            scheduleMovedTerminalRefresh(panelId: movedPanelId)
        }
#if DEBUG
        let selectedAfter = controller.selectedTab(inPane: destination)
            .map { String(String(describing: $0.id).prefix(5)) } ?? "nil"
        let focusedPaneAfter = controller.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let focusedPanelAfter = focusedPanelId?.uuidString.prefix(5) ?? "nil"
        let movedPanelFocused = (movedPanelIdAfter != nil && movedPanelIdAfter == focusedPanelId) ? 1 : 0
        dlog(
            "split.moveTab.state.after idx=\(debugDidMoveTabEventCount) panel=\(movedPanel) " +
            "destSelected=\(selectedAfter) focusedPane=\(focusedPaneAfter) focusedPanel=\(focusedPanelAfter) " +
            "movedFocused=\(movedPanelFocused)"
        )
#endif
        normalizePinnedTabs(in: source)
        normalizePinnedTabs(in: destination)
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        FocusLogStore.shared.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    /// Canonical per-panel metadata teardown shared by every close path.
    /// The single-surface and pane-close paths previously hand-copied this
    /// list and drifted (pane close leaked inheritance font points and never
    /// cleared notifications). Aggregate recomputes (syncRemotePortScanTTYs,
    /// recomputeListeningPorts) stay at the call sites.
    private func removeSurfaceMetadata(panelId: UUID) {
        panelDirectories.removeValue(forKey: panelId)
        panelGitBranches.removeValue(forKey: panelId)
        panelPullRequests.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelCustomTitles.removeValue(forKey: panelId)
        pinnedPanelIds.remove(panelId)
        manualUnreadPanelIds.remove(panelId)
        manualUnreadMarkedAt.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)
        panelShellActivityStates.removeValue(forKey: panelId)
        surfaceTTYNames.removeValue(forKey: panelId)
        surfaceListeningPorts.removeValue(forKey: panelId)
        restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        terminalInheritanceFontPointsByPanelId.removeValue(forKey: panelId)
        if lastTerminalConfigInheritancePanelId == panelId {
            lastTerminalConfigInheritancePanelId = nil
        }
        PortScanner.shared.unregisterPanel(workspaceId: id, panelId: panelId)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: id, surfaceId: panelId)
        if progressSourcePanelId == panelId {
            progress = nil
            progressSourcePanelId = nil
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        let closedPanelIds = pendingPaneClosePanelIds.removeValue(forKey: paneId.id) ?? []
        let shouldScheduleFocusReconcile = !isDetachingCloseTransaction

        if !closedPanelIds.isEmpty {
            for panelId in closedPanelIds {
                panels[panelId]?.close()
                panels.removeValue(forKey: panelId)
                untrackRemoteTerminalSurface(panelId)
                pendingRemoteTerminalChildExitSurfaceIds.remove(panelId)
                removeSurfaceMetadata(panelId: panelId)
            }

            syncRemotePortScanTTYs()
            let closedSet = Set(closedPanelIds)
            surfaceIdToPanelId = surfaceIdToPanelId.filter { !closedSet.contains($0.value) }
            recomputeListeningPorts()
            clearRemoteConfigurationIfWorkspaceBecameLocal()

            if let focusedPane = bonsplitController.focusedPaneId,
               let focusedTabId = bonsplitController.selectedTab(inPane: focusedPane)?.id {
                applyTabSelection(tabId: focusedTabId, inPane: focusedPane)
            } else if shouldScheduleFocusReconcile {
                scheduleFocusReconcile()
            }
        }

        scheduleTerminalGeometryReconcile()
        if shouldScheduleFocusReconcile {
            scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               let terminalPanel = terminalPanel(for: panelId),
               panelNeedsConfirmClose(panelId: panelId, fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()) {
                pendingPaneClosePanelIds.removeValue(forKey: pane.id)
                return false
            }
        }
        pendingPaneClosePanelIds[pane.id] = tabs.compactMap { panelIdFromSurfaceId($0.id) }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
#if DEBUG
        let panelKindForTab: (TabID) -> String = { tabId in
            guard let panelId = self.panelIdFromSurfaceId(tabId),
                  let panel = self.panels[panelId] else { return "placeholder" }
            if panel is TerminalPanel { return "terminal" }
            if panel is BrowserPanel { return "browser" }
            return String(describing: type(of: panel))
        }
        let paneKindSummary: (PaneID) -> String = { paneId in
            let tabs = controller.tabs(inPane: paneId)
            guard !tabs.isEmpty else { return "-" }
            return tabs.map { tab in
                String(panelKindForTab(tab.id).prefix(1))
            }.joined(separator: ",")
        }
        let originalSelectedKind = controller.selectedTab(inPane: originalPane).map { panelKindForTab($0.id) } ?? "none"
        let newSelectedKind = controller.selectedTab(inPane: newPane).map { panelKindForTab($0.id) } ?? "none"
        dlog(
            "split.didSplit original=\(originalPane.id.uuidString.prefix(5)) new=\(newPane.id.uuidString.prefix(5)) " +
            "orientation=\(orientation) programmatic=\(isProgrammaticSplit ? 1 : 0) " +
            "originalTabs=\(controller.tabs(inPane: originalPane).count) newTabs=\(controller.tabs(inPane: newPane).count) " +
            "originalSelected=\(originalSelectedKind) newSelected=\(newSelectedKind) " +
            "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
        )
#endif
        let rearmBrowserPortalHostReplacement: (PaneID, String) -> Void = { paneId, reason in
            for tab in controller.tabs(inPane: paneId) {
                guard let panelId = self.panelIdFromSurfaceId(tab.id),
                      let browserPanel = self.browserPanel(for: panelId) else {
                    continue
                }
                browserPanel.preparePortalHostReplacementForNextDistinctClaim(
                    inPane: paneId,
                    reason: reason
                )
            }
        }
        rearmBrowserPortalHostReplacement(originalPane, "workspace.didSplit.original")
        rearmBrowserPortalHostReplacement(newPane, "workspace.didSplit.new")

        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
#if DEBUG
            dlog(
                "split.didSplit.drag original=\(originalPane.id.uuidString.prefix(5)) " +
                "new=\(newPane.id.uuidString.prefix(5)) originalTabs=\(originalTabs.count) " +
                "newTabs=\(controller.tabs(inPane: newPane).count) hasRealSurface=\(hasRealSurface ? 1 : 0) " +
                "originalKinds=[\(paneKindSummary(originalPane))] newKinds=[\(paneKindSummary(newPane))]"
            )
#endif
            if !hasRealSurface {
                let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
#if DEBUG
                dlog(
                    "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                    "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
                )
#endif
                if let replacementTab = placeholderTabs.first {
                    // Keep the existing placeholder tab identity and replace only the panel mapping.
                    // This avoids an extra create+close tab churn that can transiently render an
                    // empty pane during drag-to-split of a single-tab pane.
                    let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

                    let replacementPanel = TerminalPanel(
                        workspaceId: id,
                        context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                        configTemplate: inheritedConfig,
                        portOrdinal: portOrdinal
                    )
                    configureTerminalPanel(replacementPanel)
                    panels[replacementPanel.id] = replacementPanel
                    panelTitles[replacementPanel.id] = replacementPanel.displayTitle
                    seedTerminalInheritanceFontPoints(panelId: replacementPanel.id, configTemplate: inheritedConfig)
                    surfaceIdToPanelId[replacementTab.id] = replacementPanel.id

                    bonsplitController.updateTab(
                        replacementTab.id,
                        title: replacementPanel.displayTitle,
                        icon: .some(replacementPanel.displayIcon),
                        iconImageData: .some(nil),
                        kind: .some(SurfaceKind.terminal),
                        hasCustomTitle: false,
                        isDirty: replacementPanel.isDirty,
                        showsNotificationBadge: false,
                        isLoading: false,
                        isPinned: false
                    )

                    for extraPlaceholder in placeholderTabs.dropFirst() {
                        bonsplitController.closeTab(extraPlaceholder.id)
                    }
                } else {
#if DEBUG
                    dlog(
                        "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                        "fallback=createTerminalAndDropPlaceholders"
                    )
#endif
                    _ = newTerminalSurface(inPane: originalPane, focus: false)
                    for tab in controller.tabs(inPane: originalPane) {
                        if panelIdFromSurfaceId(tab.id) == nil {
                            bonsplitController.closeTab(tab.id)
                        }
                    }
                }
            }
            normalizePinnedTabs(in: originalPane)
            normalizePinnedTabs(in: newPane)
            scheduleTerminalGeometryReconcile()
            return
        }

        // Mirror Cmd+D behavior: split buttons should always seed a terminal in the new pane.
        // When the focused source is a browser, inherit terminal config from nearby terminals
        // (or fall back to defaults) instead of leaving an empty selector pane.
        let sourceTabId = controller.selectedTab(inPane: originalPane)?.id
        let sourcePanelId = sourceTabId.flatMap { panelIdFromSurfaceId($0) }

#if DEBUG
        dlog(
            "split.didSplit.autoCreate pane=\(newPane.id.uuidString.prefix(5)) " +
            "fromPane=\(originalPane.id.uuidString.prefix(5)) sourcePanel=\(sourcePanelId.map { String($0.uuidString.prefix(5)) } ?? "none")"
        )
#endif

        let inheritedConfig = inheritedTerminalConfig(
            preferredPanelId: sourcePanelId,
            inPane: originalPane
        )

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig,
            portOrdinal: portOrdinal
        )
        configureTerminalPanel(newPanel)
        panels[newPanel.id] = newPanel
        panelTitles[newPanel.id] = newPanel.displayTitle
        seedTerminalInheritanceFontPoints(panelId: newPanel.id, configTemplate: inheritedConfig)

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            kind: SurfaceKind.terminal,
            isDirty: newPanel.isDirty,
            isPinned: false,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            panelTitles.removeValue(forKey: newPanel.id)
            terminalInheritanceFontPointsByPanelId.removeValue(forKey: newPanel.id)
            return
        }

        surfaceIdToPanelId[newTabId] = newPanel.id
        normalizePinnedTabs(in: newPane)
#if DEBUG
        dlog(
            "split.didSplit.autoCreate.done pane=\(newPane.id.uuidString.prefix(5)) " +
            "panel=\(newPanel.id.uuidString.prefix(5))"
        )
#endif

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {
        switch kind {
        case "terminal":
            _ = newTerminalSurface(inPane: pane)
        case "browser":
            _ = newBrowserSurface(inPane: pane)
        default:
            _ = newTerminalSurface(inPane: pane)
        }
    }

    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {
        switch action {
        case .rename:
            promptRenamePanel(tabId: tab.id)
        case .clearName:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            setPanelCustomTitle(panelId: panelId, title: nil)
        case .closeToLeft:
            closeTabs(tabIdsToLeft(of: tab.id, inPane: pane))
        case .closeToRight:
            closeTabs(tabIdsToRight(of: tab.id, inPane: pane))
        case .closeOthers:
            closeTabs(tabIdsToCloseOthers(of: tab.id, inPane: pane))
        case .move:
            promptMovePanel(tabId: tab.id)
        case .moveToLeftPane:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let targetPane = controller.adjacentPane(to: pane, direction: .left) else { return }
            moveSurface(panelId: panelId, toPane: targetPane)
        case .moveToRightPane:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let targetPane = controller.adjacentPane(to: pane, direction: .right) else { return }
            moveSurface(panelId: panelId, toPane: targetPane)
        case .newTerminalToRight:
            createTerminalToRight(of: tab.id, inPane: pane)
        case .newBrowserToRight:
            createBrowserToRight(of: tab.id, inPane: pane)
        case .reload:
            guard let panelId = panelIdFromSurfaceId(tab.id),
                  let browser = browserPanel(for: panelId) else { return }
            browser.reload()
        case .duplicate:
            duplicateBrowserToRight(anchorTabId: tab.id, inPane: pane)
        case .togglePin:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            let shouldPin = !pinnedPanelIds.contains(panelId)
            setPanelPinned(panelId: panelId, pinned: shouldPin)
        case .markAsRead:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            clearManualUnread(panelId: panelId)
        case .markAsUnread:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            markPanelUnread(panelId)
        case .toggleZoom:
            guard let panelId = panelIdFromSurfaceId(tab.id) else { return }
            toggleSplitZoom(panelId: panelId)
        @unknown default:
            break
        }
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        tmuxLayoutSnapshot = snapshot
        scheduleTerminalGeometryReconcile()
        if !isDetachingCloseTransaction {
            scheduleFocusReconcile()
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
