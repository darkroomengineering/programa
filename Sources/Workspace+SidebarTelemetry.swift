// Extracted from Workspace.swift (nuclear-review #98): sidebar telemetry mutation/query members
// (directory, shell-activity, git-branch, pull-request, status, log, and metadata-block state).

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
    func updatePanelDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId, currentDirectory != trimmed {
            currentDirectory = trimmed
        }
    }

    /// Updates the shell-activity state for a panel.
    ///
    /// - Returns: `true` if the update was applied (panel exists and state changed),
    ///   `false` if it was a no-op (panel absent or state unchanged).
    ///   Callers that deduplicate reports MUST only record the state in their dedup
    ///   dict when this returns `true`; recording on `false` would suppress the next
    ///   identical report even though it was never actually applied.
    @discardableResult
    func updatePanelShellActivityState(panelId: UUID, state: PanelShellActivityState) -> Bool {
        guard panels[panelId] != nil else { return false }
        let previousState = panelShellActivityStates[panelId] ?? .unknown
        guard previousState != state else { return false }
        panelShellActivityStates[panelId] = state
#if DEBUG
        dlog(
            "surface.shellState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) from=\(previousState.rawValue) to=\(state.rawValue)"
        )
#endif
        return true
    }

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != branch
        if existing?.branch != branch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
        }
        if branchChanged {
            if panelPullRequests[panelId] != nil {
                panelPullRequests.removeValue(forKey: panelId)
            }
            if panelId == focusedPanelId, pullRequest != nil {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        if panelGitBranches[panelId] != nil {
            panelGitBranches.removeValue(forKey: panelId)
        }
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId {
            if gitBranch != nil {
                gitBranch = nil
            }
            if pullRequest != nil {
                pullRequest = nil
            }
        }
    }

    func updatePanelPullRequest(
        panelId: UUID,
        number: Int,
        label: String,
        url: URL,
        status: SidebarPullRequestStatus,
        branch: String? = nil,
        checks: SidebarPullRequestChecksStatus? = nil
    ) {
        let existing = panelPullRequests[panelId]
        let normalizedBranch = normalizedSidebarBranchName(branch)
        let currentPanelBranch = normalizedSidebarBranchName(panelGitBranches[panelId]?.branch)
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.branch
        }()
        let resolvedChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard let existing,
                  existing.number == number,
                  existing.label == label,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.checks
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: label,
            url: url,
            status: status,
            branch: resolvedBranch,
            checks: resolvedChecks
        )
        if existing != state {
            panelPullRequests[panelId] = state
        }
        if panelId == focusedPanelId, pullRequest != state {
            pullRequest = state
        }
    }

    func clearPanelPullRequest(panelId: UUID) {
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
        }
        if panelId == focusedPanelId, pullRequest != nil {
            pullRequest = nil
        }
    }

    func resetSidebarContext(reason: String = "unspecified") {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentListeningPorts.removeAll()
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        panelGitBranches.removeAll()
        pullRequest = nil
        panelPullRequests.removeAll()
        surfaceListeningPorts.removeAll()
        listeningPorts.removeAll()
        metadataBlocks.removeAll()
        resetBrowserPanelsForContextChange(reason: reason)
    }

    func resetBrowserPanelsForContextChange(reason: String) {
        let browserPanels = panels.values.compactMap { $0 as? BrowserPanel }
        guard !browserPanels.isEmpty else { return }

#if DEBUG
        dlog(
            "workspace.contextReset.browserPanels workspace=\(id.uuidString.prefix(5)) " +
            "reason=\(reason) count=\(browserPanels.count)"
        )
#endif

        for browserPanel in browserPanels {
            browserPanel.resetForWorkspaceContextChange(reason: reason)
            let nextTitle = browserPanel.displayTitle
            _ = updatePanelTitle(panelId: browserPanel.id, title: nextTitle)

            guard let tabId = surfaceIdFromPanelId(browserPanel.id),
                  let existing = bonsplitController.tab(tabId) else {
                continue
            }

            let faviconUpdate: Data?? = existing.iconImageData == nil ? nil : .some(nil)
            let loadingUpdate: Bool? = existing.isLoading ? false : nil

            guard faviconUpdate != nil || loadingUpdate != nil else {
                continue
            }

            bonsplitController.updateTab(
                tabId,
                iconImageData: faviconUpdate,
                hasCustomTitle: panelCustomTitles[browserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
    }

    @discardableResult
    func updatePanelTitle(panelId: UUID, title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var didMutate = false

        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
            didMutate = true
        }
        panelsWithLiveTitle.insert(panelId)

        // Update bonsplit tab title only when this panel's title changed.
        if didMutate,
           let tabId = surfaceIdFromPanelId(panelId),
           let panel = panels[panelId] {
            let baseTitle = panelTitles[panelId] ?? panel.displayTitle
            let resolvedTitle = resolvedPanelTitle(panelId: panelId, fallback: baseTitle)
            bonsplitController.updateTab(
                tabId,
                title: resolvedTitle,
                hasCustomTitle: panelCustomTitles[panelId] != nil
            )
        }

        // The focused pane titles the workspace (tmux-style). Single-panel
        // workspaces have no focus ambiguity; in splits, only the focused
        // pane's title propagates so two panes never fight over the sidebar.
        if panels.count == 1 || panelId == focusedPanelId, customTitle == nil {
            if self.title != trimmed {
                self.title = trimmed
                didMutate = true
            }
            if processTitle != trimmed {
                processTitle = trimmed
            }
        }

        return didMutate
    }

    /// Re-derive the workspace title from the focused panel's last known
    /// title. Called on pane-focus changes so the sidebar follows the active
    /// pane without waiting for it to emit a new OSC title. Only titles that
    /// arrived through a real update qualify; creation-time displayTitle
    /// seeds must not overwrite the workspace's default title.
    func refreshWorkspaceTitleFromFocusedPanel() {
        guard customTitle == nil,
              let panelId = focusedPanelId,
              panelsWithLiveTitle.contains(panelId),
              let stored = panelTitles[panelId] else { return }
        if title != stored { title = stored }
        if processTitle != stored { processTitle = stored }
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        panelsWithLiveTitle = panelsWithLiveTitle.filter { validSurfaceIds.contains($0) }
        panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        remoteDetectedSurfaceIds = remoteDetectedSurfaceIds.filter { validSurfaceIds.contains($0) }
        panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
            .union(remoteDetectedPorts)
            .union(remoteForwardedPorts)
        let next = unique.sorted()
        if listeningPorts != next {
            listeningPorts = next
        }
    }

    func sidebarOrderedPanelIds() -> [UUID] {
        let paneTabs: [String: [UUID]] = Dictionary(
            uniqueKeysWithValues: bonsplitController.allPaneIds.map { paneId in
                let panelIds = bonsplitController
                    .tabs(inPane: paneId)
                    .compactMap { panelIdFromSurfaceId($0.id) }
                return (paneId.id.uuidString, panelIds)
            }
        )

        let fallbackPanelIds = panels.keys.sorted { $0.uuidString < $1.uuidString }
        let tree = bonsplitController.treeSnapshot()
        return SidebarBranchOrdering.orderedPanelIds(
            tree: tree,
            paneTabs: paneTabs,
            fallbackPanelIds: fallbackPanelIds
        )
    }

    func normalizedSidebarDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        if isRemoteWorkspace {
            return SidebarBranchOrdering.inferredRemoteHomeDirectory(
                from: Array(resolvedPanelDirectories.values),
                fallbackDirectory: normalizedSidebarDirectory(currentDirectory)
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    func sidebarResolvedDirectory(for panelId: UUID) -> String? {
        if let directory = normalizedSidebarDirectory(panelDirectories[panelId]) {
            return directory
        }
        if let requestedDirectory = normalizedSidebarDirectory(
            terminalPanel(for: panelId)?.requestedWorkingDirectory
        ) {
            return requestedDirectory
        }
        guard panelId == focusedPanelId else { return nil }
        return normalizedSidebarDirectory(currentDirectory)
    }

    func sidebarResolvedPanelDirectories(orderedPanelIds: [UUID]) -> [UUID: String] {
        var resolved: [UUID: String] = [:]
        for panelId in orderedPanelIds {
            if let directory = sidebarResolvedDirectory(for: panelId) {
                resolved[panelId] = directory
            }
        }
        return resolved
    }

    func sidebarDirectoriesInDisplayOrder(orderedPanelIds: [UUID]) -> [String] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        let homeDirectoryForCanonicalization = sidebarHomeDirectoryForCanonicalization(
            resolvedPanelDirectories: resolvedDirectories
        )
        var ordered: [String] = []
        var seen: Set<String> = []

        for panelId in orderedPanelIds {
            guard let directory = resolvedDirectories[panelId],
                  let key = SidebarBranchOrdering.canonicalDirectoryKey(
                      directory,
                      homeDirectoryForTildeExpansion: homeDirectoryForCanonicalization
                  ) else { continue }
            if seen.insert(key).inserted {
                ordered.append(directory)
            }
        }

        if ordered.isEmpty, let fallbackDirectory = normalizedSidebarDirectory(currentDirectory) {
            return [fallbackDirectory]
        }

        return ordered
    }

    func sidebarDirectoriesInDisplayOrder() -> [String] {
        sidebarDirectoriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarGitBranchesInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarGitBranchState] {
        SidebarBranchOrdering
            .orderedUniqueBranches(
                orderedPanelIds: orderedPanelIds,
                panelBranches: panelGitBranches,
                fallbackBranch: gitBranch
            )
            .map { SidebarGitBranchState(branch: $0.name, isDirty: $0.isDirty) }
    }

    func sidebarGitBranchesInDisplayOrder() -> [SidebarGitBranchState] {
        sidebarGitBranchesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder(
        orderedPanelIds: [UUID]
    ) -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        let resolvedDirectories = sidebarResolvedPanelDirectories(orderedPanelIds: orderedPanelIds)
        return SidebarBranchOrdering.orderedUniqueBranchDirectoryEntries(
            orderedPanelIds: orderedPanelIds,
            panelBranches: panelGitBranches,
            panelDirectories: resolvedDirectories,
            defaultDirectory: normalizedSidebarDirectory(currentDirectory),
            homeDirectoryForTildeExpansion: sidebarHomeDirectoryForCanonicalization(
                resolvedPanelDirectories: resolvedDirectories
            ),
            fallbackBranch: gitBranch
        )
    }

    func sidebarBranchDirectoryEntriesInDisplayOrder() -> [SidebarBranchOrdering.BranchDirectoryEntry] {
        sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarPullRequestsInDisplayOrder(orderedPanelIds: [UUID]) -> [SidebarPullRequestState] {
        let validPanelPullRequests = panelPullRequests.filter { panelId, state in
            guard let pullRequestBranch = normalizedSidebarBranchName(state.branch) else {
                return true
            }
            return normalizedSidebarBranchName(panelGitBranches[panelId]?.branch) == pullRequestBranch
        }
        return SidebarBranchOrdering.orderedUniquePullRequests(
            orderedPanelIds: orderedPanelIds,
            panelPullRequests: validPanelPullRequests,
            fallbackPullRequest: nil
        )
    }

    func sidebarPullRequestsInDisplayOrder() -> [SidebarPullRequestState] {
        sidebarPullRequestsInDisplayOrder(orderedPanelIds: sidebarOrderedPanelIds())
    }

    func sidebarStatusEntriesInDisplayOrder() -> [SidebarStatusEntry] {
        statusEntries.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func sidebarMetadataBlocksInDisplayOrder() -> [SidebarMetadataBlock] {
        metadataBlocks.values.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.key < rhs.key
        }
    }

    func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logEntries.append(SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date()))
        let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        let limit = max(1, min(500, configuredLimit))
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
    }
}
