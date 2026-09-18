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

enum SidebarTelemetryLimits {
    static let maxKeyBytes = 512
    static let maxDirectoryBytes = 4 * 1024
    static let maxGitBranchBytes = 1024
    static let maxPullRequestURLBytes = 4 * 1024
    static let maxPullRequestLabelBytes = 64
    static let maxProgressLabelBytes = 512
    static let maxTTYNameBytes = 1024
    static let maxStatusIconBytes = 256
    static let maxStatusColorBytes = 128
    static let maxStatusURLBytes = 4 * 1024
    static let maxLogSourceBytes = 512
    static let maxLogMessageBytes = 64 * 1024
    static let maxStatusValueBytes = 16 * 1024
    static let maxMetadataMarkdownBytes = 256 * 1024
    static let maxStatusEntries = 128
    static let maxMetadataBlocks = 128
    static let maxAgentPIDs = 128
    // With no protocol dimension, 1...65_535 exhausts the numeric port domain;
    // duplicates count toward this raw ingress limit before canonicalization.
    static let maxReportedPorts = 65_535

    static func utf8ByteCount(_ value: String) -> Int {
        value.utf8.count
    }

    static func isWithinUTF8Limit(_ value: String?, maxBytes: Int) -> Bool {
        value.map { utf8ByteCount($0) <= maxBytes } ?? true
    }

