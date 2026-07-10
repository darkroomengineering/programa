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
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = Self.workspaceGitMetadataPollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
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
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let interval = Self.selectedWorkspaceGitMetadataPollInterval
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshSelectedWorkspaceGitMetadata()
            }
        }
        timer.resume()
        selectedWorkspaceGitMetadataPollTimer = timer
    }

    private func refreshTrackedWorkspaceGitMetadata() {
        let activeProbeKeys = Set(workspaceGitProbeGenerationByKey.keys)

        for workspace in tabs {
            for panelId in trackedWorkspaceGitMetadataPollCandidatePanelIds(
                in: workspace,
                activeProbeKeys: activeProbeKeys
            ) {
                scheduleWorkspaceGitMetadataRefreshIfPossible(
                    workspaceId: workspace.id,
                    panelId: panelId,
                    reason: "periodicPoll"
                )
            }
        }
    }

    private func refreshSelectedWorkspaceGitMetadata() {
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

        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspace.id,
            panelId: focusedPanelId,
            reason: "selectedPeriodicPoll"
        )
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
                PortScanner.shared.refreshAgentPorts(workspaceId: tab.id, agentPIDs: remainingAgentPIDs)
                // Also clear stale notifications (e.g. "Doing well, thanks!")
                // left behind when Claude was killed without SessionEnd firing.
                AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            }
        }
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
        guard let workspace = workspace(withId: workspaceId),
              !workspace.isRemoteWorkspace else {
            return
        }
        scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason,
            delays: Self.initialWorkspaceGitProbeDelays
        )
    }

    func scheduleWorkspaceGitMetadataRefreshIfPossible(
        workspaceId: UUID,
        panelId: UUID,
        reason: String,
        delays: [TimeInterval] = [0]
    ) {
        guard let workspace = workspace(withId: workspaceId),
              workspace.panels[panelId] != nil,
              let directory = gitProbeDirectory(for: workspace, panelId: panelId) else {
            return
        }

        scheduleWorkspaceGitMetadataRefresh(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: directory,
            delays: delays,
            reason: reason
        )
    }
}
