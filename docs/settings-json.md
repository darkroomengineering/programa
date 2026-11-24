# settings.json

The Windows frontend reads the `windows` section in
`%USERPROFILE%\\.config\\programa\\settings.json`; see the
[Windows configuration guide](../windows/README.md#windows-behavior).

On macOS, Programa reads `~/.config/programa/settings.json` on launch and reloads it whenever the file changes, so edits apply without a restart. Almost every macOS key also has a row in the Settings window, and a key set in the file wins over its row until you remove the key from the file. While the file sets a key, its row is disabled and says "Managed in settings.json". The macOS key without a row is `sidebarAppearance.matchTerminalBackground`. The file may contain `//` comments. The full contract is `Resources/settings.schema.json` in the repository. This page is maintained by hand. `scripts/check-settings-docs.py` fails when a schema key is missing from it (or the reverse), and when a schema key has no Settings row or a Settings row has no key, apart from the exceptions it lists.

Keys you do not set fall back to the defaults listed below. Keyboard shortcuts live under `shortcuts.bindings` and are documented in [keyboard-shortcuts.md](keyboard-shortcuts.md); terminal theme and font keys are explained in [terminal-themes.md](terminal-themes.md).

## Checking the file

When a reload finds problems, a notice in the bottom-right corner of the main window says how many there are, with a button that opens the file. It shows once for each new set of problems, so an unchanged file does not bring it back on the next launch. A value with a problem is skipped and the rest of the file still applies. A file that does not parse at all keeps the last settings that did.

To list the problems, run:

```bash
programa config check
```

It uses the same parser as the app and works while Programa is closed. It prints one line per problem, with the line of the key in the file when it can find one, and exits 1:

```
settings.json:4: app.appearance: expected one of "system", "light", "dark"
settings.json:9: shortcuts.bindings.newTabb: unknown shortcut action
```

With no problems it prints `settings.json is valid` and exits 0. It also exits 0 when there is no settings file, since the defaults are in use. `--file <path>` checks another file, such as a copy you are editing. Exit code 2 means the check could not run: a usage error, a `--file` path that does not exist, or a CLI that is not the one inside `Programa.app`.

The check covers the sections the settings loader applies: `app`, `notifications`, `sidebarAppearance`, `automation`, `customCommands`, `browser` and `shortcuts`. It does not check `storage` and `worktrees`, which the worktree manager reads separately. It reports unknown shortcut actions but no other unknown keys, and some values of the wrong type, such as a number where a boolean or a string belongs, are skipped without a report.

## `app`

General app preferences. Most are in Settings > General > App; `appearance` and `minimalMode` are in Settings > Appearance > Appearance, and `terminalTheme` and `terminalFont` in Settings > Appearance > Terminal.

| Key | Type | Default | What it does |
|---|---|---|---|
| `appearance` | string | `"system"` | App appearance mode. One of: `system`, `light`, `dark`. |
| `terminalTheme` | object or null | `null` | Terminal themes from Settings > Appearance. Use null, or null for both variants, to remove Programa's managed theme override and inherit Ghostty configuration. |
| `terminalFont` | object (`family`, `size`) or null | `null` | Terminal font from Settings > Appearance. Use null to remove Programa's managed override and inherit Ghostty configuration. |
| `newWorkspacePlacement` | string | `"afterCurrent"` | Where new workspaces are inserted in the sidebar. One of: `top`, `afterCurrent`, `end`. |
| `minimalMode` | boolean | `false` | Hide the workspace title bar so each pane's tab bar sits at the top of the window, next to the toolbar. |
| `warnBeforeQuit` | boolean | `true` | Show a confirmation before quitting Programa. |
| `confirmCloseLastPane` | boolean | `true` | Ask before closing a workspace's last tab closes the workspace, or the window when it is the last workspace. When off, an idle last tab closes without asking; a running process still asks. Shell `exit` never asks. |
| `saveScrollbackOnQuit` | boolean | `true` | Save terminal scrollback when Programa quits and restore it on the next launch. When `false`, terminal scrollback is not written to disk. |
| `autoResumeAgents` | boolean | `true` | Resume Claude Code, Codex and OpenCode sessions that were running at quit when their pane is restored. |
| `reapLeftoverAgentProcesses` | boolean | `true` | When a Claude Code session exits, stop the processes it started and left running (MCP servers, dev servers, debug binaries). Processes started with `nohup` are kept. See [Processes an agent leaves behind](workspace-interface.md#processes-an-agent-leaves-behind). |
| `commandPaletteSearchesAllSurfaces` | boolean | `false` | Search every surface in the command palette switcher instead of only the active workspace. |
| `reviewDiffRenderer` | string | `"pierre"` | How the Review panel draws diffs. One of: `pierre` (split view with syntax colors and word-level changes, drawn in a web view), `native` (the plain built-in list, which uses less memory on very large diffs). |

## `notifications`

Notification behavior. `sound` is in Settings > General > Notifications; `showInMenuBar` is the Show in Menu Bar row in Settings > General > App.

| Key | Type | Default | What it does |
|---|---|---|---|
| `showInMenuBar` | boolean | `false` | Show the menu bar extra. |
| `sound` | string | `"default"` | Notification sound preset. One of: `default`, `Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`, `none`. |

## `sidebarAppearance`

Sidebar settings from Settings > Appearance > Sidebar. `matchTerminalBackground` has no row there; set it in this file.

| Key | Type | Default | What it does |
|---|---|---|---|
| `matchTerminalBackground` | boolean | `false` | Use the terminal background instead of the sidebar tint. macOS 14 and 15 only: on macOS 26 and later the sidebar uses the system sidebar glass. |
| `showClaudeQuota` | boolean | `true` | Show the Provider Usage button in the sidebar footer, which opens Claude and OpenAI rate limit usage. See [workspace-interface.md](workspace-interface.md#provider-usage). |

## `automation`

Socket control and agent settings. `socketControlMode` and `socketPassword` are in Settings > Automation > Socket Control; the others are in Settings > Automation > Agents.

| Key | Type | Default | What it does |
|---|---|---|---|
| `socketControlMode` | string | `"programaOnly"` | Socket control mode. Legacy aliases are accepted and normalized. One of: `off`, `programaOnly`, `automation`, `password`, `allowAll`, `openAccess`, `fullOpenAccess`, `notifications`, `full`. |
| `socketPassword` | object |  | Password for password-mode socket access. Use null or an empty string to clear it. |
| `claudeCodeIntegration` | boolean | `true` | Enable Programa integration hooks for Claude Code. |
| `claudeTeamsByDefault` | boolean | `true` | Start plain `claude` in a Programa terminal with Claude Code agent teams on, the same as `programa claude-teams`: teammates open as Programa panes. An explicit `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` in the environment, including `0`, always wins. Applies to new terminals. |
| `holdAgentTextWhileTyping` | boolean | `true` | Refuse agent and script text sent to a terminal while you have typed input there that you have not submitted. Socket writes return `draft_in_progress` instead (see [socket-api.md](socket-api.md#text-delivery-draft_in_progress)). A draft stops holding text 60 seconds after your last keystroke. |
| `protectApprovalPrompts` | boolean | `true` | Refuse agent and script writes to a terminal while the agent there waits on a permission or sign-in prompt, so only you can answer it. Socket writes return `agent_awaiting_approval` instead (see [socket-api.md](socket-api.md#approval-prompts-agent_awaiting_approval)). The refusal lifts when you press a key at the prompt or the agent moves on. Questions are not protected. |
| `agentScreenDetection` | boolean | `true` | Show working, blocked and idle status for agent CLIs that have no installed integration, such as Gemini CLI and GitHub Copilot CLI, by reading the terminal screen. Sessions with hooks (Claude Code, Codex, OpenCode) are not affected. |

## `customCommands`

Custom command trust settings from Settings > Automation > Custom Commands.

| Key | Type | Default | What it does |
|---|---|---|---|
| `trustedDirectories` | array | `[]` | Directories whose programa.json commands can run without confirmation. |

## `browser`

Settings for links that open in other apps, from Settings > General > Links. The Apps Allowed to Open Links list there shows each entry, and Remove takes it out so that app asks again.

| Key | Type | Default | What it does |
|---|---|---|---|
| `externalAppOpenAllowlist` | array | `[]` | Entries for which you chose Always allow in the external app open prompt, each written as `bundleId\|scheme`, for example `com.tinyspeck.slackmacgap\|slack`. Links with that scheme that open that app skip the prompt. Bare bundle identifiers are ignored. |

## `storage`

Developer cache cleanup and low disk space warning settings, from Settings > General > Storage.

| Key | Type | Default | What it does |
|---|---|---|---|
| `autoCleanCaches` | boolean | `true` | Every 6 hours, clean eligible developer caches when their tools are idle. Manual-only caches are kept. This runs independently of worktree cleanup. |
| `lowDiskWarningGB` | number | `20` | Warn when available home-volume space falls below this many GB. `0` disables warnings. Another warning is allowed only after space rises above the threshold plus 5 GB. |

## `worktrees`

Native git worktree workflow settings, from Settings > General > Storage.

| Key | Type | Default | What it does |
|---|---|---|---|
| `directory` | string | `"~/.programa/worktrees"` | Base directory for new git worktrees created via 'programa worktree create' (or the 'worktree.create' socket method) when no explicit --path is given. Worktrees are created under <directory>/<repo-name>/<branch-slug>. |
| `autoRemoveMerged` | boolean | `true` | Every 6 hours, remove git worktrees under `directory` whose branch is merged into the remote default branch (or whose upstream branch was deleted), that have no uncommitted or untracked changes, hold no ignored `.env*` files outside `node_modules/` and no other ignored files outside rebuildable build and dependency folders such as `node_modules/`, `build/` or `.venv/` (for example a `.dev.vars`, a local database or a nested clone), are not open in a workspace, have no process running inside, and were not used for `autoRemoveAfterHours`. Uses `git worktree remove` without `--force` and never deletes branches. See `programa storage`. |
| `autoRemoveAfterHours` | number | `24` | Hours a merged worktree must go unused before `autoRemoveMerged` removes it. Values below 1 are treated as 1. |

## `shortcuts`

Keyboard shortcut settings from Settings > Shortcuts.

| Key | Type | Default | What it does |
|---|---|---|---|
| `bindings` | object | `{}` | Shortcut overrides keyed by Programa action id. Use a string for a single shortcut or an array for a chord. |

## `windows`

Settings read by the Windows frontend only. The macOS app ignores this section.

| Key | Type | Default | What it does |
|---|---|---|---|
| `shortcuts` | object | see below | Windows keyboard bindings keyed by action id. |
| `shell` | string or null | `null` | Absolute path to an `.exe` file for new terminals. Replaces Ghostty's `command`; without either, the default shell starts. |
| `startingDirectory` | string or null | `null` | Absolute directory for a new terminal that has no directory to inherit. Defaults to the user's home directory. |

Programa reads the shell and starting directory each time it starts a terminal, so existing terminals keep their shell and directory. A split or a new tab starts in the directory of the terminal it came from. An invalid value is written to `launch.log` and ignored.

A binding is modifiers and one key joined by hyphens, for example `ctrl-shift-t`. Modifiers are
`ctrl`, `alt` and `shift`; the key is one letter or digit, `comma`, `insert`, `pageup`, `pagedown`, `tab`, `enter`, `left`, `right`, `up`, `down`, `equals`, `minus` or `f1` to `f12`. Only a function key can go without a modifier. An empty string leaves the action without a shortcut. `ctrl-c`,
`ctrl-d` and `ctrl-w` are reserved for the terminal, and no two actions can share a binding.

| Action id | Default |
|---|---|
| `open_settings` | `ctrl-comma` |
| `new_tab` | `ctrl-shift-t` |
| `close_tab` | `ctrl-shift-w` |
| `split_vertical` | `ctrl-shift-d` |
| `split_horizontal` | `ctrl-shift-e` |
| `select_tab_1` to `select_tab_9` | `alt-1` to `alt-9` (9 is the last tab) |
| `copy` | `ctrl-shift-c` |
| `paste` | `ctrl-shift-v` |
| `paste_alternate` | `shift-insert` |
| `new_workspace` | `ctrl-shift-n` |
| `close_workspace` | `ctrl-alt-shift-w` |
| `rename_workspace` | `ctrl-shift-r` |
| `next_workspace` | `ctrl-pagedown` |
| `previous_workspace` | `ctrl-pageup` |
| `toggle_sidebar` | `ctrl-shift-b` |
| `jump_to_unread` | `ctrl-shift-u` |
| `show_notifications` | `ctrl-shift-i` |
| `command_palette` | `ctrl-shift-p` |
| `next_tab` | `ctrl-tab` |
| `previous_tab` | `ctrl-shift-tab` |
| `reopen_tab` | `ctrl-alt-shift-t` |
| `new_claude_workspace` | `ctrl-alt-shift-c` |
| `new_window` | `ctrl-alt-shift-n` |
| `toggle_zoom` | `ctrl-shift-enter` |
| `focus_left` | `ctrl-alt-left` |
| `focus_right` | `ctrl-alt-right` |
| `focus_up` | `ctrl-alt-up` |
| `focus_down` | `ctrl-alt-down` |
| `find` | `ctrl-shift-f` |
| `clear_scrollback` | `ctrl-shift-k` |
| `font_bigger` | `ctrl-equals` |
| `font_smaller` | `ctrl-minus` |
| `font_reset` | `ctrl-0` |
| `select_workspace_1` to `select_workspace_9` | `ctrl-1` to `ctrl-9` (9 is the last workspace) |
| `rename_tab` | `ctrl-alt-shift-r` |
| `edit_workspace_description` | `ctrl-alt-shift-e` |
| `close_other_tabs` | `ctrl-alt-shift-o` |
| `find_next` | `ctrl-shift-g` |
| `find_previous` | `ctrl-alt-shift-g` |
| `hide_find` | `ctrl-alt-shift-f` |
| `use_selection_for_find` | none |
| `trigger_flash` | `ctrl-shift-h` |
| `go_to_workspace` | `ctrl-alt-shift-p` |
| `open_folder` | `ctrl-shift-o` |
| `open_review` | none |
| `toggle_full_screen` | `f11` |
| `reload_configuration` | `ctrl-shift-comma` |
| `send_feedback` | `ctrl-shift-f1` |
| `close_window` | `ctrl-shift-f4` |
| `quit` | `ctrl-shift-q` |
| `toggle_terminal_copy_mode` | `ctrl-shift-m` |
