import AppKit
import Bonsplit
import SwiftUI

extension CommandPaletteView {
    @ViewBuilder
    func attachCommandPaletteFocusHandlers(to view: some View) -> some View {
        view
            .onChange(of: isCommandPaletteSearchFocused) { _, focused in
                if focused {
                    attemptCommandPaletteTextSelectionIfNeeded()
                }
            }
            .onChange(of: isCommandPaletteRenameFocused) { _, focused in
                if focused {
                    attemptCommandPaletteTextSelectionIfNeeded()
                }
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification,
                object: observedWindow
            )) { _ in
                attemptCommandPaletteFocusRestoreIfNeeded()
                attemptCommandPaletteTextSelectionIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSText.didBeginEditingNotification)) { notification in
                guard commandPaletteController.commandPalettePendingTextSelectionBehavior != nil else { return }
                guard let editor = notification.object as? NSTextView,
                      editor.isFieldEditor else { return }
                guard let observedWindow else { return }
                guard editor.window === observedWindow else { return }
                attemptCommandPaletteTextSelectionIfNeeded()
            }
    }

    @ViewBuilder
    func attachCommandPaletteRequestHandlers(to view: some View) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteToggleRequested)) { notification in
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                toggleCommandPalette()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRequested)) { notification in
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                openCommandPaletteCommands()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteSwitcherRequested)) { notification in
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                openCommandPaletteSwitcher()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteSubmitRequested)) { notification in
                guard commandPaletteController.isCommandPalettePresented else { return }
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                handleCommandPaletteSubmitRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteDismissRequested)) { notification in
                guard commandPaletteController.isCommandPalettePresented else { return }
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                dismissCommandPalette(restoreFocus: notification.userInfo?["restoreFocus"] as? Bool ?? true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameTabRequested)) { notification in
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                openCommandPaletteRenameTabInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameWorkspaceRequested)) { notification in
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                openCommandPaletteRenameWorkspaceInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteEditWorkspaceDescriptionRequested)) { notification in
                let shouldHandle = shouldHandleCommandPaletteRequest(notification)
    #if DEBUG
                let requestedWindow = notification.object as? NSWindow
                dlog(
                    "palette.wsDescription.request observed={\(debugCommandPaletteWindowSummary(observedWindow))} " +
                    "requested={\(debugCommandPaletteWindowSummary(requestedWindow))} " +
                    "shouldHandle=\(shouldHandle ? 1 : 0) presented=\(commandPaletteController.isCommandPalettePresented ? 1 : 0) " +
                    "mode=\(debugCommandPaletteModeLabel(commandPaletteController.commandPaletteMode))"
                )
    #endif
                guard shouldHandle else { return }
                openCommandPaletteWorkspaceDescriptionInput()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteMoveSelection)) { notification in
                guard commandPaletteController.isCommandPalettePresented else { return }
                guard case .commands = commandPaletteController.commandPaletteMode else { return }
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                guard let delta = notification.userInfo?["delta"] as? Int, delta != 0 else { return }
                moveCommandPaletteSelection(by: delta)
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputInteractionRequested)) { notification in
                guard commandPaletteController.isCommandPalettePresented else { return }
                guard case .renameInput = commandPaletteController.commandPaletteMode else { return }
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                handleCommandPaletteRenameInputInteraction()
            }
            .onReceive(NotificationCenter.default.publisher(for: .commandPaletteRenameInputDeleteBackwardRequested)) { notification in
                guard commandPaletteController.isCommandPalettePresented else { return }
                guard case .renameInput = commandPaletteController.commandPaletteMode else { return }
                guard shouldHandleCommandPaletteRequest(notification) else { return }
                _ = handleCommandPaletteRenameDeleteBackward(modifiers: [])
            }
    }

    private func shouldHandleCommandPaletteRequest(_ notification: Notification) -> Bool {
        Self.shouldHandleCommandPaletteRequest(
            observedWindow: observedWindow,
            requestedWindow: notification.object as? NSWindow,
            keyWindow: NSApp.keyWindow,
            mainWindow: NSApp.mainWindow
        )
    }

    var commandPaletteListScope: CommandPaletteListScope {
        Self.commandPaletteListScope(for: commandPaletteController.commandPaletteQuery)
    }

    var commandPaletteCurrentSearchFingerprint: Int {
        let scope = commandPaletteListScope
        return commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: commandPaletteSwitcherIncludesSurfaceEntries,
            commandsContext: scope == .commands ? commandPaletteCachedCommandsContext() : nil
        )
    }

    var commandPaletteSwitcherIncludesSurfaceEntries: Bool {
        Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteController.commandPaletteSearchAllSurfaces,
            query: commandPaletteController.commandPaletteQuery
        )
    }

    var commandPaletteSearchPlaceholder: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsPlaceholder", defaultValue: "Type a command")
        case .switcher:
            if paneHandoffTarget != nil {
                return String(localized: "commandPalette.search.paneHandoffPlaceholder", defaultValue: "Pick a pane to paste its output")
            }
            return commandPaletteController.commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherPlaceholderAllSurfaces", defaultValue: "Search workspaces and surfaces")
                : String(localized: "commandPalette.search.switcherPlaceholder", defaultValue: "Search workspaces")
        }
    }

    var commandPaletteEmptyStateText: String {
        switch commandPaletteListScope {
        case .commands:
            return String(localized: "commandPalette.search.commandsEmpty", defaultValue: "No commands match your search.")
        case .switcher:
            if paneHandoffTarget != nil {
                return String(localized: "commandPalette.search.paneHandoffEmpty", defaultValue: "No other terminal panes match your search.")
            }
            return commandPaletteController.commandPaletteSearchAllSurfaces
                ? String(localized: "commandPalette.search.switcherEmptyAllSurfaces", defaultValue: "No workspaces or surfaces match your search.")
                : String(localized: "commandPalette.search.switcherEmpty", defaultValue: "No workspaces match your search.")
        }
    }

    var commandPaletteQueryForMatching: String {
        Self.commandPaletteQueryForMatching(
            query: commandPaletteController.commandPaletteQuery,
            scope: commandPaletteListScope
        )
    }

    private func refreshCommandPaletteSearchCorpus(
        force: Bool = false,
        query: String? = nil
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteController.commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let includeSurfaces = Self.commandPaletteSwitcherIncludesSurfaceEntries(
            searchAllSurfaces: commandPaletteController.commandPaletteSearchAllSurfaces,
            query: effectiveQuery
        )
        let terminalOpenTargets = resolveCommandPaletteTerminalOpenTargets(for: scope)
        if commandPaletteController.commandPaletteTerminalOpenTargetAvailability != terminalOpenTargets {
            commandPaletteController.commandPaletteTerminalOpenTargetAvailability = terminalOpenTargets
        }
        let commandsContext = scope == .commands
            ? commandPaletteCommandsContext(terminalOpenTargets: terminalOpenTargets)
            : nil
        let fingerprint = commandPaletteEntriesFingerprint(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        guard force || commandPaletteController.cachedCommandPaletteScope != scope || commandPaletteController.cachedCommandPaletteFingerprint != fingerprint else {
            return
        }

        let entries = commandPaletteEntries(
            for: scope,
            includeSurfaces: includeSurfaces,
            commandsContext: commandsContext
        )
        // `uniquingKeysWith` (not `uniqueKeysWithValues:`) guards against a crash if two entries
        // ever share an id -- e.g. Unicode-normalization-equal saved-layout filenames on a
        // non-APFS mount -- rather than trapping the whole palette.
        commandPaletteController.commandPaletteSearchCommandsByID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let searchCorpus = entries.map { entry in
            CommandPaletteSearchCorpusEntry(
                payload: entry.id,
                rank: entry.rank,
                title: entry.title,
                searchableTexts: entry.searchableTexts
            )
        }
        commandPaletteController.commandPaletteSearchCorpus = searchCorpus
        commandPaletteController.commandPaletteSearchCorpusByID = Dictionary(searchCorpus.map { ($0.payload, $0) }, uniquingKeysWith: { first, _ in first })
        commandPaletteController.cachedCommandPaletteScope = scope
        commandPaletteController.cachedCommandPaletteFingerprint = fingerprint
    }

    private func cancelCommandPaletteSearch() {
        commandPaletteController.cancelSearch()
    }

    private func setCommandPaletteVisibleResults(
        _ results: [CommandPaletteSearchResult],
        scope: CommandPaletteListScope,
        fingerprint: Int?
    ) {
        commandPaletteController.setVisibleResults(results, scope: scope, fingerprint: fingerprint)
    }

    private func refreshPendingCommandPaletteVisibleResults(
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        query: String,
        usageHistory: [String: CommandPaletteUsageEntry],
        queryIsEmpty: Bool,
        historyTimestamp: TimeInterval
    ) {
        let candidateCommandIDs: [String]
        if commandPaletteController.commandPaletteVisibleResultsScope == scope,
           commandPaletteController.commandPaletteVisibleResultsFingerprint == fingerprint {
            candidateCommandIDs = Self.commandPalettePreviewCandidateCommandIDs(
                resultIDs: commandPaletteController.commandPaletteVisibleResults.map(\.id),
                limit: Self.commandPaletteVisiblePreviewCandidateLimit
            )
        } else {
            candidateCommandIDs = []
        }

        let previewMatches = Self.commandPalettePreviewSearchMatches(
            scope: scope,
            searchCorpus: commandPaletteController.commandPaletteSearchCorpus,
            candidateCommandIDs: candidateCommandIDs,
            searchCorpusByID: commandPaletteController.commandPaletteSearchCorpusByID,
            query: query,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp,
            resultLimit: Self.commandPaletteVisiblePreviewResultLimit
        )
        let previewResults = Self.commandPaletteMaterializedSearchResults(
            matches: previewMatches,
            commandsByID: commandPaletteController.commandPaletteSearchCommandsByID
        )
        setCommandPaletteVisibleResults(
            previewResults,
            scope: scope,
            fingerprint: fingerprint
        )
    }

    private func commitCommandPaletteResolvedResults(
        requestID: UInt64,
        scope: CommandPaletteListScope,
        fingerprint: Int?,
        matchingQuery: String
    ) {
        commandPaletteController.commandPaletteResolvedSearchRequestID = requestID
        commandPaletteController.commandPaletteResolvedSearchScope = scope
        commandPaletteController.commandPaletteResolvedSearchFingerprint = fingerprint
        commandPaletteController.commandPaletteResolvedMatchingQuery = matchingQuery
        commandPaletteController.isCommandPaletteSearchPending = false
        setCommandPaletteVisibleResults(
            commandPaletteController.cachedCommandPaletteResults,
            scope: scope,
            fingerprint: fingerprint
        )
    }

    func scheduleCommandPaletteResultsRefresh(
        query: String? = nil,
        forceSearchCorpusRefresh: Bool = false
    ) {
        let effectiveQuery = Self.commandPaletteRefreshQuery(
            stateQuery: commandPaletteController.commandPaletteQuery,
            observedQuery: query
        )
        let scope = Self.commandPaletteListScope(for: effectiveQuery)
        let matchingQuery = Self.commandPaletteQueryForMatching(
            query: effectiveQuery,
            scope: scope
        )

        refreshCommandPaletteSearchCorpus(
            force: forceSearchCorpusRefresh,
            query: effectiveQuery
        )

        commandPaletteController.commandPaletteSearchRequestID &+= 1
        let requestID = commandPaletteController.commandPaletteSearchRequestID
        let fingerprint = commandPaletteController.cachedCommandPaletteFingerprint
        let searchCorpus = commandPaletteController.commandPaletteSearchCorpus
        let commandsByID = commandPaletteController.commandPaletteSearchCommandsByID
        let usageHistory = commandPaletteController.commandPaletteUsageHistoryByCommandId
        let queryIsEmpty = CommandPaletteFuzzyMatcher.preparedQuery(matchingQuery).isEmpty
        let historyTimestamp = Date().timeIntervalSince1970
        commandPaletteController.commandPalettePendingActivation = nil
        cancelCommandPaletteSearch()
        if Self.commandPaletteShouldSynchronouslySeedResults(
            hasVisibleResultsForScope: commandPaletteController.commandPaletteVisibleResultsScope == scope
        ) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp
            )
            commandPaletteController.cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                matches: matches,
                commandsByID: commandsByID
            )
            commitCommandPaletteResolvedResults(requestID: requestID, scope: scope, fingerprint: fingerprint, matchingQuery: matchingQuery)
            commandPaletteController.commandPaletteResultsRevision &+= 1
            return
        }
        refreshPendingCommandPaletteVisibleResults(
            scope: scope,
            fingerprint: fingerprint,
            query: matchingQuery,
            usageHistory: usageHistory,
            queryIsEmpty: queryIsEmpty,
            historyTimestamp: historyTimestamp
        )
        commandPaletteController.isCommandPaletteSearchPending = true

        commandPaletteController.commandPaletteSearchTask = Task.detached(priority: .userInitiated) {
            let matches = Self.commandPaletteResolvedSearchMatches(
                searchCorpus: searchCorpus,
                query: matchingQuery,
                usageHistory: usageHistory,
                queryIsEmpty: queryIsEmpty,
                historyTimestamp: historyTimestamp,
                shouldCancel: { Task.isCancelled }
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentScope = Self.commandPaletteListScope(for: commandPaletteController.commandPaletteQuery)
                guard commandPaletteController.commandPaletteSearchRequestID == requestID,
                      commandPaletteController.isCommandPalettePresented,
                      currentScope == scope,
                      Self.commandPaletteQueryForMatching(
                          query: commandPaletteController.commandPaletteQuery,
                          scope: currentScope
                      ) == matchingQuery,
                      commandPaletteController.cachedCommandPaletteFingerprint == fingerprint else {
                    return
                }

                commandPaletteController.cachedCommandPaletteResults = Self.commandPaletteMaterializedSearchResults(
                    matches: matches,
                    commandsByID: commandPaletteController.commandPaletteSearchCommandsByID
                )
                let resultIDs = commandPaletteController.cachedCommandPaletteResults.map(\.id)
                let pendingActivation = commandPaletteController.commandPalettePendingActivation
                let resolvedActivation = Self.commandPaletteResolvedPendingActivation(
                    pendingActivation,
                    requestID: requestID,
                    resultIDs: resultIDs
                )
                commitCommandPaletteResolvedResults(requestID: requestID, scope: scope, fingerprint: fingerprint, matchingQuery: matchingQuery)
                if Self.commandPalettePendingActivationRequestID(pendingActivation) == requestID {
                    commandPaletteController.commandPalettePendingActivation = nil
                }
                commandPaletteController.commandPaletteResultsRevision &+= 1
                if commandPaletteController.commandPaletteSearchRequestID == requestID {
                    commandPaletteController.commandPaletteSearchTask = nil
                }
                if let resolvedActivation {
                    runCommandPaletteResolvedActivation(resolvedActivation)
                }
            }
        }
    }

    func commandPaletteSelectedIndex(resultCount: Int) -> Int {
        commandPaletteController.selectedIndex(resultCount: resultCount)
    }

    func updateCommandPaletteScrollTarget(resultCount: Int) {
        guard resultCount > 0 else {
            commandPaletteController.commandPaletteScrollTargetIndex = nil
            commandPaletteController.commandPaletteScrollTargetAnchor = nil
            return
        }

        let selectedIndex = commandPaletteSelectedIndex(resultCount: resultCount)
        commandPaletteController.commandPaletteScrollTargetAnchor = Self.commandPaletteScrollPositionAnchor(
            selectedIndex: selectedIndex,
            resultCount: resultCount
        )

        commandPaletteController.commandPaletteScrollTargetIndex = selectedIndex
    }

    private func syncCommandPaletteSelectionAnchor(resultIDs: [String]) {
        commandPaletteController.syncSelectionAnchor(resultIDs: resultIDs)
    }

    func syncCommandPaletteSelectionAnchorFromCurrentResults() {
        syncCommandPaletteSelectionAnchor(resultIDs: commandPaletteController.cachedCommandPaletteResults.map(\.id))
    }

    func moveCommandPaletteSelection(by delta: Int) {
        let count = commandPaletteController.commandPaletteVisibleResults.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let resultIDs = commandPaletteHasCurrentResolvedResults
            ? commandPaletteController.cachedCommandPaletteResults.map(\.id)
            : commandPaletteController.commandPaletteVisibleResults.map(\.id)
        _ = commandPaletteController.moveSelection(by: delta, resultIDs: resultIDs)
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func handleCommandPaletteRenameDeleteBackward(
        modifiers: EventModifiers
    ) -> BackportKeyPressResult {
        guard case .renameInput = commandPaletteController.commandPaletteMode else { return .ignored }
        let blockedModifiers: EventModifiers = [.command, .control, .option, .shift]
        guard modifiers.intersection(blockedModifiers).isEmpty else { return .ignored }

        if Self.commandPaletteShouldPopRenameInputOnDelete(
            renameDraft: commandPaletteController.commandPaletteRenameDraft,
            modifiers: modifiers
        ) {
            commandPaletteController.commandPaletteMode = .commands
            resetCommandPaletteSearchFocus()
            syncCommandPaletteDebugStateForObservedWindow()
            return .handled
        }

        if let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow,
           let editor = window.firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.deleteBackward(nil)
            commandPaletteController.commandPaletteRenameDraft = editor.string
        } else if !commandPaletteController.commandPaletteRenameDraft.isEmpty {
            commandPaletteController.commandPaletteRenameDraft.removeLast()
        }

        syncCommandPaletteDebugStateForObservedWindow()
        return .handled
    }

    private var commandPaletteHasCurrentResolvedResults: Bool {
        !commandPaletteController.isCommandPaletteSearchPending && commandPaletteController.commandPaletteResolvedSearchRequestID == commandPaletteController.commandPaletteSearchRequestID
    }

    var commandPaletteShouldShowEmptyState: Bool {
        guard commandPaletteController.commandPaletteVisibleResults.isEmpty else { return false }
        if commandPaletteHasCurrentResolvedResults {
            return true
        }

        return Self.commandPaletteShouldPreserveEmptyStateWhileSearchPending(
            isSearchPending: commandPaletteController.isCommandPaletteSearchPending,
            visibleResultsScopeMatches: commandPaletteController.commandPaletteVisibleResultsScope == commandPaletteListScope,
            resolvedSearchScopeMatches: commandPaletteController.commandPaletteResolvedSearchScope == commandPaletteListScope,
            resolvedSearchFingerprintMatches: commandPaletteController.commandPaletteResolvedSearchFingerprint == commandPaletteController.commandPaletteVisibleResultsFingerprint,
            resolvedResultsAreEmpty: commandPaletteController.cachedCommandPaletteResults.isEmpty,
            currentMatchingQuery: commandPaletteQueryForMatching,
            resolvedMatchingQuery: commandPaletteController.commandPaletteResolvedMatchingQuery
        )
    }

    private func runCommandPaletteResolvedActivation(_ activation: CommandPaletteResolvedActivation) {
        switch activation {
        case .command(let commandID):
            guard let command = commandPaletteController.cachedCommandPaletteResults.first(where: { $0.id == commandID })?.command else {
                return
            }
            runCommandPaletteCommand(command)
        case .selected(let fallbackIndex):
            guard !commandPaletteController.cachedCommandPaletteResults.isEmpty else {
                NSSound.beep()
                return
            }
            let resolvedIndex = Self.commandPaletteResolvedSelectionIndex(
                preferredCommandID: commandPaletteController.commandPaletteSelectionAnchorCommandID,
                fallbackSelectedIndex: fallbackIndex,
                resultIDs: commandPaletteController.cachedCommandPaletteResults.map(\.id)
            )
            commandPaletteController.commandPaletteSelectedResultIndex = resolvedIndex
            syncCommandPaletteSelectionAnchorFromCurrentResults()
            runCommandPaletteCommand(commandPaletteController.cachedCommandPaletteResults[resolvedIndex].command)
        }
    }

    func runCommandPaletteResult(commandID: String) {
        guard commandPaletteHasCurrentResolvedResults else {
            if commandPaletteController.isCommandPalettePresented {
                commandPaletteController.commandPalettePendingActivation = .command(
                    requestID: commandPaletteController.commandPaletteSearchRequestID,
                    commandID: commandID
                )
            }
            return
        }
        runCommandPaletteResolvedActivation(.command(commandID: commandID))
    }

    func runSelectedCommandPaletteResult() {
        guard commandPaletteHasCurrentResolvedResults else {
            if commandPaletteController.isCommandPalettePresented {
                commandPaletteController.commandPalettePendingActivation = .selected(
                    requestID: commandPaletteController.commandPaletteSearchRequestID,
                    fallbackSelectedIndex: commandPaletteController.commandPaletteSelectedResultIndex,
                    preferredCommandID: commandPaletteController.commandPaletteSelectionAnchorCommandID
                )
            }
            return
        }

        runCommandPaletteResolvedActivation(.selected(index: commandPaletteController.commandPaletteSelectedResultIndex))
    }

    private func handleCommandPaletteSubmitRequest() {
        switch commandPaletteController.commandPaletteMode {
        case .commands:
            runSelectedCommandPaletteResult()
        case .renameInput(let target):
            continueRenameFlow(target: target)
        case .workspaceDescriptionInput(let target):
#if DEBUG
            let newlineCount = commandPaletteController.commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.submit.request workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "draftLen=\((commandPaletteController.commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount)"
            )
#endif
            applyWorkspaceDescriptionFlow(
                target: target,
                proposedDescription: commandPaletteController.commandPaletteWorkspaceDescriptionDraft
            )
        }
    }

    private func runCommandPaletteCommand(_ command: CommandPaletteCommand) {
#if DEBUG
        dlog("palette.run commandId=\(command.id) dismissOnRun=\(command.dismissOnRun ? 1 : 0)")
#endif
        recordCommandPaletteUsage(command.id)
        command.action()
        if command.dismissOnRun {
            dismissCommandPalette(restoreFocus: false)
        }
    }

    private func toggleCommandPalette() {
        if commandPaletteController.isCommandPalettePresented {
            dismissCommandPalette()
        } else {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
    }

    private func openCommandPaletteCommands() {
        handleCommandPaletteListRequest(scope: .commands)
    }

    private func openCommandPaletteSwitcher() {
        handleCommandPaletteListRequest(scope: .switcher)
    }

    private func handleCommandPaletteListRequest(scope: CommandPaletteListScope) {
        let initialQuery = (scope == .commands) ? Self.commandPaletteCommandsPrefix : ""
        guard commandPaletteController.isCommandPalettePresented else {
            presentCommandPalette(initialQuery: initialQuery)
            return
        }

        if case .commands = commandPaletteController.commandPaletteMode,
           commandPaletteListScope == scope {
            dismissCommandPalette()
            return
        }

        resetCommandPaletteListState(initialQuery: initialQuery)
    }

    private func openCommandPaletteRenameTabInput() {
        if !commandPaletteController.isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameTabFlow()
    }

    private func openCommandPaletteRenameWorkspaceInput() {
        if !commandPaletteController.isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginRenameWorkspaceFlow()
    }

    private func openCommandPaletteWorkspaceDescriptionInput() {
#if DEBUG
        dlog(
            "palette.wsDescription.open begin presented=\(commandPaletteController.isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteController.commandPaletteMode)) " +
            "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
        )
#endif
        if !commandPaletteController.isCommandPalettePresented {
            presentCommandPalette(initialQuery: Self.commandPaletteCommandsPrefix)
        }
        beginWorkspaceDescriptionFlow()
#if DEBUG
        dlog(
            "palette.wsDescription.open end presented=\(commandPaletteController.isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteController.commandPaletteMode)) " +
            "focusFlag=\(commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
    }

    func syncCommandPaletteDebugStateForObservedWindow() {
        commandPaletteController.syncDebugState(observedWindow: observedWindow)
    }

    private func presentCommandPalette(initialQuery: String) {
        let restoreFocusTarget: CommandPaletteRestoreFocusTarget?
        if let panelContext = focusedPanelContext {
            restoreFocusTarget = CommandPaletteRestoreFocusTarget(
                workspaceId: panelContext.workspace.id,
                panelId: panelContext.panelId,
                intent: panelContext.panel.captureFocusIntent(in: observedWindow)
            )
        } else {
            restoreFocusTarget = nil
        }
        commandPaletteController.beginPresentation(
            initialQuery: initialQuery,
            restoreFocusTarget: restoreFocusTarget,
            minimumEditorHeight: CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        )
        refreshCommandPaletteUsageHistory()
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true)
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func resetCommandPaletteListState(initialQuery: String) {
        commandPaletteController.resetListState(
            initialQuery: initialQuery,
            minimumEditorHeight: CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        )
        scheduleCommandPaletteResultsRefresh(forceSearchCorpusRefresh: true)
        resetCommandPaletteSearchFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func dismissCommandPalette(restoreFocus: Bool = true) {
        dismissCommandPalette(restoreFocus: restoreFocus, preferredFocusTarget: nil)
    }

    func dismissCommandPalette(
        restoreFocus: Bool,
        preferredFocusTarget: CommandPaletteRestoreFocusTarget?
    ) {
#if DEBUG
        if case .workspaceDescriptionInput(let target) = commandPaletteController.commandPaletteMode {
            let newlineCount = commandPaletteController.commandPaletteWorkspaceDescriptionDraft.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.dismiss workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "restoreFocus=\(restoreFocus ? 1 : 0) " +
                "draftLen=\((commandPaletteController.commandPaletteWorkspaceDescriptionDraft as NSString).length) " +
                "newlines=\(newlineCount) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))}"
            )
        }
#endif
        paneHandoffTarget = nil
        let storedFocusTarget = commandPaletteController.prepareDismissal(
            minimumEditorHeight: CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        )
        let focusTarget = preferredFocusTarget ?? storedFocusTarget
        isCommandPaletteSearchFocused = false
        isCommandPaletteRenameFocused = false
        if let window = observedWindow {
            _ = window.makeFirstResponder(nil)
        }
        syncCommandPaletteDebugStateForObservedWindow()

        guard restoreFocus, let focusTarget else { return }
        requestCommandPaletteFocusRestore(target: focusTarget)
    }

    func handleCommandPaletteBackdropClick(atContentPoint contentPoint: CGPoint) {
        let clickedFocusTarget = commandPaletteBackdropFocusTarget(atContentPoint: contentPoint)
#if DEBUG
        if let clickedFocusTarget {
            dlog(
                "palette.dismiss.backdrop focusTarget panel=\(clickedFocusTarget.panelId.uuidString.prefix(5)) " +
                "workspace=\(clickedFocusTarget.workspaceId.uuidString.prefix(5)) intent=\(debugCommandPaletteFocusIntent(clickedFocusTarget.intent))"
            )
        } else {
            dlog("palette.dismiss.backdrop focusTarget=nil")
        }
#endif
        dismissCommandPalette(restoreFocus: true, preferredFocusTarget: clickedFocusTarget)
    }

    private func commandPaletteBackdropFocusTarget(atContentPoint contentPoint: CGPoint) -> CommandPaletteRestoreFocusTarget? {
        guard let window = observedWindow,
              let contentView = window.contentView else {
            return nil
        }

        let nsContentPoint = NSPoint(x: contentPoint.x, y: contentPoint.y)
        let windowPoint = contentView.convert(nsContentPoint, to: nil)
        return commandPaletteBackdropFocusTarget(atWindowPoint: windowPoint, in: window)
    }

    private func commandPaletteBackdropFocusTarget(
        atWindowPoint windowPoint: NSPoint,
        in window: NSWindow
    ) -> CommandPaletteRestoreFocusTarget? {
        let overlayController = commandPaletteWindowOverlayController(for: window)
        if let responder = overlayController.underlyingResponder(atWindowPoint: windowPoint),
           let target = commandPaletteBackdropFocusTarget(for: responder) {
            return target
        }

        if let terminalView = TerminalWindowPortalRegistry.terminalViewAtWindowPoint(windowPoint, in: window),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return makeCommandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: window
            )
        }

        return nil
    }

    private func commandPaletteBackdropFocusTarget(for responder: NSResponder) -> CommandPaletteRestoreFocusTarget? {
        if let terminalView = programaOwningGhosttyView(for: responder),
           let workspaceId = terminalView.tabId,
           let panelId = terminalView.terminalSurface?.id,
           tabManager.tabs.contains(where: { $0.id == workspaceId }) {
            return makeCommandPaletteRestoreFocusTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                fallbackIntent: .terminal(.surface),
                in: observedWindow
            )
        }

        return nil
    }

    private func makeCommandPaletteRestoreFocusTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent,
        in window: NSWindow?
    ) -> CommandPaletteRestoreFocusTarget {
        let intent = tabManager.tabs
            .first(where: { $0.id == workspaceId })?
            .panels[panelId]?
            .captureFocusIntent(in: window) ?? fallbackIntent

        return CommandPaletteRestoreFocusTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: intent
        )
    }

    private func requestCommandPaletteFocusRestore(target: CommandPaletteRestoreFocusTarget) {
        commandPaletteController.requestFocusRestore(
            target: target,
            tabManager: tabManager,
            observedWindow: observedWindow
        )
    }

    func attemptCommandPaletteFocusRestoreIfNeeded() {
        commandPaletteController.attemptFocusRestoreIfNeeded(tabManager: tabManager, observedWindow: observedWindow)
    }

