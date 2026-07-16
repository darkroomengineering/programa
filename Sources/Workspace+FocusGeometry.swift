// Extracted from Workspace.swift (nuclear-review #98): focus/geometry reconciliation members
// (non-focus-split focus preservation, focusPanel, attention flashes, portal lifecycle, and the
// event-driven layout follow-up / terminal-geometry / portal-visibility reconciliation pipeline).

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

extension Workspace {
    func preserveFocusAfterNonFocusSplit(
        preferredPanelId: UUID?,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?
    ) {
        guard let preferredPanelId, panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert()
            scheduleFocusReconcile()
            return
        }

        let generation = beginNonFocusSplitFocusReassert(
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        )
        let focusTransitionRequest: FocusTransitionCoordinator.Request? = {
            guard let owningTabManager,
                  let panel = panels[preferredPanelId] else {
                return nil
            }
            let owner = FocusTransitionCoordinator.Owner(
                workspaceID: id,
                panelID: preferredPanelId,
                intent: panel.preferredFocusIntentForActivation()
            )
            return owningTabManager.focusTransitionCoordinator.captureCurrentGeneration(
                for: owner,
                reason: .nonFocusSplit
            )
        }()

        // Bonsplit splitPane focuses the newly created pane and may emit one delayed
        // didSelect/didFocus callback. Re-assert focus over multiple turns so model
        // focus and AppKit first responder stay aligned with non-focus-intent splits.
        reassertFocusAfterNonFocusSplit(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId,
            previousHostedView: previousHostedView,
            allowPreviousHostedView: true,
            focusTransitionRequest: focusTransitionRequest
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reassertFocusAfterNonFocusSplit(
                generation: generation,
                preferredPanelId: preferredPanelId,
                splitPanelId: splitPanelId,
                previousHostedView: previousHostedView,
                allowPreviousHostedView: false,
                focusTransitionRequest: focusTransitionRequest
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reassertFocusAfterNonFocusSplit(
                    generation: generation,
                    preferredPanelId: preferredPanelId,
                    splitPanelId: splitPanelId,
                    previousHostedView: previousHostedView,
                    allowPreviousHostedView: false,
                    focusTransitionRequest: focusTransitionRequest
                )
                self.scheduleFocusReconcile()
                self.clearNonFocusSplitFocusReassert(generation: generation)
            }
        }
    }

    func reassertFocusAfterNonFocusSplit(
        generation: UInt64,
        preferredPanelId: UUID,
        splitPanelId: UUID,
        previousHostedView: GhosttySurfaceScrollView?,
        allowPreviousHostedView: Bool,
        focusTransitionRequest: FocusTransitionCoordinator.Request?
    ) {
        guard matchesPendingNonFocusSplitFocusReassert(
            generation: generation,
            preferredPanelId: preferredPanelId,
            splitPanelId: splitPanelId
        ) else {
            return
        }

        if let focusTransitionRequest,
           owningTabManager?.focusTransitionCoordinator.isCurrentGeneration(focusTransitionRequest) != true {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        guard panels[preferredPanelId] != nil else {
            clearNonFocusSplitFocusReassert(generation: generation)
            return
        }

        if focusedPanelId == splitPanelId {
            let shouldReassertAppKitFocus = owningTabManager.map { $0.selectedTabId == id } ?? true
            focusPanel(
                preferredPanelId,
                previousHostedView: allowPreviousHostedView ? previousHostedView : nil,
                reassertAppKitFocus: shouldReassertAppKitFocus
            )
            return
        }

        guard focusedPanelId == preferredPanelId,
              let terminalPanel = terminalPanel(for: preferredPanelId) else {
            return
        }
        if let owningTabManager, owningTabManager.selectedTabId != id {
            return
        }
        terminalPanel.hostedView.ensureFocus(for: id, surfaceId: preferredPanelId)
    }

    func focusPanel(
        _ panelId: UUID,
        previousHostedView: GhosttySurfaceScrollView? = nil,
        reassertAppKitFocus: Bool = true,
        trigger: FocusPanelTrigger = .standard
    ) {
        markExplicitFocusIntent(on: panelId)
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil"
        let triggerLabel = trigger == .terminalFirstResponder ? "firstResponder" : "standard"
        dlog("focus.panel panel=\(panelId.uuidString.prefix(5)) pane=\(pane) trigger=\(triggerLabel)")
        FocusLogStore.shared.append(
            "Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane) trigger=\(triggerLabel)"
        )
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()
        let shouldSuppressReentrantRefocus = trigger == .terminalFirstResponder && selectionAlreadyConverged
#if DEBUG
        let targetPaneShort = targetPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let focusedPaneShort = bonsplitController.focusedPaneId.map { String($0.id.uuidString.prefix(5)) } ?? "nil"
        let selectedTabShort = bonsplitController.focusedPaneId
            .flatMap { bonsplitController.selectedTab(inPane: $0)?.id }
            .map { String($0.uuid.uuidString.prefix(5)) } ?? "nil"
        let currentPanelShort = currentlyFocusedPanelId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        dlog(
            "focus.panel.begin workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) trigger=\(String(describing: trigger)) " +
            "targetPane=\(targetPaneShort) focusedPane=\(focusedPaneShort) selectedTab=\(selectedTabShort) " +
            "converged=\(selectionAlreadyConverged ? 1 : 0) " +
            "currentPanel=\(currentPanelShort)"
        )
        if shouldSuppressReentrantRefocus {
            dlog(
                "focus.panel.skipReentrant panel=\(panelId.uuidString.prefix(5)) " +
                "reason=firstResponderAlreadyConverged"
            )
        }
#endif

        if let targetPaneId, !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.focusPane workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) pane=\(targetPaneId.id.uuidString.prefix(5))"
            )
