# Agent Overview window

Removed 2026-10-23. Last present at commit ec987c2d8f. Restore with `git checkout ec987c2d8f -- Sources/AgentOverviewWindow.swift programaTests/AgentOverviewTests.swift`, then re-add its four `project.pbxproj` entries and its entry points (listed below) by hand from `git show ec987c2d8f:<path>`, since those files have changed since.

## What it did

A separate window listing every workspace across all windows, with its terminals and its reported helpers (Claude Code subagents and other `agent.task.*` records). It had a search field, an "All / Needs input / Failed" filter, and a detail pane. For a helper the pane showed its agent type, start time, run time and final report; for a terminal it showed up to 200 lines of live output (read only while the pane was visible, at most once a second) and offered Open, Send Message, Stop and Review Changes. "Clear Done" removed done and stopped helpers. Opening it from a workspace's sidebar row scoped it to that workspace and its agent and worktree descendants.

## How it was wired

- Entry points: the sidebar's "N helpers running" line, the workspace context menu item "Open Agent Overview", the command palette command `palette.openAgentOverview`, and the unbound shortcut action `openAgentOverview` (Settings, `settings.json` `shortcuts.bindings`, `Resources/settings.schema.json`, `docs/keyboard-shortcuts.md`, `docs/settings-json.md`).
- `AgentOverviewWindowController` hosted a SwiftUI `NavigationSplitView` through an `NSHostingController` with `sceneBridgingOptions = [.title, .toolbars]`, so the title, toolbar and sidebar search field joined the window's unified toolbar.
- It read `AgentSupervisionRegistry` and the workspaces through `AppDelegate.scriptableMainWindows()` on a one-second timer while visible. `AppDelegate.scriptableMainWindowForTab` and `focusScriptableMainWindow` existed only for its Open action and were removed with it.

## Files removed and files edited

Deleted `Sources/AgentOverviewWindow.swift` (1,329 lines) and `programaTests/AgentOverviewTests.swift` (224 lines). The file and its test were renamed in place to `Sources/AgentHelpersPopover.swift` and `programaTests/AgentHelpersPopoverTests.swift`, which now hold the replacement. Entry points were cut from `Sources/TabItemView.swift`, `Sources/CommandPaletteView+Commands.swift`, `Sources/CommandPaletteView+Helpers.swift`, `Sources/AppDelegate+ShortcutActions.swift`, `Sources/KeyboardShortcutSettings.swift`, `Sources/AppDelegate.swift`, the docs and schema above, and about 40 `agentOverview.*` strings in `Resources/Localizable.xcstrings`.

## What we learned

- The window mostly repeated the main window: its terminal rows and actions were things you could do by clicking the terminal. The part with no other home was helper reports, which fits a popover on the sidebar row.
- Refreshing on a timer must not reassign an equal snapshot to a `@Published` property. Doing so re-rendered every row each second, which read as jumping and reset hover and scroll state.
- Showing or hiding a detail pane next to a list resizes the list; a split view with a permanent detail column (or no detail pane) avoids that.
- Terminal output is read only while explicitly shown and visible, capped at 200 lines, because reading it every second for every selection is not free. Helpers that run inside their parent's terminal (`runs_with_parent`) have no output of their own.

## Why removed

A whole window was too much for what it showed. Helpers now open from the sidebar's helper line as a popover listing that workspace's helpers, with a report preview, Copy, and Open Report (the full report in a markdown pane).
