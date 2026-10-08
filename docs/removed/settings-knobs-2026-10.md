# Settings knobs, wave 3

Removed 2026-10-08. Last present at commit 8a3edbe485. The restore hint for any file below is `git show 8a3edbe485:<path>`; the paths to start from are `Sources/ProgramaSettingsFileStore.swift`, `Sources/SettingsView.swift`, `Sources/SettingsModels.swift`, `Sources/TerminalSurface.swift`, `Sources/SidebarShortcutHints.swift`, `Sources/NotificationSoundStaging.swift`, `Sources/LastCommandOutcome.swift`, `Sources/TabManager.swift`, `CLI/CLI+AgentWrappers.swift`, `Resources/bin/claude`, `Resources/settings.schema.json` and `Resources/Localizable.xcstrings`.

## What was removed

Each key had a `settings.json` entry, a schema entry, localized strings and (where listed) a Settings control. Each now behaves as its default.

| Key | Default now fixed | Notes |
|---|---|---|
| `app.preferredEditor` | Cmd-click opens files with the system default app | Settings row and `PreferredEditorSettings` shell-command branch removed. The UI-test open-capture hook stays. |
| `app.reorderOnNotification` | `true` | Workspaces with a new notification always move up. `WorkspaceAutoReorderSettings` removed. |
| `app.terminalOpacity` | unmanaged, inherits the Ghostty config | Settings slider and the `settings.json` ownership removed. `programa themes set --opacity` and `background-opacity` in the Ghostty config still work. |
| `app.terminalBlur` | unmanaged, inherits the Ghostty config | Same as opacity, for the Background Blur toggle and `--blur`. |
| `notifications.command` | no command | `NotificationSoundSettings.runCustomCommand` and the `PROGRAMA_NOTIFICATION_*` environment removed. |
| `notifications.longCommandThresholdSeconds` | `30` | Long-command notification always fires at 30 seconds. It can no longer be turned off. |
| `sidebarAppearance.tintColor`, `lightModeTintColor`, `darkModeTintColor`, `tintOpacity` | `SidebarTintDefaults` | The `sidebarTint*` UserDefaults keys stay: the Debug window and `sidebar-background` in the Ghostty config still write them. |
| `automation.portBase`, `automation.portRange` | `9100`, `10` | Settings Ports section and the `cmuxPortBase` / `cmuxPortRange` UserDefaults keys removed. `PROGRAMA_PORT*` is always 9100 plus 10 per terminal. |
| `automation.claudeBinaryPath` | `claude` found on `PATH` | Settings row, the `PROGRAMA_CUSTOM_CLAUDE_PATH` environment variable, the `claudeCodeCustomClaudePath` default and the lookup in `CLI/CLI+AgentWrappers.swift` and `Resources/bin/claude` removed. |
| `workspaceColors.indicatorStyle`, `selectionColor`, `notificationBadgeColor`, `colors` (and the legacy `paletteOverrides`, `customColors`) | indicator `leftRail`, no selection or badge color override, built-in palette | The whole section and the Workspace Color Indicator picker are gone. The `sidebarActiveTabIndicatorStyle`, `sidebarSelectionColorHex` and `sidebarNotificationBadgeColorHex` defaults stay for the Debug window. |
| `shortcuts.showModifierHoldHints` | `true` | Holding Cmd always shows the shortcut hint pills. |

## Kept on purpose

- `app.minimalMode`: its default is minimal, so removing it would delete the standard-mode layout. The UI tests also launch with `-workspacePresentationMode standard` and toggle it in Settings.
- `app.commandPaletteSearchesAllSurfaces`: `SidebarHelpMenuUITests` toggles `CommandPaletteSearchAllSurfacesToggle` and asserts the non-default behavior.
- `automation.socketControlMode` values `allowAll` and `password`: `scripts/reload.sh`, `scripts/smoke-test-ci.sh`, the UI tests and the socket security unit tests launch with them.

## Why removed

Narrow options. These keys were rarely changed, and the defaults are what ships.