#endif
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
#if DEBUG
            dlog(
                "focus.panel.selectTab workspace=\(id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) tab=\(tabId.uuid.uuidString.prefix(5))"
            )
#endif
            bonsplitController.selectTab(tabId)
        }

        if let targetPaneId {
            let activationIntent = panels[panelId]?.preferredFocusIntentForActivation()
            applyTabSelection(
                tabId: tabId,
                inPane: targetPaneId,
                reassertAppKitFocus: reassertAppKitFocus && !shouldSuppressReentrantRefocus,
                focusIntent: activationIntent,
                previousTerminalHostedView: previousTerminalHostedView
            )
        }

        if reassertAppKitFocus,
           let browserPanel = panels[panelId] as? BrowserPanel {
            maybeAutoFocusBrowserAddressBarOnPanelFocus(browserPanel, trigger: trigger)
        }

        if trigger == .terminalFirstResponder,
           panels[panelId] is TerminalPanel {
            beginEventDrivenLayoutFollowUp(
                reason: "workspace.focusPanel.terminal",
                terminalFocusPanelId: panelId
            )
        }
    }

    func maybeAutoFocusBrowserAddressBarOnPanelFocus(
        _ browserPanel: BrowserPanel,
        trigger: FocusPanelTrigger
    ) {
        guard trigger == .standard else { return }
        guard !isCommandPaletteVisibleForWorkspaceWindow() else { return }
        guard !browserPanel.shouldSuppressOmnibarAutofocus() else { return }
        guard browserPanel.isShowingNewTabPage || browserPanel.preferredURLStringForOmnibar() == nil else { return }

        _ = browserPanel.requestAddressBarFocus()
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: browserPanel.id)
    }

    func isCommandPaletteVisibleForWorkspaceWindow() -> Bool {
        guard let app = AppDelegate.shared else {
            return false
        }

        if let manager = app.tabManagerFor(tabId: id),
           let windowId = app.windowId(for: manager),
           let window = app.mainWindow(for: windowId),
           app.isCommandPaletteVisible(for: window) {
            return true
        }

        if let keyWindow = NSApp.keyWindow, app.isCommandPaletteVisible(for: keyWindow) {
            return true
        }
        if let mainWindow = NSApp.mainWindow, app.isCommandPaletteVisible(for: mainWindow) {
            return true
        }
        return false
    }

    func moveFocus(direction: NavigationDirection) {
        // If a pane is zoomed, un-zoom before navigating so the target
        // pane becomes visible — matches tmux behavior (#1605).
        if bonsplitController.isSplitZoomed {
            _ = clearSplitZoom(reason: "workspace.moveFocus")
        }
        let previousFocusedPanelId = focusedPanelId

        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = previousFocusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }

    }

    func triggerFocusFlash(panelId: UUID) {
        requestAttentionFlash(panelId: panelId, reason: .navigation)
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard terminalPanel(for: panelId) != nil else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        requestAttentionFlash(panelId: panelId, reason: .notificationArrival)
    }

    func triggerNotificationDismissFlash(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }
        requestAttentionFlash(panelId: panelId, reason: .notificationDismiss)
    }

    func triggerDebugFlash(panelId: UUID) {
        guard panels[panelId] != nil else { return }
        focusPanel(panelId)
        requestAttentionFlash(panelId: panelId, reason: .debug)
    }

    /// Hide all terminal portal views for this workspace.
    /// Called before the workspace is unmounted to prevent portal-hosted terminal
    /// views from covering browser panes in the newly selected workspace.
    func hideAllTerminalPortalViews() {
        for panel in panels.values {
            guard let terminal = panel as? TerminalPanel else { continue }
            terminal.hostedView.setVisibleInUI(false)
            TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
        }
    }

    func hideAllBrowserPortalViews() {
        for panel in panels.values {
            guard let browser = panel as? BrowserPanel else { continue }
            browser.hideBrowserPortalView(source: "workspaceRetire")
        }
    }

    func reconcileFocusState() {
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
        if let dir = panelDirectories[targetPanelId] {
            currentDirectory = dir
        }
        gitBranch = panelGitBranches[targetPanelId]
        pullRequest = panelPullRequests[targetPanelId]
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    func scheduleFocusReconcile() {
#if DEBUG
        if isDetachingCloseTransaction {
            debugFocusReconcileScheduledDuringDetachCount += 1
        }
#endif
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    func beginEventDrivenLayoutFollowUp(
        reason: String,
        browserPanelId: UUID? = nil,
        browserExitFocusPanelId: UUID? = nil,
        terminalFocusPanelId: UUID? = nil,
        includeGeometry: Bool = false
    ) {
        layoutFollowUpReason = reason
        if let browserPanelId {
            layoutFollowUpBrowserPanelId = browserPanelId
        }
        if let browserExitFocusPanelId {
            layoutFollowUpBrowserExitFocusPanelId = browserExitFocusPanelId
        }
        if let terminalFocusPanelId {
            layoutFollowUpTerminalFocusPanelId = terminalFocusPanelId
        }
        layoutFollowUpNeedsGeometryPass = layoutFollowUpNeedsGeometryPass || includeGeometry
        layoutFollowUpStalledAttemptCount = 0
        // Invalidate any pending retry whose delay was computed from a stale stall count.
        // Incrementing the version causes old closures to exit early; clearing the flag
        // allows scheduleLayoutFollowUpAttempt() below to enqueue a fresh asyncAfter(0).
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false

        if layoutFollowUpTimeoutWorkItem == nil {
            installLayoutFollowUpObservers()
        }
        refreshLayoutFollowUpTimeout()
        // Use async scheduling instead of a synchronous call here. beginEventDrivenLayoutFollowUp
        // is often invoked from splitTabBar(_:didChangeGeometry:), which fires from inside
        // SwiftUI's .onChange(of: geometry) during an active layout pass. Calling
        // attemptEventDrivenLayoutFollowUp() synchronously in that context causes
        // flushWorkspaceWindowLayouts() → displayIfNeeded() to be called re-entrantly,
        // incrementing AppKit's per-window constraint-pass counter on every display cycle
        // until it exceeds the limit and crashes with NSGenericException.
        // scheduleLayoutFollowUpAttempt() defers via asyncAfter(0) so the flush always
        // happens after the current layout pass completes.
        scheduleLayoutFollowUpAttempt()
    }

    func installLayoutFollowUpObservers() {
        guard layoutFollowUpTimeoutWorkItem == nil else { return }

        let enqueueAttempt: () -> Void = { [weak self] in
            self?.scheduleLayoutFollowUpAttempt()
        }

        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceDidBecomeReady,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalSurfaceHostedViewDidMoveToWindow,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .terminalPortalVisibilityDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidBecomeFirstResponderSurface,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpObservers.append(NotificationCenter.default.addObserver(
            forName: .browserDidBecomeFirstResponderWebView,
            object: nil,
            queue: .main
        ) { _ in
            enqueueAttempt()
        })
        layoutFollowUpPanelsCancellable = $panels
            .map { _ in () }
            .sink { _ in
                enqueueAttempt()
            }
    }

    func refreshLayoutFollowUpTimeout() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearLayoutFollowUp()
        }
        layoutFollowUpTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    func clearLayoutFollowUp() {
        layoutFollowUpTimeoutWorkItem?.cancel()
        layoutFollowUpTimeoutWorkItem = nil
        layoutFollowUpObservers.forEach { NotificationCenter.default.removeObserver($0) }
        layoutFollowUpObservers.removeAll()
        layoutFollowUpPanelsCancellable?.cancel()
        layoutFollowUpPanelsCancellable = nil
        layoutFollowUpReason = nil
        layoutFollowUpTerminalFocusPanelId = nil
        layoutFollowUpBrowserPanelId = nil
        layoutFollowUpBrowserExitFocusPanelId = nil
        layoutFollowUpNeedsGeometryPass = false
        layoutFollowUpAttemptVersion &+= 1
        layoutFollowUpAttemptScheduled = false
        layoutFollowUpStalledAttemptCount = 0
    }

    func scheduleLayoutFollowUpAttempt() {
        guard layoutFollowUpTimeoutWorkItem != nil else { return }
        guard !layoutFollowUpAttemptScheduled else { return }

        layoutFollowUpAttemptScheduled = true
        let delay = layoutFollowUpBackoffDelay()
        let version = layoutFollowUpAttemptVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.layoutFollowUpAttemptVersion == version else { return }
            self.layoutFollowUpAttemptScheduled = false
            self.attemptEventDrivenLayoutFollowUp()
        }
    }

    func layoutFollowUpBackoffDelay() -> TimeInterval {
        guard layoutFollowUpStalledAttemptCount > 0 else { return 0 }
        let baseDelay: TimeInterval = 0.01
        let exponent = min(layoutFollowUpStalledAttemptCount - 1, 5)
        return min(0.25, baseDelay * pow(2.0, Double(exponent)))
    }

    func flushWorkspaceWindowLayouts() {
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
    }

    func browserPortalAnchorReady(for browserPanel: BrowserPanel) -> Bool {
        let anchorView = browserPanel.portalAnchorView
        return
            anchorView.window != nil &&
            anchorView.superview != nil &&
            anchorView.bounds.width > 1 &&
            anchorView.bounds.height > 1
    }

    func browserPortalReady(for browserPanel: BrowserPanel) -> Bool {
        browserPortalAnchorReady(for: browserPanel) &&
            browserPanel.webView.window != nil &&
            browserPanel.webView.superview != nil &&
            BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: browserPanel.portalAnchorView)
    }

    func browserSplitZoomExitFocusNeedsFollowUp(panelId: UUID) -> Bool {
        guard let browserPanel = browserPanel(for: panelId),
              let paneId = paneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else {
            return false
        }
        let selectionConverged =
            bonsplitController.focusedPaneId == paneId &&
            bonsplitController.selectedTab(inPane: paneId)?.id == tabId
        return !selectionConverged || !browserPortalAnchorReady(for: browserPanel)
    }

    func terminalFocusNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpTerminalFocusPanelId,
              let terminalPanel = terminalPanel(for: panelId) else {
            return false
        }
        return focusedPanelId != panelId || !terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    func browserPanelNeedsFollowUp() -> Bool {
        guard let panelId = layoutFollowUpBrowserPanelId,
              let browserPanel = browserPanel(for: panelId) else {
            return false
        }
        return !browserPortalReady(for: browserPanel)
    }

    func attemptEventDrivenLayoutFollowUp() {
        guard layoutFollowUpTimeoutWorkItem != nil, !isAttemptingLayoutFollowUp else { return }
        isAttemptingLayoutFollowUp = true
        defer { isAttemptingLayoutFollowUp = false }

        flushWorkspaceWindowLayouts()

        let geometryPendingBefore = layoutFollowUpNeedsGeometryPass
        let terminalPortalPendingBefore = terminalPortalVisibilityNeedsFollowUp()
        let browserVisibilityPendingBefore = browserPortalVisibilityNeedsFollowUp()
        let terminalFocusPendingBefore = terminalFocusNeedsFollowUp()
        let browserPanelPendingBefore = browserPanelNeedsFollowUp()
        let browserExitPendingBefore = layoutFollowUpBrowserExitFocusPanelId != nil

        if layoutFollowUpNeedsGeometryPass {
            layoutFollowUpNeedsGeometryPass = reconcileTerminalGeometryPass()
        }

        if let terminalFocusPanelId = layoutFollowUpTerminalFocusPanelId {
            if let terminalPanel = terminalPanel(for: terminalFocusPanelId),
               focusedPanelId == terminalFocusPanelId {
                terminalPanel.hostedView.ensureFocus(for: id, surfaceId: terminalFocusPanelId)
                if terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    layoutFollowUpTerminalFocusPanelId = nil
                }
            } else if terminalPanel(for: terminalFocusPanelId) == nil {
                layoutFollowUpTerminalFocusPanelId = nil
            }
        }

        reconcileTerminalPortalVisibilityForCurrentRenderedLayout()
        let terminalPortalPending = terminalPortalVisibilityNeedsFollowUp()

        let reason = layoutFollowUpReason ?? "workspace.layout"
        reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: reason)
        let browserVisibilityPending = browserPortalVisibilityNeedsFollowUp()

        if let browserPanelId = layoutFollowUpBrowserPanelId {
            if let browserPanel = browserPanel(for: browserPanelId) {
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let wasReady = browserPortalReady(for: browserPanel)
                if anchorReady && !wasReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(browserPanel.portalAnchorView)
                }
                let isReady = browserPortalReady(for: browserPanel)
                if isReady,
                   (!wasReady || BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)?.containerHidden == true) {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                }
                if isReady {
                    layoutFollowUpBrowserPanelId = nil
                }
            } else {
                layoutFollowUpBrowserPanelId = nil
            }
        }

        if let browserExitFocusPanelId = layoutFollowUpBrowserExitFocusPanelId {
            if browserSplitZoomExitFocusNeedsFollowUp(panelId: browserExitFocusPanelId) {
                if browserPanel(for: browserExitFocusPanelId) != nil {
                    focusPanel(browserExitFocusPanelId)
                    scheduleFocusReconcile()
                } else {
                    layoutFollowUpBrowserExitFocusPanelId = nil
                }
            } else {
                layoutFollowUpBrowserExitFocusPanelId = nil
            }
        }

        let terminalFocusPending = terminalFocusNeedsFollowUp()
        let browserPanelPending = browserPanelNeedsFollowUp()
        let browserExitPending = layoutFollowUpBrowserExitFocusPanelId != nil
        let needsMoreWork =
            layoutFollowUpNeedsGeometryPass ||
            terminalPortalPending ||
            browserVisibilityPending ||
            terminalFocusPending ||
            browserPanelPending ||
            browserExitPending

        if !needsMoreWork {
            clearLayoutFollowUp()
            return
        }

        let didMakeProgress =
            (geometryPendingBefore && !layoutFollowUpNeedsGeometryPass) ||
            (terminalPortalPendingBefore && !terminalPortalPending) ||
            (browserVisibilityPendingBefore && !browserVisibilityPending) ||
            (terminalFocusPendingBefore && !terminalFocusPending) ||
            (browserPanelPendingBefore && !browserPanelPending) ||
            (browserExitPendingBefore && !browserExitPending)

        if didMakeProgress {
            layoutFollowUpStalledAttemptCount = 0
            scheduleLayoutFollowUpAttempt()
        } else {
            layoutFollowUpStalledAttemptCount += 1
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    func reconcileTerminalGeometryPass() -> Bool {
        var needsFollowUpPass = false

        // Flush pending AppKit layout first so terminal-host bounds reflect latest split topology.
        for window in NSApp.windows {
            window.contentView?.layoutSubtreeIfNeeded()
        }

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let hostedView = terminalPanel.hostedView
            let hasUsableBounds = hostedView.bounds.width > 1 && hostedView.bounds.height > 1
            let hasSurface = terminalPanel.surface.surface != nil
            let isAttached = hostedView.window != nil && hostedView.superview != nil

            // Split close/reparent churn can transiently detach a surviving terminal view.
            // Force one SwiftUI representable update so the portal binding reattaches it.
            if !isAttached || !hasUsableBounds || !hasSurface {
                terminalPanel.requestViewReattach()
                needsFollowUpPass = true
            }

            hostedView.reconcileGeometryNow()
            // Re-check surface after reconcileGeometryNow() which can trigger AppKit
            // layout and view lifecycle changes that free surfaces (#432).
            if terminalPanel.surface.surface != nil {
                terminalPanel.surface.forceRefresh()
            }
            if terminalPanel.surface.surface == nil, isAttached && hasUsableBounds {
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                needsFollowUpPass = true
            }
        }

        return needsFollowUpPass
    }

    func scheduleTerminalGeometryReconcile() {
        beginEventDrivenLayoutFollowUp(
            reason: "workspace.geometry",
            includeGeometry: true
        )
    }

    func renderedVisiblePanelIdsForCurrentLayout() -> Set<UUID> {
        let renderedPaneIds = bonsplitController.zoomedPaneId.map { [$0] } ?? bonsplitController.allPaneIds
        var visiblePanelIds: Set<UUID> = []

        for paneId in renderedPaneIds {
            let selectedTab = bonsplitController.selectedTab(inPane: paneId) ?? bonsplitController.tabs(inPane: paneId).first
            guard let selectedTab,
                  let panelId = panelIdFromSurfaceId(selectedTab.id),
                  panels[panelId] != nil else {
                continue
            }
            visiblePanelIds.insert(panelId)
        }

        if let focusedPanelId,
           panels[focusedPanelId] != nil,
           let focusedPaneId = paneId(forPanelId: focusedPanelId),
           renderedPaneIds.contains(where: { $0.id == focusedPaneId.id }) {
            visiblePanelIds.insert(focusedPanelId)
        }

        return visiblePanelIds
    }

    @discardableResult
    func reconcileTerminalPortalVisibilityForCurrentRenderedLayout() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            if terminalPanel.hostedView.debugPortalVisibleInUI != shouldBeVisible {
                terminalPanel.hostedView.setVisibleInUI(shouldBeVisible)
                didChange = true
            }
            let shouldBeActive = shouldBeVisible && focusedPanelId == terminalPanel.id
            if terminalPanel.hostedView.debugPortalActive != shouldBeActive {
                terminalPanel.hostedView.setActive(shouldBeActive)
                didChange = true
            }
            TerminalWindowPortalRegistry.updateEntryVisibility(
                for: terminalPanel.hostedView,
                visibleInUI: shouldBeVisible
            )
        }

        return didChange
    }

    func terminalPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let terminalPanel = panel as? TerminalPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(terminalPanel.id)
            let hostedView = terminalPanel.hostedView

            if shouldBeVisible {
                if hostedView.isHidden || hostedView.window == nil || hostedView.superview == nil {
                    return true
                }
            } else if !hostedView.isHidden {
                return true
            }
        }

        return false
    }

    @discardableResult
    func reconcileBrowserPortalVisibilityForCurrentRenderedLayout(reason: String) -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()
        var didChange = false

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            let shouldBeVisible = visiblePanelIds.contains(browserPanel.id)
            let anchorView = browserPanel.portalAnchorView
            let snapshot = BrowserWindowPortalRegistry.debugSnapshot(for: browserPanel.webView)
            if shouldBeVisible {
                if snapshot?.visibleInUI == false {
                    BrowserWindowPortalRegistry.updateEntryVisibility(
                        for: browserPanel.webView,
                        visibleInUI: true,
                        zPriority: 2
                    )
                    didChange = true
                }
                let anchorReady = browserPortalAnchorReady(for: browserPanel)
                let portalReady = browserPortalReady(for: browserPanel)
                if anchorReady && !portalReady {
                    BrowserWindowPortalRegistry.synchronizeForAnchor(anchorView)
                    if browserPortalReady(for: browserPanel) {
                        BrowserWindowPortalRegistry.refresh(
                            webView: browserPanel.webView,
                            reason: reason
                        )
                        didChange = true
                    }
                } else if anchorReady && snapshot?.containerHidden == true {
                    BrowserWindowPortalRegistry.refresh(
                        webView: browserPanel.webView,
                        reason: reason
                    )
                    didChange = true
                }
            } else {
                let portalNeedsHide =
                    snapshot?.visibleInUI == true ||
                    snapshot?.containerHidden == false
                if portalNeedsHide {
                    if snapshot?.visibleInUI == true {
                        BrowserWindowPortalRegistry.updateEntryVisibility(
                            for: browserPanel.webView,
                            visibleInUI: false,
                            zPriority: 0
                        )
                    }
                    BrowserWindowPortalRegistry.hide(
                        webView: browserPanel.webView,
                        source: reason
                    )
                    didChange = true
                }
            }
        }

        return didChange
    }

    func browserPortalVisibilityNeedsFollowUp() -> Bool {
        let visiblePanelIds = renderedVisiblePanelIdsForCurrentLayout()

        for panel in panels.values {
            guard let browserPanel = panel as? BrowserPanel else { continue }
            guard visiblePanelIds.contains(browserPanel.id) else { continue }
            let anchorView = browserPanel.portalAnchorView
            let anchorReady =
                anchorView.window != nil &&
                anchorView.superview != nil &&
                anchorView.bounds.width > 1 &&
                anchorView.bounds.height > 1
            if !anchorReady ||
                browserPanel.webView.window == nil ||
                browserPanel.webView.superview == nil ||
                !BrowserWindowPortalRegistry.isWebView(browserPanel.webView, boundTo: anchorView) {
                return true
            }
        }

        return false
    }

    func scheduleMovedTerminalRefresh(panelId: UUID) {
        guard terminalPanel(for: panelId) != nil else { return }

        // Force an NSViewRepresentable update after drag/move reparenting. This keeps
        // portal host binding current when a pane auto-closes during tab moves.
        terminalPanel(for: panelId)?.requestViewReattach()

        let runRefreshPass: (TimeInterval) -> Void = { [weak self] delay in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let self, let panel = self.terminalPanel(for: panelId) else { return }
                panel.hostedView.reconcileGeometryNow()
                if panel.surface.surface != nil {
                    panel.surface.forceRefresh()
                }
                if panel.surface.surface == nil {
                    panel.surface.requestBackgroundSurfaceStartIfNeeded()
                }
            }
        }

        // Run once immediately and once on the next turn so rapid split close/reparent
        // sequences still get a post-layout redraw.
        runRefreshPass(0)
        runRefreshPass(0.03)
    }
}
