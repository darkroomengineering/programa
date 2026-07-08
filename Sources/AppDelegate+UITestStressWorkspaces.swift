// Extracted from AppDelegate.swift (nuclear-review N3): XCUITest-only instrumentation.
import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin

extension AppDelegate {
#if DEBUG
    @objc func openDebugStressWorkspacesWithLoadedSurfaces(_ sender: Any?) {
        guard !debugStressWorkspaceCreationInProgress else { return }
        guard let tabManager else { return }

        debugStressLagProbeEnabled = true
        debugStressWorkspaceCreationInProgress = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.debugStressWorkspaceCreationInProgress = false }

            let totalStart = ProcessInfo.processInfo.systemUptime
            let originalSelectedWorkspaceId = tabManager.selectedTabId
            var created: [Workspace] = []
            created.reserveCapacity(self.debugStressWorkspaceCount)
            var layoutFailures = 0
            var cumulativeWorkspaceMs: Double = 0
            var slowWorkspaceCount = 0
            var worstWorkspaceMs: Double = 0

            dlog(
                "stress.setup.start workspaces=\(self.debugStressWorkspaceCount) panes=\(self.debugStressPaneCount) " +
                "tabsPerPane=\(self.debugStressTabsPerPane) lagProbe=1"
            )

            for index in 0..<self.debugStressWorkspaceCount {
                let workspaceStart = ProcessInfo.processInfo.systemUptime
                let workspace = tabManager.addWorkspace(select: false, placementOverride: .end)
                created.append(workspace)
                tabManager.setCustomTitle(
                    tabId: workspace.id,
                    title: "\(self.debugPerfWorkspaceTitlePrefix)\(index + 1)"
                )

                if !(await self.configureDebugStressWorkspaceLayout(
                    workspace,
                    paneCount: self.debugStressPaneCount,
                    tabsPerPane: self.debugStressTabsPerPane
                )) {
                    layoutFailures += 1
                }

                let workspaceMs = (ProcessInfo.processInfo.systemUptime - workspaceStart) * 1000.0
                cumulativeWorkspaceMs += workspaceMs
                worstWorkspaceMs = max(worstWorkspaceMs, workspaceMs)
                if workspaceMs >= 35 {
                    slowWorkspaceCount += 1
                }

                if workspaceMs >= 35 || ((index + 1) % 5 == 0) {
                    let pending = self.pendingDebugTerminalSurfaceCount(in: created)
                    dlog(
                        "stress.setup.workspace idx=\(index + 1)/\(self.debugStressWorkspaceCount) " +
                        "ms=\(String(format: "%.2f", workspaceMs)) failures=\(layoutFailures) pending=\(pending)"
                    )
                }

                if ((index + 1) % self.debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }

            let creationElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let loadStats = await self.loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
                created,
                tabManager: tabManager
            )
            let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStart) * 1000.0
            let avgWorkspaceMs = created.isEmpty ? 0 : (cumulativeWorkspaceMs / Double(created.count))
            let expectedSurfaceCount = self.debugStressWorkspaceCount
                * self.debugStressPaneCount
                * self.debugStressTabsPerPane
            if let originalSelectedWorkspaceId,
               tabManager.tabs.contains(where: { $0.id == originalSelectedWorkspaceId }) {
                tabManager.selectedTabId = originalSelectedWorkspaceId
            }

            dlog(
                "stress.setup.done createMs=\(String(format: "%.2f", creationElapsedMs)) " +
                "loadMs=\(String(format: "%.2f", loadStats.elapsedMs)) loadedPanels=\(loadStats.loadedPanels) " +
                "loadFailures=\(loadStats.failedPanels) totalMs=\(String(format: "%.2f", totalElapsedMs)) " +
                "workspaceAvgMs=\(String(format: "%.2f", avgWorkspaceMs)) workspaceWorstMs=\(String(format: "%.2f", worstWorkspaceMs)) " +
                "workspaceSlowCount=\(slowWorkspaceCount) waitAttempts=\(loadStats.attempts) " +
                "pendingSurfaces=\(loadStats.pendingSurfaces) expectedSurfaces=\(expectedSurfaceCount)"
            )

            NSLog(
                "Debug stress workspaces: created=%d panesPerWorkspace=%d tabsPerPane=%d expectedSurfaces=%d layoutFailures=%d pendingSurfaces=%d createMs=%.2f loadMs=%.2f loadedPanels=%d failedPanels=%d totalMs=%.2f workspaceAvgMs=%.2f workspaceWorstMs=%.2f waitAttempts=%d",
                self.debugStressWorkspaceCount,
                self.debugStressPaneCount,
                self.debugStressTabsPerPane,
                expectedSurfaceCount,
                layoutFailures,
                loadStats.pendingSurfaces,
                creationElapsedMs,
                loadStats.elapsedMs,
                loadStats.loadedPanels,
                loadStats.failedPanels,
                totalElapsedMs,
                avgWorkspaceMs,
                worstWorkspaceMs,
                loadStats.attempts
            )
        }
    }

    private func configureDebugStressWorkspaceLayout(
        _ workspace: Workspace,
        paneCount: Int,
        tabsPerPane: Int
    ) async -> Bool {
        guard let topLeftPanelId = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId else {
            return false
        }
        guard let topRight = workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .horizontal,
            focus: false
        ) else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topLeftPanelId,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()
        guard workspace.newTerminalSplit(
            from: topRight.id,
            orientation: .vertical,
            focus: false
        ) != nil else {
            return false
        }
        await Task.yield()

        let paneIds = workspace.bonsplitController.allPaneIds
        guard paneIds.count == paneCount else { return false }

        let additionalTabsPerPane = max(0, tabsPerPane - 1)
        if additionalTabsPerPane > 0 {
            for (paneIndex, paneId) in paneIds.enumerated() {
                for tabOffset in 0..<additionalTabsPerPane {
                    guard workspace.newTerminalSurface(inPane: paneId, focus: false) != nil else {
                        return false
                    }
                    if ((tabOffset + 1) % debugStressYieldInterval) == 0 {
                        await Task.yield()
                    }
                }
                if ((paneIndex + 1) % debugStressYieldInterval) == 0 {
                    await Task.yield()
                }
            }
        }

        return true
    }

    private struct DebugStressSurfaceLoadStats {
        let pendingSurfaces: Int
        let loadedPanels: Int
        let failedPanels: Int
        let attempts: Int
        let elapsedMs: Double
    }

    private struct DebugStressTerminalLoadTarget {
        let workspace: Workspace
        let paneId: PaneID
        let tabId: TabID
        let panelId: UUID
    }

    private func waitForDebugStressCondition(
        timeout: TimeInterval,
        installObservers: (@escaping () -> Void) -> [NSObjectProtocol],
        evaluate: @escaping () -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            var observers: [NSObjectProtocol] = []
            var timeoutWorkItem: DispatchWorkItem?
            var finished = false

            func cleanup() {
                observers.forEach { NotificationCenter.default.removeObserver($0) }
                observers.removeAll()
                timeoutWorkItem?.cancel()
                timeoutWorkItem = nil
            }

            func finish(_ result: Bool) {
                guard !finished else { return }
                finished = true
                cleanup()
                continuation.resume(returning: result)
            }

            let trigger = {
                if evaluate() {
                    finish(true)
                }
            }

            observers = installObservers {
                DispatchQueue.main.async {
                    trigger()
                }
            }
            let workItem = DispatchWorkItem {
                finish(evaluate())
            }
            timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
            trigger()
        }
    }

    private func loadAllDebugStressWorkspacesForTerminalSurfaceReadiness(
        _ workspaces: [Workspace],
        tabManager: TabManager
    ) async -> DebugStressSurfaceLoadStats {
        guard !workspaces.isEmpty else {
            return DebugStressSurfaceLoadStats(
                pendingSurfaces: 0,
                loadedPanels: 0,
                failedPanels: 0,
                attempts: 0,
                elapsedMs: 0
            )
        }

        let retainedWorkspaceIds = Set(workspaces.map(\.id))
        let loadStart = ProcessInfo.processInfo.systemUptime
        var attempts = 0
        var queuedTargets: [DebugStressTerminalLoadTarget] = []
        queuedTargets.reserveCapacity(
            workspaces.count * debugStressPaneCount * debugStressTabsPerPane
        )

        tabManager.retainDebugWorkspaceLoads(for: retainedWorkspaceIds)
        defer { tabManager.releaseDebugWorkspaceLoads(for: retainedWorkspaceIds) }

        await Task.yield()
        forceDebugStressVisibleLayout()
        let mountedWorkspaceCount = await waitForDebugStressMountedWorkspaces(workspaces)

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for paneId in workspace.bonsplitController.allPaneIds {
                for tab in workspace.bonsplitController.tabs(inPane: paneId) {
                    guard let panelId = workspace.panelIdFromSurfaceId(tab.id),
                          workspace.panel(for: tab.id) is TerminalPanel else {
                        continue
                    }
                    if workspace.preloadTerminalPanelForDebugStress(tabId: tab.id, inPane: paneId) != nil {
                        queuedTargets.append(
                            DebugStressTerminalLoadTarget(
                                workspace: workspace,
                                paneId: paneId,
                                tabId: tab.id,
                                panelId: panelId
                            )
                        )
                        attempts += 1
                    }
                }
            }

            dlog(
                "stress.setup.queue workspace=\(workspaceIndex + 1)/\(workspaces.count) " +
                "mounted=\(mountedWorkspaceCount)/\(workspaces.count) queued=\(queuedTargets.count)"
            )
            await Task.yield()
        }

        let waitResult = await waitForDebugStressTerminalPanelSurfaces(queuedTargets)
        attempts += waitResult.attempts
        let failedPanels = waitResult.pendingTargets.count
        let loadedPanels = max(0, queuedTargets.count - failedPanels)
        for target in waitResult.pendingTargets {
            dlog(
                "stress.setup.surfaceTimeout workspace=\(target.workspace.id.uuidString.prefix(5)) " +
                "panel=\(target.panelId.uuidString.prefix(5)) pane=\(target.paneId.id.uuidString.prefix(5))"
            )
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000.0
        return DebugStressSurfaceLoadStats(
            pendingSurfaces: pendingDebugTerminalSurfaceCount(in: workspaces),
            loadedPanels: loadedPanels,
            failedPanels: failedPanels,
            attempts: attempts,
            elapsedMs: elapsedMs
        )
    }

    private func waitForDebugStressMountedWorkspaces(_ workspaces: [Workspace]) async -> Int {
        guard !workspaces.isEmpty else { return 0 }
        var mountedWorkspaceCount = 0
        let selectedWorkspaceId = tabManager?.selectedTabId

        let updateMountedCount = { [self] in
            self.forceDebugStressVisibleLayout()
            mountedWorkspaceCount = 0
            for workspace in workspaces {
                if workspace.id == selectedWorkspaceId {
                    workspace.scheduleDebugStressTerminalGeometryReconcile()
                } else {
                    workspace.requestBackgroundTerminalSurfaceStartIfNeeded()
                }
                if workspace.panels.values.contains(where: { panel in
                    guard let terminalPanel = panel as? TerminalPanel else { return false }
                    return terminalPanel.hostedView.superview != nil || terminalPanel.surface.surface != nil
                }) {
                    mountedWorkspaceCount += 1
                }
            }
        }
        let _ = await waitForDebugStressCondition(
            timeout: 0.25,
            installObservers: { trigger in
                [
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceDidBecomeReady,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: .terminalSurfaceHostedViewDidMoveToWindow,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    },
                    NotificationCenter.default.addObserver(
                        forName: NSWindow.didUpdateNotification,
                        object: nil,
                        queue: .main
                    ) { _ in
                        trigger()
                    }
                ]
            },
            evaluate: {
                updateMountedCount()
                return mountedWorkspaceCount == workspaces.count
            }
        )

        dlog("stress.setup.mount mounted=\(mountedWorkspaceCount)/\(workspaces.count)")
        return mountedWorkspaceCount
    }

    private func waitForDebugStressTerminalPanelSurfaces(
        _ targets: [DebugStressTerminalLoadTarget]
    ) async -> (pendingTargets: [DebugStressTerminalLoadTarget], attempts: Int) {
        guard !targets.isEmpty else {
            return (pendingTargets: [], attempts: 0)
        }

        let deadline = Date().addingTimeInterval(debugStressSurfaceLoadTimeoutSeconds)
        let selectedWorkspaceId = tabManager?.selectedTabId
        var pendingTargets = targets
        var attempts = 0
        var eventCount = 0

        func refreshPendingTargets() {
            self.forceDebugStressVisibleLayout()
            var nextPending: [DebugStressTerminalLoadTarget] = []
            nextPending.reserveCapacity(pendingTargets.count)
            var startedThisPass = 0

            for target in pendingTargets {
                guard let terminalPanel = target.workspace.panel(for: target.tabId) as? TerminalPanel else {
                    nextPending.append(target)
                    continue
                }
                if terminalPanel.surface.surface != nil {
                    continue
                }

                let hostedView = terminalPanel.hostedView
                let shouldReconcileVisibleSelection =
                    target.workspace.id == selectedWorkspaceId &&
                    hostedView.window != nil &&
                    hostedView.superview != nil

                if shouldReconcileVisibleSelection {
                    target.workspace.scheduleDebugStressTerminalGeometryReconcile()
                    terminalPanel.requestViewReattach()
                }
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
                startedThisPass += 1
                nextPending.append(target)
            }

            eventCount += 1
            if nextPending.count != pendingTargets.count || startedThisPass > 0 || eventCount == 1 {
                dlog(
                    "stress.setup.await event=\(eventCount) pending=\(nextPending.count) " +
                    "started=\(startedThisPass)"
                )
            }
            attempts += startedThisPass
            pendingTargets = nextPending
        }
        refreshPendingTargets()
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0, !pendingTargets.isEmpty {
            let _ = await waitForDebugStressCondition(
                timeout: remaining,
                installObservers: { trigger in
                    [
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceDidBecomeReady,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: .terminalSurfaceHostedViewDidMoveToWindow,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        },
                        NotificationCenter.default.addObserver(
                            forName: NSWindow.didUpdateNotification,
                            object: nil,
                            queue: .main
                        ) { _ in
                            trigger()
                        }
                    ]
                },
                evaluate: {
                    refreshPendingTargets()
                    return pendingTargets.isEmpty
                }
            )
        }

        return (pendingTargets: pendingTargets, attempts: attempts)
    }

    private func forceDebugStressVisibleLayout() {
        if let activeWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            activeWindow.contentView?.layoutSubtreeIfNeeded()
            activeWindow.contentView?.displayIfNeeded()
            return
        }

        for (windowIndex, window) in NSApp.windows.enumerated() {
            window.contentView?.layoutSubtreeIfNeeded()
            if windowIndex == 0 {
                window.contentView?.displayIfNeeded()
            }
        }
    }

    private func pendingDebugTerminalSurfaceCount(in workspaces: [Workspace]) -> Int {
        var pending = 0
        for workspace in workspaces {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                if terminalPanel.surface.surface == nil {
                    pending += 1
                }
            }
        }
        return pending
    }

    private func debugStressLagSnapshot() -> (
        workspaceCount: Int,
        terminalPanelCount: Int,
        loadedSurfaceCount: Int,
        selectedWorkspace: String
    ) {
        guard let tabManager else {
            return (0, 0, 0, "nil")
        }
        var terminalPanelCount = 0
        var loadedSurfaceCount = 0
        for workspace in tabManager.tabs {
            for panel in workspace.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                terminalPanelCount += 1
                if terminalPanel.surface.surface != nil {
                    loadedSurfaceCount += 1
                }
            }
        }
        let selectedWorkspace = tabManager.selectedTabId.map { String($0.uuidString.prefix(5)) } ?? "nil"
        return (
            tabManager.tabs.count,
            terminalPanelCount,
            loadedSurfaceCount,
            selectedWorkspace
        )
    }

    func logSlowShortcutMonitorLatencyIfNeeded(
        event: NSEvent,
        handledByShortcut: Bool,
        elapsedMs: Double
    ) {
        guard debugStressLagProbeEnabled else { return }
        guard event.type == .keyDown else { return }

        let normalizedFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let isPlainTyping = normalizedFlags.isDisjoint(with: [.command, .control, .option])
        let thresholdMs: Double = event.isARepeat ? 1.5 : (isPlainTyping ? 2.5 : 6.0)
        guard elapsedMs >= thresholdMs else { return }

        let snapshot = debugStressLagSnapshot()
        dlog(
            "stress.inputLag path=appMonitor ms=\(String(format: "%.2f", elapsedMs)) " +
            "threshold=\(String(format: "%.2f", thresholdMs)) handled=\(handledByShortcut ? 1 : 0) " +
            "plain=\(isPlainTyping ? 1 : 0) repeat=\(event.isARepeat ? 1 : 0) keyCode=\(event.keyCode) " +
            "mods=\(event.modifierFlags.rawValue) workspaces=\(snapshot.workspaceCount) " +
            "terminals=\(snapshot.terminalPanelCount) surfacesReady=\(snapshot.loadedSurfaceCount) " +
            "selected=\(snapshot.selectedWorkspace)"
        )
    }
#endif
}
