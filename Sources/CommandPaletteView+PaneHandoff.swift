import AppKit
import SwiftUI

/// "Paste Context From Pane…": the switcher lists the other terminal panes, and picking one pastes
/// its recent output into the pane that was focused when the command ran. Nothing is submitted.
@MainActor
final class CommandPalettePaneHandoffTarget {
    let workspaceId: UUID
    let panelId: UUID
    weak var panel: TerminalPanel?

    init(workspaceId: UUID, panelId: UUID, panel: TerminalPanel) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.panel = panel
    }
}

@MainActor
private enum CommandPalettePaneHandoffStore {
    /// Keyed by palette controller (one per window). `CommandPaletteController.swift` is at its
    /// line budget, so the pick state lives here and is cleared on every palette dismissal.
    static var targets: [ObjectIdentifier: CommandPalettePaneHandoffTarget] = [:]
}

extension CommandPaletteView {
    /// Set while the switcher is picking the pane to paste from.
    var paneHandoffTarget: CommandPalettePaneHandoffTarget? {
        get { CommandPalettePaneHandoffStore.targets[ObjectIdentifier(commandPaletteController)] }
        nonmutating set { CommandPalettePaneHandoffStore.targets[ObjectIdentifier(commandPaletteController)] = newValue }
    }

    func beginPaneHandoffPickFlow() {
        guard let context = focusedPanelContext, let terminal = context.panel as? TerminalPanel else {
            NSSound.beep()
            return
        }
        paneHandoffTarget = CommandPalettePaneHandoffTarget(
            workspaceId: context.workspace.id,
            panelId: context.panelId,
            panel: terminal
        )
        resetCommandPaletteListState(initialQuery: "")
    }

    private typealias PaneHandoffSource = (
        context: CommandPaletteSwitcherWindowContext,
        workspace: Workspace,
        panelId: UUID,
        panel: TerminalPanel
    )

    private func paneHandoffSources(excluding target: CommandPalettePaneHandoffTarget) -> [PaneHandoffSource] {
        var sources: [PaneHandoffSource] = []
        for context in commandPaletteSwitcherWindowContexts() {
            for workspace in commandPaletteOrderedSwitcherWorkspaces(for: context) {
                for panelId in commandPaletteOrderedSwitcherPanels(for: workspace) where panelId != target.panelId {
                    guard let terminal = workspace.panels[panelId] as? TerminalPanel else { continue }
                    sources.append((context: context, workspace: workspace, panelId: panelId, panel: terminal))
                }
            }
        }
        return sources
    }

    func paneHandoffSourceEntriesFingerprint(target: CommandPalettePaneHandoffTarget) -> Int {
        var hasher = Hasher()
        hasher.combine("paneHandoff")
        hasher.combine(target.panelId)
        for source in paneHandoffSources(excluding: target) {
            hasher.combine(source.panelId)
            hasher.combine(panelDisplayName(workspace: source.workspace, panelId: source.panelId, fallback: source.panel.displayTitle))
            hasher.combine(workspaceDisplayName(source.workspace))
            hasher.combine(source.context.windowLabel)
        }
        return hasher.finalize()
    }

    func paneHandoffSourceEntries(target: CommandPalettePaneHandoffTarget) -> [CommandPaletteCommand] {
        paneHandoffSources(excluding: target).enumerated().map { index, source in
            let name = panelDisplayName(workspace: source.workspace, panelId: source.panelId, fallback: source.panel.displayTitle)
            let workspaceName = workspaceDisplayName(source.workspace)
            let sourcePanel = source.panel
            return CommandPaletteCommand(
                id: "paneHandoff.source.\(source.panelId.uuidString.lowercased())",
                rank: index,
                title: name,
                subtitle: Self.commandPaletteSwitcherSubtitle(base: workspaceName, windowLabel: source.context.windowLabel),
                shortcutHint: nil,
                kindLabel: commandPaletteSurfaceKindLabel(for: sourcePanel.panelType),
                keywords: ["paste", "context", "handoff", name, workspaceName],
                // The action dismisses itself so focus goes back to the pane receiving the paste.
                dismissOnRun: false,
                action: {
                    pastePaneHandoffContext(from: sourcePanel, label: name, into: target)
                }
            )
        }
    }

    private func pastePaneHandoffContext(
        from source: TerminalPanel,
        label: String,
        into target: CommandPalettePaneHandoffTarget
    ) {
        defer { dismissCommandPalette(restoreFocus: true) }
        guard let targetPanel = target.panel, targetPanel !== source,
              let text = TerminalController.shared.readTerminalText(
                  terminalPanel: source,
                  includeScrollback: true,
                  lineLimit: PaneHandoffFormatter.defaultLineCount
              ) else {
            NSSound.beep()
            return
        }
        targetPanel.surface.sendPaste(PaneHandoffFormatter.format(sourceLabel: label, text: text, note: nil))
    }
}
