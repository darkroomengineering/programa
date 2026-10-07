# settings.json

This reference describes macOS. The Windows frontend stores its
editable shortcuts under `windows.shortcuts` in
`%USERPROFILE%\\.config\\programa\\settings.json`; see the
[Windows configuration guide](../windows/README.md#windows-behavior).

Programa reads `~/.config/programa/settings.json` on launch and reloads it whenever the file changes, so edits apply without a restart. Many keys also have a control in the Settings window; where one does, a key set in the file wins over it until you remove the key from the file. The file may contain `//` comments. The full contract is `Resources/settings.schema.json` in the repository. This page is maintained by hand, and `scripts/check-settings-docs.py` fails when a schema key is missing from it (or the reverse).

Keys you do not set fall back to the defaults listed below. Keyboard shortcuts live under `shortcuts.bindings` and are documented in [keyboard-shortcuts.md](keyboard-shortcuts.md); terminal theme and font keys are explained in [terminal-themes.md](terminal-themes.md).

## `app`

General app preferences from Settings > App.

| Key | Type | Default | What it does |
|---|---|---|---|
| `appearance` | string | `"system"` | App appearance mode. One of: `system`, `light`, `dark`. |
| `terminalTheme` | object or null | `null` | Terminal themes from Settings > Appearance. Use null, or null for both variants, to remove Programa's managed theme override and inherit Ghostty configuration. |
| `terminalOpacity` | number (0 to 1) or null | `null` | Terminal background opacity from Settings > Appearance. Use null to remove Programa's managed override and inherit Ghostty configuration. |
| `terminalBlur` | boolean or null | `null` | Terminal background blur from Settings > Appearance. Use null to remove Programa's managed override and inherit Ghostty configuration. |
| `terminalFont` | object (`family`, `size`) or null | `null` | Terminal font from Settings > Appearance. Use null to remove Programa's managed override and inherit Ghostty configuration. |
| `newWorkspacePlacement` | string | `"afterCurrent"` | Where new workspaces are inserted in the sidebar. One of: `top`, `afterCurrent`, `end`. |
| `minimalMode` | boolean | `false` | Hide the workspace title bar and move controls into the sidebar. |
| `preferredEditor` | string |  | Custom editor command used by Programa where applicable. Leave empty to use the default. |
| `reorderOnNotification` | boolean | `true` | Move workspaces with new notifications toward the top. |
| `warnBeforeQuit` | boolean | `true` | Show a confirmation before quitting Programa. |
| `commandPaletteSearchesAllSurfaces` | boolean | `false` | Search every surface in the command palette switcher instead of only the active workspace. |

## `notifications`

Notification behavior from Settings > Notifications.

| Key | Type | Default | What it does |
|---|---|---|---|
| `showInMenuBar` | boolean | `false` | Show the menu bar extra. |
| `sound` | string | `"default"` | Notification sound preset. One of: `default`, `Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`, `none`. |
| `command` | string |  | Optional shell command to run alongside notification delivery. |
| `longCommandThresholdSeconds` | integer | `30` | Minimum duration, in seconds, a command must run before a finish notification is posted for a pane the user isn't looking at. 0 disables this notification entirely. |

## `workspaceColors`

Workspace tab and badge colors from Settings > Workspace Colors.

| Key | Type | Default | What it does |
|---|---|---|---|
| `indicatorStyle` | string | `"leftRail"` | Active workspace indicator style. Legacy aliases are accepted and normalized. One of: `leftRail`, `solidFill`, `rail`, `border`, `wash`, `lift`, `typography`, `washRail`, `blueWashColorRail`. |
| `selectionColor` | string (`"#RRGGBB"`) or null | `null` | Override the selected workspace background color. |
| `notificationBadgeColor` | string (`"#RRGGBB"`) or null | `null` | Override the unread notification badge color. |
| `colors` | object | `{"Red": "#C0392B", "Crimson": "#922B21", "Orange": "#A04000", "Amber": "#7D6608", "Olive": "#4A5C18", "Green": "#196F3D", "Teal": "#006B6B", "Aqua": "#0E6B8C", "Blue": "#1565C0", "Navy": "#1A5276", "Indigo": "#283593", "Purple": "#6A1B9A", "Magenta": "#AD1457", "Rose": "#880E4F", "Brown": "#7B3F00", "Charcoal": "#3E4B5E"}` | Full named workspace color palette. Include built-in entries you want to keep, remove keys to remove colors, and add more named entries to extend the picker. |

## `sidebarAppearance`

Sidebar tint settings from Settings > Sidebar Appearance.

| Key | Type | Default | What it does |
|---|---|---|---|
| `matchTerminalBackground` | boolean | `false` | Use the terminal background instead of the sidebar tint. |
| `tintColor` | string (`"#RRGGBB"`) | `"#000000"` | Base sidebar tint color used when light/dark overrides are not set. |
| `lightModeTintColor` | string (`"#RRGGBB"`) or null | `null` | Sidebar tint override for light appearance. |
| `darkModeTintColor` | string (`"#RRGGBB"`) or null | `null` | Sidebar tint override for dark appearance. |
| `tintOpacity` | number | `0.03` | Sidebar tint opacity from 0 to 1. |
| `showClaudeQuota` | boolean | `true` | Show Claude Code rate-limit headroom (5h/7d windows) in the sidebar footer, read from ~/.claude/tmp/rate-limits.json when present. |

## `automation`

Socket control and automation settings from Settings > Automation.

| Key | Type | Default | What it does |
|---|---|---|---|
| `socketControlMode` | string | `"programaOnly"` | Socket control mode. Legacy aliases are accepted and normalized. One of: `off`, `programaOnly`, `cmuxOnly` (legacy alias of `programaOnly`), `automation`, `password`, `allowAll`, `openAccess`, `fullOpenAccess`, `notifications`, `full`. |
| `socketPassword` | object |  | Password for password-mode socket access. Use null or an empty string to clear it. |
| `claudeCodeIntegration` | boolean | `true` | Enable Programa integration hooks for Claude Code. |
| `claudeBinaryPath` | string |  | Custom path to the claude binary. |
| `portBase` | integer | `9100` | Starting value for workspace PROGRAMA_PORT assignments. The complete range must fit within 1-65535. |
| `portRange` | integer | `10` | Number of ports reserved per workspace. The complete range must fit within 1-65535. |

## `customCommands`

Custom command trust settings from Settings > Custom Commands.

| Key | Type | Default | What it does |
|---|---|---|---|
| `trustedDirectories` | array | `[]` | Directories whose programa.json (or legacy cmux.json) commands can run without confirmation. |

## `browser`

Settings for links that open in other apps.

| Key | Type | Default | What it does |
|---|---|---|---|
| `externalAppOpenAllowlist` | array | `[]` | Entries for which you chose Always allow in the external app open prompt, each written as `bundleId\|scheme`, for example `com.tinyspeck.slackmacgap\|slack`. Links with that scheme that open that app skip the prompt. Bare bundle identifiers are ignored. |

## `worktrees`

Native git worktree workflow settings.

| Key | Type | Default | What it does |
|---|---|---|---|
| `directory` | string | `"~/.programa/worktrees"` | Base directory for new git worktrees created via 'programa worktree create' (or the 'worktree.create' socket method) when no explicit --path is given. Worktrees are created under <directory>/<repo-name>/<branch-slug>. |

## `shortcuts`

Keyboard shortcut settings from Settings > Keyboard Shortcuts.

| Key | Type | Default | What it does |
|---|---|---|---|
| `showModifierHoldHints` | boolean | `true` | Show shortcut hint pills while holding Cmd or Ctrl. |
| `bindings` | object | `{}` | Shortcut overrides keyed by Programa action id. Use a string for a single shortcut or an array for a chord. |

`openAgentOverview` opens the all-workspaces Agent Overview. It is unbound by default;
set it under `shortcuts.bindings` or use Settings → Keyboard Shortcuts.

## `windows`

Settings read by the Windows frontend only. The macOS app ignores this section.

| Key | Type | Default | What it does |
|---|---|---|---|
| `shortcuts` | object | see below | Windows keyboard bindings keyed by action id. |

A binding is modifiers and one key joined by hyphens, for example `ctrl-shift-t`. Modifiers are
`ctrl`, `alt` and `shift`; the key is one letter or digit, `comma` or `insert`. `ctrl-c`,
`ctrl-d` and `ctrl-w` are reserved for the terminal, and no two actions can share a binding.

| Action id | Default |
|---|---|
| `open_settings` | `ctrl-comma` |
| `new_tab` | `ctrl-shift-t` |
| `close_tab` | `ctrl-shift-w` |
| `split_vertical` | `ctrl-shift-d` |
| `split_horizontal` | `ctrl-shift-e` |
| `select_tab_1` to `select_tab_9` | `alt-1` to `alt-9` |
| `copy` | `ctrl-shift-c` |
| `paste` | `ctrl-shift-v` |
| `paste_alternate` | `shift-insert` |