    static func truncatedToUTF8Limit(_ value: String, maxBytes: Int) -> String {
        guard utf8ByteCount(value) > maxBytes else { return value }
        guard maxBytes > 0 else { return "" }

        var result = ""
        result.reserveCapacity(maxBytes)
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard characterBytes <= maxBytes - byteCount else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    static func configuredMaxLogEntries() -> Int {
        let configured = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
        return max(1, min(500, configured))
    }
}

extension Workspace {
    func updatePanelDirectory(panelId: UUID, directory: String) {
        guard let normalized = normalizedSidebarDirectory(directory) else { return }
        if panelDirectories[panelId] != normalized {
            panelDirectories[panelId] = normalized
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId, currentDirectory != normalized {
            currentDirectory = normalized
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
            hasKnownTTY: surfaceTTYNames[panelId] != nil,
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool) {
        guard let normalizedBranch = normalizedBoundedSidebarBranchName(branch) else { return }
        let state = SidebarGitBranchState(branch: normalizedBranch, isDirty: isDirty)
        let existing = panelGitBranches[panelId]
        let branchChanged = existing?.branch != nil && existing?.branch != normalizedBranch
        var titleMetadataChanged = false
        if existing?.branch != normalizedBranch || existing?.isDirty != isDirty {
            panelGitBranches[panelId] = state
            titleMetadataChanged = true
        }
        if branchChanged {
            if panelPullRequests[panelId] != nil {
                panelPullRequests.removeValue(forKey: panelId)
                titleMetadataChanged = true
            }
            if panelId == focusedPanelId, pullRequest != nil {
                pullRequest = nil
            }
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
        if titleMetadataChanged {
            syncResolvedPanelTitle(panelId: panelId)
        }
    }

    func clearPanelGitBranch(panelId: UUID) {
        var titleMetadataChanged = false
        if panelGitBranches[panelId] != nil {
            panelGitBranches.removeValue(forKey: panelId)
            titleMetadataChanged = true
        }
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
            titleMetadataChanged = true
        }
        if panelId == focusedPanelId {
            if gitBranch != nil {
                gitBranch = nil
            }
            if pullRequest != nil {
                pullRequest = nil
            }
        }
        if titleMetadataChanged {
            syncResolvedPanelTitle(panelId: panelId)
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
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(normalizedLabel) <= SidebarTelemetryLimits.maxPullRequestLabelBytes,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              SidebarTelemetryLimits.utf8ByteCount(url.absoluteString) <= SidebarTelemetryLimits.maxPullRequestURLBytes else {
            return
        }
        let existing = panelPullRequests[panelId]
        let normalizedBranch = normalizedSidebarBranchName(branch)
        guard normalizedBranch.map({
            SidebarTelemetryLimits.utf8ByteCount($0) <= SidebarTelemetryLimits.maxGitBranchBytes
        }) ?? true else {
            return
        }
        let currentPanelBranch = normalizedBoundedSidebarBranchName(panelGitBranches[panelId]?.branch)
        let resolvedBranch: String? = {
            if let normalizedBranch {
                return normalizedBranch
            }
            if let currentPanelBranch {
                return currentPanelBranch
            }
            guard let existing,
                  existing.number == number,
                  existing.label == normalizedLabel,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return normalizedBoundedSidebarBranchName(existing.branch)
        }()
        let resolvedChecks: SidebarPullRequestChecksStatus? = {
            if let checks {
                return checks
            }
            guard let existing,
                  existing.number == number,
                  existing.label == normalizedLabel,
                  existing.url == url,
                  existing.status == status else {
                return nil
            }
            return existing.checks
        }()
        let state = SidebarPullRequestState(
            number: number,
            label: normalizedLabel,
            url: url,
            status: status,
            branch: resolvedBranch,
            checks: resolvedChecks
        )
        if existing != state {
            panelPullRequests[panelId] = state
            syncResolvedPanelTitle(panelId: panelId)
        }
        if panelId == focusedPanelId, pullRequest != state {
            pullRequest = state
        }
    }

    func clearPanelPullRequest(panelId: UUID) {
        if panelPullRequests[panelId] != nil {
            panelPullRequests.removeValue(forKey: panelId)
            syncResolvedPanelTitle(panelId: panelId)
        }
        if panelId == focusedPanelId, pullRequest != nil {
            pullRequest = nil
        }
    }

    /// Reports an agent activity state for a surface (issue #164 hook tier; screen-manifest
    /// `.inferred` tier added by docs/plans/screen-manifest-detection.md). This is the single
    /// funnel every report path goes through — `TabManager.updateSurfaceAgentState` (called by
    /// both `TerminalController+Telemetry.swift`'s hook-driven `v2SurfaceReportAgentState` and
    /// `AgentScreenDetectionEngine`'s screen-manifest sampler) is the only caller.
    ///
    /// Hooks-always-win precedence (source defaults to `.hooks` so every pre-existing call site
    /// compiles and behaves unchanged):
    /// - `source == .hooks` always writes — state and source both update unconditionally, even
    ///   if the state value itself is unchanged, so a surface's source can flip from `.inferred`
    ///   back to `.hooks` the instant a hook speaks.
    /// - `source == .inferred` only writes if the surface's currently recorded source is `nil`
    ///   (never reported) or already `.inferred`. If it's `.hooks`, the write is silently
    ///   dropped — belt-and-suspenders: the screen-manifest engine's Phase A should already skip
    ///   sampling a hooks-owned surface, but this is the authoritative guard regardless.
    func updatePanelAgentState(
        panelId: UUID,
        state: AgentActivityState,
        source: AgentStateSource = .hooks,
        sessionKey: AgentSessionKey? = nil,
        at now: Date = Date()
    ) {
        let current = panelAgentPresence[panelId]

        if source == .inferred, let current, current.source == .hooks {
            // Hooks always win: dropped write must not move lastEventAt either, so a
            // hooks-owned surface's staleness clock keeps ticking from its last real hook
            // event, not from an inferred sample that never took effect.
            return
        }

        // `.inferred` writes never carry a session key -- there is no session to key on.
        let resolvedSessionKey = source == .inferred ? nil : sessionKey

        guard current?.state != state || current?.source != source || current?.sessionKey != resolvedSessionKey else {
            // Same state from the same writer: only the liveness clock moves. Without this a
            // long-running agent that keeps reporting `working` would read as stale at the
            // threshold. No wait-registry or socket fan-out, since nothing observable changed.
            panelAgentPresence[panelId]?.lastEventAt = now
            return
        }
        panelAgentPresence[panelId] = AgentPresence(
            state: state,
            source: source,
            lastEventAt: now,
            sessionKey: resolvedSessionKey
        )
        // Event-driven half of surface.wait's `agent_state` condition (#166 task 2) and
        // agent.prompt's internal working/idle watch (#166 task 3) -- see
        // AgentStateWaitRegistry's doc comment in TerminalController+SurfaceWait.swift for why
        // this is the single safe place to fire from.
        AgentStateWaitRegistry.shared.notify(surfaceId: panelId, newState: state, source: source)
        SocketEventBroadcaster.shared.publishAgentState(workspaceId: id, surfaceId: panelId, state: state, source: source)
#if DEBUG
        dlog(
            "surface.agentState workspace=\(id.uuidString.prefix(5)) " +
            "panel=\(panelId.uuidString.prefix(5)) state=\(state.rawValue) source=\(source.rawValue)"
        )
#endif
    }

    func clearPanelAgentState(panelId: UUID) {
        guard panelAgentPresence[panelId] != nil else { return }
        panelAgentPresence.removeValue(forKey: panelId)
        AgentStateWaitRegistry.shared.notify(surfaceId: panelId, newState: nil, source: nil)
        SocketEventBroadcaster.shared.publishAgentState(workspaceId: id, surfaceId: panelId, state: nil, source: nil)
#if DEBUG
        dlog("surface.agentState.clear workspace=\(id.uuidString.prefix(5)) panel=\(panelId.uuidString.prefix(5))")
#endif
    }

    func resetSidebarContext(
        reason: String = "unspecified",
        portScanner: PortScanner = .shared
    ) {
        statusEntries.removeAll()
        agentPIDs.removeAll()
        portScanner.refreshAgentPorts(workspaceId: id, agentPIDs: [])
        agentListeningPorts.removeAll()
        logEntries.removeAll()
        progress = nil
        gitBranch = nil
        let panelIdsWithAutomaticTitles = Set(panelGitBranches.keys).union(panelPullRequests.keys)
        panelGitBranches.removeAll()
        pullRequest = nil
        panelPullRequests.removeAll()
        for panelId in panelIdsWithAutomaticTitles {
            syncResolvedPanelTitle(panelId: panelId)
        }
        // Clears bypass updatePanelAgentState/clearPanelAgentState's per-surface notify, so fan
        // it out here too -- otherwise a surface.wait `agent_state` (or a subscribed client)
        // watching a surface whose state got wiped by a sidebar reset would hang until timeout
        // instead of observing the transition to "no state".
        let clearedAgentSurfaceIds = Array(panelAgentPresence.keys)
        panelAgentPresence.removeAll()
        for surfaceId in clearedAgentSurfaceIds {
            AgentStateWaitRegistry.shared.notify(surfaceId: surfaceId, newState: nil, source: nil)
            SocketEventBroadcaster.shared.publishAgentState(workspaceId: id, surfaceId: surfaceId, state: nil, source: nil)
        }
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
        if didMutate {
            syncResolvedPanelTitle(panelId: panelId)
        }

        // The focused pane titles the workspace (tmux-style). Single-panel
        // workspaces have no focus ambiguity; in splits, only the focused
        // pane's title propagates so two panes never fight over the sidebar.
        if panels.count == 1 || panelId == focusedPanelId {
            let previousTitle = self.title
            processTitle = trimmed
            refreshResolvedWorkspaceTitle()
            if self.title != previousTitle { didMutate = true }
        }

        return didMutate
    }

    /// Re-derive the workspace title from the focused panel's last known
    /// title. Called on pane-focus changes so the sidebar follows the active
    /// pane without waiting for it to emit a new OSC title. Only titles that
    /// arrived through a real update qualify; creation-time displayTitle
    /// seeds must not overwrite the workspace's default title.
    func refreshWorkspaceTitleFromFocusedPanel() {
        guard let panelId = focusedPanelId,
              panelsWithLiveTitle.contains(panelId),
              let stored = panelTitles[panelId] else { return }
        if processTitle != stored { processTitle = stored }
        refreshResolvedWorkspaceTitle()
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        if panelDirectories.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        }
        if panelTitles.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        }
        if panelsWithLiveTitle.contains(where: { !validSurfaceIds.contains($0) }) {
            panelsWithLiveTitle = panelsWithLiveTitle.filter { validSurfaceIds.contains($0) }
        }
        if panelCustomTitles.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelCustomTitles = panelCustomTitles.filter { validSurfaceIds.contains($0.key) }
        }
        if pinnedPanelIds.contains(where: { !validSurfaceIds.contains($0) }) {
            pinnedPanelIds = pinnedPanelIds.filter { validSurfaceIds.contains($0) }
        }
        if manualUnreadPanelIds.contains(where: { !validSurfaceIds.contains($0) }) {
            manualUnreadPanelIds = manualUnreadPanelIds.filter { validSurfaceIds.contains($0) }
        }
        if panelGitBranches.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelGitBranches = panelGitBranches.filter { validSurfaceIds.contains($0.key) }
        }
        if manualUnreadMarkedAt.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            manualUnreadMarkedAt = manualUnreadMarkedAt.filter { validSurfaceIds.contains($0.key) }
        }
        let didPruneListeningPorts = surfaceListeningPorts.keys.contains(where: {
            !validSurfaceIds.contains($0)
        })
        if didPruneListeningPorts {
            surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        }
        let didPruneTTYNames = surfaceTTYNames.keys.contains(where: {
            !validSurfaceIds.contains($0)
        })
        if didPruneTTYNames {
            surfaceTTYNames = surfaceTTYNames.filter { validSurfaceIds.contains($0.key) }
        }
        if panelShellActivityStates.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelShellActivityStates = panelShellActivityStates.filter { validSurfaceIds.contains($0.key) }
        }
        if panelPullRequests.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelPullRequests = panelPullRequests.filter { validSurfaceIds.contains($0.key) }
        }
        if panelAgentPresence.keys.contains(where: { !validSurfaceIds.contains($0) }) {
            panelAgentPresence = panelAgentPresence.filter { validSurfaceIds.contains($0.key) }
        }
        if didPruneListeningPorts {
            recomputeListeningPorts()
        }
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
            .union(agentListeningPorts)
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
        guard !trimmed.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(trimmed) <= SidebarTelemetryLimits.maxDirectoryBytes else {
            return nil
        }
        return trimmed
    }

    func normalizedBoundedSidebarBranchName(_ branch: String?) -> String? {
        guard let normalized = normalizedSidebarBranchName(branch),
              SidebarTelemetryLimits.utf8ByteCount(normalized) <= SidebarTelemetryLimits.maxGitBranchBytes else {
            return nil
        }
        return normalized
    }

    func normalizedSidebarTTYName(_ ttyName: String?) -> String? {
        guard let ttyName else { return nil }
        let trimmed = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(trimmed) <= SidebarTelemetryLimits.maxTTYNameBytes else {
            return nil
        }
        return trimmed
    }

    func sidebarHomeDirectoryForCanonicalization(
        resolvedPanelDirectories: [UUID: String]
    ) -> String? {
        FileManager.default.homeDirectoryForCurrentUser.path
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

    @discardableResult
    func setSidebarStatusEntry(_ entry: SidebarStatusEntry) -> (inserted: Bool, evictedAgentPID: Bool) {
        guard SidebarTelemetryLimits.utf8ByteCount(entry.key) <= SidebarTelemetryLimits.maxKeyBytes,
              SidebarTelemetryLimits.utf8ByteCount(entry.value) <= SidebarTelemetryLimits.maxStatusValueBytes,
              SidebarTelemetryLimits.isWithinUTF8Limit(entry.icon, maxBytes: SidebarTelemetryLimits.maxStatusIconBytes),
              SidebarTelemetryLimits.isWithinUTF8Limit(entry.color, maxBytes: SidebarTelemetryLimits.maxStatusColorBytes),
              SidebarTelemetryLimits.isWithinUTF8Limit(
                  entry.url?.absoluteString,
                  maxBytes: SidebarTelemetryLimits.maxStatusURLBytes
              ) else {
            return (false, false)
        }
        var evictedAgentPID = false
        while statusEntries[entry.key] == nil,
              statusEntries.count >= SidebarTelemetryLimits.maxStatusEntries,
              let oldestKey = statusEntries.min(by: { lhs, rhs in
                  if lhs.value.timestamp != rhs.value.timestamp {
                      return lhs.value.timestamp < rhs.value.timestamp
                  }
                  return lhs.key < rhs.key
              })?.key {
            statusEntries.removeValue(forKey: oldestKey)
            if agentPIDs.removeValue(forKey: oldestKey) != nil {
                evictedAgentPID = true
            }
        }
        statusEntries[entry.key] = entry
        return (true, evictedAgentPID)
    }

    @discardableResult
    func setSidebarProgress(value: Double, label: String?) -> Bool {
        guard value.isFinite,
              (0.0...1.0).contains(value),
              SidebarTelemetryLimits.isWithinUTF8Limit(
                  label,
                  maxBytes: SidebarTelemetryLimits.maxProgressLabelBytes
              ) else {
            return false
        }
        progress = SidebarProgressState(value: value, label: label)
        return true
    }

    @discardableResult
    func setSidebarAgentPID(key: String, pid: pid_t) -> Bool {
        guard SidebarTelemetryLimits.utf8ByteCount(key) <= SidebarTelemetryLimits.maxKeyBytes,
              pid > 0,
              agentPIDs[key] != nil || agentPIDs.count < SidebarTelemetryLimits.maxAgentPIDs else {
            return false
        }
        agentPIDs[key] = pid
        return true
    }

    @discardableResult
    func setSidebarTTYName(panelId: UUID, ttyName: String) -> Bool {
        guard let normalized = normalizedSidebarTTYName(ttyName) else { return false }
        surfaceTTYNames[panelId] = normalized
        return true
    }

    @discardableResult
    func setSidebarMetadataBlock(_ block: SidebarMetadataBlock) -> Bool {
        guard SidebarTelemetryLimits.utf8ByteCount(block.key) <= SidebarTelemetryLimits.maxKeyBytes,
              SidebarTelemetryLimits.utf8ByteCount(block.markdown) <= SidebarTelemetryLimits.maxMetadataMarkdownBytes else {
            return false
        }
        while metadataBlocks[block.key] == nil,
              metadataBlocks.count >= SidebarTelemetryLimits.maxMetadataBlocks,
              let oldestKey = metadataBlocks.min(by: { lhs, rhs in
                  if lhs.value.timestamp != rhs.value.timestamp {
                      return lhs.value.timestamp < rhs.value.timestamp
                  }
                  return lhs.key < rhs.key
              })?.key {
            metadataBlocks.removeValue(forKey: oldestKey)
        }
        metadataBlocks[block.key] = block
        return true
    }

    @discardableResult
    func appendSidebarLogEntry(_ entry: SidebarLogEntry) -> Bool {
        guard !entry.message.isEmpty,
              SidebarTelemetryLimits.utf8ByteCount(entry.message) <= SidebarTelemetryLimits.maxLogMessageBytes,
              SidebarTelemetryLimits.isWithinUTF8Limit(
                  entry.source,
                  maxBytes: SidebarTelemetryLimits.maxLogSourceBytes
              ) else {
            return false
        }
        logEntries.append(entry)
        let limit = SidebarTelemetryLimits.configuredMaxLogEntries()
        if logEntries.count > limit {
            logEntries.removeFirst(logEntries.count - limit)
        }
        return true
    }

    func appendSidebarLog(message: String, level: SidebarLogLevel, source: String?) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = appendSidebarLogEntry(
            SidebarLogEntry(message: trimmed, level: level, source: source, timestamp: Date())
        )
    }

    func restoreSidebarLogEntries(_ entries: [SidebarLogEntry]) {
        logEntries.removeAll(keepingCapacity: true)
        for entry in entries {
            _ = appendSidebarLogEntry(entry)
        }
    }
}
