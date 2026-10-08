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
| `terminalFont` | object (`family`, `size`) or null | `null` | Terminal font from Settings > Appearance. Use null to remove Programa's managed override and inherit Ghostty configuration. |
| `newWorkspacePlacement` | string | `"afterCurrent"` | Where new workspaces are inserted in the sidebar. One of: `top`, `afterCurrent`, `end`. |
| `minimalMode` | boolean | `false` | Hide the workspace title bar and move controls into the sidebar. |
| `warnBeforeQuit` | boolean | `true` | Show a confirmation before quitting Programa. |
| `commandPaletteSearchesAllSurfaces` | boolean | `false` | Search every surface in the command palette switcher instead of only the active workspace. |

## `notifications`

Notification behavior from Settings > Notifications.

| Key | Type | Default | What it does |
|---|---|---|---|
| `showInMenuBar` | boolean | `false` | Show the menu bar extra. |
| `sound` | string | `"default"` | Notification sound preset. One of: `default`, `Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`, `none`. |

## `sidebarAppearance`

Sidebar settings from Settings > Sidebar.

| Key | Type | Default | What it does |
|---|---|---|---|
| `matchTerminalBackground` | boolean | `false` | Use the terminal background instead of the sidebar tint. |
| `showClaudeQuota` | boolean | `true` | Show Claude Code rate-limit headroom (5h/7d windows) in the sidebar footer, read from ~/.claude/tmp/rate-limits.json when present. |

## `automation`

Socket control and automation settings from Settings > Automation.

| Key | Type | Default | What it does |
|---|---|---|---|
| `socketControlMode` | string | `"programaOnly"` | Socket control mode. Legacy aliases are accepted and normalized. One of: `off`, `programaOnly`, `automation`, `password`, `allowAll`, `openAccess`, `fullOpenAccess`, `notifications`, `full`. |
| `socketPassword` | object |  | Password for password-mode socket access. Use null or an empty string to clear it. |
| `claudeCodeIntegration` | boolean | `true` | Enable Programa integration hooks for Claude Code. |

## `customCommands`

Custom command trust settings from Settings > Custom Commands.

| Key | Type | Default | What it does |
|---|---|---|---|
| `trustedDirectories` | array | `[]` | Directories whose programa.json commands can run without confirmation. |

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
