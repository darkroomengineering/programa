// Extracted from Workspace.swift (nuclear-review #98): session snapshot/restore (sessionSnapshot, restoreSessionSnapshot, and their layout/panel helpers).

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
    func sessionSnapshot(includeScrollback: Bool) -> SessionWorkspaceSnapshot {
        let tree = bonsplitController.treeSnapshot()
        let layout = sessionLayoutSnapshot(from: tree)

        let orderedPanelIds = sidebarOrderedPanelIds()
        var seen: Set<UUID> = []
        var allPanelIds: [UUID] = []
        for panelId in orderedPanelIds where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }
        for panelId in panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(panelId).inserted {
            allPanelIds.append(panelId)
        }

        let panelSnapshots = allPanelIds
            .prefix(SessionPersistencePolicy.maxPanelsPerWorkspace)
            .compactMap { sessionPanelSnapshot(panelId: $0, includeScrollback: includeScrollback) }

        let statusSnapshots = statusEntries.values
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { entry in
                SessionStatusEntrySnapshot(
                    key: entry.key,
                    value: entry.value,
                    icon: entry.icon,
                    color: entry.color,
                    timestamp: entry.timestamp.timeIntervalSince1970
                )
            }
        let logSnapshots = logEntries.map { entry in
            SessionLogEntrySnapshot(
                message: entry.message,
                level: entry.level.rawValue,
                source: entry.source,
                timestamp: entry.timestamp.timeIntervalSince1970
            )
        }

        let progressSnapshot = progress.map { progress in
            SessionProgressSnapshot(value: progress.value, label: progress.label)
        }
        let gitBranchSnapshot = gitBranch.map { branch in
            SessionGitBranchSnapshot(branch: branch.branch, isDirty: branch.isDirty)
        }

        return SessionWorkspaceSnapshot(
            processTitle: processTitle,
            customTitle: customTitle,
            customDescription: customDescription,
            customColor: customColor,
            isPinned: isPinned,
            currentDirectory: currentDirectory,
            focusedPanelId: focusedPanelId,
            layout: layout,
            panels: panelSnapshots,
            statusEntries: statusSnapshots,
            logEntries: logSnapshots,
            progress: progressSnapshot,
            gitBranch: gitBranchSnapshot,
            worktreeFolderId: worktreeFolderId,
            worktreeFolderRepoRoot: worktreeFolderRepoRoot,
            isWorktreeFolder: isWorktreeFolder,
            isWorktreeFolderCollapsed: isWorktreeFolderCollapsed,
            worktreeBranch: worktreeBranch
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionWorkspaceSnapshot) {
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)

        // Divider-race fix (restore-replay-residuals): bump the restore
        // generation and open the settle gate before any panel/surface gets
        // created below. Any surface revived via `attemptSessionReattach`
        // during this pass (`TerminalSurface.createSurface`) registers itself
        // under `restoreGeneration` and holds its one-shot scrollback seed
        // until this same pass clears the gate below, after divider positions
        // are applied. See `TerminalSurface.isSessionRestoreSettling`'s doc
        // comment for the full race this closes.
        let restoreGeneration = TerminalSurface.beginSessionRestorePass()

        if let normalizedCurrentDirectory = normalizedSidebarDirectory(snapshot.currentDirectory) {
            currentDirectory = normalizedCurrentDirectory
        }

        // Recovery input can be user-edited or come from an older/crashed build. Keep the
        // first snapshot for a panel ID instead of trapping in
        // `Dictionary(uniqueKeysWithValues:)` when malformed input contains duplicates.
        // The layout refers to panels by ID, so later duplicates cannot be addressed
        // independently anyway.
        var panelSnapshotsById: [UUID: SessionPanelSnapshot] = [:]
        for panelSnapshot in snapshot.panels where panelSnapshotsById[panelSnapshot.id] == nil {
            panelSnapshotsById[panelSnapshot.id] = panelSnapshot
        }
        isRestoringSessionLayout = true
        let leafEntries = restoreSessionLayout(snapshot.layout)
        isRestoringSessionLayout = false
        var oldToNewPanelIds: [UUID: UUID] = [:]

        for entry in leafEntries {
            restorePane(
                entry.paneId,
                snapshot: entry.snapshot,
                panelSnapshotsById: panelSnapshotsById,
                oldToNewPanelIds: &oldToNewPanelIds
            )
        }

        applyPendingReviewPanelSourceFixups(oldToNewPanelIds: oldToNewPanelIds)
        pruneSurfaceMetadata(validSurfaceIds: Set(panels.keys))
        applySessionDividerPositions(snapshotNode: snapshot.layout, liveNode: bonsplitController.treeSnapshot())

        // Divider-race fix: give bonsplit's SwiftUI/AppKit relayout for the
        // divider fractions just applied above one additional main-queue turn
        // before releasing any surface gated under this restore pass -- see
        // `TerminalSurface.isSessionRestoreSettling`'s doc comment.
        //
        // Widened to two turns (was one): the primary-window restore path
        // runs this restore before `window.setFrame(restoredFrame, display:
        // true)` (`AppDelegate.swift` restore-then-setFrame ordering), and the
        // terminal portal's own geometry sync is itself deferred past the
        // current layout turn (`TerminalWindowPortalRegistry
        // .scheduleExternalGeometrySynchronize`,
        // `GhosttyTerminalView+SwiftUIWrapper.swift`). One turn released the
        // gate before the surface ever saw the final window width, which is
        // what let width-dependent WAL replay scatter text across the wrong
        // columns on restore.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                TerminalSurface.clearSessionRestoreGateAndFlushPendingSurfaces(generation: restoreGeneration)
            }
        }

        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle)
        setCustomDescription(snapshot.customDescription)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned
        worktreeFolderId = snapshot.worktreeFolderId
        worktreeFolderRepoRoot = normalizedSidebarDirectory(snapshot.worktreeFolderRepoRoot ?? "")
        isWorktreeFolder = snapshot.isWorktreeFolder ?? false
        isWorktreeFolderCollapsed = snapshot.isWorktreeFolderCollapsed ?? false
        worktreeBranch = normalizedSidebarBranchName(snapshot.worktreeBranch)
        worktreeParentWorkspaceId = nil

        // Status entries and agent PIDs are ephemeral runtime state tied to running
        // processes (e.g. claude_code "Running"). Don't restore them across app
        // restarts because the processes that set them are gone.
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentListeningPorts.removeAll()
        restoreSidebarLogEntries(snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        })
        progress = nil
        if let restoredProgress = snapshot.progress {
            _ = setSidebarProgress(value: restoredProgress.value, label: restoredProgress.label)
        }
        gitBranch = snapshot.gitBranch.flatMap { restoredBranch in
            normalizedBoundedSidebarBranchName(restoredBranch.branch).map {
                SidebarGitBranchState(branch: $0, isDirty: restoredBranch.isDirty)
            }
        }

        recomputeListeningPorts()

        if let focusedOldPanelId = snapshot.focusedPanelId,
           let focusedNewPanelId = oldToNewPanelIds[focusedOldPanelId],
           panels[focusedNewPanelId] != nil {
            focusPanel(focusedNewPanelId)
        } else if let fallbackFocusedPanelId = focusedPanelId, panels[fallbackFocusedPanelId] != nil {
            focusPanel(fallbackFocusedPanelId)
        } else {
            scheduleFocusReconcile()
        }
    }

    /// Remaps each restored review panel's `sourceSurfaceId` from its pre-restore (old) value to
    /// the newly-created panel id, once every pane in the layout has been restored and
    /// `oldToNewPanelIds` is complete. Installs the auto-refresh subscription only after the
    /// remap, since it captures `sourceSurfaceId` at install time. A review panel whose source
    /// terminal no longer exists after restore (e.g. it failed to recreate) keeps its stale old
    /// id -- the panel simply shows its "not a git repository"/empty state rather than crashing.
    private func applyPendingReviewPanelSourceFixups(oldToNewPanelIds: [UUID: UUID]) {
        guard !pendingReviewPanelSourceFixups.isEmpty else { return }
        for (reviewPanelId, oldSourceSurfaceId) in pendingReviewPanelSourceFixups {
            guard let reviewPanel = panels[reviewPanelId] as? ReviewPanel else { continue }
            if let newSourceSurfaceId = oldToNewPanelIds[oldSourceSurfaceId] {
                reviewPanel.sourceSurfaceId = newSourceSurfaceId
            }
            reviewPanel.sendToSourceSurface = { [weak self, weak reviewPanel] text in
                guard let self, let reviewPanel else { return false }
                return self.sendReviewComments(sourceSurfaceId: reviewPanel.sourceSurfaceId, text: text)
            }
            installReviewPanelSubscription(reviewPanel)
            reviewPanel.refresh()
        }
        pendingReviewPanelSourceFixups.removeAll()
    }

    private func sessionLayoutSnapshot(from node: ExternalTreeNode) -> SessionWorkspaceLayoutSnapshot {
        switch node {
        case .pane(let pane):
            let panelIds = sessionPanelIDs(for: pane)
            let selectedPanelId = pane.selectedTabId.flatMap(sessionPanelID(forExternalTabIDString:))
            return .pane(
                SessionPaneLayoutSnapshot(
                    panelIds: panelIds,
                    selectedPanelId: selectedPanelId
                )
            )
        case .split(let split):
            return .split(
                SessionSplitLayoutSnapshot(
                    orientation: split.orientation.lowercased() == "vertical" ? .vertical : .horizontal,
                    dividerPosition: split.dividerPosition,
                    first: sessionLayoutSnapshot(from: split.first),
                    second: sessionLayoutSnapshot(from: split.second)
                )
            )
        }
    }

    private func sessionPanelIDs(for pane: ExternalPaneNode) -> [UUID] {
        var panelIds: [UUID] = []
        var seen = Set<UUID>()
        for tab in pane.tabs {
            guard let panelId = sessionPanelID(forExternalTabIDString: tab.id) else { continue }
            if seen.insert(panelId).inserted {
                panelIds.append(panelId)
            }
        }
        return panelIds
    }

    private func sessionPanelID(forExternalTabIDString tabIDString: String) -> UUID? {
        guard let tabUUID = UUID(uuidString: tabIDString) else { return nil }
        for (surfaceId, panelId) in surfaceIdToPanelId {
            guard let surfaceUUID = sessionSurfaceUUID(for: surfaceId) else { continue }
            if surfaceUUID == tabUUID {
                return panelId
            }
        }
        return nil
    }

    private func sessionSurfaceUUID(for surfaceId: TabID) -> UUID? {
        struct EncodedSurfaceID: Decodable {
            let id: UUID
        }

        guard let data = try? JSONEncoder().encode(surfaceId),
              let decoded = try? JSONDecoder().decode(EncodedSurfaceID.self, from: data) else {
            return nil
        }
        return decoded.id
    }

    private func sessionPanelSnapshot(panelId: UUID, includeScrollback: Bool) -> SessionPanelSnapshot? {
        guard let panel = panels[panelId] else { return nil }

        let panelTitle = panelTitles[panelId] ?? panel.displayTitle
        let customTitle = panelCustomTitles[panelId]
        let directory = panelDirectories[panelId]
        let isPinned = pinnedPanelIds.contains(panelId)
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let branchSnapshot = panelGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        let ttyName = surfaceTTYNames[panelId]

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        let markdownSnapshot: SessionMarkdownPanelSnapshot?
        let reviewSnapshot: SessionReviewPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let shouldPersistScrollback = ScrollbackPersistenceSettings.isEnabled()
                && terminalPanel.shouldPersistScrollbackForSessionSnapshot()
            let capturedScrollback = includeScrollback && shouldPersistScrollback
                ? TerminalController.shared.readTerminalTextForSnapshot(
                    terminalPanel: terminalPanel,
                    includeScrollback: true,
                    lineLimit: SessionPersistencePolicy.maxScrollbackLinesPerTerminal
                )
                : nil
            let resolvedScrollback = terminalSnapshotScrollback(
                panelId: panelId,
                capturedScrollback: capturedScrollback,
                includeScrollback: includeScrollback,
                allowFallbackScrollback: shouldPersistScrollback
            )
            terminalSnapshot = SessionTerminalPanelSnapshot(
                workingDirectory: panelDirectories[panelId],
                scrollback: resolvedScrollback
            )
            browserSnapshot = nil
            markdownSnapshot = nil
            reviewSnapshot = nil
        case .browser:
            guard let browserPanel = panel as? BrowserPanel else { return nil }
            terminalSnapshot = nil
            let historySnapshot = browserPanel.sessionNavigationHistorySnapshot()
            browserSnapshot = SessionBrowserPanelSnapshot(
                urlString: browserPanel.preferredURLStringForOmnibar(),
                profileID: browserPanel.profileID,
                shouldRenderWebView: browserPanel.shouldRenderWebView,
                pageZoom: Double(browserPanel.currentPageZoomFactor()),
                developerToolsVisible: browserPanel.isDeveloperToolsVisible(),
                backHistoryURLStrings: historySnapshot.backHistoryURLStrings,
                forwardHistoryURLStrings: historySnapshot.forwardHistoryURLStrings
            )
            markdownSnapshot = nil
            reviewSnapshot = nil
        case .markdown:
            guard let markdownPanel = panel as? MarkdownPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = SessionMarkdownPanelSnapshot(filePath: markdownPanel.filePath)
            reviewSnapshot = nil
        case .review:
            guard let reviewPanel = panel as? ReviewPanel else { return nil }
            terminalSnapshot = nil
            browserSnapshot = nil
            markdownSnapshot = nil
            reviewSnapshot = SessionReviewPanelSnapshot(
                sourceSurfaceId: reviewPanel.sourceSurfaceId,
                mode: reviewPanel.mode.rawValue,
                baseBranch: reviewPanel.baseBranch,
                comments: reviewPanel.comments
            )
        }

        return SessionPanelSnapshot(
            id: panelId,
            type: panel.panelType,
            title: panelTitle,
            customTitle: customTitle,
            directory: directory,
            isPinned: isPinned,
            isManuallyUnread: isManuallyUnread,
            gitBranch: branchSnapshot,
            listeningPorts: listeningPorts,
            ttyName: ttyName,
            terminal: terminalSnapshot,
            browser: browserSnapshot,
            markdown: markdownSnapshot,
            review: reviewSnapshot
        )
    }

    nonisolated static func resolvedSnapshotTerminalScrollback(
        capturedScrollback: String?,
        fallbackScrollback: String?,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        if let captured = SessionPersistencePolicy.truncatedScrollback(capturedScrollback) {
            return captured
        }
        guard allowFallbackScrollback else { return nil }
        return SessionPersistencePolicy.truncatedScrollback(fallbackScrollback)
    }

    private func terminalSnapshotScrollback(
        panelId: UUID,
        capturedScrollback: String?,
        includeScrollback: Bool,
        allowFallbackScrollback: Bool = true
    ) -> String? {
        guard includeScrollback else { return nil }
        let fallback = allowFallbackScrollback ? restoredTerminalScrollbackByPanelId[panelId] : nil
        let resolved = Self.resolvedSnapshotTerminalScrollback(
            capturedScrollback: capturedScrollback,
            fallbackScrollback: fallback,
            allowFallbackScrollback: allowFallbackScrollback
        )
        if let resolved {
            restoredTerminalScrollbackByPanelId[panelId] = resolved
        } else {
            restoredTerminalScrollbackByPanelId.removeValue(forKey: panelId)
        }
        return resolved
    }

    private func restoreSessionLayout(_ layout: SessionWorkspaceLayoutSnapshot) -> [SessionPaneRestoreEntry] {
        guard let rootPaneId = bonsplitController.allPaneIds.first else {
            return []
        }

        var leaves: [SessionPaneRestoreEntry] = []
        restoreSessionLayoutNode(layout, inPane: rootPaneId, leaves: &leaves)
        return leaves
    }

    private func restoreSessionLayoutNode(
        _ node: SessionWorkspaceLayoutSnapshot,
        inPane paneId: PaneID,
        leaves: inout [SessionPaneRestoreEntry]
    ) {
        switch node {
        case .pane(let pane):
            leaves.append(SessionPaneRestoreEntry(paneId: paneId, snapshot: pane))
        case .split(let split):
            var anchorPanelId = bonsplitController
                .tabs(inPane: paneId)
                .compactMap { panelIdFromSurfaceId($0.id) }
                .first

            if anchorPanelId == nil {
                anchorPanelId = newTerminalSurface(inPane: paneId, focus: false)?.id
            }

            guard let anchorPanelId,
                  let newSplitPanel = newTerminalSplit(
                    from: anchorPanelId,
                    orientation: split.orientation.splitOrientation,
                    insertFirst: false,
                    focus: false
                  ),
                  let secondPaneId = self.paneId(forPanelId: newSplitPanel.id) else {
                leaves.append(
                    SessionPaneRestoreEntry(
                        paneId: paneId,
                        snapshot: SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)
                    )
                )
                return
            }

            restoreSessionLayoutNode(split.first, inPane: paneId, leaves: &leaves)
            restoreSessionLayoutNode(split.second, inPane: secondPaneId, leaves: &leaves)
        }
    }

    private func restorePane(
        _ paneId: PaneID,
        snapshot: SessionPaneLayoutSnapshot,
        panelSnapshotsById: [UUID: SessionPanelSnapshot],
        oldToNewPanelIds: inout [UUID: UUID]
    ) {
        let existingPanelIds = bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
        let desiredOldPanelIds = snapshot.panelIds.filter { panelSnapshotsById[$0] != nil }

        var createdPanelIds: [UUID] = []
        for oldPanelId in desiredOldPanelIds {
            guard let panelSnapshot = panelSnapshotsById[oldPanelId] else { continue }
            guard let createdPanelId = createPanel(from: panelSnapshot, inPane: paneId) else { continue }
            createdPanelIds.append(createdPanelId)
            oldToNewPanelIds[oldPanelId] = createdPanelId
        }

        guard !createdPanelIds.isEmpty else { return }

        for oldPanelId in existingPanelIds where !createdPanelIds.contains(oldPanelId) {
            _ = closePanel(oldPanelId, force: true)
        }

        for (index, panelId) in createdPanelIds.enumerated() {
            _ = reorderSurface(panelId: panelId, toIndex: index)
        }

        let selectedPanelId: UUID? = {
            if let selectedOldId = snapshot.selectedPanelId {
                return oldToNewPanelIds[selectedOldId]
            }
            return createdPanelIds.first
        }()

        if let selectedPanelId,
           let selectedTabId = surfaceIdFromPanelId(selectedPanelId) {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(selectedTabId)
        }
    }

    private func createPanel(from snapshot: SessionPanelSnapshot, inPane paneId: PaneID) -> UUID? {
        switch snapshot.type {
        case .terminal:
            let workingDirectory = normalizedSidebarDirectory(snapshot.terminal?.workingDirectory)
                ?? normalizedSidebarDirectory(snapshot.directory)
                ?? currentDirectory

            // Issue #182 slice 2: try to reattach to a still-alive escrowed
            // child before falling back to the spawn-fresh + WAL-tail
            // replay path below. Strictly additive and best-effort -- any
            // failure (never escrowed, holder unreachable, token mismatch,
            // child already exited, timeout) falls straight through to the
            // existing unchanged code.
            if let revivedPanelId = attemptSessionReattach(
                snapshot: snapshot,
                inPane: paneId,
                workingDirectory: workingDirectory
            ) {
                return revivedPanelId
            }

            // Prefer the clean-quit/autosave scrollback text. If it's missing or
            // blank -- the app died before the next snapshot captured it -- fall
            // back to this same OLD session's WAL tail (issue #181). `snapshot.id`
            // is the pre-restore panel/surface UUID, which is also the WAL
            // session directory name (TerminalPanel.id == TerminalSurface.id).
            // The result feeds the exact same replay/truncation path either way;
            // this is purely an alternative source of scrollback bytes.
            let hasStoredScrollback = snapshot.terminal?.scrollback?.contains { !$0.isWhitespace } ?? false
            let scrollbackText = ScrollbackPersistenceSettings.isEnabled()
                ? (hasStoredScrollback
                    ? snapshot.terminal?.scrollback
                    : SessionWALStore.shared.readFallbackScrollbackText(sessionId: snapshot.id.uuidString))
                : nil
            // Routed through the fresh surface's revive-seed path
            // (`TerminalSurface.pendingReviveSeed` / `seedRevivedScrollbackIfPending`)
            // instead of the old temp-file + shell-rc `cat` mechanism --
            // see `SessionFreshSpawnScrollbackSeed`'s doc comment.
            let preparedSeedText = SessionFreshSpawnScrollbackSeed.preparedText(for: scrollbackText)
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: workingDirectory,
                pendingScrollbackSeedText: preparedSeedText
            ) else {
                return nil
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(scrollbackText)
            if let fallbackScrollback {
                restoredTerminalScrollbackByPanelId[terminalPanel.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByPanelId.removeValue(forKey: terminalPanel.id)
            }
            applySessionPanelMetadata(snapshot, toPanelId: terminalPanel.id)
            // This old session's WAL has now been given its one chance to be
            // read as a restore fallback; the new panel above has its own fresh
            // WAL directory going forward, so the old one is dead weight.
            SessionWALStore.shared.discardOrphanedSession(sessionId: snapshot.id.uuidString)
            return terminalPanel.id
        case .browser:
            guard let browserPanel = newBrowserSurface(
                inPane: paneId,
                url: nil,
                focus: false,
                preferredProfileID: snapshot.browser?.profileID
            ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: browserPanel.id)
            return browserPanel.id
        case .markdown:
            guard let filePath = snapshot.markdown?.filePath,
                  let markdownPanel = newMarkdownSurface(
                    inPane: paneId,
                    filePath: filePath,
                    focus: false
                  ) else {
                return nil
            }
            applySessionPanelMetadata(snapshot, toPanelId: markdownPanel.id)
            return markdownPanel.id
        case .review:
            // Re-runs `git diff` fresh rather than persisting stale content (see
            // `SessionReviewPanelSnapshot`'s doc comment). `sourceSurfaceId` here is still the
            // OLD panel id -- remapped in `restoreSessionSnapshot`'s post-restore fixup pass,
            // since the source terminal may be restored in a pane visited after this one.
            guard let reviewSnapshot = snapshot.review,
                  let mode = ReviewDiffMode(rawValue: reviewSnapshot.mode) else {
                return nil
            }
            let directory = normalizedSidebarDirectory(snapshot.directory) ?? currentDirectory
            let baseBranch = normalizedBoundedSidebarBranchName(reviewSnapshot.baseBranch) ?? "origin/main"
            let reviewPanel = ReviewPanel(
                workspaceId: id,
                sourceSurfaceId: reviewSnapshot.sourceSurfaceId,
                directory: directory,
                mode: mode,
                baseBranch: baseBranch
            )
            reviewPanel.restoreComments(reviewSnapshot.comments ?? [])
            panels[reviewPanel.id] = reviewPanel
            panelTitles[reviewPanel.id] = reviewPanel.displayTitle
            updatePanelDirectory(panelId: reviewPanel.id, directory: directory)

            guard let newTabId = bonsplitController.createTab(
                title: reviewPanel.displayTitle,
                icon: reviewPanel.displayIcon,
                kind: SurfaceKind.review,
                isDirty: reviewPanel.isDirty,
                isLoading: false,
                isPinned: false,
                inPane: paneId
            ) else {
                panels.removeValue(forKey: reviewPanel.id)
                panelTitles.removeValue(forKey: reviewPanel.id)
                panelDirectories.removeValue(forKey: reviewPanel.id)
                return nil
            }
            surfaceIdToPanelId[newTabId] = reviewPanel.id
            pendingReviewPanelSourceFixups[reviewPanel.id] = reviewSnapshot.sourceSurfaceId
            applySessionPanelMetadata(snapshot, toPanelId: reviewPanel.id)
            return reviewPanel.id
        }
    }

    /// Issue #182 slice 2: the reattach half of `createPanel(from:inPane:)`'s
    /// `.terminal` case. `snapshot.id` is the pre-restore panel/surface
    /// UUID, which is also the WAL session directory name (`TerminalPanel
    /// .id == TerminalSurface.id`) -- the same key the non-revive fallback
    /// path already reads for scrollback. Returns the new panel id on
    /// success (revival already seeds scrollback and re-escrows via the
    /// normal `TerminalSurface.createSurface`/`resolveSessionWALIdentity`
    /// path, so the caller must not also spawn fresh or WAL-replay); nil on
    /// any failure so the caller falls through to its existing
    /// spawn-fresh path unchanged. Synchronous and launch-time only, same
    /// contract as the WAL restore reads it builds on.
    ///
    /// Thin wrapper over `revivePanel(sessionId:inPane:workingDirectory:)`
    /// (below), which holds every bit of the actual retrieve/build/cleanup
    /// logic. This wrapper only adds the snapshot-specific bookkeeping
    /// (`applySessionPanelMetadata`) once the generic revive succeeds, so
    /// the coarse-snapshot restore path stays byte-for-byte identical to
    /// before the split.
    private func attemptSessionReattach(
        snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID,
        workingDirectory: String?
    ) -> UUID? {
        guard let panelId = revivePanel(
            sessionId: snapshot.id.uuidString,
            inPane: paneId,
            workingDirectory: workingDirectory
        ) else {
            return nil
        }
        applySessionPanelMetadata(snapshot, toPanelId: panelId)
        return panelId
    }

    /// The generic escrow-retrieve-and-build-panel primitive extracted from
    /// `attemptSessionReattach` above (Issue #307 orphan-reconciliation
    /// fix). Given only a session id -- no `SessionPanelSnapshot` -- looks
    /// up `meta.json`, retrieves the escrowed PTY fd from the holder, and
    /// builds a live `TerminalPanel` seeded with pre-crash scrollback.
    /// Callers own attaching any of their own bookkeeping (title, pin
    /// state, etc.) on top of the returned panel id; this method itself is
    /// pure revive-and-build so it can be shared between the coarse-snapshot
    /// restore path (via `attemptSessionReattach`) and the orphan
    /// reconciliation pass (`AppDelegate.reconcileOrphanedEscrowedSessions`),
    /// with no duplicated retrieve/cleanup logic between them. Synchronous
    /// and launch-time only, same contract as `attemptSessionReattach`.
    func revivePanel(
        sessionId: String,
        inPane paneId: PaneID,
        workingDirectory: String?
    ) -> UUID? {
        guard !SessionMachineryGate.isUnitTesting else { return nil }
        let oldSessionId = sessionId
        guard let meta = SessionWALStore.shared.readMeta(sessionId: oldSessionId),
              meta.escrowed == true,
              let socketPath = meta.escrowSocketPath,
              let tokenHex = meta.escrowToken,
              let childPID = meta.childPID else {
            dilog("escrow.reattach", "session=\(oldSessionId.prefix(8)) outcome=fallback reason=not_escrowed")
            return nil
        }
        // 2026-08-10 mass-drain fix: a pre-reason holder (the holder
        // outlives the app, so an updated client talking to the previous
        // version's holder is the NORMAL update path) can only deny with an
        // unspecified reason. A heartbeat written within the death-detection
        // window plus the retry window means the old app was alive seconds
        // ago -- the retrieve-before-drain race signature -- so an
        // unspecified denial is worth retrying; one long dead is not.
        let heartbeatFreshEnoughToRetryUnspecifiedDeny = Date().timeIntervalSince(meta.lastHeartbeatAt)
            < SessionEscrowPolicy.heartbeatStaleAfter + SessionEscrowPolicy.retrieveDenyRetryWindow
        guard let masterFD = SessionEscrowClient.retrieve(
            sessionId: oldSessionId,
            tokenHex: tokenHex,
            socketPath: socketPath,
            allowUnspecifiedDenyRetry: heartbeatFreshEnoughToRetryUnspecifiedDeny
        ) else {
            dilog("escrow.reattach", "session=\(oldSessionId.prefix(8)) outcome=fallback reason=retrieve_failed")
            return nil
        }

        let scrollbackText = SessionWALStore.shared.readFallbackScrollbackText(sessionId: oldSessionId)
        let retainedDescriptor: SessionEscrowRetainedDescriptor?
        let descriptorFD: Int32
        if socketPath == SessionEscrowClient.legacySocketPath() {
            let owner = SessionEscrowRetainedDescriptor.retain(
                sessionId: oldSessionId, masterFD: masterFD, childPID: childPID,
                tokenHex: tokenHex, socketPath: socketPath, recoveryPending: false
            )
            guard let fd = owner.duplicate() else {
                owner.markRecoveryPending()
                return nil
            }
            retainedDescriptor = owner
            descriptorFD = fd
        } else {
            retainedDescriptor = nil
            descriptorFD = masterFD
        }
        let reviveDescriptor = TerminalSurfaceReviveDescriptor(
            masterFD: descriptorFD,
            childPID: Int64(childPID),
            scrollbackText: scrollbackText,
            retainedDescriptor: retainedDescriptor
        )

        guard let terminalPanel = newTerminalSurface(
            inPane: paneId,
            focus: false,
            workingDirectory: workingDirectory,
            reviveDescriptor: reviveDescriptor
        ) else {
            retainedDescriptor?.markRecoveryPending()
            // TerminalSurface closes its descriptor on failure. A legacy
            // migration retains a separate master until Retry can establish
            // acknowledged holder ownership, preserving the running child.
            dilog("escrow.reattach", "session=\(oldSessionId.prefix(8)) outcome=fallback reason=panel_creation_failed")
            return nil
        }

        // This old session's directory has now been given its one chance to
        // be read (childPID/token/scrollback); the new panel above has its
        // own fresh WAL directory going forward under a new id, so the old
        // one is dead weight. `force` because the escrow claim was just
        // CONSUMED by the successful retrieve above -- the holder removed
        // the session from its registry, so meta.json's escrow fields are
        // stale despite a fresh-looking heartbeat, and the preservation
        // check must not keep this directory alive.
        SessionWALStore.shared.discardOrphanedSession(sessionId: oldSessionId, force: true)
        dilog("escrow.reattach", "session=\(oldSessionId.prefix(8)) outcome=revived newPanel=\(terminalPanel.id.uuidString.prefix(8))")
        return terminalPanel.id
    }

    private func applySessionPanelMetadata(_ snapshot: SessionPanelSnapshot, toPanelId panelId: UUID) {
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            panelTitles[panelId] = title
            panelsWithLiveTitle.insert(panelId)
        }

        setPanelCustomTitle(panelId: panelId, title: snapshot.customTitle)
        setPanelPinned(panelId: panelId, pinned: snapshot.isPinned)

        if snapshot.isManuallyUnread {
            markPanelUnread(panelId)
        } else {
            clearManualUnread(panelId: panelId)
        }

        if let directory = normalizedSidebarDirectory(snapshot.directory) {
            updatePanelDirectory(panelId: panelId, directory: directory)
        }

        if let branch = snapshot.gitBranch,
           let normalizedBranch = normalizedBoundedSidebarBranchName(branch.branch) {
            updatePanelGitBranch(panelId: panelId, branch: normalizedBranch, isDirty: branch.isDirty)
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }

        surfaceListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()

        if let ttyName = normalizedSidebarTTYName(snapshot.ttyName) {
            _ = setSidebarTTYName(panelId: panelId, ttyName: ttyName)
        } else {
            surfaceTTYNames.removeValue(forKey: panelId)
        }

        if let browserSnapshot = snapshot.browser,
           let browserPanel = browserPanel(for: panelId) {
            let pageZoom = CGFloat(max(0.25, min(5.0, browserSnapshot.pageZoom)))
            if pageZoom.isFinite {
                _ = browserPanel.setPageZoomFactor(pageZoom)
            }

            browserPanel.restoreSessionSnapshot(browserSnapshot)

            if browserSnapshot.developerToolsVisible {
                _ = browserPanel.showDeveloperTools()
                browserPanel.requestDeveloperToolsRefreshAfterNextAttach(reason: "session_restore")
            } else {
                _ = browserPanel.hideDeveloperTools()
            }
        }
    }

    private func applySessionDividerPositions(
        snapshotNode: SessionWorkspaceLayoutSnapshot,
        liveNode: ExternalTreeNode
    ) {
        switch (snapshotNode, liveNode) {
        case (.split(let snapshotSplit), .split(let liveSplit)):
            if let splitID = UUID(uuidString: liveSplit.id) {
                _ = bonsplitController.setDividerPosition(
                    CGFloat(snapshotSplit.dividerPosition),
                    forSplit: splitID,
                    fromExternal: true
                )
            }
            applySessionDividerPositions(snapshotNode: snapshotSplit.first, liveNode: liveSplit.first)
            applySessionDividerPositions(snapshotNode: snapshotSplit.second, liveNode: liveSplit.second)
        default:
            return
        }
    }
}