#if DEBUG
    private func debugCommandPaletteFocusIntent(_ intent: PanelFocusIntent) -> String {
        switch intent {
        case .panel:
            return "panel"
        case .terminal(.surface):
            return "terminal.surface"
        case .terminal(.findField):
            return "terminal.findField"
        }
    }

    func debugCommandPaletteModeLabel(_ mode: CommandPaletteMode) -> String {
        switch mode {
        case .commands:
            return "commands"
        case .renameInput:
            return "renameInput"
        case .workspaceDescriptionInput:
            return "workspaceDescriptionInput"
        }
    }
#endif

    func resetCommandPaletteSearchFocus() {
        applyCommandPaletteInputFocusPolicy(.search)
    }

    func resetCommandPaletteRenameFocus() {
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    func resetCommandPaletteWorkspaceDescriptionFocus() {
#if DEBUG
        dlog(
            "palette.wsDescription.focus.reset schedule presented=\(commandPaletteController.isCommandPalettePresented ? 1 : 0) " +
            "mode=\(debugCommandPaletteModeLabel(commandPaletteController.commandPaletteMode)) " +
            "focusFlag=\(commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0)"
        )
#endif
        DispatchQueue.main.async {
#if DEBUG
            dlog(
                "palette.wsDescription.focus.reset apply.before search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "window={\(debugCommandPaletteWindowSummary(observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow))} " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
            isCommandPaletteSearchFocused = false
            isCommandPaletteRenameFocused = false
            commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor = true
            commandPaletteController.commandPalettePendingTextSelectionBehavior = nil
#if DEBUG
            dlog(
                "palette.wsDescription.focus.reset apply.after search=\(isCommandPaletteSearchFocused ? 1 : 0) " +
                "rename=\(isCommandPaletteRenameFocused ? 1 : 0) " +
                "editor=\(commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor ? 1 : 0) " +
                "fr=\(debugCommandPaletteResponderSummary((observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder))"
            )
#endif
        }
    }

    func handleCommandPaletteRenameInputInteraction() {
        guard commandPaletteController.isCommandPalettePresented else { return }
        guard case .renameInput = commandPaletteController.commandPaletteMode else { return }
        applyCommandPaletteInputFocusPolicy(commandPaletteRenameInputFocusPolicy())
    }

    private func commandPaletteRenameInputFocusPolicy() -> CommandPaletteInputFocusPolicy {
        // Rename always opens with the existing name selected, so typing replaces it.
        return CommandPaletteInputFocusPolicy(
            focusTarget: .rename,
            selectionBehavior: .selectAll
        )
    }

    private func applyCommandPaletteInputFocusPolicy(_ policy: CommandPaletteInputFocusPolicy) {
        DispatchQueue.main.async {
            commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor = false
            switch policy.focusTarget {
            case .search:
                isCommandPaletteRenameFocused = false
                isCommandPaletteSearchFocused = true
            case .rename:
                isCommandPaletteSearchFocused = false
                isCommandPaletteRenameFocused = true
            }
            applyCommandPaletteTextSelection(policy.selectionBehavior)
        }
    }

    private func applyCommandPaletteTextSelection(_ behavior: CommandPaletteTextSelectionBehavior) {
        commandPaletteController.commandPalettePendingTextSelectionBehavior = behavior
        attemptCommandPaletteTextSelectionIfNeeded()
    }

    func attemptCommandPaletteTextSelectionIfNeeded() {
        guard commandPaletteController.isCommandPalettePresented else {
            commandPaletteController.commandPalettePendingTextSelectionBehavior = nil
            return
        }
        guard let behavior = commandPaletteController.commandPalettePendingTextSelectionBehavior else { return }
        switch behavior {
        case .selectAll:
            guard case .renameInput = commandPaletteController.commandPaletteMode else { return }
        case .caretAtEnd:
            switch commandPaletteController.commandPaletteMode {
            case .commands, .renameInput:
                break
            case .workspaceDescriptionInput:
                return
            }
        }
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }

        guard let editor = window.firstResponder as? NSTextView,
              editor.isFieldEditor else {
            return
        }
        let length = (editor.string as NSString).length
        switch behavior {
        case .selectAll:
            editor.setSelectedRange(NSRange(location: 0, length: length))
        case .caretAtEnd:
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
        commandPaletteController.commandPalettePendingTextSelectionBehavior = nil
    }

    private func refreshCommandPaletteUsageHistory() {
        commandPaletteController.commandPaletteUsageHistoryByCommandId = loadCommandPaletteUsageHistory()
    }

    private func loadCommandPaletteUsageHistory() -> [String: CommandPaletteUsageEntry] {
        guard let data = UserDefaults.standard.data(forKey: Self.commandPaletteUsageDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: CommandPaletteUsageEntry].self, from: data)) ?? [:]
    }

    private func persistCommandPaletteUsageHistory(_ history: [String: CommandPaletteUsageEntry]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: Self.commandPaletteUsageDefaultsKey)
    }

    private func recordCommandPaletteUsage(_ commandId: String) {
        persistCommandPaletteUsageHistory(
            commandPaletteController.recordUsage(commandId: commandId, usedAt: Date().timeIntervalSince1970)
        )
    }

    func beginRenameWorkspaceFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteRenameTarget(
            kind: .workspace(workspaceId: workspace.id),
            currentName: workspaceDisplayName(workspace)
        )
        startRenameFlow(target)
    }

    func beginWorkspaceDescriptionFlow() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        let target = CommandPaletteWorkspaceDescriptionTarget(
            workspaceId: workspace.id,
            currentDescription: workspace.customDescription ?? ""
        )
        startWorkspaceDescriptionFlow(target)
    }

    func beginRenameTabFlow() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        let panelName = panelDisplayName(
            workspace: panelContext.workspace,
            panelId: panelContext.panelId,
            fallback: panelContext.panel.displayTitle
        )
        let target = CommandPaletteRenameTarget(
            kind: .tab(workspaceId: panelContext.workspace.id, panelId: panelContext.panelId),
            currentName: panelName
        )
        startRenameFlow(target)
    }

    private func startRenameFlow(_ target: CommandPaletteRenameTarget) {
        commandPaletteController.commandPaletteRenameDraft = target.currentName
        commandPaletteController.commandPaletteShouldFocusWorkspaceDescriptionEditor = false
        commandPaletteController.commandPaletteMode = .renameInput(target)
        resetCommandPaletteRenameFocus()
        syncCommandPaletteDebugStateForObservedWindow()
    }

    private func startWorkspaceDescriptionFlow(_ target: CommandPaletteWorkspaceDescriptionTarget) {
#if DEBUG
        dlog(
            "palette.wsDescription.flow.start workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "descLen=\((target.currentDescription as NSString).length) " +
            "presented=\(commandPaletteController.isCommandPalettePresented ? 1 : 0) " +
            "modeBefore=\(debugCommandPaletteModeLabel(commandPaletteController.commandPaletteMode))"
        )
#endif
        commandPaletteController.commandPaletteWorkspaceDescriptionDraft = target.currentDescription
        commandPaletteController.commandPaletteWorkspaceDescriptionHeight = CommandPaletteMultilineTextEditorRepresentable.defaultMinimumHeight
        commandPaletteController.commandPalettePendingTextSelectionBehavior = nil
        commandPaletteController.commandPaletteMode = .workspaceDescriptionInput(target)
        resetCommandPaletteWorkspaceDescriptionFocus()
#if DEBUG
        dlog(
            "palette.wsDescription.flow.armed workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "height=\(String(format: "%.1f", commandPaletteController.commandPaletteWorkspaceDescriptionHeight)) " +
            "modeAfter=\(debugCommandPaletteModeLabel(commandPaletteController.commandPaletteMode))"
        )
#endif
        syncCommandPaletteDebugStateForObservedWindow()
    }

    func continueRenameFlow(target: CommandPaletteRenameTarget) {
        guard case .renameInput(let activeTarget) = commandPaletteController.commandPaletteMode,
              activeTarget == target else { return }
        applyRenameFlow(target: target, proposedName: commandPaletteController.commandPaletteRenameDraft)
    }

    private func applyRenameFlow(target: CommandPaletteRenameTarget, proposedName: String) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            tabManager.setCustomTitle(tabId: workspaceId, title: normalizedName)
        case .tab(let workspaceId, let panelId):
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else {
                NSSound.beep()
                return
            }
            workspace.setPanelCustomTitle(panelId: panelId, title: normalizedName)
        }

        dismissCommandPalette()
    }

    func applyWorkspaceDescriptionFlow(
        target: CommandPaletteWorkspaceDescriptionTarget,
        proposedDescription: String
    ) {
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            NSSound.beep()
            return
        }
