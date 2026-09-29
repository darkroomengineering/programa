# Keyboard shortcuts

The reference below describes macOS. Every shortcut is editable in `Settings → Keyboard Shortcuts` and in `~/.config/programa/settings.json`. `⌘ ⇧ P` opens the command palette, which lists every action.

The defaults come from `KeyboardShortcutSettings.Action` in `Sources/KeyboardShortcutSettings.swift`. `scripts/check-settings-docs.py` fails when an action in that enum is missing from the [action id table](#action-ids-and-chord-syntax) below.

The Windows frontend uses its own editable bindings under `windows.shortcuts`
in the same configuration file. See [Windows shortcuts](../windows/README.md#windows-behavior)
for defaults and [Windows testing](windows-testing.md) for validation status.

## Workspaces

| Shortcut | Action |
|----------|--------|
| ⌘ N | New workspace |
| ⌘ ⇧ C | New Claude Code workspace |
| ⌘ P | Go to workspace |
| ⌘ 1–8 | Jump to workspace 1–8 |
| ⌘ 9 | Jump to last workspace |
| ⌃ ⌘ ] | Next workspace |
| ⌃ ⌘ [ | Previous workspace |
| ⌘ ⇧ W | Close workspace |
| ⌘ ⇧ R | Rename workspace |
| ⌘ B | Toggle sidebar |
| ⌘ O | Open folder |
| ⌘ R | Rename tab (browser panes use ⌘ R for reload) |
| ⌘ ⇧ E | Edit workspace description |

## Surfaces

| Shortcut | Action |
|----------|--------|
| ⌘ T | New surface |
| ⌘ ⇧ ] | Next surface |
| ⌘ ⇧ [ | Previous surface |
| ⌃ Tab | Next surface |
| ⌃ ⇧ Tab | Previous surface |
| ⌃ 1–8 | Jump to surface 1–8 |
| ⌃ 9 | Jump to last surface |
| ⌘ ⇧ T | Reopen closed panel |
| ⌘ W | Close tab (action `closeTab`) |
| ⌥ ⌘ T | Close other tabs in the pane |

## Split panes

| Shortcut | Action |
|----------|--------|
| ⌘ D | Split right |
| ⌘ ⇧ D | Split down |
| ⌘ ⇧ ↩ | Toggle pane zoom |
| ⌥ ⌘ D | Split browser right |
| ⌥ ⇧ ⌘ D | Split browser down |
| ⌥ ⌘ ← → ↑ ↓ | Focus pane directionally |
| ⌘ ⇧ H | Flash focused panel |

## Browser

Browser developer-tool shortcuts follow Safari defaults.

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ L | Open browser in split |
| ⌘ L | Focus address bar |
| ⌘ [ | Back |
| ⌘ ] | Forward |
| ⌘ R | Reload page (in a browser pane; elsewhere ⌘ R renames the tab) |
| ⌘ = | Zoom in |
| ⌘ - | Zoom out |
| ⌘ 0 | Actual size |
| ⌥ ⌘ I | Toggle Developer Tools (Safari default) |
| ⌥ ⌘ C | Show JavaScript Console (Safari default) |

## Notifications

Agent Overview is available from the command palette as **Open Agent Overview**. Its
shortcut is unbound by default; assign it in Settings → Keyboard Shortcuts. Use the
All, Needs input, and Failed filters or search by workspace/agent name to find attention items.

| Shortcut | Action |
|----------|--------|
| ⌘ I | Show notifications panel |
| ⌘ ⇧ U | Jump to latest unread |

## Find

| Shortcut | Action |
|----------|--------|
| ⌘ F | Find |
| ⌘ G / ⌥ ⌘ G | Find next / previous |
| ⌘ ⇧ F | Hide find bar |
| ⌘ E | Use selection for find |

## Terminal

| Shortcut | Action |
|----------|--------|
| ⌘ K | Clear scrollback |
| ⌘ C | Copy (with selection) |
| ⌘ V | Paste |
| ⌘ + / ⌘ - | Increase / decrease font size (in a terminal pane) |
| ⌘ 0 | Reset font size (in a terminal pane) |
| ⌘ ⇧ M | Toggle terminal copy mode |
| { / } (in copy mode) | Jump to previous / next prompt |

## Window

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ N | New window |
| ⌃ ⌘ F | Toggle full screen |
| ⌥ ⌘ F | Send feedback |
| ⌃ ⌘ W | Hide window, keeping its sessions running |
| ⌘ ⇧ P | Command palette |
| ⌘ , | Settings |
| ⌘ ⇧ , | Reload configuration |
| ⌘ Q | Quit |

Closing a window with its red button or Close Window keeps its workspaces and terminal
processes running. Click Programa in the Dock to reopen it. When no main window is
visible, New Window and New Workspace reopen the most recently closed window first.
Close Surface and Close Workspace still end the selected session; quitting the app
uses session recovery on the next launch rather than keeping every process running.

## Review

| Shortcut | Action |
|----------|--------|
| (unbound by default) | Open review panel — set a custom shortcut in Settings → Keyboard Shortcuts |

The agent diff review panel (`programa review open`, or the command palette) shows the
worktree diff for a terminal surface, with line comments you can send back into the agent's
input. No default keyboard shortcut ships for v1 to avoid colliding with existing bindings
(⌘⇧R is already Rename Workspace) — bind one yourself if you want a shortcut.

## Git worktrees & named layouts

The native git worktree workflow (`programa worktree ...`) and named layout configs
(`programa layout ...`, "Apply layout: <name>" in the command palette) add no new keyboard
shortcuts — CLI and command palette only, by design (not an oversight).

## Action ids and chord syntax

Bind an action by setting its id under `shortcuts.bindings` in `~/.config/programa/settings.json`.
A value is one string for a single shortcut, or an array of two strings for a two-stroke chord:

```json
{
  "shortcuts": {
    "bindings": {
      "splitRight": "cmd+d",
      "newSurface": ["cmd+k", "cmd+t"]
    }
  }
}
```

A stroke is modifiers and one key joined by `+`. Modifiers are `cmd` (`command`, `⌘`),
`shift` (`⇧`), `opt` (`option`, `alt`, `⌥`) and `ctrl` (`control`, `⌃`). The first stroke of a
binding needs at least one modifier. The key is a single character or one of `left`, `right`,
`up`, `down`, `tab`, `return`, `space`, `comma`, `period`, `slash`, `backslash`, `semicolon`,
`quote`, `backtick`, `minus`, `plus`, `equals`, `leftbracket`, `rightbracket`. Unknown action ids
and invalid values are ignored and logged.

`selectSurfaceByNumber` and `selectWorkspaceByNumber` bind the digit `1`, and the same modifiers
apply to digits 1 to 9.

| Action id | Action | Default | Setting value |
|---|---|---|---|
| `openSettings` | Settings… | ⌘, | "cmd+," |
| `reloadConfiguration` | Reload Configuration | ⇧⌘, | "cmd+shift+," |
| `newWindow` | New Window | ⇧⌘N | "cmd+shift+n" |
| `closeWindow` | Close Window | ⌃⌘W | "cmd+ctrl+w" |
| `toggleFullScreen` | Toggle Full Screen | ⌃⌘F | "cmd+ctrl+f" |
| `quit` | Quit Programa | ⌘Q | "cmd+q" |
| `toggleSidebar` | Toggle Sidebar | ⌘B | "cmd+b" |
| `newTab` | New Workspace | ⌘N | "cmd+n" |
| `newClaudeWorkspace` | New Claude Code Workspace | ⇧⌘C | "cmd+shift+c" |
| `openFolder` | Open Folder | ⌘O | "cmd+o" |
| `goToWorkspace` | Go to Workspace… | ⌘P | "cmd+p" |
| `commandPalette` | Command Palette… | ⇧⌘P | "cmd+shift+p" |
| `sendFeedback` | Send Feedback | ⌥⌘F | "cmd+opt+f" |
| `showNotifications` | Show Notifications | ⌘I | "cmd+i" |
| `jumpToUnread` | Jump to Latest Unread | ⇧⌘U | "cmd+shift+u" |
| `triggerFlash` | Flash Focused Panel | ⇧⌘H | "cmd+shift+h" |
| `nextSurface` | Next Surface | ⇧⌘] | "cmd+shift+]" |
| `prevSurface` | Previous Surface | ⇧⌘[ | "cmd+shift+[" |
| `selectSurfaceByNumber` | Select Surface 1…9 | ⌃1 | "ctrl+1" |
| `nextSidebarTab` | Next Workspace | ⌃⌘] | "cmd+ctrl+]" |
| `prevSidebarTab` | Previous Workspace | ⌃⌘[ | "cmd+ctrl+[" |
| `selectWorkspaceByNumber` | Select Workspace 1…9 | ⌘1 | "cmd+1" |
| `renameTab` | Rename Tab | ⌘R | "cmd+r" |
| `renameWorkspace` | Rename Workspace | ⇧⌘R | "cmd+shift+r" |
| `editWorkspaceDescription` | Edit Workspace Description | ⇧⌘E | "cmd+shift+e" |
| `closeTab` | Close Tab | ⌘W | "cmd+w" |
| `closeOtherTabsInPane` | Close Other Tabs in Pane | ⌥⌘T | "cmd+opt+t" |
| `closeWorkspace` | Close Workspace | ⇧⌘W | "cmd+shift+w" |
| `reopenClosedBrowserPanel` | Reopen Closed Panel | ⇧⌘T | "cmd+shift+t" |
| `newSurface` | New Surface | ⌘T | "cmd+t" |
| `toggleTerminalCopyMode` | Toggle Terminal Copy Mode | ⇧⌘M | "cmd+shift+m" |
| `focusLeft` | Focus Pane Left | ⌥⌘← | "cmd+opt+left" |
| `focusRight` | Focus Pane Right | ⌥⌘→ | "cmd+opt+right" |
| `focusUp` | Focus Pane Up | ⌥⌘↑ | "cmd+opt+up" |
| `focusDown` | Focus Pane Down | ⌥⌘↓ | "cmd+opt+down" |
| `splitRight` | Split Right | ⌘D | "cmd+d" |
| `splitDown` | Split Down | ⇧⌘D | "cmd+shift+d" |
| `toggleSplitZoom` | Toggle Pane Zoom | ⇧⌘↩ | "cmd+shift+return" |
| `splitBrowserRight` | Split Browser Right | ⌥⌘D | "cmd+opt+d" |
| `splitBrowserDown` | Split Browser Down | ⌥⇧⌘D | "cmd+shift+opt+d" |
| `openBrowser` | Open Browser | ⇧⌘L | "cmd+shift+l" |
| `focusBrowserAddressBar` | Focus Address Bar | ⌘L | "cmd+l" |
| `browserBack` | Back | ⌘[ | "cmd+[" |
| `browserForward` | Forward | ⌘] | "cmd+]" |
| `browserReload` | Reload Page | ⌘R | "cmd+r" |
| `browserZoomIn` | Zoom In | ⌘= | "cmd+=" |
| `browserZoomOut` | Zoom Out | ⌘- | "cmd+-" |
| `browserZoomReset` | Actual Size | ⌘0 | "cmd+0" |
| `find` | Find… | ⌘F | "cmd+f" |
| `findNext` | Find Next | ⌘G | "cmd+g" |
| `findPrevious` | Find Previous | ⌥⌘G | "cmd+opt+g" |
| `hideFind` | Hide Find Bar | ⇧⌘F | "cmd+shift+f" |
| `useSelectionForFind` | Use Selection for Find | ⌘E | "cmd+e" |
| `toggleBrowserDeveloperTools` | Toggle Browser Developer Tools | ⌥⌘I | "cmd+opt+i" |
| `showBrowserJavaScriptConsole` | Show Browser JavaScript Console | ⌥⌘C | "cmd+opt+c" |
| `openReview` | Open Review Panel | (unbound) | (none) |
| `openAgentOverview` | Open Agent Overview | (unbound) | (none) |
