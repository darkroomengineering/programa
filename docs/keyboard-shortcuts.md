# Keyboard shortcuts

The reference below describes macOS. Every shortcut is editable in `Settings → Keyboard Shortcuts` and in `~/.config/programa/settings.json`. `⌘ ⇧ P` opens the command palette, which lists every action.

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
| ⌘ W | Close surface |

## Split panes

| Shortcut | Action |
|----------|--------|
| ⌘ D | Split right |
| ⌘ ⇧ D | Split down |
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
| ⌘ R | Reload page |
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
| ⌘ G / ⌘ ⇧ G | Find next / previous |
| ⌘ ⇧ F | Hide find bar |
| ⌘ E | Use selection for find |

## Terminal

| Shortcut | Action |
|----------|--------|
| ⌘ K | Clear scrollback |
| ⌘ C | Copy (with selection) |
| ⌘ V | Paste |
| ⌘ + / ⌘ - | Increase / decrease font size |
| ⌘ 0 | Reset font size |
| ⌘ ⇧ M | Toggle terminal copy mode |
| { / } (in copy mode) | Jump to previous / next prompt |

## Window

| Shortcut | Action |
|----------|--------|
| ⌘ ⇧ N | New window |
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