#if DEBUG
        let newlineCount = proposedDescription.reduce(into: 0) { count, character in
            if character == "\n" { count += 1 }
        }
        dlog(
            "palette.wsDescription.apply.begin workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "proposedLen=\((proposedDescription as NSString).length) " +
            "newlines=\(newlineCount) " +
            "text=\"\(debugCommandPaletteTextPreview(proposedDescription))\""
        )
#endif
        tabManager.setCustomDescription(tabId: target.workspaceId, description: proposedDescription)
#if DEBUG
        if let updatedWorkspace = tabManager.tabs.first(where: { $0.id == target.workspaceId }) {
            let persisted = updatedWorkspace.customDescription ?? ""
            let persistedNewlineCount = persisted.reduce(into: 0) { count, character in
                if character == "\n" { count += 1 }
            }
            dlog(
                "palette.wsDescription.apply.end workspace=\(target.workspaceId.uuidString.prefix(8)) " +
                "persistedLen=\((persisted as NSString).length) " +
                "persistedNewlines=\(persistedNewlineCount) " +
                "text=\"\(debugCommandPaletteTextPreview(persisted))\""
            )
        }
#endif
        dismissCommandPalette()
    }

    func openWorkspacePullRequests() -> Bool {
        guard let workspace = tabManager.selectedWorkspace else { return false }
        let pullRequests = workspace.sidebarPullRequestsInDisplayOrder()
        guard !pullRequests.isEmpty else { return false }

        var openedCount = 0
        for pullRequest in pullRequests {
            if ExternalOpenPolicy.open(pullRequest.url) {
                openedCount += 1
            }
        }
        return openedCount > 0
    }

    func openFocusedDirectory(in target: TerminalDirectoryOpenTarget) -> Bool {
        guard let directoryURL = focusedTerminalDirectoryURL() else { return false }
        return openFocusedDirectory(directoryURL, in: target)
    }

    func openFocusedDirectory(_ directoryURL: URL, in target: TerminalDirectoryOpenTarget) -> Bool {
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: directoryURL.path)
            return true
        default:
            guard let applicationURL = target.applicationURL() else { return false }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([directoryURL], withApplicationAt: applicationURL, configuration: configuration)
            return true
        }
    }

    private func focusedTerminalDirectoryURL() -> URL? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        let rawDirectory: String = {
            if let focusedPanelId = workspace.focusedPanelId,
               let directory = workspace.panelDirectories[focusedPanelId] {
                return directory
            }
            return workspace.currentDirectory
        }()
        let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmed) else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }
}
