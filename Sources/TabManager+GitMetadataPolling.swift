import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo
import Combine

// MARK: - Agent PID Sweep

extension TabManager {
    /// Periodically checks agent PIDs associated with status entries.
    /// If a process has exited (SIGKILL, crash, etc.), clears the stale status entry.
    /// This is the safety net for cases where no hook fires (e.g. SIGKILL).
    func startAgentPIDSweepTimer() {
        guard !isStopped, agentPIDSweepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.sweepStaleAgentPIDs()
            }
        }
        timer.resume()
        agentPIDSweepTimer = timer
    }

    /// Periodically refreshes git/PR metadata for tracked workspace branches so
    /// remote GitHub state changes (e.g. PR open -> merged) reach sidebar state
    /// even when the local branch/directory does not change.
    func startWorkspaceGitMetadataPollTimer() {
        guard !isStopped, workspaceGitMetadataPollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = Self.workspaceGitMetadataPollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.refreshTrackedWorkspaceGitMetadata()
            }
        }
        timer.resume()
        workspaceGitMetadataPollTimer = timer
    }

    /// Refresh the selected workspace more aggressively so branch checkouts and
    /// newly created PRs show up in the sidebar without waiting for the slower
    /// background sweep across every tracked workspace.
    func startSelectedWorkspaceGitMetadataPollTimer() {
        guard !isStopped, selectedWorkspaceGitMetadataPollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = Self.selectedWorkspaceGitMetadataPollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isStopped else { return }
                self.refreshSelectedWorkspaceGitMetadata()
            }
        }
        timer.resume()
        selectedWorkspaceGitMetadataPollTimer = timer
    }

    /// Pure tier decision for the background sweep: should this workspace's periodic
    /// git metadata sweep be skipped this tick? Extracted for direct unit testing
    /// (no live TabManager/workspace needed).
    ///
    /// - Selected workspace: never skipped -- it's also freshened every
    ///   `selectedWorkspaceGitMetadataPollInterval` (5s) by the dedicated selected-workspace
    ///   poll, so this just keeps the 30s sweep consistent for it too.
    /// - Hidden workspace with no recorded refresh yet: never skipped (so newly tracked
    ///   workspaces aren't starved).
    /// - Hidden workspace refreshed within `hiddenRefreshInterval`: skipped (this is the
    ///   perf win -- 10x fewer background git spawns for workspaces the user isn't looking at).
    /// - Hidden workspace stale beyond `hiddenRefreshInterval`: not skipped (badges must not
    ///   go stale forever).
    static func shouldSkipHiddenWorkspaceGitMetadataSweep(
        isSelected: Bool,
        lastRefreshedAt: Date?,
        now: Date,
        hiddenRefreshInterval: TimeInterval
    ) -> Bool {
        guard !isSelected else { return false }
        guard let lastRefreshedAt else { return false }
        return now.timeIntervalSince(lastRefreshedAt) < hiddenRefreshInterval
    }

    private func refreshTrackedWorkspaceGitMetadata() {
        guard !isStopped else { return }
        let activeProbeKeys = Set(workspaceGitProbeGenerationByKey.keys)
        let selectedWorkspaceId = selectedWorkspace?.id
        let now = Date()

        for workspace in tabs {
            let shouldSkip = Self.shouldSkipHiddenWorkspaceGitMetadataSweep(
                isSelected: workspace.id == selectedWorkspaceId,
                lastRefreshedAt: workspaceGitMetadataLastRefreshedAt[workspace.id],
                now: now,
                hiddenRefreshInterval: Self.hiddenWorkspaceGitMetadataRefreshInterval
            )
            guard !shouldSkip else { continue }

            var scheduledAny = false
            for panelId in trackedWorkspaceGitMetadataPollCandidatePanelIds(
                in: workspace,
                activeProbeKeys: activeProbeKeys
            ) {
                if scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: "periodicPoll"
                ) {
                    scheduledAny = true
                }
            }
            if scheduledAny {
                workspaceGitMetadataLastRefreshedAt[workspace.id] = now
            }
        }
    }

    private func refreshSelectedWorkspaceGitMetadata() {
        guard !isStopped else { return }
        guard let workspace = selectedWorkspace,
              let focusedPanelId = workspace.focusedPanelId else {
            return
        }

        let activeProbeKeys = Set(workspaceGitProbeGenerationByKey.keys)
        let candidatePanelIds = trackedWorkspaceGitMetadataPollCandidatePanelIds(
            in: workspace,
            activeProbeKeys: activeProbeKeys
        )
        guard candidatePanelIds.contains(focusedPanelId) else { return }

        if scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspace.id,
            panelId: focusedPanelId,
            reason: "selectedPeriodicPoll"
        ) {
            // Keeps the hidden-workspace tier's "last refreshed" timestamp fresh for the
            // currently-selected workspace, so it doesn't immediately read as stale in
            // refreshTrackedWorkspaceGitMetadata() the moment it stops being selected.
            workspaceGitMetadataLastRefreshedAt[workspace.id] = Date()
        }
    }

    func refreshTrackedWorkspaceGitMetadataForTesting() {
        refreshTrackedWorkspaceGitMetadata()
    }

    func trackedWorkspaceGitMetadataPollCandidatePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let activeProbeKeys = Set(workspaceGitProbeGenerationByKey.keys)
        guard let workspace = workspace(withId: workspaceId) else {
            return []
        }
        return trackedWorkspaceGitMetadataPollCandidatePanelIds(
            in: workspace,
            activeProbeKeys: activeProbeKeys
        )
    }

    func activeWorkspaceGitProbePanelIdsForTesting(workspaceId: UUID) -> Set<UUID> {
        let probeKeys = Set(workspaceGitProbeGenerationByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitProbeTimersByKey.keys.filter { $0.workspaceId == workspaceId })
        return Set(probeKeys.map(\.panelId))
    }

    private func trackedWorkspaceGitMetadataPollCandidatePanelIds(
        in workspace: Workspace,
        activeProbeKeys: Set<WorkspaceGitProbeKey>
    ) -> Set<UUID> {
        // Panels with already-confirmed git branch/PR metadata are always eligible
        // for periodic re-verification (to catch drift, e.g. a checkout or a PR
        // opening/merging) regardless of whether some other probe (e.g. the
        // multi-attempt startup probe, or the probe scheduled by the very branch
        // update that populated this metadata) happens to still be in flight for
        // that panel. Excluding them here would starve confirmed panels of
        // periodic refresh for as long as any unrelated probe stays active.
        var candidatePanelIds = Set(workspace.panelGitBranches.keys)
        candidatePanelIds.formUnion(workspace.panelPullRequests.keys)
        // Only keep background polling panels whose current directory has already
        // proven to yield sidebar git metadata. Initial multi-attempt probes handle
        // startup races; this avoids polling non-repo directories forever. Skip
        // panels whose own probe for this exact directory is still actively
        // resolving so the periodic sweep doesn't redundantly interrupt/reset it.
        candidatePanelIds.formUnion(
            workspace.panels.keys.compactMap { panelId in
                guard let currentDirectory = gitProbeDirectory(for: workspace, panelId: panelId) else {
                    return nil
                }
                let probeKey = WorkspaceGitProbeKey(workspaceId: workspace.id, panelId: panelId)
                guard workspaceGitTrackedDirectoryByKey[probeKey] == currentDirectory else {
                    return nil
                }
                guard !activeProbeKeys.contains(probeKey) else {
                    return nil
                }
                return panelId
            }
        )

        if candidatePanelIds.isEmpty,
           let focusedPanelId = workspace.focusedPanelId,
           (workspace.gitBranch != nil || workspace.pullRequest != nil),
           gitProbeDirectory(for: workspace, panelId: focusedPanelId) != nil {
            candidatePanelIds.insert(focusedPanelId)
        }

        return candidatePanelIds
    }

    private func sweepStaleAgentPIDs() {
        var allStalePanelIds: Set<UUID> = []
        for tab in tabs {
            var keysToRemove: [String] = []
            for (key, pid) in tab.agentPIDs {
                guard pid > 0 else {
                    keysToRemove.append(key)
                    continue
                }
                // kill(pid, 0) probes process liveness without sending a signal.
                // ESRCH = process doesn't exist (stale). EPERM = process exists
                // but we lack permission (not stale, keep tracking).
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    keysToRemove.append(key)
                }
            }
            if !keysToRemove.isEmpty {
                for key in keysToRemove {
                    tab.statusEntries.removeValue(forKey: key)
                    tab.agentPIDs.removeValue(forKey: key)
                }
                let remainingAgentPIDs = Set(tab.agentPIDs.values.compactMap { $0 > 0 ? Int($0) : nil })
                core.ports.refreshAgentPorts(workspaceId: tab.id, agentPIDs: remainingAgentPIDs)
                // Also clear stale notifications (e.g. "Doing well, thanks!")
                // left behind when Claude was killed without SessionEnd firing.
                AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            }

            allStalePanelIds.formUnion(sweepAgentPresence(for: tab))
        }
        // `sweepAgentPresence` already consulted the previous `staleAgentPanelIds` to decide
        // whether to nudge the publisher, so this tick's stale set becomes the new tracked set.
        staleAgentPanelIds = allStalePanelIds
    }

    /// Extends the same sweep to `panelAgentPresence`: clears presence whose reported pid has
    /// exited, and nudges the publisher once per stale transition so the sidebar row redraws
    /// without a new timer. Runs on main, same as the rest of `sweepStaleAgentPIDs`. Returns this
    /// tab's currently-stale panel ids so the caller can reconcile `staleAgentPanelIds` across
    /// every tab in one pass.
    @discardableResult
    private func sweepAgentPresence(for tab: Workspace) -> Set<UUID> {
        let now = Date()
        var currentlyStalePanelIds: Set<UUID> = []
        for (panelId, presence) in tab.panelAgentPresence {
            if let pid = presence.sessionKey?.pid, pid > 0 {
                errno = 0
                if kill(pid, 0) == -1, POSIXErrorCode(rawValue: errno) == .ESRCH {
                    tab.clearPanelAgentState(panelId: panelId)
                    continue
                }
            }
            if presence.isStale(now: now) {
                currentlyStalePanelIds.insert(panelId)
                if !staleAgentPanelIds.contains(panelId) {
                    // No-op write: republishes `panelAgentPresence` so the sidebar row picks up
                    // the newly-stale indicator without writing new data.
                    tab.panelAgentPresence[panelId] = presence
                }
            }
        }
        return currentlyStalePanelIds
    }

    func gitProbeDirectory(for workspace: Workspace, panelId: UUID) -> String? {
        // Match the sidebar directory fallback chain so hidden/background panels can
        // still probe git metadata before OSC 7 has reported a live cwd.
        let rawDirectory = workspace.panelDirectories[panelId]
            ?? workspace.terminalPanel(for: panelId)?.requestedWorkingDirectory
            ?? (workspace.focusedPanelId == panelId ? workspace.currentDirectory : nil)
        return rawDirectory.flatMap(normalizedWorkingDirectory)
    }

    func scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String = "initial"
    ) {
        guard !isStopped, workspace(withId: workspaceId) != nil else {
            return
        }
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason,
            delays: Self.initialWorkspaceGitProbeDelays
        )
    }

    /// Returns whether a refresh was actually scheduled — callers that stamp
    /// `workspaceGitMetadataLastRefreshedAt` must only do so on `true`, or a
    /// workspace whose panels all early-return here would be marked fresh
    /// without any probe running, deferring its next real attempt by a full
    /// hidden-refresh interval.
    @discardableResult
    func scheduleWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        delays: [TimeInterval] = [0]
    ) -> Bool {
        guard !isStopped,
              let workspace = workspace(withId: workspaceId),
              workspace.panels[panelId] != nil,
              let directory = gitProbeDirectory(for: workspace, panelId: panelId) else {
            return false
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason
        )
        return true
    }
}
