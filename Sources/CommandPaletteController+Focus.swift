// Palette behavior that ContentView drives as well as CommandPaletteView:
// restoring terminal focus after a dismissal, and the per-window debug state
// AppDelegate exposes to the socket. Neither touches @FocusState, so both live
// on the model. ContentView calls them from inside its own surface-focus
// handlers so the restore runs after the workspace handoff in the same
// notification callback.

import AppKit

@MainActor
extension CommandPaletteController {
    func requestFocusRestore(
        target: CommandPaletteView.CommandPaletteRestoreFocusTarget,
        tabManager: TabManager,
        observedWindow: NSWindow?
    ) {
        commandPalettePendingDismissFocusTarget = target
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        let timeoutWork = DispatchWorkItem {
            self.commandPalettePendingDismissFocusTarget = nil
            self.commandPaletteRestoreTimeoutWorkItem = nil
        }
        commandPaletteRestoreTimeoutWorkItem = timeoutWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timeoutWork)
        attemptFocusRestoreIfNeeded(tabManager: tabManager, observedWindow: observedWindow)
    }

    func attemptFocusRestoreIfNeeded(tabManager: TabManager, observedWindow: NSWindow?) {
        guard !isCommandPalettePresented else { return }
        guard let target = commandPalettePendingDismissFocusTarget else { return }
        if let window = observedWindow, !window.isVisible {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem?.cancel()
            commandPaletteRestoreTimeoutWorkItem = nil
            return
        }
        guard tabManager.tabs.contains(where: { $0.id == target.workspaceId }) else {
            commandPalettePendingDismissFocusTarget = nil
            commandPaletteRestoreTimeoutWorkItem?.cancel()
            commandPaletteRestoreTimeoutWorkItem = nil
            return
        }

        if let window = observedWindow, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        tabManager.focusTab(target.workspaceId, surfaceId: target.panelId, suppressFlash: true)

        guard let context = CommandPaletteView.focusedPanelContext(in: tabManager),
              context.workspace.id == target.workspaceId,
              context.panelId == target.panelId else {
            return
        }
        guard context.panel.restoreFocusIntent(target.intent) else { return }
        commandPalettePendingDismissFocusTarget = nil
        commandPaletteRestoreTimeoutWorkItem?.cancel()
        commandPaletteRestoreTimeoutWorkItem = nil
    }

    func syncDebugState(observedWindow: NSWindow?) {
        guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        AppDelegate.shared?.setCommandPaletteVisible(isCommandPalettePresented, for: window)
        let visibleResultCount = commandPaletteVisibleResults.count
        let selectedIndex = isCommandPalettePresented ? selectedIndex(resultCount: visibleResultCount) : 0
        AppDelegate.shared?.setCommandPaletteSelectionIndex(selectedIndex, for: window)
        AppDelegate.shared?.setCommandPaletteSnapshot(debugSnapshot(), for: window)
    }

    private func debugSnapshot() -> CommandPaletteDebugSnapshot {
        guard isCommandPalettePresented else { return .empty }

        let listScope = CommandPaletteView.commandPaletteListScope(for: commandPaletteQuery)
        let mode: String
        switch commandPaletteMode {
        case .commands:
            mode = listScope.rawValue
        case .renameInput:
            mode = "rename_input"
        case .workspaceDescriptionInput:
            mode = "workspace_description_input"
        }

        let rows = Array(commandPaletteVisibleResults.prefix(100)).map { result in
            CommandPaletteDebugResultRow(
                commandId: result.command.id,
                title: result.command.title,
                shortcutHint: result.command.shortcutHint,
                trailingLabel: CommandPaletteView.commandPaletteTrailingLabel(for: result.command)?.text,
                score: result.score
            )
        }

        return CommandPaletteDebugSnapshot(
            query: CommandPaletteView.commandPaletteQueryForMatching(query: commandPaletteQuery, scope: listScope),
            mode: mode,
            results: rows
        )
    }
}
