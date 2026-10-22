// Command-palette state ownership.
//
// CommandPaletteController owns every piece of palette state that is
// exclusively used by the command palette (query, mode,
// search corpus/results, rename/workspace-description drafts, focus-restore
// targets, usage history, etc.). ContentView creates it as a
// `@StateObject` (one per main window) and passes it to CommandPaletteView,
// whose CommandPaletteView*.swift extensions hold the palette's UI, commands
// and flows. The focus-restore and debug-state methods ContentView also
// calls live in CommandPaletteController+Focus.swift.
//
// The two @FocusState properties (isCommandPaletteSearchFocused,
// isCommandPaletteRenameFocused) live on CommandPaletteView: @FocusState is
// a SwiftUI View-only property wrapper and cannot be hosted on an
// ObservableObject.
//
// CommandPaletteMode, CommandPaletteRestoreFocusTarget, CommandPaletteCommand,
// CommandPaletteSearchResult, CommandPaletteListScope,
// CommandPalettePendingActivation, CommandPaletteTextSelectionBehavior,
// CommandPaletteUsageEntry and CommandPaletteMultilineTextEditorRepresentable
// are internal nested types of CommandPaletteView, referenced here via
// `CommandPaletteView.` qualification since nested-type name lookup requires
// it from outside the enclosing type's lexical scope.

import AppKit
import Combine
import SwiftUI

struct CommandPaletteDebugResultRow {
    let commandId: String
    let title: String
    let shortcutHint: String?
    let trailingLabel: String?
    let score: Int
}

struct CommandPaletteDebugSnapshot {
    let query: String
    let mode: String
    let results: [CommandPaletteDebugResultRow]

    static let empty = CommandPaletteDebugSnapshot(query: "", mode: "commands", results: [])
}

private struct CommandPaletteWindowState {
    var isVisible = false
    var pendingOpen = false
    var recentRequestAt: TimeInterval?
    var escapeSuppressed = false
    var escapeSuppressionStartedAt: TimeInterval?
    var selectionIndex = 0
    var snapshot: CommandPaletteDebugSnapshot = .empty
}

/// Owns per-window presentation and keyboard-routing state independently of AppDelegate's
/// AppKit effect application.
final class CommandPaletteWindowLifecycle {
    private var states: [UUID: CommandPaletteWindowState] = [:]

    func teardown(windowId: UUID) { states.removeValue(forKey: windowId) }

    func reset(windowId: UUID) { states[windowId] = CommandPaletteWindowState() }

    func markOpenRequested(windowId: UUID, now: TimeInterval) {
        update(windowId) { $0.pendingOpen = true; $0.recentRequestAt = now }
    }

    func clearPendingOpen(windowId: UUID) {
        update(windowId) { $0.pendingOpen = false; $0.recentRequestAt = nil }
    }

    func pruneExpiredPendingOpen(now: TimeInterval, maximumAge: TimeInterval) {
        for windowId in Array(states.keys) where states[windowId]?.pendingOpen == true {
            guard let requestedAt = states[windowId]?.recentRequestAt,
                  now - requestedAt <= maximumAge else {
                states[windowId]?.pendingOpen = false
                states[windowId]?.recentRequestAt = nil
                continue
            }
        }
    }

    func isPendingOpen(windowId: UUID, now: TimeInterval, maximumAge: TimeInterval) -> Bool {
        pruneExpiredPendingOpen(now: now, maximumAge: maximumAge)
        return states[windowId]?.pendingOpen == true
    }

    func recentRequestAge(
        windowId: UUID,
        now: TimeInterval,
        maximumAge: TimeInterval,
        graceInterval: TimeInterval
    ) -> TimeInterval? {
        guard isPendingOpen(windowId: windowId, now: now, maximumAge: maximumAge),
              let requestedAt = states[windowId]?.recentRequestAt else { return nil }
        let age = now - requestedAt
        return age <= graceInterval ? age : nil
    }

    func beginEscapeSuppression(windowId: UUID, now: TimeInterval) {
        update(windowId) { $0.escapeSuppressed = true; $0.escapeSuppressionStartedAt = now }
    }

    func endEscapeSuppression(windowId: UUID) {
        update(windowId) { $0.escapeSuppressed = false; $0.escapeSuppressionStartedAt = nil }
    }

    func shouldConsumeSuppressedEscape(windowId: UUID, now: TimeInterval, duration: TimeInterval = 0.35) -> Bool {
        guard states[windowId]?.escapeSuppressed == true else { return false }
        let shouldConsume = now - (states[windowId]?.escapeSuppressionStartedAt ?? 0) <= duration
        if !shouldConsume { endEscapeSuppression(windowId: windowId) }
        return shouldConsume
    }

