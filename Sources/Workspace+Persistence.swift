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
    nonisolated static let remoteDaemonManifestInfoKey = WorkspaceRemoteSessionController.remoteDaemonManifestInfoKey

    nonisolated static func remoteDaemonManifest(from infoDictionary: [String: Any]?) -> WorkspaceRemoteDaemonManifest? {
        WorkspaceRemoteSessionController.remoteDaemonManifest(from: infoDictionary)
    }

    nonisolated static func remoteDaemonCachedBinaryURL(
        version: String,
        goOS: String,
        goArch: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try WorkspaceRemoteSessionController.remoteDaemonCachedBinaryURL(
            version: version,
            goOS: goOS,
            goArch: goArch,
            fileManager: fileManager
        )
    }

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
            gitBranch: gitBranchSnapshot
        )
    }

    func restoreSessionSnapshot(_ snapshot: SessionWorkspaceSnapshot) {
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)

        let normalizedCurrentDirectory = snapshot.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedCurrentDirectory.isEmpty {
            currentDirectory = normalizedCurrentDirectory
        }

        let panelSnapshotsById = Dictionary(uniqueKeysWithValues: snapshot.panels.map { ($0.id, $0) })
        let leafEntries = restoreSessionLayout(snapshot.layout)
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

        applyProcessTitle(snapshot.processTitle)
        setCustomTitle(snapshot.customTitle)
        setCustomDescription(snapshot.customDescription)
        setCustomColor(snapshot.customColor)
        isPinned = snapshot.isPinned

        // Status entries and agent PIDs are ephemeral runtime state tied to running
        // processes (e.g. claude_code "Running"). Don't restore them across app
        // restarts because the processes that set them are gone.
        statusEntries.removeAll()
        agentPIDs.removeAll()
        agentListeningPorts.removeAll()
        logEntries = snapshot.logEntries.map { entry in
            SidebarLogEntry(
                message: entry.message,
                level: SidebarLogLevel(rawValue: entry.level) ?? .info,
                source: entry.source,
                timestamp: Date(timeIntervalSince1970: entry.timestamp)
            )
        }
        progress = snapshot.progress.map { SidebarProgressState(value: $0.value, label: $0.label) }
        gitBranch = snapshot.gitBranch.map { SidebarGitBranchState(branch: $0.branch, isDirty: $0.isDirty) }

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
                guard let self, let reviewPanel else { return }
                self.sendReviewComments(sourceSurfaceId: reviewPanel.sourceSurfaceId, text: text)
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

        let panelTitle = panelTitle(panelId: panelId)
        let customTitle = panelCustomTitles[panelId]
        let directory = panelDirectories[panelId]
        let isPinned = pinnedPanelIds.contains(panelId)
        let isManuallyUnread = manualUnreadPanelIds.contains(panelId)
        let branchSnapshot = panelGitBranches[panelId].map {
            SessionGitBranchSnapshot(branch: $0.branch, isDirty: $0.isDirty)
        }
        let listeningPorts: [Int]
        if remoteDetectedSurfaceIds.contains(panelId) || isRemoteTerminalSurface(panelId) {
            listeningPorts = []
        } else {
            listeningPorts = (surfaceListeningPorts[panelId] ?? []).sorted()
        }
        let ttyName = surfaceTTYNames[panelId]

        let terminalSnapshot: SessionTerminalPanelSnapshot?
        let browserSnapshot: SessionBrowserPanelSnapshot?
        let markdownSnapshot: SessionMarkdownPanelSnapshot?
        let reviewSnapshot: SessionReviewPanelSnapshot?
        switch panel.panelType {
        case .terminal:
            guard let terminalPanel = panel as? TerminalPanel else { return nil }
            let shouldPersistScrollback = terminalPanel.shouldPersistScrollbackForSessionSnapshot()
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
                baseBranch: reviewPanel.baseBranch
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
            let workingDirectory = snapshot.terminal?.workingDirectory ?? snapshot.directory ?? currentDirectory
            let replayEnvironment = SessionScrollbackReplayStore.replayEnvironment(
                for: snapshot.terminal?.scrollback
            )
            guard let terminalPanel = newTerminalSurface(
                inPane: paneId,
                focus: false,
                workingDirectory: workingDirectory,
                startupEnvironment: replayEnvironment
            ) else {
                return nil
            }
            let fallbackScrollback = SessionPersistencePolicy.truncatedScrollback(snapshot.terminal?.scrollback)
            if let fallbackScrollback {
                restoredTerminalScrollbackByPanelId[terminalPanel.id] = fallbackScrollback
            } else {
                restoredTerminalScrollbackByPanelId.removeValue(forKey: terminalPanel.id)
            }
            applySessionPanelMetadata(snapshot, toPanelId: terminalPanel.id)
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
            let directory = snapshot.directory ?? currentDirectory
            let reviewPanel = ReviewPanel(
                workspaceId: id,
                sourceSurfaceId: reviewSnapshot.sourceSurfaceId,
                directory: directory,
                mode: mode,
                baseBranch: reviewSnapshot.baseBranch
            )
            panels[reviewPanel.id] = reviewPanel
            panelTitles[reviewPanel.id] = reviewPanel.displayTitle
            panelDirectories[reviewPanel.id] = directory

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

        if let directory = snapshot.directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            updatePanelDirectory(panelId: panelId, directory: directory)
        }

        if let branch = snapshot.gitBranch {
            panelGitBranches[panelId] = SidebarGitBranchState(branch: branch.branch, isDirty: branch.isDirty)
        } else {
            panelGitBranches.removeValue(forKey: panelId)
        }

        surfaceListeningPorts[panelId] = Array(Set(snapshot.listeningPorts)).sorted()

        if let ttyName = snapshot.ttyName?.trimmingCharacters(in: .whitespacesAndNewlines), !ttyName.isEmpty {
            surfaceTTYNames[panelId] = ttyName
        } else {
            surfaceTTYNames.removeValue(forKey: panelId)
        }
        syncRemotePortScanTTYs()

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
