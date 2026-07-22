// TabItemView + its exclusive helper-view cluster, extracted from ContentView.swift (nuclear-review #94.2).
// Pure move — behavior-identical relocation. Do NOT touch TabItemView's Equatable
// conformance, its precomputed let parameters, or the .equatable() call site in
// VerticalTabsSidebar (ContentView.swift) — see CLAUDE.md typing-latency-sensitive paths.
//
// Access-level widening: TabItemView was `private struct` (file-private to the old
// ContentView.swift); widened to internal (default) so VerticalTabsSidebar, which stays
// in ContentView.swift, can still construct it. No other behavior change.

import AppKit
import Bonsplit
import Combine
import SwiftUI


// PERF: TabItemView is Equatable so SwiftUI skips body re-evaluation when
// the parent rebuilds with unchanged values. Without this, every TabManager
// or NotificationStore publish causes ALL tab items to re-evaluate (~18% of
// main thread during typing). If you add new properties, update == below.
// Reactive workspace state inside the row must not rely on parent diffs alone:
// `.equatable()` can otherwise leave sidebar badges/details stale until an
// unrelated parent change sneaks through. Keep the workspace reference plain
// and bridge only sidebar-visible workspace changes into local state.
// Do NOT add @EnvironmentObject or new @Binding without updating ==.
// Do NOT remove .equatable() from the ForEach call site in VerticalTabsSidebar.
struct TabItemView: View, Equatable {
    private static let workspaceObservationCoalesceInterval: RunLoop.SchedulerTimeType.Stride = .milliseconds(40)

    // Closures, Bindings, and object references are excluded from ==
    // because they're recreated every parent eval but don't affect rendering.
    nonisolated static func == (lhs: TabItemView, rhs: TabItemView) -> Bool {
        lhs.tab === rhs.tab &&
        lhs.index == rhs.index &&
        lhs.isActive == rhs.isActive &&
        lhs.workspaceShortcutDigit == rhs.workspaceShortcutDigit &&
        lhs.workspaceShortcutModifierSymbol == rhs.workspaceShortcutModifierSymbol &&
        lhs.canCloseWorkspace == rhs.canCloseWorkspace &&
        lhs.accessibilityWorkspaceCount == rhs.accessibilityWorkspaceCount &&
        lhs.unreadCount == rhs.unreadCount &&
        lhs.latestNotificationText == rhs.latestNotificationText &&
        lhs.rowSpacing == rhs.rowSpacing &&
        lhs.showsModifierShortcutHints == rhs.showsModifierShortcutHints &&
        lhs.contextMenuWorkspaceIds == rhs.contextMenuWorkspaceIds &&
        lhs.remoteContextMenuWorkspaceIds == rhs.remoteContextMenuWorkspaceIds &&
        lhs.allRemoteContextMenuTargetsConnecting == rhs.allRemoteContextMenuTargetsConnecting &&
        lhs.allRemoteContextMenuTargetsDisconnected == rhs.allRemoteContextMenuTargetsDisconnected &&
        lhs.settings == rhs.settings &&
        lhs.showsWorktreeBadge == rhs.showsWorktreeBadge
    }

    // Use plain references instead of @EnvironmentObject to avoid subscribing
    // to ALL changes on these objects. Body reads use precomputed parameters;
    // action handlers use the plain references without triggering re-evaluation.
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    @Environment(\.colorScheme) private var colorScheme
    let tab: Workspace
    let index: Int
    let isActive: Bool
    let workspaceShortcutDigit: Int?
    let workspaceShortcutModifierSymbol: String
    let canCloseWorkspace: Bool
    let accessibilityWorkspaceCount: Int
    let unreadCount: Int
    let latestNotificationText: String?
    let rowSpacing: CGFloat
    let setSelectionToTabs: () -> Void
    @Binding var selectedTabIds: Set<UUID>
    @Binding var lastSidebarSelectionIndex: Int?
    let showsModifierShortcutHints: Bool
    let dragAutoScrollController: SidebarDragAutoScrollController
    @Binding var draggedTabId: UUID?
    @Binding var dropIndicator: SidebarDropIndicator?
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let settings: SidebarTabItemSettingsSnapshot
    /// Set at creation time by `worktree.create`/`worktree.open` (`Workspace.worktreeParentWorkspaceId`).
    /// Precomputed by the caller (VerticalTabsSidebar) and included in `==` -- see the
    /// Equatable typing-latency contract at the top of this file. Do NOT read
    /// `tab.worktreeParentWorkspaceId` directly in `body`.
    let showsWorktreeBadge: Bool
    @State private var workspaceObservationGeneration: UInt64 = 0
    @State private var isHovering = false
    @State private var rowHeight: CGFloat = 1
    // Cached results of the expensive bonsplit tree walk + branch/dir/PR snapshot.
    // Updated only by the debounced publisher, onAppear, and settings changes —
    // NOT by the immediate publisher (title keystrokes). This prevents the tree
    // walk from running on every keystroke in single-panel workspaces.
    @State private var cachedOrderedPanelIds: [UUID]? = nil
    @State private var cachedBranchDirectoryLines: [VerticalBranchDirectoryLine] = []
    @State private var cachedPullRequestRows: [PullRequestDisplay] = []

    var isMultiSelected: Bool {
        selectedTabIds.contains(tab.id)
    }

    private var isBeingDragged: Bool {
        draggedTabId == tab.id
    }

    private var sidebarShortcutHintXOffset: Double {
        settings.sidebarShortcutHintXOffset
    }

    private var sidebarShortcutHintYOffset: Double {
        settings.sidebarShortcutHintYOffset
    }

    private var alwaysShowShortcutHints: Bool {
        settings.alwaysShowShortcutHints
    }

    private var sidebarShowGitBranch: Bool {
        settings.showsGitBranch
    }

    private var sidebarBranchVerticalLayout: Bool {
        settings.usesVerticalBranchLayout
    }

    private var sidebarShowGitBranchIcon: Bool {
        settings.showsGitBranchIcon
    }

    private var sidebarShowSSH: Bool {
        settings.showsSSH
    }

    private var activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle {
        settings.activeTabIndicatorStyle
    }

    private var sidebarSelectionColorHex: String? {
        settings.selectionColorHex
    }

    private var sidebarNotificationBadgeColorHex: String? {
        settings.notificationBadgeColorHex
    }

    private var openSidebarPullRequestLinksInProgramaBrowser: Bool {
        settings.openPullRequestLinksInProgramaBrowser
    }