    func clearAllEscapeSuppression() {
        for windowId in states.keys { endEscapeSuppression(windowId: windowId) }
    }

    func setVisible(_ visible: Bool, windowId: UUID) -> Bool {
        let wasVisible = state(windowId).isVisible
        update(windowId) { $0.isVisible = visible }
        if visible || wasVisible { clearPendingOpen(windowId: windowId) }
        return wasVisible
    }

    func isVisible(windowId: UUID) -> Bool { states[windowId]?.isVisible ?? false }
    func setSelectionIndex(_ index: Int, windowId: UUID) { update(windowId) { $0.selectionIndex = max(0, index) } }
    func selectionIndex(windowId: UUID) -> Int { states[windowId]?.selectionIndex ?? 0 }
    func setSnapshot(_ snapshot: CommandPaletteDebugSnapshot, windowId: UUID) { update(windowId) { $0.snapshot = snapshot } }
    func snapshot(windowId: UUID) -> CommandPaletteDebugSnapshot { states[windowId]?.snapshot ?? .empty }
    func firstVisibleWindowId() -> UUID? { states.first(where: { $0.value.isVisible })?.key }
    func firstPendingWindowId() -> UUID? { states.first(where: { $0.value.pendingOpen })?.key }

    private func state(_ windowId: UUID) -> CommandPaletteWindowState { states[windowId] ?? CommandPaletteWindowState() }
    private func update(_ windowId: UUID, _ mutation: (inout CommandPaletteWindowState) -> Void) {
        var value = state(windowId)
        mutation(&value)
        states[windowId] = value
    }
}

final class CommandPaletteController: ObservableObject {
    static let windowLifecycle = CommandPaletteWindowLifecycle()
    @Published var isCommandPalettePresented = false
    @Published var commandPaletteQuery: String = ""
    @Published var commandPaletteMode: CommandPaletteView.CommandPaletteMode = .commands
    @Published var commandPaletteRenameDraft: String = ""
    @Published var commandPaletteWorkspaceDescriptionDraft: String = ""
    @Published var commandPaletteWorkspaceDescriptionHeight: CGFloat = CommandPaletteView.CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    @Published var commandPaletteSelectedResultIndex: Int = 0
    @Published var commandPaletteSelectionAnchorCommandID: String?
    @Published var commandPaletteHoveredResultIndex: Int?
    @Published var commandPaletteScrollTargetIndex: Int?
    @Published var commandPaletteScrollTargetAnchor: UnitPoint?
    @Published var commandPaletteRestoreFocusTarget: CommandPaletteView.CommandPaletteRestoreFocusTarget?
    @Published var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @Published var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @Published var commandPaletteSearchCommandsByID: [String: CommandPaletteView.CommandPaletteCommand] = [:]
    @Published var cachedCommandPaletteResults: [CommandPaletteView.CommandPaletteSearchResult] = []
    @Published var commandPaletteVisibleResults: [CommandPaletteView.CommandPaletteSearchResult] = []
    @Published var commandPaletteVisibleResultsScope: CommandPaletteView.CommandPaletteListScope?
    @Published var commandPaletteVisibleResultsFingerprint: Int?
    @Published var cachedCommandPaletteScope: CommandPaletteView.CommandPaletteListScope?
    @Published var cachedCommandPaletteFingerprint: Int?
    @Published var commandPalettePendingDismissFocusTarget: CommandPaletteView.CommandPaletteRestoreFocusTarget?
    @Published var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem?
    @Published var commandPalettePendingTextSelectionBehavior: CommandPaletteView.CommandPaletteTextSelectionBehavior?
    @Published var commandPaletteSearchTask: Task<Void, Never>?
    @Published var commandPaletteSearchRequestID: UInt64 = 0
    @Published var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @Published var commandPaletteResolvedSearchScope: CommandPaletteView.CommandPaletteListScope?
    @Published var commandPaletteResolvedSearchFingerprint: Int?
    @Published var commandPaletteResolvedMatchingQuery = ""
    @Published var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @Published var isCommandPaletteSearchPending = false
    @Published var commandPalettePendingActivation: CommandPaletteView.CommandPalettePendingActivation?
    @Published var commandPaletteResultsRevision: UInt64 = 0
    @Published var commandPaletteUsageHistoryByCommandId: [String: CommandPaletteView.CommandPaletteUsageEntry] = [:]
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @Published var commandPaletteShouldFocusWorkspaceDescriptionEditor = false

