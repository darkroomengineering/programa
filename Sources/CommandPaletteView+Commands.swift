import AppKit
import Bonsplit
import SwiftUI

extension CommandPaletteView {
    func focusCommandPaletteSwitcherTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID
    ) {
        // Switcher commands dismiss the palette after action dispatch.
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(workspaceId, suppressFlash: true)
        }
    }

    func focusCommandPaletteSwitcherSurfaceTarget(
        windowId: UUID,
        tabManager: TabManager,
        workspaceId: UUID,
        panelId: UUID
    ) {
        DispatchQueue.main.async {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            tabManager.focusTab(workspaceId, surfaceId: panelId, suppressFlash: true)
        }
    }

    func commandPaletteCachedCommandsContext() -> CommandPaletteCommandsContext {
        commandPaletteCommandsContext(
            terminalOpenTargets: commandPaletteController.commandPaletteTerminalOpenTargetAvailability
        )
    }

    func commandPaletteCommands(
        commandsContext: CommandPaletteCommandsContext
    ) -> [CommandPaletteCommand] {
        let context = commandsContext.snapshot
        let contributions = commandPaletteCommandContributions()
        var handlerRegistry = CommandPaletteHandlerRegistry()
        registerCommandPaletteHandlers(&handlerRegistry)

        var commands: [CommandPaletteCommand] = []
        commands.reserveCapacity(contributions.count)
        var nextRank = 0

        for contribution in contributions {
            guard contribution.when(context), contribution.enablement(context) else { continue }
            guard let action = handlerRegistry.handler(for: contribution.commandId) else {
                assertionFailure("No command palette handler registered for \(contribution.commandId)")
                continue
            }
            commands.append(
                CommandPaletteCommand(
                    id: contribution.commandId,
                    rank: nextRank,
                    title: contribution.title(context),
                    subtitle: contribution.subtitle(context),
                    shortcutHint: commandPaletteShortcutHint(for: contribution),
                    kindLabel: nil,
                    keywords: contribution.keywords,
                    dismissOnRun: contribution.dismissOnRun,
                    action: action
                )
            )
            nextRank += 1
        }

        return commands
    }

    private func commandPaletteCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        func workspaceSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.workspaceName) ?? String(localized: "commandPalette.subtitle.workspaceFallback", defaultValue: "Workspace")
            return String(localized: "commandPalette.subtitle.workspaceWithName", defaultValue: "Workspace • \(name)")
        }

        func panelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.tabWithName", defaultValue: "Tab • \(name)")
        }

        func terminalPanelSubtitle(_ context: CommandPaletteContextSnapshot) -> String {
            let name = context.string(CommandPaletteContextKeys.panelName) ?? String(localized: "commandPalette.subtitle.tabFallback", defaultValue: "Tab")
            return String(localized: "commandPalette.subtitle.terminalWithName", defaultValue: "Terminal • \(name)")
        }

        var contributions: [CommandPaletteCommandContribution] = []

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                title: constant(String(localized: "command.newWorkspace.title", defaultValue: "New Workspace")),
                subtitle: constant(String(localized: "command.newWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["create", "new", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newClaudeWorkspace",
                title: constant(String(localized: "command.newClaudeWorkspace.title", defaultValue: "New Claude Code Workspace")),
                subtitle: constant(String(localized: "command.newClaudeWorkspace.subtitle", defaultValue: "Open a new workspace running Claude Code in the current project")),
                keywords: ["claude", "agent", "ai", "new"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newWindow",
                title: constant(String(localized: "command.newWindow.title", defaultValue: "New Window")),
                subtitle: constant(String(localized: "command.newWindow.subtitle", defaultValue: "Window")),
                keywords: ["create", "new", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.sendFeedback",
                title: constant(String(localized: "command.sendFeedback.title", defaultValue: "Send Feedback…")),
                subtitle: constant(String(localized: "command.sendFeedback.subtitle", defaultValue: "Compose feedback to the programa team")),
                keywords: ["feedback", "report", "bug"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.reloadConfiguration",
                title: constant(String(localized: "command.reloadConfiguration.title", defaultValue: "Reload Configuration")),
                subtitle: constant(String(localized: "command.reloadConfiguration.subtitle", defaultValue: "Re-read settings.json and programa.json")),
                keywords: ["reload", "config", "settings", "refresh"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.installCLI",
                title: constant(String(localized: "command.installCLI.title", defaultValue: "Shell Command: Install 'programa' in PATH")),
                subtitle: constant(String(localized: "command.installCLI.subtitle", defaultValue: "CLI")),
                keywords: ["install", "cli", "path", "shell", "command", "symlink"],
                when: { !$0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.uninstallCLI",
                title: constant(String(localized: "command.uninstallCLI.title", defaultValue: "Shell Command: Uninstall 'programa' from PATH")),
                subtitle: constant(String(localized: "command.uninstallCLI.subtitle", defaultValue: "CLI")),
                keywords: ["uninstall", "remove", "cli", "path", "shell", "command", "symlink"],
                when: { $0.bool(CommandPaletteContextKeys.cliInstalledInPATH) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openFolder",
                title: constant(String(localized: "command.openFolder.title", defaultValue: "Open Folder…")),
                subtitle: constant(String(localized: "command.openFolder.subtitle", defaultValue: "Workspace")),
                keywords: ["open", "folder", "repository", "project", "directory"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.newTerminalTab",
                title: constant(String(localized: "command.newTerminalTab.title", defaultValue: "New Tab (Terminal)")),
                subtitle: constant(String(localized: "command.newTerminalTab.subtitle", defaultValue: "Tab")),
                keywords: ["new", "terminal", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeTab",
                title: constant(String(localized: "command.closeTab.title", defaultValue: "Close Tab")),
                subtitle: constant(String(localized: "command.closeTab.subtitle", defaultValue: "Tab")),
                keywords: ["close", "tab"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspace",
                title: constant(String(localized: "command.closeWorkspace.title", defaultValue: "Close Workspace")),
                subtitle: constant(String(localized: "command.closeWorkspace.subtitle", defaultValue: "Workspace")),
                keywords: ["close", "workspace"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWindow",
                title: constant(String(localized: "command.closeWindow.title", defaultValue: "Close Window")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["close", "window"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleFullScreen",
                title: constant(String(localized: "command.toggleFullScreen.title", defaultValue: "Toggle Full Screen")),
                subtitle: constant(String(localized: "command.toggleFullScreen.subtitle", defaultValue: "Window")),
                keywords: ["fullscreen", "full", "screen", "window", "toggle"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSidebar",
                title: constant(String(localized: "command.toggleSidebar.title", defaultValue: "Toggle Sidebar")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["toggle", "sidebar", "layout"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.enableMinimalMode",
                title: constant(String(localized: "command.enableMinimalMode.title", defaultValue: "Enable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { !$0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.disableMinimalMode",
                title: constant(String(localized: "command.disableMinimalMode.title", defaultValue: "Disable Minimal Mode")),
                subtitle: constant(String(localized: "command.toggleSidebar.subtitle", defaultValue: "Layout")),
                keywords: ["minimal", "mode", "titlebar", "sidebar", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceMinimalModeEnabled) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.showNotifications",
                title: constant(String(localized: "command.showNotifications.title", defaultValue: "Show Notifications")),
                subtitle: constant(String(localized: "command.showNotifications.subtitle", defaultValue: "Notifications")),
                keywords: ["notifications", "inbox"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.jumpUnread",
                title: constant(String(localized: "command.jumpUnread.title", defaultValue: "Jump to Latest Unread")),
                subtitle: constant(String(localized: "command.jumpUnread.subtitle", defaultValue: "Notifications")),
                keywords: ["jump", "unread", "notification"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openSettings",
                title: constant(String(localized: "command.openSettings.title", defaultValue: "Open Settings")),
                subtitle: constant(String(localized: "command.openSettings.subtitle", defaultValue: "Global")),
                keywords: ["settings", "preferences"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.checkForUpdates",
                title: constant(String(localized: "command.checkForUpdates.title", defaultValue: "Check for Updates")),
                subtitle: constant(String(localized: "command.checkForUpdates.subtitle", defaultValue: "Global")),
                keywords: ["update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.applyUpdateIfAvailable",
                title: constant(String(localized: "command.applyUpdateIfAvailable.title", defaultValue: "Apply Update (If Available)")),
                subtitle: constant(String(localized: "command.applyUpdateIfAvailable.subtitle", defaultValue: "Global")),
                keywords: ["apply", "install", "update", "available"],
                when: { $0.bool(CommandPaletteContextKeys.updateHasAvailable) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.attemptUpdate",
                title: constant(String(localized: "command.attemptUpdate.title", defaultValue: "Attempt Update")),
                subtitle: constant(String(localized: "command.attemptUpdate.subtitle", defaultValue: "Global")),
                keywords: ["attempt", "check", "update", "upgrade", "release"]
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.restartSocketListener",
                title: constant(String(localized: "command.restartSocketListener.title", defaultValue: "Restart CLI Listener")),
                subtitle: constant(String(localized: "command.restartSocketListener.subtitle", defaultValue: "Global")),
                keywords: ["restart", "socket", "listener", "cli", "programa", "control"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameWorkspace",
                title: constant(String(localized: "command.renameWorkspace.title", defaultValue: "Rename Workspace…")),
                subtitle: workspaceSubtitle,
                keywords: ["rename", "workspace", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.editWorkspaceDescription",
                title: constant(String(localized: "command.editWorkspaceDescription.title", defaultValue: "Edit Workspace Description…")),
                subtitle: workspaceSubtitle,
                keywords: ["edit", "workspace", "description", "notes", "markdown"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceName",
                title: constant(String(localized: "command.clearWorkspaceName.title", defaultValue: "Clear Workspace Name")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearWorkspaceDescription",
                title: constant(String(localized: "command.clearWorkspaceDescription.title", defaultValue: "Clear Workspace Description")),
                subtitle: workspaceSubtitle,
                keywords: ["clear", "workspace", "description", "notes"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace)
                        && $0.bool(CommandPaletteContextKeys.workspaceHasCustomDescription)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleWorkspacePin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.workspaceShouldPin) ? String(localized: "command.pinWorkspace.title", defaultValue: "Pin Workspace") : String(localized: "command.unpinWorkspace.title", defaultValue: "Unpin Workspace")
                },
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextWorkspace",
                title: constant(String(localized: "command.nextWorkspace.title", defaultValue: "Next Workspace")),
                subtitle: constant(String(localized: "command.nextWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["next", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousWorkspace",
                title: constant(String(localized: "command.previousWorkspace.title", defaultValue: "Previous Workspace")),
                subtitle: constant(String(localized: "command.previousWorkspace.subtitle", defaultValue: "Workspace Navigation")),
                keywords: ["previous", "workspace", "navigate"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceUp",
                title: constant(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "up", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceDown",
                title: constant(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "down", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.moveWorkspaceToTop",
                title: constant(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "move", "top", "reorder"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeOtherWorkspaces",
                title: constant(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "other", "workspaces", "reset", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasPeers) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesBelow",
                title: constant(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "below", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasBelow) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.closeWorkspacesAbove",
                title: constant(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")),
                subtitle: workspaceSubtitle,
                keywords: ["close", "above", "workspaces", "workspace"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasAbove) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceRead",
                title: constant(String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "read", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasUnread) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.markWorkspaceUnread",
                title: constant(String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread")),
                subtitle: workspaceSubtitle,
                keywords: ["workspace", "unread", "notification", "inbox"],
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) },
                enablement: { $0.bool(CommandPaletteContextKeys.workspaceHasRead) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.renameTab",
                title: constant(String(localized: "command.renameTab.title", defaultValue: "Rename Tab…")),
                subtitle: panelSubtitle,
                keywords: ["rename", "tab", "title"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.clearTabName",
                title: constant(String(localized: "command.clearTabName.title", defaultValue: "Clear Tab Name")),
                subtitle: panelSubtitle,
                keywords: ["clear", "tab", "name"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                        && $0.bool(CommandPaletteContextKeys.panelHasCustomName)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabPin",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelShouldPin) ? String(localized: "command.pinTab.title", defaultValue: "Pin Tab") : String(localized: "command.unpinTab.title", defaultValue: "Unpin Tab")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "pin", "pinned"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleTabUnread",
                title: { context in
                    context.bool(CommandPaletteContextKeys.panelHasUnread) ? String(localized: "command.markTabRead.title", defaultValue: "Mark Tab as Read") : String(localized: "command.markTabUnread.title", defaultValue: "Mark Tab as Unread")
                },
                subtitle: panelSubtitle,
                keywords: ["tab", "read", "unread", "notification"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.nextTabInPane",
                title: constant(String(localized: "command.nextTabInPane.title", defaultValue: "Next Tab in Pane")),
                subtitle: constant(String(localized: "command.nextTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["next", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.previousTabInPane",
                title: constant(String(localized: "command.previousTabInPane.title", defaultValue: "Previous Tab in Pane")),
                subtitle: constant(String(localized: "command.previousTabInPane.subtitle", defaultValue: "Tab Navigation")),
                keywords: ["previous", "tab", "pane"],
                when: { $0.bool(CommandPaletteContextKeys.hasFocusedPanel) }
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openWorkspacePullRequests",
                title: constant(String(localized: "command.openWorkspacePRLinks.title", defaultValue: "Open All Workspace PR Links")),
                subtitle: workspaceSubtitle,
                keywords: ["pull", "request", "review", "merge", "pr", "mr", "open", "links", "workspace"],
                when: {
                    $0.bool(CommandPaletteContextKeys.hasWorkspace) &&
                    $0.bool(CommandPaletteContextKeys.workspaceHasPullRequests)
                }
            )
        )

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: target.commandPaletteCommandId,
                    title: constant(target.commandPaletteTitle),
                    subtitle: terminalPanelSubtitle,
                    keywords: target.commandPaletteKeywords,
                    when: { context in
                        context.bool(CommandPaletteContextKeys.panelIsTerminal)
                    }
                )
            )
        }
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFind",
                title: constant(String(localized: "command.terminalFind.title", defaultValue: "Find…")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindNext",
                title: constant(String(localized: "command.terminalFindNext.title", defaultValue: "Find Next")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "find", "next", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.pasteContextFromPane",
                title: constant(String(localized: "command.pasteContextFromPane.title", defaultValue: "Paste Context From Pane…")),
                subtitle: terminalPanelSubtitle,
                keywords: ["paste", "context", "handoff", "pane", "output", "agent", "prompt"],
                dismissOnRun: false,
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalFindPrevious",
                title: constant(String(localized: "command.terminalFindPrevious.title", defaultValue: "Find Previous")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "find", "previous", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalHideFind",
                title: constant(String(localized: "command.terminalHideFind.title", defaultValue: "Hide Find Bar")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "hide", "find", "search"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalUseSelectionForFind",
                title: constant(String(localized: "command.terminalUseSelectionForFind.title", defaultValue: "Use Selection for Find")),
                subtitle: terminalPanelSubtitle,
                keywords: ["terminal", "selection", "find"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitRight",
                title: constant(String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right")),
                subtitle: constant(String(localized: "command.terminalSplitRight.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "right"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.terminalSplitDown",
                title: constant(String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down")),
                subtitle: constant(String(localized: "command.terminalSplitDown.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "split", "down"],
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.toggleSplitZoom",
                title: constant(String(localized: "command.toggleSplitZoom.title", defaultValue: "Toggle Pane Zoom")),
                subtitle: constant(String(localized: "command.toggleSplitZoom.subtitle", defaultValue: "Terminal Layout")),
                keywords: ["terminal", "pane", "split", "zoom", "maximize"],
                when: { context in
                    context.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    context.bool(CommandPaletteContextKeys.workspaceHasSplits)
                }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.equalizeSplits",
                title: constant(String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits")),
                subtitle: workspaceSubtitle,
                keywords: ["split", "equalize", "balance", "divider", "layout"],
                when: { $0.bool(CommandPaletteContextKeys.workspaceHasSplits) }
            )
        )
        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.openReviewPanel",
                title: constant(String(localized: "command.openReviewPanel.title", defaultValue: "Open Review Panel")),
                subtitle: constant(String(localized: "command.openReviewPanel.subtitle", defaultValue: "Diff of the focused terminal's repo")),
                keywords: ["review", "diff", "agent", "changes", "git"]
            )
        )

        contributions.append(
            CommandPaletteCommandContribution(
                commandId: "palette.resumeAgentSession",
                title: constant(String(localized: "command.resumeAgentSession.title", defaultValue: "Resume Agent Session")),
                subtitle: terminalPanelSubtitle,
                keywords: ["agent", "resume", "session", "claude", "codex", "restore"],
                when: { $0.bool(CommandPaletteContextKeys.panelCanResumeAgent) }
            )
        )

        let programaConfigDefaultSubtitle = constant(String(localized: "command.programaConfig.subtitle", defaultValue: "programa.json"))
        for command in programaConfigStore.loadedCommands {
            let commandName = sanitizeProgramaConfigPaletteText(command.name)
            let subtitle = command.description
                .map { sanitizeProgramaConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : constant($0) }
                ?? programaConfigDefaultSubtitle
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: command.id,
                    title: constant(String(localized: "command.programaConfig.customTitle", defaultValue: "Custom: \(commandName)")),
                    subtitle: subtitle,
                    keywords: command.keywords ?? []
                )
            )
        }

        for recipe in programaConfigStore.loadedRecipes {
            let recipeName = sanitizeProgramaConfigPaletteText(recipe.name)
            let subtitle = recipe.description
                .map { sanitizeProgramaConfigPaletteText($0) }
                .flatMap { $0.isEmpty ? nil : constant($0) }
                ?? programaConfigDefaultSubtitle
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: recipe.id,
                    title: constant(String(localized: "command.programaConfig.recipeTitle", defaultValue: "Recipe: \(recipeName)")),
                    subtitle: subtitle,
                    keywords: recipe.keywords ?? []
                )
            )
        }

        let layoutSubtitle = constant(String(localized: "command.applyLayout.subtitle", defaultValue: "Layout"))
        for savedLayout in programaLayoutStore.savedLayouts {
            contributions.append(
                CommandPaletteCommandContribution(
                    commandId: "palette.applyLayout." + savedLayout.name,
                    title: constant(String(localized: "command.applyLayout.title", defaultValue: "Apply layout: \(savedLayout.name)")),
                    subtitle: layoutSubtitle,
                    keywords: ["layout", "apply", savedLayout.name]
                )
            )
        }

        return contributions
    }

    private func registerCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.newWorkspace") {
            tabManager.addWorkspace()
        }
        registry.register(commandId: "palette.openReviewPanel") {
            guard let workspace = tabManager.selectedWorkspace,
                  let focusedPanelId = workspace.focusedPanelId else { return }
            _ = workspace.newReviewSplit(from: focusedPanelId, orientation: .horizontal, focus: true)
        }
        registry.register(commandId: "palette.resumeAgentSession") {
            // Re-checked here: the agent may have started since the palette opened.
            guard let context = Self.focusedPanelContext(in: tabManager),
                  let terminalPanel = context.panel as? TerminalPanel,
                  context.workspace.panelAgentPresence[context.panelId] == nil,
                  context.workspace.panelShellActivityStates[context.panelId] == .promptIdle,
                  let target = AgentResumeStore.shared.target(panelId: context.panelId),
                  let line = AgentResumeCommand.line(
                    for: target, paneDirectory: context.workspace.panelDirectories[context.panelId]
                  ),
                  !AgentResumeCommand.claudeTranscriptIsMissing(for: target) else {
                NSSound.beep()
                return
            }
            terminalPanel.sendInput(line + "\r")
        }
        registry.register(commandId: "palette.newClaudeWorkspace") {
            let trimmedCwd = tabManager.selectedWorkspace?.currentDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let workingDirectory = (trimmedCwd?.isEmpty ?? true) ? nil : trimmedCwd
            tabManager.addWorkspace(workingDirectory: workingDirectory, initialTerminalCommand: "claude")
        }
        registry.register(commandId: "palette.openFolder") {
            // Defer so the command palette dismisses before the modal sheet appears.
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = String(localized: "panel.openFolder.title", defaultValue: "Open Folder")
                panel.prompt = String(localized: "panel.openFolder.prompt", defaultValue: "Open")
                if panel.runModal() == .OK, let url = panel.url {
                    tabManager.addWorkspace(workingDirectory: url.path)
                }
            }
        }
        registry.register(commandId: "palette.newWindow") {
            AppDelegate.shared?.openNewMainWindow(nil)
        }
        registry.register(commandId: "palette.sendFeedback") {
            onSendFeedback()
        }
        registry.register(commandId: "palette.reloadConfiguration") {
            GhosttyApp.shared.reloadConfiguration(source: "palette.reloadConfiguration")
        }
        registry.register(commandId: "palette.installCLI") {
            AppDelegate.shared?.installProgramaCLIInPath(nil)
        }
        registry.register(commandId: "palette.uninstallCLI") {
            AppDelegate.shared?.uninstallProgramaCLIInPath(nil)
        }
        registry.register(commandId: "palette.newTerminalTab") {
            tabManager.newSurface()
        }
        registry.register(commandId: "palette.closeTab") {
            tabManager.closeCurrentPanelWithConfirmation()
        }
        registry.register(commandId: "palette.closeWorkspace") {
            tabManager.closeCurrentWorkspaceWithConfirmation()
        }
        registry.register(commandId: "palette.closeWindow") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.close()
        }
        registry.register(commandId: "palette.toggleFullScreen") {
            guard let window = observedWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
                NSSound.beep()
                return
            }
            window.toggleFullScreen(nil)
        }
        registry.register(commandId: "palette.toggleSidebar") {
            sidebarState.toggle()
        }
        registry.register(commandId: "palette.enableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.minimal.rawValue
        }
        registry.register(commandId: "palette.disableMinimalMode") {
            workspacePresentationMode = WorkspacePresentationModeSettings.Mode.standard.rawValue
        }
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.showNotifications") {
            AppDelegate.shared?.toggleNotificationsPopover(animated: false)
        }
        registry.register(commandId: "palette.jumpUnread") {
            AppDelegate.shared?.jumpToLatestUnread()
        }
        registry.register(commandId: "palette.openSettings") {
#if DEBUG
            dlog("palette.openSettings.invoke")
#endif
            if let appDelegate = AppDelegate.shared {
                appDelegate.openPreferencesWindow(debugSource: "palette.openSettings")
            } else {
#if DEBUG
                dlog("palette.openSettings.missingAppDelegate fallback=1")
#endif
                AppDelegate.presentPreferencesWindow()
            }
        }
        registry.register(commandId: "palette.checkForUpdates") {
            AppDelegate.shared?.checkForUpdates(nil)
        }
        registry.register(commandId: "palette.applyUpdateIfAvailable") {
            AppDelegate.shared?.applyUpdateIfAvailable(nil)
        }
        registry.register(commandId: "palette.attemptUpdate") {
            AppDelegate.shared?.attemptUpdate(nil)
        }
        registry.register(commandId: "palette.restartSocketListener") {
            AppDelegate.shared?.restartSocketListener(nil)
        }

        registry.register(commandId: "palette.renameWorkspace") {
            beginRenameWorkspaceFlow()
        }
        registry.register(commandId: "palette.editWorkspaceDescription") {
            beginWorkspaceDescriptionFlow()
        }
        registry.register(commandId: "palette.clearWorkspaceName") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomTitle(tabId: workspace.id)
        }
        registry.register(commandId: "palette.clearWorkspaceDescription") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.clearCustomDescription(tabId: workspace.id)
        }
        registry.register(commandId: "palette.toggleWorkspacePin") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.setPinned(workspace, pinned: !workspace.isPinned)
        }
        registry.register(commandId: "palette.nextWorkspace") {
            tabManager.selectNextTab()
        }
        registry.register(commandId: "palette.previousWorkspace") {
            tabManager.selectPreviousTab()
        }
        registry.register(commandId: "palette.moveWorkspaceUp") {
            moveSelectedWorkspace(by: -1)
        }
        registry.register(commandId: "palette.moveWorkspaceDown") {
            moveSelectedWorkspace(by: 1)
        }
        registry.register(commandId: "palette.moveWorkspaceToTop") {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            tabManager.moveTabsToTop([workspace.id])
            tabManager.selectWorkspace(workspace)
        }
        registry.register(commandId: "palette.closeOtherWorkspaces") {
            closeOtherSelectedWorkspaces()
        }
        registry.register(commandId: "palette.closeWorkspacesBelow") {
            closeSelectedWorkspacesBelow()
        }
        registry.register(commandId: "palette.closeWorkspacesAbove") {
            closeSelectedWorkspacesAbove()
        }
        registry.register(commandId: "palette.markWorkspaceRead") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markRead(forTabId: workspaceId)
        }
        registry.register(commandId: "palette.markWorkspaceUnread") {
            guard let workspaceId = tabManager.selectedWorkspace?.id else {
                NSSound.beep()
                return
            }
            notificationStore.markUnread(forTabId: workspaceId)
        }

        registry.register(commandId: "palette.renameTab") {
            beginRenameTabFlow()
        }
        registry.register(commandId: "palette.clearTabName") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelCustomTitle(panelId: panelContext.panelId, title: nil)
        }
        registry.register(commandId: "palette.toggleTabPin") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            panelContext.workspace.setPanelPinned(
                panelId: panelContext.panelId,
                pinned: !panelContext.workspace.isPanelPinned(panelContext.panelId)
            )
        }
        registry.register(commandId: "palette.toggleTabUnread") {
            guard let panelContext = focusedPanelContext else {
                NSSound.beep()
                return
            }
            let hasUnread = panelContext.workspace.manualUnreadPanelIds.contains(panelContext.panelId)
                || notificationStore.hasUnreadNotification(forTabId: panelContext.workspace.id, surfaceId: panelContext.panelId)
            if hasUnread {
                panelContext.workspace.markPanelRead(panelContext.panelId)
            } else {
                panelContext.workspace.markPanelUnread(panelContext.panelId)
            }
        }
        registry.register(commandId: "palette.nextTabInPane") {
            tabManager.selectNextSurface()
        }
        registry.register(commandId: "palette.previousTabInPane") {
            tabManager.selectPreviousSurface()
        }
        registry.register(commandId: "palette.openWorkspacePullRequests") {
            DispatchQueue.main.async {
                if !openWorkspacePullRequests() {
                    NSSound.beep()
                }
            }
        }

        for target in TerminalDirectoryOpenTarget.commandPaletteShortcutTargets {
            registry.register(commandId: target.commandPaletteCommandId) {
                if !openFocusedDirectory(in: target) {
                    NSSound.beep()
                }
            }
        }
        registry.register(commandId: "palette.terminalFind") {
            tabManager.startSearch()
        }
        registry.register(commandId: "palette.terminalFindNext") {
            tabManager.findNext()
        }
        registry.register(commandId: "palette.pasteContextFromPane") {
            beginPaneHandoffPickFlow()
        }
        registry.register(commandId: "palette.terminalFindPrevious") {
            tabManager.findPrevious()
        }
        registry.register(commandId: "palette.terminalHideFind") {
            tabManager.hideFind()
        }
        registry.register(commandId: "palette.terminalUseSelectionForFind") {
            tabManager.searchSelection()
        }
        registry.register(commandId: "palette.terminalSplitRight") {
            tabManager.createSplit(direction: .right)
        }
        registry.register(commandId: "palette.terminalSplitDown") {
            tabManager.createSplit(direction: .down)
        }
        registry.register(commandId: "palette.toggleSplitZoom") {
            if !tabManager.toggleFocusedSplitZoom() {
                NSSound.beep()
            }
        }
        registry.register(commandId: "palette.equalizeSplits") {
            guard let workspace = tabManager.selectedWorkspace,
                  tabManager.equalizeSplits(tabId: workspace.id) else {
                NSSound.beep()
                return
            }
        }

        for command in programaConfigStore.loadedCommands {
            let sourcePath = programaConfigStore.commandSourcePaths[command.id]
            let globalPath = programaConfigStore.globalConfigPath
            registry.register(commandId: command.id) {
                let rawCwd = tabManager.selectedWorkspace?.currentDirectory
                let baseCwd = (rawCwd?.isEmpty == false) ? rawCwd!
                    : FileManager.default.homeDirectoryForCurrentUser.path
                ProgramaConfigExecutor.execute(
                    command: command,
                    tabManager: tabManager,
                    baseCwd: baseCwd,
                    configSourcePath: sourcePath,
                    globalConfigPath: globalPath
                )
            }
        }

        for recipe in programaConfigStore.loadedRecipes {
            let sourcePath = programaConfigStore.recipeSourcePaths[recipe.id]
            let globalPath = programaConfigStore.globalConfigPath
            registry.register(commandId: recipe.id) {
                ProgramaConfigExecutor.executeRecipe(
                    recipe: recipe,
                    tabManager: tabManager,
                    configSourcePath: sourcePath,
                    globalConfigPath: globalPath
                )
            }
        }

        for savedLayout in programaLayoutStore.savedLayouts {
            let layoutName = savedLayout.name
            registry.register(commandId: "palette.applyLayout." + layoutName) {
                guard let saved = programaLayoutStore.load(name: layoutName) else { return }
                let workspace = tabManager.addWorkspace()
                workspace.applyCustomLayout(saved.layout, baseCwd: workspace.currentDirectory)
            }
        }
    }

    private func selectedWorkspaceIndex() -> Int? {
        guard let workspace = tabManager.selectedWorkspace else { return nil }
        return tabManager.tabs.firstIndex { $0.id == workspace.id }
    }

    func moveSelectedWorkspace(by delta: Int) {
        guard let workspace = tabManager.selectedWorkspace else { return }
        tabManager.moveWorkspaceAmongSiblings(tabId: workspace.id, by: delta)
        tabManager.selectWorkspace(workspace)
    }

    private func closeWorkspaceIds(_ workspaceIds: [UUID], allowPinned: Bool) {
        tabManager.closeWorkspacesWithConfirmation(workspaceIds, allowPinned: allowPinned)
    }

    func closeOtherSelectedWorkspaces() {
        guard let workspace = tabManager.selectedWorkspace else { return }
        let workspaceIds = tabManager.tabs.compactMap { $0.id == workspace.id ? nil : $0.id }
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    func closeSelectedWorkspacesBelow() {
        guard let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.suffix(from: anchorIndex + 1).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    func closeSelectedWorkspacesAbove() {
        guard let anchorIndex = selectedWorkspaceIndex() else { return }
        let workspaceIds = tabManager.tabs.prefix(upTo: anchorIndex).map(\.id)
        closeWorkspaceIds(workspaceIds, allowPinned: true)
    }

    var focusedPanelContext: (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        Self.focusedPanelContext(in: tabManager)
    }

    static func focusedPanelContext(in tabManager: TabManager) -> (workspace: Workspace, panelId: UUID, panel: any Panel)? {
        guard let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return (workspace, panelId, panel)
    }

    func workspaceDisplayName(_ workspace: Workspace) -> String {
        Self.commandPaletteWorkspaceDisplayName(workspace)
    }

    func panelDisplayName(workspace: Workspace, panelId: UUID, fallback: String) -> String {
        let title = workspace.panelTitle(panelId: panelId)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedFallback.isEmpty ? String(localized: "panel.displayName.fallback", defaultValue: "Tab") : trimmedFallback
    }
}
