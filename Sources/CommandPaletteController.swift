// Command-palette state ownership, extracted from ContentView.swift (nuclear-review #88).
//
// CommandPaletteController owns every @State property that used to live on
// ContentView and is exclusively used by the command palette (query, mode,
// search corpus/results, rename/workspace-description drafts, focus-restore
// targets, usage history, etc.). ContentView holds a single
// `@StateObject private var commandPaletteController` and exposes each
// property back to its existing (unqualified) call sites in its body via
// thin computed proxies — this keeps the ~4000 lines of palette orchestration
// code that reads/writes these properties unchanged while genuinely moving
// storage ownership onto the controller (no more @State duplicated per-view).
//
// The two @FocusState properties (isCommandPaletteSearchFocused,
// isCommandPaletteRenameFocused) stay on ContentView: @FocusState is a
// SwiftUI View-only property wrapper and cannot be hosted on an
// ObservableObject.
//
// Access-level widening: CommandPaletteMode, CommandPaletteRestoreFocusTarget,
// CommandPaletteTextSelectionBehavior, and CommandPaletteMultilineTextEditorRepresentable
// were `private` nested types inside ContentView; widened to internal (dropped
// the `private` modifier) so this controller (a different file) can reference
// them. No other behavior change. CommandPaletteCommand, CommandPaletteSearchResult,
// CommandPaletteListScope, CommandPalettePendingActivation, and
// CommandPaletteUsageEntry were already internal nested types; referenced here
// via `ContentView.` qualification since nested-type name lookup requires it
// from outside the enclosing type's lexical scope.

import AppKit
import Combine
import SwiftUI

final class CommandPaletteController: ObservableObject {
    @Published var isCommandPalettePresented = false
    @Published var commandPaletteQuery: String = ""
    @Published var commandPaletteMode: ContentView.CommandPaletteMode = .commands
    @Published var commandPaletteRenameDraft: String = ""
    @Published var commandPaletteWorkspaceDescriptionDraft: String = ""
    @Published var commandPaletteWorkspaceDescriptionHeight: CGFloat = ContentView.CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
    @Published var commandPaletteSelectedResultIndex: Int = 0
    @Published var commandPaletteSelectionAnchorCommandID: String?
    @Published var commandPaletteHoveredResultIndex: Int?
    @Published var commandPaletteScrollTargetIndex: Int?
    @Published var commandPaletteScrollTargetAnchor: UnitPoint?
    @Published var commandPaletteRestoreFocusTarget: ContentView.CommandPaletteRestoreFocusTarget?
    @Published var commandPaletteSearchCorpus: [CommandPaletteSearchCorpusEntry<String>] = []
    @Published var commandPaletteSearchCorpusByID: [String: CommandPaletteSearchCorpusEntry<String>] = [:]
    @Published var commandPaletteSearchCommandsByID: [String: ContentView.CommandPaletteCommand] = [:]
    @Published var cachedCommandPaletteResults: [ContentView.CommandPaletteSearchResult] = []
    @Published var commandPaletteVisibleResults: [ContentView.CommandPaletteSearchResult] = []
    @Published var commandPaletteVisibleResultsScope: ContentView.CommandPaletteListScope?
    @Published var commandPaletteVisibleResultsFingerprint: Int?
    @Published var cachedCommandPaletteScope: ContentView.CommandPaletteListScope?
    @Published var cachedCommandPaletteFingerprint: Int?
    @Published var commandPalettePendingDismissFocusTarget: ContentView.CommandPaletteRestoreFocusTarget?
    @Published var commandPaletteRestoreTimeoutWorkItem: DispatchWorkItem?
    @Published var commandPalettePendingTextSelectionBehavior: ContentView.CommandPaletteTextSelectionBehavior?
    @Published var commandPaletteSearchTask: Task<Void, Never>?
    @Published var commandPaletteSearchRequestID: UInt64 = 0
    @Published var commandPaletteResolvedSearchRequestID: UInt64 = 0
    @Published var commandPaletteResolvedSearchScope: ContentView.CommandPaletteListScope?
    @Published var commandPaletteResolvedSearchFingerprint: Int?
    @Published var commandPaletteResolvedMatchingQuery = ""
    @Published var commandPaletteTerminalOpenTargetAvailability: Set<TerminalDirectoryOpenTarget> = []
    @Published var isCommandPaletteSearchPending = false
    @Published var commandPalettePendingActivation: ContentView.CommandPalettePendingActivation?
    @Published var commandPaletteResultsRevision: UInt64 = 0
    @Published var commandPaletteUsageHistoryByCommandId: [String: ContentView.CommandPaletteUsageEntry] = [:]
    @AppStorage(CommandPaletteRenameSelectionSettings.selectAllOnFocusKey)
    var commandPaletteRenameSelectAllOnFocus = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
    @AppStorage(CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey)
    var commandPaletteSearchAllSurfaces = CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces
    @Published var commandPaletteShouldFocusWorkspaceDescriptionEditor = false
}