    private var openSidebarPortLinksInProgramaBrowser: Bool {
        settings.openPortLinksInProgramaBrowser
    }

    private var titleFontWeight: Font.Weight {
        .semibold
    }

    private var showsLeadingRail: Bool {
        explicitRailColor != nil
    }

    private var activeBorderLineWidth: CGFloat {
        switch activeTabIndicatorStyle {
        case .leftRail:
            return 0
        case .solidFill:
            return isActive ? 1.5 : 0
        }
    }

    private var activeBorderColor: Color {
        guard isActive else { return .clear }
        switch activeTabIndicatorStyle {
        case .leftRail:
            return .clear
        case .solidFill:
            return Color.primary.opacity(0.5)
        }
    }

    private var usesInvertedActiveForeground: Bool {
        isActive
    }

    private var activePrimaryTextColor: Color {
        usesInvertedActiveForeground
            ? Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 1.0))
            : .primary
    }

    private func activeSecondaryColor(_ opacity: Double = 0.75) -> Color {
        usesInvertedActiveForeground
            ? Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat(opacity)))
            : .secondary
    }

    private var activeUnreadBadgeFillColor: Color {
        if let hex = sidebarNotificationBadgeColorHex, let nsColor = NSColor(hex: hex) {
            return Color(nsColor: nsColor)
        }
        return usesInvertedActiveForeground ? Color.white.opacity(0.25) : programaAccentColor()
    }

    // MARK: - Agent status badge (issue #164, v1 hook tier)
    //
    // Worst-of aggregate across every surface in this workspace (a single blocked surface
    // makes the whole tab read as blocked). Fed exclusively by installed lifecycle hooks
    // (Claude Code / Codex / OpenCode) via `Workspace.panelAgentStates` — no in-body
    // subscription needed: `tab` is read directly (same pattern as `tab.progress` /
    // `tab.isPinned` above), and `panelAgentStates` is already wired into
    // `sidebarObservationPublisher` (Workspace.swift), so `.onReceive` below already
    // triggers the re-render this relies on. No change to TabItemView's Equatable
    // conformance or precomputed `let` parameters is needed or should be made — see
    // CLAUDE.md typing-latency-sensitive paths.
    private var agentActivityState: AgentActivityState? {
        tab.aggregateAgentState
    }

    private var agentStateBadgeSystemImage: String? {
        switch agentActivityState {
        case .blocked: return "exclamationmark.circle.fill"
        case .working: return "bolt.fill"
        case .idle: return "moon.fill"
        case nil: return nil
        }
    }

    private var agentStateBadgeColor: Color {
        switch agentActivityState {
        case .blocked: return .red
        case .working: return programaAccentColor()
        case .idle, nil: return activeSecondaryColor(0.6)
        }
    }

    private var agentStateBadgeAccessibilityLabel: String {
        switch agentActivityState {
        case .blocked:
            return String(localized: "sidebar.agentState.blocked", defaultValue: "Agent blocked, needs your input")
        case .working:
            return String(localized: "sidebar.agentState.working", defaultValue: "Agent working")
        case .idle:
            return String(localized: "sidebar.agentState.idle", defaultValue: "Agent idle")
        case nil:
            return ""
        }
    }

    private var activeProgressTrackColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.15) : Color.secondary.opacity(0.2)
    }

    private var activeProgressFillColor: Color {
        usesInvertedActiveForeground ? Color.white.opacity(0.8) : programaAccentColor()
    }

    private var shortcutHintEmphasis: Double {
        usesInvertedActiveForeground ? 1.0 : 0.9
    }

    private var showCloseButton: Bool {
        (isHovering || isActive) && canCloseWorkspace && !(showsModifierShortcutHints || alwaysShowShortcutHints)
    }

    private var workspaceShortcutLabel: String? {
        guard let workspaceShortcutDigit else { return nil }
        return "\(workspaceShortcutModifierSymbol)\(workspaceShortcutDigit)"
    }

    private var showsWorkspaceShortcutHint: Bool {
        (showsModifierShortcutHints || alwaysShowShortcutHints) && workspaceShortcutLabel != nil
    }

    private var trailingAccessoryWidth: CGFloat {
        SidebarTrailingAccessoryWidthPolicy.width(
            canCloseWorkspace: canCloseWorkspace,
            showsWorkspaceShortcutHint: showsWorkspaceShortcutHint,
            workspaceShortcutLabel: workspaceShortcutLabel,
            debugXOffset: sidebarShortcutHintXOffset
        )
    }

    private var remoteWorkspaceSidebarText: String? {
        guard tab.hasActiveRemoteTerminalSessions else { return nil }
        let trimmedTarget = tab.remoteDisplayTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedTarget, !trimmedTarget.isEmpty {
            return trimmedTarget
        }
        return String(localized: "sidebar.remote.subtitleFallback", defaultValue: "SSH workspace")
    }

    private var copyableSidebarSSHError: String? {
        let fallbackTarget = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let trimmedDetail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tab.remoteConnectionState == .error, let trimmedDetail, !trimmedDetail.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: trimmedDetail
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        if let statusValue = tab.statusEntries["remote.error"]?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !statusValue.isEmpty {
            let entry = SidebarRemoteErrorCopyEntry(
                workspaceTitle: tab.title,
                target: fallbackTarget,
                detail: statusValue
            )
            return SidebarRemoteErrorCopySupport.clipboardText(for: [entry])
        }
        return nil
    }

    private var remoteConnectionStatusText: String {
        switch tab.remoteConnectionState {
        case .connected:
            return String(localized: "remote.status.connected", defaultValue: "Connected")
        case .connecting:
            return String(localized: "remote.status.connecting", defaultValue: "Connecting")
        case .error:
            return String(localized: "remote.status.error", defaultValue: "Error")
        case .disconnected:
            return String(localized: "remote.status.disconnected", defaultValue: "Disconnected")
        }
    }

    @ViewBuilder
    private var remoteWorkspaceSection: some View {
        if sidebarShowSSH, let remoteWorkspaceSidebarText {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(remoteWorkspaceSidebarText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    Text(remoteConnectionStatusText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(activeSecondaryColor(0.58))
                        .lineLimit(1)
                }
            }
            .padding(.top, latestNotificationText == nil ? 1 : 2)
            .safeHelp(remoteStateHelpText)
        }
    }

    private func copyTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility {
        settings.visibleAuxiliaryDetails
    }

    var body: some View {
        let _ = workspaceObservationGeneration
        let closeWorkspaceTooltip = String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close Workspace")
        let protectedWorkspaceTooltip = String(
            localized: "sidebar.pinnedWorkspaceProtected.tooltip",
            defaultValue: "Pinned workspace. Closing requires confirmation."
        )
        let closeButtonTooltip = tab.isPinned
            ? protectedWorkspaceTooltip
            : KeyboardShortcutSettings.Action.closeWorkspace.tooltip(closeWorkspaceTooltip)
        let worktreeBadgeTooltip = String(localized: "sidebar.worktreeBadge.tooltip", defaultValue: "Git worktree workspace")
        let worktreeBadgeAccessibilityLabel = String(localized: "sidebar.worktreeBadge.accessibilityLabel", defaultValue: "Git worktree workspace")
        let accessibilityHintText = String(localized: "sidebar.workspace.accessibilityHint", defaultValue: "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.")
        let moveUpActionText = String(localized: "sidebar.workspace.moveUpAction", defaultValue: "Move Up")
        let moveDownActionText = String(localized: "sidebar.workspace.moveDownAction", defaultValue: "Move Down")
        let latestNotificationSubtitle = latestNotificationText
        let effectiveSubtitle = latestNotificationSubtitle
        let detailVisibility = visibleAuxiliaryDetails
        // Read from cache — updated only by the debounced publisher, onAppear,
        // and settings changes. Title-keystroke re-renders skip this tree walk.
        let orderedPanelIds: [UUID]? = cachedOrderedPanelIds
        let branchDirectoryLines: [VerticalBranchDirectoryLine] = cachedBranchDirectoryLines
        let pullRequestRows: [PullRequestDisplay] = cachedPullRequestRows
        let compactGitBranchSummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  sidebarShowGitBranch,
                  let orderedPanelIds else {
                return nil
            }
            return gitBranchSummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactDirectorySummaryText: String? = {
            guard detailVisibility.showsBranchDirectory,
                  !sidebarBranchVerticalLayout,
                  let orderedPanelIds else {
                return nil
            }
            return directorySummaryText(orderedPanelIds: orderedPanelIds)
        }()
        let compactBranchDirectoryRow = branchDirectoryRow(
            gitSummary: compactGitBranchSummaryText,
            directorySummary: compactDirectorySummaryText
        )
        let branchLinesContainBranch = sidebarShowGitBranch && branchDirectoryLines.contains { $0.branch != nil }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if showsWorktreeBadge {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(activeSecondaryColor(0.7))
                        .safeHelp(worktreeBadgeTooltip)
                        .accessibilityLabel(Text(worktreeBadgeAccessibilityLabel))
                }

                if unreadCount > 0 {
                    ZStack {
                        Circle()
                            .fill(activeUnreadBadgeFillColor)
                        Text("\(unreadCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 16, height: 16)
                }

                if tab.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .safeHelp(protectedWorkspaceTooltip)
                }

                if let agentStateBadgeSystemImage {
                    Image(systemName: agentStateBadgeSystemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(agentStateBadgeColor)
                        .safeHelp(agentStateBadgeAccessibilityLabel)
                        .accessibilityLabel(Text(agentStateBadgeAccessibilityLabel))
                }

                Text(tab.title)
                    .font(.system(size: 12.5, weight: titleFontWeight))
                    .foregroundColor(activePrimaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                ZStack(alignment: .trailing) {
                    Button(action: {
                        #if DEBUG
                        dlog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=button")
                        #endif
                        tabManager.closeWorkspaceWithConfirmation(tab)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(activeSecondaryColor(0.7))
                    }
                    .buttonStyle(.plain)
                    .safeHelp(closeButtonTooltip)
                    .frame(width: SidebarTrailingAccessoryWidthPolicy.closeButtonWidth, height: 16, alignment: .center)
                    .opacity(showCloseButton && !showsWorkspaceShortcutHint ? 1 : 0)
                    .allowsHitTesting(showCloseButton && !showsWorkspaceShortcutHint)

                    if showsWorkspaceShortcutHint, let workspaceShortcutLabel {
                        Text(workspaceShortcutLabel)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(activePrimaryTextColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ShortcutHintPillBackground(emphasis: shortcutHintEmphasis))
                            .offset(
                                x: ShortcutHintDebugSettings.clamped(sidebarShortcutHintXOffset),
                                y: ShortcutHintDebugSettings.clamped(sidebarShortcutHintYOffset)
                            )
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.14), value: showsModifierShortcutHints || alwaysShowShortcutHints)
                .frame(width: trailingAccessoryWidth, height: 16, alignment: .trailing)
            }

            if let description = tab.customDescription {
                SidebarWorkspaceDescriptionText(
                    markdown: description,
                    isActive: usesInvertedActiveForeground
                )
                .id(description)
            }

            if let subtitle = effectiveSubtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(activeSecondaryColor(0.8))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
            }

            remoteWorkspaceSection

            if detailVisibility.showsMetadata {
                let metadataEntries = tab.sidebarStatusEntriesInDisplayOrder()
                let metadataBlocks = tab.sidebarMetadataBlocksInDisplayOrder()
                if !metadataEntries.isEmpty {
                    SidebarMetadataRows(
                        entries: metadataEntries,
                        isActive: usesInvertedActiveForeground,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if !metadataBlocks.isEmpty {
                    SidebarMetadataMarkdownBlocks(
                        blocks: metadataBlocks,
                        isActive: usesInvertedActiveForeground,
                        onFocus: { updateSelection() }
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Latest log entry
            if detailVisibility.showsLog, let latestLog = tab.logEntries.last {
                HStack(spacing: 4) {
                    Image(systemName: logLevelIcon(latestLog.level))
                        .font(.system(size: 8))
                        .foregroundColor(logLevelColor(latestLog.level, isActive: usesInvertedActiveForeground))
                    Text(latestLog.message)
                        .font(.system(size: 10))
                        .foregroundColor(activeSecondaryColor(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Progress bar
            if detailVisibility.showsProgress, let progress = tab.progress {
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(activeProgressTrackColor)
                            Capsule()
                                .fill(activeProgressFillColor)
                                .frame(width: max(0, geo.size.width * CGFloat(progress.value)))
                        }
                    }
                    .frame(height: 3)

                    if let label = progress.label {
                        Text(label)
                            .font(.system(size: 9))
                            .foregroundColor(activeSecondaryColor(0.6))
                            .lineLimit(1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Branch + directory row
            if detailVisibility.showsBranchDirectory {
                if sidebarBranchVerticalLayout {
                    if !branchDirectoryLines.isEmpty {
                        HStack(alignment: .top, spacing: 3) {
                            if sidebarShowGitBranchIcon, branchLinesContainBranch {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9))
                                    .foregroundColor(activeSecondaryColor(0.6))
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(branchDirectoryLines.enumerated()), id: \.offset) { _, line in
                                    HStack(spacing: 3) {
                                        if let branch = line.branch {
                                            Text(branch)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(activeSecondaryColor(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                        if line.branch != nil, line.directory != nil {
                                            Image(systemName: "circle.fill")
                                                .font(.system(size: 3))
                                                .foregroundColor(activeSecondaryColor(0.6))
                                                .padding(.horizontal, 1)
                                        }
                                        if let directory = line.directory {
                                            Text(directory)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundColor(activeSecondaryColor(0.75))
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if let dirRow = compactBranchDirectoryRow {
                    HStack(spacing: 3) {
                        if sidebarShowGitBranchIcon, compactGitBranchSummaryText != nil {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9))
                                .foregroundColor(activeSecondaryColor(0.6))
                        }
                        Text(dirRow)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(activeSecondaryColor(0.75))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            // Pull request rows
            if detailVisibility.showsPullRequests, !pullRequestRows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(pullRequestRows) { pullRequest in
                        Button(action: {
                            openPullRequestLink(pullRequest.url)
                        }) {
                            HStack(spacing: 4) {
                                PullRequestStatusIcon(
                                    status: pullRequest.status,
                                    color: pullRequestForegroundColor
                                )
                                Text("\(pullRequest.label) #\(pullRequest.number)")
                                    .underline()
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(pullRequestStatusLabel(pullRequest.status, checks: pullRequest.checks))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(pullRequestForegroundColor)
                        }
                        .buttonStyle(.plain)
                        .safeHelp(String(localized: "sidebar.pullRequest.openTooltip", defaultValue: "Open \(pullRequest.label) #\(pullRequest.number)"))
                    }
                }
            }

            // Ports row
            if detailVisibility.showsPorts, !tab.listeningPorts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tab.listeningPorts, id: \.self) { port in
                        Button(action: {
                            openPortLink(port)
                        }) {
                            Text(String(localized: "sidebar.port.label", defaultValue: ":\(port)"))
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .safeHelp(String(localized: "sidebar.port.openTooltip", defaultValue: "Open localhost:\(port)"))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(activeSecondaryColor(0.75))
                .lineLimit(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: tab.logEntries.count)
        .animation(.easeInOut(duration: 0.2), value: tab.progress != nil)
        .animation(.easeInOut(duration: 0.2), value: tab.metadataBlocks.count)
        .padding(.leading, showsWorktreeBadge ? 6 : 0)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(activeBorderColor, lineWidth: activeBorderLineWidth)
                }
                .overlay(alignment: .leading) {
                    if showsLeadingRail {
                        Capsule(style: .continuous)
                            .fill(railColor)
                            .frame(width: 3)
                            .padding(.leading, 4)
                            .padding(.vertical, 5)
                            .offset(x: -1)
                    }
                }
        )
        .padding(.horizontal, 6)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        rowHeight = max(proxy.size.height, 1)
                    }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        rowHeight = max(newHeight, 1)
                    }
            }
        }
        .contentShape(Rectangle())
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay {
            MiddleClickCapture {
                #if DEBUG
                dlog("sidebar.close workspace=\(tab.id.uuidString.prefix(5)) method=middleClick")
                #endif
                tabManager.closeWorkspaceWithConfirmation(tab)
            }
        }
        .overlay(alignment: .top) {
            if showsCenteredTopDropIndicator {
                Rectangle()
                    .fill(programaAccentColor())
                    .frame(height: 2)
                    .padding(.horizontal, 8)
                    .offset(y: index == 0 ? 0 : -(rowSpacing / 2))
            }
        }
        .onReceive(
            tab.sidebarImmediateObservationPublisher
                .receive(on: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            dlog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=immediate " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            workspaceObservationGeneration &+= 1
        }
        .onReceive(
            tab.sidebarObservationPublisher
                .receive(on: RunLoop.main)
                // Prompt-time sidebar telemetry can arrive as a short burst
                // (pwd, branch, PR, shell state). Coalesce that burst so the
                // row redraws once with the settled state instead of blinking.
                .debounce(for: Self.workspaceObservationCoalesceInterval, scheduler: RunLoop.main)
        ) { _ in
#if DEBUG
            let description = tab.customDescription ?? ""
            dlog(
                "sidebar.row.invalidate workspace=\(tab.id.uuidString.prefix(8)) " +
                "source=debounced " +
                "title=\"\(debugCommandPaletteTextPreview(tab.title))\" " +
                "descLen=\((description as NSString).length) " +
                "desc=\"\(debugCommandPaletteTextPreview(description))\""
            )
#endif
            // Refresh expensive caches (tree walk, branch/dir/PR) before
            // signalling a redraw. The immediate publisher intentionally does
            // NOT call this so that title keystrokes skip the tree walk.
            recomputeSidebarDetailCache()
            workspaceObservationGeneration &+= 1
        }
        .onDrag {
            #if DEBUG
            dlog("sidebar.onDrag tab=\(tab.id.uuidString.prefix(5))")
            #endif
            draggedTabId = tab.id
            dropIndicator = nil
            return SidebarTabDragPayload.provider(for: tab.id)
        }
        .internalOnlyTabDrag()
        .onDrop(of: SidebarTabDragPayload.dropContentTypes, delegate: SidebarTabDropDelegate(
            targetTabId: tab.id,
            tabManager: tabManager,
            draggedTabId: $draggedTabId,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex,
            targetRowHeight: rowHeight,
            dragAutoScrollController: dragAutoScrollController,
            dropIndicator: $dropIndicator
        ))
        .onDrop(of: BonsplitTabDragPayload.dropContentTypes, delegate: SidebarBonsplitTabDropDelegate(
            targetWorkspaceId: tab.id,
            tabManager: tabManager,
            selectedTabIds: $selectedTabIds,
            lastSidebarSelectionIndex: $lastSidebarSelectionIndex
        ))
        .onTapGesture {
            updateSelection()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityHint(Text(accessibilityHintText))
        .accessibilityAction(named: Text(moveUpActionText)) {
            moveBy(-1)
        }
        .accessibilityAction(named: Text(moveDownActionText)) {
            moveBy(1)
        }
        .onAppear {
            // Prime the cache so branch/dir/PR rows appear immediately,
            // before the first debounced publisher fires.
            recomputeSidebarDetailCache()
        }
        .onChange(of: visibleAuxiliaryDetails) {
            // Toggling branch/PR columns changes which data we need to cache.
            recomputeSidebarDetailCache()
        }
        .contextMenu { workspaceContextMenu }
    }

    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    private func remoteContextMenuWorkspaces() -> [Workspace] {
        guard !remoteContextMenuWorkspaceIds.isEmpty else { return [] }
        return remoteContextMenuWorkspaceIds.compactMap { workspaceId in
            tabManager.tabs.first(where: { $0.id == workspaceId })
        }
    }

    @ViewBuilder
    private var workspaceContextMenu: some View {
        let targetIds = contextMenuWorkspaceIds
        let isMulti = targetIds.count > 1
        let tabColorPalette = WorkspaceTabColorSettings.palette()
        let shouldPin = !tab.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        Button(pinLabel) {
            for id in targetIds {
                if let tab = tabManager.tabs.first(where: { $0.id == id }) {
                    tabManager.setPinned(tab, pinned: shouldPin)
                }
            }
            syncSelectionAfterMutation()
        }

        if let key = renameWorkspaceShortcut.keyEquivalent {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
            .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
        } else {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
        }

        if tab.hasCustomTitle {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                tabManager.clearCustomTitle(tabId: tab.id)
            }
        }

        if !isMulti {
            if let key = editWorkspaceDescriptionShortcut.keyEquivalent {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
                .keyboardShortcut(key, modifiers: editWorkspaceDescriptionShortcut.eventModifiers)
            } else {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
            }

            if tab.hasCustomDescription {
                Button(String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")) {
                    tabManager.clearCustomDescription(tabId: tab.id)
                }
            }
        }

        if !remoteContextMenuWorkspaceIds.isEmpty {
            Divider()

            Button(reconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.reconnectRemoteConnection()
                }
            }
            .disabled(allRemoteContextMenuTargetsConnecting)

            Button(disconnectLabel) {
                for workspace in remoteContextMenuWorkspaces() {
                    workspace.disconnectRemoteConnection(clearConfiguration: false)
                }
            }
            .disabled(allRemoteContextMenuTargetsDisconnected)
        }

        Menu(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {
            if tab.customColor != nil {
                Button {
                    applyTabColor(nil, targetIds: targetIds)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }

            Button {
                promptCustomColor(targetIds: targetIds)
            } label: {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }

            if !tabColorPalette.isEmpty {
                Divider()
            }

            ForEach(tabColorPalette, id: \.id) { entry in
                Button {
                    applyTabColor(entry.hex, targetIds: targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: coloredCircleImage(color: tabColorSwatchColor(for: entry.hex)))
                    }
                }
            }
        }

        if let copyableSidebarSSHError {
            Button(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
                copyTextToPasteboard(copyableSidebarSSHError)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveBy(-1)
        }
        .disabled(index == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveBy(1)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            tabManager.moveTabsToTop(Set(targetIds))
            syncSelectionAfterMutation()
        }
        .disabled(targetIds.isEmpty)

        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                moveWorkspacesToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    moveWorkspaces(targetIds, toWindow: target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        if let key = closeWorkspaceShortcut.keyEquivalent {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(closeLabel) {
                closeTabs(targetIds, allowPinned: true)
            }
            .disabled(targetIds.isEmpty)
        }

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            closeOtherTabs(targetIds)
        }
        .disabled(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            closeTabsBelow(tabId: tab.id)
        }
        .disabled(index >= tabManager.tabs.count - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            closeTabsAbove(tabId: tab.id)
        }
        .disabled(index == 0)

        Divider()

        Button(markReadLabel) {
            markTabsRead(targetIds)
        }
        .disabled(!hasUnreadNotifications(in: targetIds))

        Button(markUnreadLabel) {
            markTabsUnread(targetIds)
        }
        .disabled(!hasReadNotifications(in: targetIds))

        Button(clearLatestNotificationLabel) {
            clearLatestNotifications(targetIds)
        }
        .disabled(!hasLatestNotifications(in: targetIds))
    }

    private var selectionBackgroundColor: NSColor {
        if let hex = sidebarSelectionColorHex, let parsed = NSColor(hex: hex) {
            return parsed
        }
        return programaAccentNSColor(for: colorScheme)
    }

    private var backgroundColor: Color {
        switch activeTabIndicatorStyle {
        case .leftRail:
            if isActive        { return Color(nsColor: selectionBackgroundColor) }
            if isMultiSelected { return programaAccentColor().opacity(0.25) }
            return Color.clear
        case .solidFill:
            if isActive { return Color(nsColor: selectionBackgroundColor) }
            if let custom = resolvedCustomTabColor {
                if isMultiSelected { return custom.opacity(0.35) }
                return custom.opacity(0.7)
            }
            if isMultiSelected { return programaAccentColor().opacity(0.25) }
            return Color.clear
        }
    }

    private var railColor: Color {
        explicitRailColor ?? .clear
    }

    private var explicitRailColor: Color? {
        guard activeTabIndicatorStyle == .leftRail,
              let custom = resolvedCustomTabColor else {
            return nil
        }
        return custom.opacity(0.95)
    }

    private var resolvedCustomTabColor: Color? {
        guard let hex = tab.customColor else { return nil }
        return WorkspaceTabColorSettings.displayColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    private func tabColorSwatchColor(for hex: String) -> NSColor {
        WorkspaceTabColorSettings.displayNSColor(
            hex: hex,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        ) ?? NSColor(hex: hex) ?? .gray
    }

    private var showsCenteredTopDropIndicator: Bool {
        guard draggedTabId != nil, let indicator = dropIndicator else { return false }
        if indicator.tabId == tab.id && indicator.edge == .top {
            return true
        }

        guard indicator.edge == .bottom,
              let currentIndex = tabManager.tabs.firstIndex(where: { $0.id == tab.id }),
              currentIndex > 0
        else {
            return false
        }
        return tabManager.tabs[currentIndex - 1].id == indicator.tabId
    }

    private var accessibilityTitle: String {
        String(localized: "accessibility.workspacePosition", defaultValue: "\(tab.title), workspace \(index + 1) of \(accessibilityWorkspaceCount)")
    }

    private func moveBy(_ delta: Int) {
        let targetIndex = index + delta
        guard targetIndex >= 0, targetIndex < tabManager.tabs.count else { return }
        guard tabManager.reorderWorkspace(tabId: tab.id, toIndex: targetIndex) else { return }
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == tab.id }
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    private func updateSelection() {
        #if DEBUG
        let mods = NSEvent.modifierFlags
        var modStr = ""
        if mods.contains(.command) { modStr += "cmd " }
        if mods.contains(.shift) { modStr += "shift " }
        if mods.contains(.option) { modStr += "opt " }
        if mods.contains(.control) { modStr += "ctrl " }
        dlog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) modifiers=\(modStr.isEmpty ? "none" : modStr.trimmingCharacters(in: .whitespaces))")
        #endif
        let modifiers = NSEvent.modifierFlags
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id

        if isShift, let lastIndex = lastSidebarSelectionIndex {
            let lower = min(lastIndex, index)
            let upper = max(lastIndex, index)
            let rangeIds = tabManager.tabs[lower...upper].map { $0.id }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }

        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    private func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    private func closeOtherTabs(_ targetIds: [UUID]) {
        let keepIds = Set(targetIds)
        let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsBelow(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func closeTabsAbove(tabId: UUID) {
        guard let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
        closeTabs(idsToClose, allowPinned: true)
    }

    private func markTabsRead(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markRead(forTabId: id)
        }
    }

    private func markTabsUnread(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.markUnread(forTabId: id)
        }
    }

    private func clearLatestNotifications(_ targetIds: [UUID]) {
        for id in targetIds {
            notificationStore.clearLatestNotification(forTabId: id)
        }
    }

    private func hasUnreadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && !$0.isRead }
    }

    private func hasReadNotifications(in targetIds: [UUID]) -> Bool {
        let targetSet = Set(targetIds)
        return notificationStore.notifications.contains { targetSet.contains($0.tabId) && $0.isRead }
    }

    private func hasLatestNotifications(in targetIds: [UUID]) -> Bool {
        targetIds.contains { notificationStore.latestNotification(forTabId: $0) != nil }
    }

    private func syncSelectionAfterMutation() {
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        if let selectedId = tabManager.selectedTabId {
            lastSidebarSelectionIndex = tabManager.tabs.firstIndex { $0.id == selectedId }
        }
    }

    private var remoteStateHelpText: String {
        let target = tab.remoteDisplayTarget ?? String(
            localized: "sidebar.remote.help.targetFallback",
            defaultValue: "remote host"
        )
        let detail = tab.remoteConnectionDetail?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tab.remoteConnectionState {
        case .connected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connected",
                    defaultValue: "SSH connected to %@"
                ),
                locale: .current,
                target
            )
        case .connecting:
            return String(
                format: String(
                    localized: "sidebar.remote.help.connecting",
                    defaultValue: "SSH connecting to %@"
                ),
                locale: .current,
                target
            )
        case .error:
            if let detail, !detail.isEmpty {
                return String(
                    format: String(
                        localized: "sidebar.remote.help.errorWithDetail",
                        defaultValue: "SSH error for %@: %@"
                    ),
                    locale: .current,
                    target,
                    detail
                )
            }
            return String(
                format: String(
                    localized: "sidebar.remote.help.error",
                    defaultValue: "SSH error for %@"
                ),
                locale: .current,
                target
            )
        case .disconnected:
            return String(
                format: String(
                    localized: "sidebar.remote.help.disconnected",
                    defaultValue: "SSH disconnected from %@"
                ),
                locale: .current,
                target
            )
        }
    }
    private func moveWorkspaces(_ workspaceIds: [UUID], toWindow windowId: UUID) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }

        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    private func moveWorkspacesToNewWindow(_ workspaceIds: [UUID]) {
        guard let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { workspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }

        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }

        if orderedWorkspaceIds.count > 1 {
            for workspaceId in orderedWorkspaceIds.dropFirst() {
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: false)
            }
            if let finalWorkspaceId = orderedWorkspaceIds.last {
                _ = app.moveWorkspaceToWindow(workspaceId: finalWorkspaceId, windowId: newWindowId, focus: true)
            }
        }

        selectedTabIds.subtract(orderedWorkspaceIds)
        syncSelectionAfterMutation()
    }

    // latestNotificationText is now passed as a parameter from the parent view
    // to avoid subscribing to notificationStore changes in every TabItemView.

    private func branchDirectoryRow(
        gitSummary: String?,
        directorySummary: String?
    ) -> String? {
        var parts: [String] = []

        if let gitSummary {
            parts.append(gitSummary)
        }

        if let directorySummary {
            parts.append(directorySummary)
        }

        let result = parts.joined(separator: " · ")
        return result.isEmpty ? nil : result
    }

    private func gitBranchSummaryText(orderedPanelIds: [UUID]) -> String? {
        let lines = gitBranchSummaryLines(orderedPanelIds: orderedPanelIds)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: " | ")
    }

    private func gitBranchSummaryLines(orderedPanelIds: [UUID]) -> [String] {
        tab.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).map { branch in
            "\(branch.branch)\(branch.isDirty ? "*" : "")"
        }
    }

    private struct VerticalBranchDirectoryLine {
        let branch: String?
        let directory: String?
    }

    /// Recomputes the expensive sidebar detail caches (bonsplit tree walk,
    /// branch/directory lines, PR snapshot) and writes them into @State.
    /// Must be called only from the debounced publisher, onAppear, and
    /// settings-change handlers — never from the immediate (title) publisher.
    private func recomputeSidebarDetailCache() {
        let detail = visibleAuxiliaryDetails
        let needsDetail = detail.showsBranchDirectory || detail.showsPullRequests
        let ids: [UUID]? = needsDetail ? tab.sidebarOrderedPanelIds() : nil
        cachedOrderedPanelIds = ids
        cachedBranchDirectoryLines = {
            guard detail.showsBranchDirectory, sidebarBranchVerticalLayout, let ids else { return [] }
            return verticalBranchDirectoryLines(orderedPanelIds: ids)
        }()
        cachedPullRequestRows = {
            guard detail.showsPullRequests, let ids else { return [] }
            return pullRequestDisplays(orderedPanelIds: ids)
        }()
    }

    private func verticalBranchDirectoryLines(orderedPanelIds: [UUID]) -> [VerticalBranchDirectoryLine] {
        let entries = tab.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds)
        let home = SidebarPathFormatter.homeDirectoryPath
        return entries.compactMap { entry in
            let branchText: String? = {
                guard sidebarShowGitBranch, let branch = entry.branch else { return nil }
                return "\(branch)\(entry.isDirty ? "*" : "")"
            }()

            let directoryText: String? = {
                guard let directory = entry.directory else { return nil }
                let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
                return shortened.isEmpty ? nil : shortened
            }()

            switch (branchText, directoryText) {
            case let (branch?, directory?):
                return VerticalBranchDirectoryLine(branch: branch, directory: directory)
            case let (branch?, nil):
                return VerticalBranchDirectoryLine(branch: branch, directory: nil)
            case let (nil, directory?):
                return VerticalBranchDirectoryLine(branch: nil, directory: directory)
            default:
                return nil
            }
        }
    }

    private func directorySummaryText(orderedPanelIds: [UUID]) -> String? {
        let home = SidebarPathFormatter.homeDirectoryPath
        let entries = tab.sidebarDirectoriesInDisplayOrder(orderedPanelIds: orderedPanelIds).compactMap { directory in
            let shortened = SidebarPathFormatter.shortenedPath(directory, homeDirectoryPath: home)
            return shortened.isEmpty ? nil : shortened
        }
        return entries.isEmpty ? nil : entries.joined(separator: " | ")
    }

    private struct PullRequestDisplay: Identifiable {
        let id: String
        let number: Int
        let label: String
        let url: URL
        let status: SidebarPullRequestStatus
        let checks: SidebarPullRequestChecksStatus?
    }

    private func pullRequestDisplays(orderedPanelIds: [UUID]) -> [PullRequestDisplay] {
        tab.sidebarPullRequestsInDisplayOrder(orderedPanelIds: orderedPanelIds).map { pullRequest in
            PullRequestDisplay(
                id: "\(pullRequest.label.lowercased())#\(pullRequest.number)|\(pullRequest.url.absoluteString)",
                number: pullRequest.number,
                label: pullRequest.label,
                url: pullRequest.url,
                status: pullRequest.status,
                checks: pullRequest.checks
            )
        }
    }

    private var pullRequestForegroundColor: Color {
        isActive ? .white.opacity(0.75) : .secondary
    }

    private func openPullRequestLink(_ url: URL) {
        updateSelection()
        if openSidebarPullRequestLinksInProgramaBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func openPortLink(_ port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        updateSelection()
        if openSidebarPortLinksInProgramaBrowser {
            if tabManager.openBrowser(
                inWorkspace: tab.id,
                url: url,
                preferSplitRight: true,
                insertAtEnd: true
            ) == nil {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func pullRequestStatusLabel(
        _ status: SidebarPullRequestStatus,
        checks _: SidebarPullRequestChecksStatus?
    ) -> String {
        switch status {
        case .open: return String(localized: "sidebar.pullRequest.statusOpen", defaultValue: "open")
        case .merged: return String(localized: "sidebar.pullRequest.statusMerged", defaultValue: "merged")
        case .closed: return String(localized: "sidebar.pullRequest.statusClosed", defaultValue: "closed")
        }
    }

    private func logLevelIcon(_ level: SidebarLogLevel) -> String {
        switch level {
        case .info: return "circle.fill"
        case .progress: return "arrowtriangle.right.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private func logLevelColor(_ level: SidebarLogLevel, isActive: Bool) -> Color {
        if isActive {
            switch level {
            case .info:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.5))
            case .progress:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.8))
            case .success:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            case .warning:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            case .error:
                return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.9))
            }
        }
        switch level {
        case .info: return .secondary
        case .progress: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func shortenPath(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path }
        if trimmed == home {
            return "~"
        }
        if trimmed.hasPrefix(home + "/") {
            return "~" + trimmed.dropFirst(home.count)
        }
        return trimmed
    }

    private struct PullRequestStatusIcon: View {
        let status: SidebarPullRequestStatus
        let color: Color
        private static let frameSize: CGFloat = 12

        var body: some View {
            switch status {
            case .open:
                PullRequestOpenIcon(color: color)
            case .merged:
                PullRequestMergedIcon(color: color)
            case .closed:
                Image(systemName: "xmark.circle")
                    .font(.system(size: 7, weight: .regular))
                    .foregroundColor(color)
                    .frame(width: Self.frameSize, height: Self.frameSize)
            }
        }
    }

    private struct PullRequestOpenIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 3.0, y: 4.8))
                    path.addLine(to: CGPoint(x: 3.0, y: 9.2))

                    path.move(to: CGPoint(x: 4.8, y: 3.0))
                    path.addLine(to: CGPoint(x: 9.4, y: 3.0))
                    path.addLine(to: CGPoint(x: 11.0, y: 4.6))
                    path.addLine(to: CGPoint(x: 11.0, y: 9.2))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 11.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private struct PullRequestMergedIcon: View {
        let color: Color
        private static let stroke = StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        private static let nodeDiameter: CGFloat = 3.0
        private static let frameSize: CGFloat = 13

        var body: some View {
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4.6, y: 4.6))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                    path.addLine(to: CGPoint(x: 9.2, y: 7.0))

                    path.move(to: CGPoint(x: 4.6, y: 9.4))
                    path.addLine(to: CGPoint(x: 7.1, y: 7.0))
                }
                .stroke(color, style: Self.stroke)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 3.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 3.0, y: 11.0)

                Circle()
                    .stroke(color, lineWidth: Self.stroke.lineWidth)
                    .frame(width: Self.nodeDiameter, height: Self.nodeDiameter)
                    .position(x: 11.0, y: 7.0)
            }
            .frame(width: Self.frameSize, height: Self.frameSize)
        }
    }

    private func applyTabColor(_ hex: String?, targetIds: [UUID]) {
        for targetId in targetIds {
            tabManager.setTabColor(tabId: targetId, color: hex)
        }
    }

    private func promptCustomColor(targetIds: [UUID]) {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")

        let seed = tab.customColor ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))

        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized, targetIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    private func promptRename() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        let alertWindow = alert.window
        alertWindow.initialFirstResponder = input
        DispatchQueue.main.async {
            alertWindow.makeFirstResponder(input)
            input.selectText(nil)
        }
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
    }

    private func beginWorkspaceDescriptionEditFromContextMenu() {
        selectedTabIds = [tab.id]
        lastSidebarSelectionIndex = index
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }
}

