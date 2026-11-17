import AppKit
import SwiftUI

/// What the palette's name prompt does with the name typed for a layout.
enum CommandPaletteLayoutNameAction: Equatable {
    case saveWorkspace(workspaceId: UUID)

    var inputHint: String {
        switch self {
        case .saveWorkspace:
            return String(localized: "commandPalette.layout.saveInputHint", defaultValue: "Enter a layout name. Press Enter to save, Escape to cancel.")
        }
    }
}

/// Palette commands for named layouts: save the current workspace's layout, and apply every
/// layout file in `~/.config/programa/layouts/`, including ones that fail to decode.
extension CommandPaletteView {
    func layoutCommandContributions() -> [CommandPaletteCommandContribution] {
        let layoutSubtitle = String(localized: "command.applyLayout.subtitle", defaultValue: "Layout")
        var contributions: [CommandPaletteCommandContribution] = [
            CommandPaletteCommandContribution(
                commandId: "palette.saveLayout",
                title: { _ in String(localized: "command.saveLayout.title", defaultValue: "Save current layout…") },
                subtitle: { _ in layoutSubtitle },
                keywords: ["layout", "save", "capture", "split", "panes"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        ]
        for entry in programaLayoutStore.entries {
            switch entry {
            case .saved(let summary):
                contributions.append(applyLayoutContribution(name: summary.name, subtitle: layoutSubtitle))
            case .failed(let failure):
                contributions.append(applyLayoutContribution(name: failure.name, subtitle: failure.displayMessage))
            }
        }
        return contributions
    }

    func registerLayoutHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.saveLayout") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            beginLayoutNameFlow(.saveWorkspace(workspaceId: workspace.id), currentName: "")
        }
        for entry in programaLayoutStore.entries {
            let layoutName = entry.name
            registry.register(commandId: "palette.applyLayout." + layoutName) {
                applySavedLayout(named: layoutName)
            }
        }
    }

    /// Runs when the name prompt is submitted. An unusable name keeps the prompt open.
    func applyLayoutNameFlow(_ action: CommandPaletteLayoutNameAction, proposedName name: String) {
        guard ProgramaLayoutStore.isValidName(name) else {
            NSSound.beep()
            return
        }
        switch action {
        case .saveWorkspace(let workspaceId):
            dismissCommandPalette()
            guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
                  let layout = workspace.captureCustomLayout() else {
                Self.showLayoutAlert(
                    title: Self.saveFailedTitle,
                    message: String(localized: "layout.saveFailed.noPanes", defaultValue: "This workspace has no terminal panes to save.")
                )
                return
            }
            Self.saveLayout(layout, name: name, store: programaLayoutStore)
        }
    }

    private func beginLayoutNameFlow(_ action: CommandPaletteLayoutNameAction, currentName: String) {
        startRenameFlow(CommandPaletteRenameTarget(kind: .layout(action), currentName: currentName))
    }

    private func applyLayoutContribution(name: String, subtitle: String) -> CommandPaletteCommandContribution {
        CommandPaletteCommandContribution(
            commandId: "palette.applyLayout." + name,
            title: { _ in String(localized: "command.applyLayout.title", defaultValue: "Apply layout: \(name)") },
            subtitle: { _ in subtitle },
            keywords: ["layout", "apply", name]
        )
    }

    /// Decodes the file again at apply time, so a file fixed or broken since the palette opened
    /// gets its current result.
    private func applySavedLayout(named name: String) {
        switch programaLayoutStore.decode(name: name) {
        case .success(let saved):
            let workspace = tabManager.addWorkspace()
            workspace.applyCustomLayout(saved.layout, baseCwd: workspace.currentDirectory)
        case .failure(let failure):
            Self.showLayoutAlert(
                title: String(localized: "layout.applyFailed.title", defaultValue: "Layout Can't Be Applied"),
                message: failure.displayMessage
            )
        }
    }

    /// Saves through `ProgramaLayoutStore.save`, asking before it replaces an existing file.
    private static func saveLayout(_ layout: ProgramaLayoutNode, name: String, store: ProgramaLayoutStore) {
        do {
            try store.save(name: name, layout: layout, force: false)
        } catch ProgramaLayoutStoreError.alreadyExists {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "layout.replace.title", defaultValue: "Replace layout “\(name)”?")
                alert.informativeText = String(localized: "layout.replace.message", defaultValue: "A saved layout with this name already exists. Replacing it overwrites its file.")
                alert.addButton(withTitle: String(localized: "layout.replace.confirm", defaultValue: "Replace"))
                alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                do {
                    try store.save(name: name, layout: layout, force: true)
                } catch {
                    showLayoutAlert(title: saveFailedTitle, message: error.localizedDescription)
                }
            }
        } catch {
            showLayoutAlert(title: saveFailedTitle, message: error.localizedDescription)
        }
    }

    private static var saveFailedTitle: String {
        String(localized: "layout.saveFailed.title", defaultValue: "Layout Not Saved")
    }

    /// Deferred so the palette dismisses before the modal appears, like `palette.openFolder`.
    static func showLayoutAlert(title: String, message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            _ = alert.runModal()
        }
    }
}
