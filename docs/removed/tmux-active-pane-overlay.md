# tmux active-pane overlay

Removed 2026-10-08. Last present at commit 959d2d6acf. Restore with `git checkout 959d2d6acf -- Sources/WorkspaceContentView.swift Sources/Panels/TerminalPanel.swift`.

## What it did

The overlay experiment had three targets: `surface` (the default, per-surface flash and notification ring), `bonsplitPane` (a workspace-level overlay drawn over the whole Bonsplit pane) and `tmuxActivePane`. The `tmuxActivePane` target drew the flash and ring over the active tmux pane inside a terminal surface, using a layout report of pane rectangles in tmux cell units. Only `defaults write` could select it (`tmuxOverlayExperimentEnabled`, `tmuxOverlayExperimentTarget`); there was no Settings UI.

## How it was wired

`TmuxOverlayExperimentTarget.tmuxActivePane` and its `usesTmuxActivePaneOverlay` flag in `Sources/WorkspaceContentView.swift`. The data model was `TmuxPaneLayoutPane` and `TmuxPaneLayoutReport` (with the `activePane` accessor), the helper `tmuxActivePaneOverlayRect(surfaceFrame:cellSize:pane:)` that converted cells to a rect, and `TerminalPanel.tmuxLayoutReport` with `updateTmuxLayoutReport(_:)`. Nothing ever called `updateTmuxLayoutReport`, so the report was always nil and the target behaved exactly like `surface`.

## Files removed and files edited

No files were deleted. Edited: `Sources/WorkspaceContentView.swift` (the target case, the flag, the layout types, the rect helper, and the unused `WorkspaceTitlebarInteractionMetrics`) and `Sources/Panels/TerminalPanel.swift` (the published report, its updater, and the switch case in `triggerFlash`).

The `bonsplitPane` target, `TmuxOverlayExperimentSettings` and the workspace pane overlay controller are still in the tree. Their unit tests set `targetOverrideForTesting = .bonsplitPane`, so removing them is a separate change.

## What we learned

The tmux side was never connected: no producer of the layout report existed in the app, the CLI or the socket API. A cell-based rectangle also cannot account for per-pane padding or the Bonsplit tab strip, which is why the workspace-level `bonsplitPane` overlay carries its own chrome-height constants. A future version should take pane geometry from the terminal (tmux control mode events) rather than a report pushed in from outside.

## Why removed

It was dead code behind a hidden default-off flag, with no producer feeding it.