private struct SidebarWorkspaceDescriptionText: View {
    let markdown: String
    let isActive: Bool

    var body: some View {
        let renderedMarkdown = SidebarMarkdownRenderer.renderWorkspaceDescription(markdown)
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
            } else {
                Text(markdown)
            }
        }
        .font(.system(size: 10.5))
        .foregroundColor(foregroundColor)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("SidebarWorkspaceDescriptionText")
        .accessibilityLabel(accessibilityText(renderedMarkdown: renderedMarkdown))
        .onAppear {
#if DEBUG
            let newlineCount = markdown.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "sidebar.description.render workspaceState=appear " +
                "len=\((markdown as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(markdown))\""
            )
#endif
        }
        .onChange(of: markdown) { _, newValue in
#if DEBUG
            let newlineCount = newValue.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "sidebar.description.render workspaceState=change " +
                "len=\((newValue as NSString).length) " +
                "newlines=\(newlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(newValue))\""
            )
#endif
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.84) : .secondary.opacity(0.95)
    }

    private func accessibilityText(renderedMarkdown: AttributedString?) -> String {
        if let renderedMarkdown {
            return String(renderedMarkdown.characters)
        }
        return markdown
    }
}

enum SidebarMarkdownRenderer {
    static func renderWorkspaceDescription(_ markdown: String) -> AttributedString? {
        try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }
}

