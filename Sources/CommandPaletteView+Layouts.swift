import AppKit
import SwiftUI

/// What the palette's name prompt does with the name typed for a layout.
enum CommandPaletteLayoutNameAction: Equatable {
    case saveWorkspace(workspaceId: UUID)
    case rename(from: String)
    case copyPreset(presetId: String)

    var inputHint: String {
        switch self {
        case .saveWorkspace:
            return String(localized: "commandPalette.layout.saveInputHint", defaultValue: "Enter a layout name. Press Enter to save, Escape to cancel.")
        case .rename:
            return String(localized: "commandPalette.layout.renameInputHint", defaultValue: "Enter a new layout name. Press Enter to rename, Escape to cancel.")
        case .copyPreset:
            return String(localized: "commandPalette.layout.copyInputHint", defaultValue: "Enter a name for the copy. Press Enter to save, Escape to cancel.")
        }
    }
}

/// Palette commands for named layouts: save the current workspace's layout, apply or copy the
/// built-in presets, and apply, rename or delete every layout file in
/// `~/.config/programa/layouts/`, including ones that fail to decode.
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
        let presetSubtitle = String(localized: "command.applyLayoutPreset.subtitle", defaultValue: "Built-in layout")
        for preset in ProgramaLayoutPreset.all {
            let title = preset.title
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.applyLayoutPreset." + preset.id,
                    title: { _ in String(localized: "command.applyLayout.title", defaultValue: "Apply layout: \(title)") },
                    subtitle: { _ in presetSubtitle },
                    keywords: ["layout", "apply", "preset", "agent", title]
                )
            )
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.copyLayoutPreset." + preset.id,
                    title: { _ in String(localized: "command.copyLayoutPreset.title", defaultValue: "Save copy of layout: \(title)…") },
                    subtitle: { _ in presetSubtitle },
                    keywords: ["layout", "save", "copy", "preset", title],
                    dismissOnRun: false
                )
            )
        }
        for entry in programaLayoutStore.entries {
            switch entry {
            case .saved(let summary):
                contributions.append(applyLayoutContribution(name: summary.name, subtitle: layoutSubtitle))
            case .failed(let failure):
                contributions.append(applyLayoutContribution(name: failure.name, subtitle: failure.displayMessage))
            }
            let name = entry.name
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.renameLayout." + name,
                    title: { _ in String(localized: "command.renameLayout.title", defaultValue: "Rename layout: \(name)…") },
                    subtitle: { _ in layoutSubtitle },
                    keywords: ["layout", "rename", name],
                    dismissOnRun: false
                )
            )
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.deleteLayout." + name,
                    title: { _ in String(localized: "command.deleteLayout.title", defaultValue: "Delete layout: \(name)…") },
                    subtitle: { _ in layoutSubtitle },
                    keywords: ["layout", "delete", "remove", name]
                )
            )
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
        for preset in ProgramaLayoutPreset.all {
            let layout = preset.layout
            registry.register(commandId: "palette.applyLayoutPreset." + preset.id) {
                applyLayout(layout)
            }
            let presetId = preset.id
            let title = preset.title
            registry.register(commandId: "palette.copyLayoutPreset." + presetId) {
                beginLayoutNameFlow(.copyPreset(presetId: presetId), currentName: title)
            }
        }
        for entry in programaLayoutStore.entries {
            let layoutName = entry.name
            registry.register(commandId: "palette.applyLayout." + layoutName) {
                applySavedLayout(named: layoutName)
            }
            registry.register(commandId: "palette.renameLayout." + layoutName) {
                beginLayoutNameFlow(.rename(from: layoutName), currentName: layoutName)
            }
            let store = programaLayoutStore
            registry.register(commandId: "palette.deleteLayout." + layoutName) {
                Self.confirmDeleteLayout(named: layoutName, store: store)
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
        case .rename(let oldName):
            dismissCommandPalette()
            do {
                try programaLayoutStore.rename(from: oldName, to: name)
            } catch ProgramaLayoutStoreError.alreadyExists {
                Self.showLayoutAlert(
                    title: Self.renameFailedTitle,
                    message: String(localized: "layout.renameFailed.exists", defaultValue: "A saved layout named “\(name)” already exists.")
                )
            } catch ProgramaLayoutStoreError.notFound {
                Self.showLayoutAlert(
                    title: Self.renameFailedTitle,
                    message: String(localized: "layout.renameFailed.missing", defaultValue: "The layout “\(oldName)” no longer exists.")
                )
            } catch {
                Self.showLayoutAlert(title: Self.renameFailedTitle, message: error.localizedDescription)
            }
        case .copyPreset(let presetId):
            dismissCommandPalette()
            guard let preset = ProgramaLayoutPreset.all.first(where: { $0.id == presetId }) else { return }
            Self.saveLayout(preset.layout, name: name, store: programaLayoutStore)
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
            applyLayout(saved.layout)
        case .failure(let failure):
            Self.showLayoutAlert(
                title: String(localized: "layout.applyFailed.title", defaultValue: "Layout Can't Be Applied"),
                message: failure.displayMessage
            )
        }
    }

    /// Saved files and presets both open this way.
    private func applyLayout(_ layout: ProgramaLayoutNode) {
        let workspace = tabManager.addWorkspace()
        workspace.applyCustomLayout(layout, baseCwd: workspace.currentDirectory)
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

    /// Deferred so the palette dismisses before the modal appears. Deletion goes through
    /// `ProgramaLayoutStore.remove`, which works on broken files too.
    private static func confirmDeleteLayout(named name: String, store: ProgramaLayoutStore) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "layout.delete.title", defaultValue: "Delete layout “\(name)”?")
            alert.informativeText = String(localized: "layout.delete.message", defaultValue: "This deletes \(name).json from ~/.config/programa/layouts. You can't undo this.")
            alert.addButton(withTitle: String(localized: "layout.delete.confirm", defaultValue: "Delete"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            alert.buttons.first?.hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do {
                try store.remove(name: name)
            } catch ProgramaLayoutStoreError.notFound {
                // Already gone; the file watcher drops the entry.
            } catch {
                showLayoutAlert(
                    title: String(localized: "layout.deleteFailed.title", defaultValue: "Layout Not Deleted"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private static var renameFailedTitle: String {
        String(localized: "layout.renameFailed.title", defaultValue: "Layout Not Renamed")
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
