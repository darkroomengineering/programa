# tmux overlay experiment

Removed 2026-10-09. Last present at commit 380b584006. Restore with `git checkout 380b584006 -- Sources/WorkspaceContentView.swift Sources/WindowOverlayControllers.swift Sources/ContentView.swift Sources/Panels/TerminalPanel.swift Sources/Workspace.swift Sources/Workspace+Bonsplit.swift Sources/Workspace+Surfaces.swift programaTests/WorkspaceUnitTests.swift programaTests/TabManagerUnitTests.swift programaTests/WindowAndDragTests.swift programaTests/WorkspaceContentViewVisibilityTests.swift`.

The `tmuxActivePane` target was removed first, in an earlier change (last present at commit 959d2d6acf, restore its files with `git checkout 959d2d6acf -- Sources/WorkspaceContentView.swift Sources/Panels/TerminalPanel.swift`). This change removes the rest.

## What it did

The overlay experiment had three targets: `surface` (the default, per-surface flash and notification ring), `bonsplitPane` (a workspace-level overlay drawn over the whole Bonsplit pane) and `tmuxActivePane`. The `tmuxActivePane` target drew the flash and ring over the active tmux pane inside a terminal surface, using a layout report of pane rectangles in tmux cell units. Only `defaults write` could select a non-default target (`tmuxOverlayExperimentEnabled`, `tmuxOverlayExperimentTarget`); there was no Settings UI. The `surface` behavior is the only one left, and it is unchanged.

## How it was wired

`tmuxActivePane`: `TmuxOverlayExperimentTarget.tmuxActivePane` and its `usesTmuxActivePaneOverlay` flag in `Sources/WorkspaceContentView.swift`. The data model was `TmuxPaneLayoutPane` and `TmuxPaneLayoutReport` (with the `activePane` accessor), the helper `tmuxActivePaneOverlayRect(surfaceFrame:cellSize:pane:)` that converted cells to a rect, and `TerminalPanel.tmuxLayoutReport` with `updateTmuxLayoutReport(_:)`. Nothing ever called `updateTmuxLayoutReport`, so the report was always nil and the target behaved exactly like `surface`.

`bonsplitPane`: `TmuxOverlayExperimentTarget`, `TmuxOverlayExperimentSettings` (the two defaults keys and a DEBUG-only `targetOverrideForTesting`), `TmuxWorkspacePaneOverlayRenderState`, `TmuxWorkspacePaneOverlayModel` and `TmuxWorkspacePaneOverlayView` in `Sources/WorkspaceContentView.swift`, plus the rect helpers there (`tmuxWorkspacePaneOverlayRect`, `tmuxWorkspacePaneWindowOverlayRect`, `effectiveTmuxLayoutSnapshot`, `tmuxWorkspacePaneUnreadRects`, `tmuxWorkspacePaneWindowUnreadRects`). `WindowTmuxWorkspacePaneOverlayController` in `Sources/WindowOverlayControllers.swift` hosted the view in a pass-through layer on the window theme frame. `ContentView.tmuxWorkspacePaneWindowOverlayState(for:)` built the render state from `Workspace.tmuxLayoutSnapshot` (updated on every Bonsplit geometry change) and `Workspace.tmuxWorkspaceFlashPanelId`, `tmuxWorkspaceFlashReason` and `tmuxWorkspaceFlashToken`. `TerminalPanel.triggerFlash` routed to `onRequestWorkspacePaneFlash`, which `Workspace.configureTerminalPanel` set to `Workspace.triggerWorkspacePaneFlash`. When this target was active, the per-surface unread ring was suppressed in favor of the overlay.

## Files removed and files edited

No files were deleted. Edited:

- `Sources/WorkspaceContentView.swift`: the target and settings types, the overlay model and view, the rect helpers, and the `usesWorkspacePaneOverlay` check on the unread ring.
- `Sources/WindowOverlayControllers.swift`: the overlay controller, its installer, its container identifier and the pass-through container view.
- `Sources/ContentView.swift`: the render-state builder, the exact-rect helpers and the overlay update call.
- `Sources/Panels/TerminalPanel.swift`: `onRequestWorkspacePaneFlash` and the target switch in `triggerFlash`.
- `Sources/Workspace.swift`, `Sources/Workspace+Bonsplit.swift`, `Sources/Workspace+Surfaces.swift`: the layout snapshot and flash state, `configureTerminalPanel` and `triggerWorkspacePaneFlash`.
- `programaTests/WorkspaceUnitTests.swift` (`WorkspaceAttentionFlashTests`), `programaTests/TabManagerUnitTests.swift` (the flash-token assertions and one duplicate test), `programaTests/WindowAndDragTests.swift` (the overlay model and exact-rect tests) and `programaTests/WorkspaceContentViewVisibilityTests.swift` (the two rect tests).

## What we learned

The tmux side was never connected: no producer of the layout report existed in the app, the CLI or the socket API. A cell-based rectangle also cannot account for per-pane padding or the Bonsplit tab strip, which is why the workspace-level `bonsplitPane` overlay carried its own chrome-height constants. A future version should take pane geometry from the terminal (tmux control mode events) rather than a report pushed in from outside.

## Why removed

It was dead code behind a hidden default-off flag, with no producer feeding it.