private struct SidebarMetadataRows: View {
    let entries: [SidebarStatusEntry]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedEntryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleEntries, id: \.key) { entry in
                SidebarMetadataEntryRow(entry: entry, isActive: isActive, onFocus: onFocus)
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less") : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? activeSecondaryTextColor : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .safeHelp(helpText)
    }

    private var activeSecondaryTextColor: Color {
        Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.65))
    }

    private var visibleEntries: [SidebarStatusEntry] {
        guard !isExpanded, entries.count > collapsedEntryLimit else { return entries }
        return Array(entries.prefix(collapsedEntryLimit))
    }

    private var helpText: String {
        entries.map { entry in
            let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? entry.key : trimmed
        }
        .joined(separator: "\n")
    }

    private var shouldShowToggle: Bool {
        entries.count > collapsedEntryLimit
    }
}

private struct SidebarMetadataEntryRow: View {
    let entry: SidebarStatusEntry
    let isActive: Bool
    let onFocus: () -> Void

    var body: some View {
        Group {
            if let url = entry.url {
                Button {
                    onFocus()
                    NSWorkspace.shared.open(url)
                } label: {
                    rowContent(underlined: true)
                }
                .buttonStyle(.plain)
                .safeHelp(url.absoluteString)
            } else {
                rowContent(underlined: false)
                    .contentShape(Rectangle())
                    .onTapGesture { onFocus() }
            }
        }
    }