    func cancelSearch() {
        commandPaletteSearchTask?.cancel()
        commandPaletteSearchTask = nil
    }

    func setVisibleResults(
        _ results: [CommandPaletteView.CommandPaletteSearchResult],
        scope: CommandPaletteView.CommandPaletteListScope,
        fingerprint: Int?
    ) {
        commandPaletteVisibleResults = results
        commandPaletteVisibleResultsScope = scope
        commandPaletteVisibleResultsFingerprint = fingerprint
    }

    func selectedIndex(resultCount: Int) -> Int {
        guard resultCount > 0 else { return 0 }
        return min(max(commandPaletteSelectedResultIndex, 0), resultCount - 1)
    }

    func syncSelectionAnchor(resultIDs: [String]) {
        commandPaletteSelectionAnchorCommandID = CommandPaletteView.commandPaletteSelectionAnchorCommandID(
            selectedIndex: commandPaletteSelectedResultIndex,
            resultIDs: resultIDs
        )
    }

    @discardableResult
    func moveSelection(by delta: Int, resultIDs: [String]) -> Bool {
        guard !resultIDs.isEmpty else { return false }
        commandPaletteSelectedResultIndex = min(
            max(selectedIndex(resultCount: resultIDs.count) + delta, 0),
            resultIDs.count - 1
        )
        syncSelectionAnchor(resultIDs: resultIDs)
        return true
    }

    func resetListState(initialQuery: String, minimumEditorHeight: CGFloat) {
        commandPaletteMode = .commands
        commandPaletteQuery = initialQuery
        commandPaletteRenameDraft = ""
        commandPaletteWorkspaceDescriptionDraft = ""
        commandPaletteWorkspaceDescriptionHeight = minimumEditorHeight
        commandPaletteSelectedResultIndex = 0
        commandPaletteSelectionAnchorCommandID = nil
        commandPaletteHoveredResultIndex = nil
        commandPaletteScrollTargetIndex = nil
        commandPaletteScrollTargetAnchor = nil
        commandPaletteShouldFocusWorkspaceDescriptionEditor = false
    }

    func beginPresentation(
        initialQuery: String,
        restoreFocusTarget: CommandPaletteView.CommandPaletteRestoreFocusTarget?,
        minimumEditorHeight: CGFloat
    ) {
        commandPaletteRestoreFocusTarget = restoreFocusTarget
        isCommandPalettePresented = true
        resetListState(initialQuery: initialQuery, minimumEditorHeight: minimumEditorHeight)
    }

    func prepareDismissal(minimumEditorHeight: CGFloat) -> CommandPaletteView.CommandPaletteRestoreFocusTarget? {
        let focusTarget = commandPaletteRestoreFocusTarget
        cancelSearch()
        commandPaletteSearchRequestID &+= 1
        isCommandPalettePresented = false
        resetListState(initialQuery: "", minimumEditorHeight: minimumEditorHeight)
        commandPaletteRestoreFocusTarget = nil
        commandPaletteSearchCorpus = []
        commandPaletteSearchCorpusByID = [:]
        commandPaletteSearchCommandsByID = [:]
        cachedCommandPaletteResults = []
        commandPaletteVisibleResults = []
        commandPaletteVisibleResultsScope = nil
        commandPaletteVisibleResultsFingerprint = nil
        cachedCommandPaletteScope = nil
        cachedCommandPaletteFingerprint = nil
        commandPalettePendingTextSelectionBehavior = nil
        commandPaletteResolvedSearchRequestID = commandPaletteSearchRequestID
        commandPaletteResolvedSearchScope = nil
        commandPaletteResolvedSearchFingerprint = nil
        commandPaletteTerminalOpenTargetAvailability = []
        isCommandPaletteSearchPending = false
        commandPalettePendingActivation = nil
        commandPaletteResultsRevision &+= 1
        return focusTarget
    }

    func recordUsage(commandId: String, usedAt: TimeInterval) -> [String: CommandPaletteView.CommandPaletteUsageEntry] {
        var entry = commandPaletteUsageHistoryByCommandId[commandId]
            ?? CommandPaletteView.CommandPaletteUsageEntry(useCount: 0, lastUsedAt: 0)
        entry.useCount += 1
        entry.lastUsedAt = usedAt
        commandPaletteUsageHistoryByCommandId[commandId] = entry
        return commandPaletteUsageHistoryByCommandId
    }
}
