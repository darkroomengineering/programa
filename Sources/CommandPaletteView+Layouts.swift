import AppKit
import SwiftUI

/// Palette commands for named layouts: apply every layout file in
/// `~/.config/programa/layouts/`, including ones that fail to decode.
extension CommandPaletteView {
    func layoutCommandContributions() -> [CommandPaletteCommandContribution] {
        let layoutSubtitle = String(localized: "command.applyLayout.subtitle", defaultValue: "Layout")
        var contributions: [CommandPaletteCommandContribution] = []
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
        for entry in programaLayoutStore.entries {
            let layoutName = entry.name
            registry.register(commandId: "palette.applyLayout." + layoutName) {
                applySavedLayout(named: layoutName)
            }
        }
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
