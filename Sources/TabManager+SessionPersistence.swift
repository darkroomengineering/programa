import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine

extension TabManager {
    func sessionAutosaveFingerprint() -> Data? {
        SessionPersistenceStore.canonicalContentIdentity(
            for: sessionSnapshot(includeScrollback: false)
        )
    }

    func sessionSnapshot(includeScrollback: Bool) -> SessionTabManagerSnapshot {
        let restorableTabs = tabs
            .filter { !$0.isRemoteWorkspace }
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        let workspaceSnapshots = restorableTabs
            .map { $0.sessionSnapshot(includeScrollback: includeScrollback) }
        let selectedWorkspaceIndex = selectedTabId.flatMap { selectedTabId in
            restorableTabs.firstIndex(where: { $0.id == selectedTabId })
        }
        return SessionTabManagerSnapshot(
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            workspaces: workspaceSnapshots
        )
    }

    private func releaseRestoredAwayWorkspace(_ workspace: Workspace) {
        // Session restore replaces the bootstrap workspace objects with freshly
        // restored ones. Tear the old graph down after the atomic swap so late
        // panel/socket callbacks cannot keep mutating hidden pre-restore state.
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)
        workspace.teardownAllPanels()
        workspace.teardownRemoteConnection()
        workspace.owningTabManager = nil
    }

    func restoreSessionSnapshot(_ snapshot: SessionTabManagerSnapshot) {
        let previousTabs = tabs
        for tab in previousTabs {
            unwireClosedBrowserTracking(for: tab)
        }
        let existingProbeKeys = Set(workspaceGitProbeGenerationByKey.keys)
            .union(workspaceGitProbeTimersByKey.keys)
        for key in existingProbeKeys {
            clearWorkspaceGitProbe(key)
        }
        workspaceGitTrackedDirectoryByKey.removeAll()

        // Clear non-@Published state without touching tabs/selectedTabId yet.
        lastFocusedPanelByTab.removeAll()
        pendingPanelTitleUpdates.removeAll()
        tabHistory.removeAll()
        historyIndex = -1
        isNavigatingHistory = false
        pendingWorkspaceUnfocusTarget = nil
        workspaceCycleCooldownTask?.cancel()
        workspaceCycleCooldownTask = nil
        isWorkspaceCycleHot = false
        selectionSideEffectsGeneration &+= 1
        recentlyClosedBrowsers = RecentlyClosedBrowserStack(capacity: 20)

        // Build the new workspace list locally to avoid intermediate @Published
        // emissions (empty tabs, nil selectedTabId) that can leave SwiftUI's
        // mountedWorkspaceIds empty and cause a frozen blank launch state (#399).
        var newTabs: [Workspace] = []
        let workspaceSnapshots = snapshot.workspaces
            .prefix(SessionPersistencePolicy.maxWorkspacesPerWindow)
        for workspaceSnapshot in workspaceSnapshots {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let workspace = Workspace(
                title: workspaceSnapshot.processTitle,
                workingDirectory: workspaceSnapshot.currentDirectory,
                portOrdinal: ordinal
            )
            workspace.owningTabManager = self
            workspace.restoreSessionSnapshot(workspaceSnapshot)
            wireClosedBrowserTracking(for: workspace)
            newTabs.append(workspace)
        }

        if newTabs.isEmpty {
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let fallback = Workspace(title: "Terminal 1", portOrdinal: ordinal)
            fallback.owningTabManager = self
            wireClosedBrowserTracking(for: fallback)
            newTabs.append(fallback)
        }

        // Determine selection before mutating @Published properties.
        let newSelectedId: UUID?
        if let selectedWorkspaceIndex = snapshot.selectedWorkspaceIndex,
           newTabs.indices.contains(selectedWorkspaceIndex) {
            newSelectedId = newTabs[selectedWorkspaceIndex].id
        } else {
            newSelectedId = newTabs.first?.id
        }

        // Single atomic assignment of @Published properties so SwiftUI observers
        // never see an intermediate state with empty tabs or nil selection.
        tabs = newTabs
        selectedTabId = newSelectedId
        let existingIds = Set(newTabs.map(\.id))
        pruneBackgroundWorkspaceLoads(existingIds: existingIds)
        sidebarSelectedWorkspaceIds.formIntersection(existingIds)
        for workspace in previousTabs {
            releaseRestoredAwayWorkspace(workspace)
        }
        for workspace in newTabs {
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            for terminalPanel in terminalPanels {
                scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: terminalPanel.id
                )
            }
        }

        if let selectedTabId {
            NotificationCenter.default.post(
                name: .ghosttyDidFocusTab,
                object: nil,
                userInfo: [GhosttyNotificationKey.tabId: selectedTabId]
            )
        }
    }
}