    @ViewBuilder
    private func rowContent(underlined: Bool) -> some View {
        HStack(spacing: 4) {
            if let icon = iconView {
                icon
                    .foregroundColor(foregroundColor.opacity(0.95))
            }
            metadataText(underlined: underlined)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var foregroundColor: Color {
        if isActive,
           let raw = entry.color,
           Color(hex: raw) != nil {
            return Color(nsColor: sidebarSelectedWorkspaceForegroundNSColor(opacity: 0.95))
        }
        if let raw = entry.color, let explicit = Color(hex: raw) {
            return explicit
        }
        return isActive ? .white.opacity(0.8) : .secondary
    }

    private var iconView: AnyView? {
        guard let iconRaw = entry.icon?.trimmingCharacters(in: .whitespacesAndNewlines),
              !iconRaw.isEmpty else {
            return nil
        }
        if iconRaw.hasPrefix("emoji:") {
            let value = String(iconRaw.dropFirst("emoji:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: 9)))
        }
        if iconRaw.hasPrefix("text:") {
            let value = String(iconRaw.dropFirst("text:".count))
            guard !value.isEmpty else { return nil }
            return AnyView(Text(value).font(.system(size: 8, weight: .semibold)))
        }
        let symbolName: String
        if iconRaw.hasPrefix("sf:") {
            symbolName = String(iconRaw.dropFirst("sf:".count))
        } else {
            symbolName = iconRaw
        }
        guard !symbolName.isEmpty else { return nil }
        return AnyView(Image(systemName: symbolName).symbolRasterSize(8, weight: .medium))
    }

    @ViewBuilder
    private func metadataText(underlined: Bool) -> some View {
        let trimmed = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? entry.key : trimmed
        if entry.format == .markdown,
           let attributed = try? AttributedString(
                markdown: display,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            Text(attributed)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        } else {
            Text(display)
                .underline(underlined)
                .foregroundColor(foregroundColor)
        }
    }
}

private struct SidebarMetadataMarkdownBlocks: View {
    let blocks: [SidebarMetadataBlock]
    let isActive: Bool
    let onFocus: () -> Void

    @State private var isExpanded: Bool = false
    private let collapsedBlockLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleBlocks, id: \.key) { block in
                SidebarMetadataMarkdownBlockRow(
                    block: block,
                    isActive: isActive,
                    onFocus: onFocus
                )
            }

            if shouldShowToggle {
                Button(isExpanded ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details") : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details")) {
                    onFocus()
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? .white.opacity(0.65) : .secondary.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var visibleBlocks: [SidebarMetadataBlock] {
        guard !isExpanded, blocks.count > collapsedBlockLimit else { return blocks }
        return Array(blocks.prefix(collapsedBlockLimit))
    }

    private var shouldShowToggle: Bool {
        blocks.count > collapsedBlockLimit
    }
}

private struct SidebarMetadataMarkdownBlockRow: View {
    let block: SidebarMetadataBlock
    let isActive: Bool
    let onFocus: () -> Void

    @State private var renderedMarkdown: AttributedString?

    var body: some View {
        Group {
            if let renderedMarkdown {
                Text(renderedMarkdown)
                    .foregroundColor(foregroundColor)
            } else {
                Text(block.markdown)
                    .foregroundColor(foregroundColor)
            }
        }
        .font(.system(size: 10))
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
        .onAppear(perform: renderMarkdown)
        .onChange(of: block.markdown) {
            renderMarkdown()
        }
    }

    private var foregroundColor: Color {
        isActive ? .white.opacity(0.8) : .secondary
    }

    private func renderMarkdown() {
        renderedMarkdown = try? AttributedString(
            markdown: block.markdown,
            options: .init(interpretedSyntax: .full)
        )
    }
}
