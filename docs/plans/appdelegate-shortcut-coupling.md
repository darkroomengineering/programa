# AppDelegate shortcut-routing coupling map

Status: reference. Shortcut routing stays inside `Sources/AppDelegate.swift`; this document records why a separate router type was not extracted.

Captured while evaluating audit findings N1/N2 ("extract AppDelegate's shortcut-routing
subsystem into its own module"). This documents why the extraction was scoped down to
Option A (in-place `switch` conversion + preamble struct, both still inside `AppDelegate.swift`)
instead of a full move to a new `ShortcutRouter` type, so a future full-extraction attempt
doesn't have to re-derive the coupling from scratch.

## The finding

The shortcut-routing code (`installShortcutMonitor`, `handleCustomShortcut`,
`handleConfiguredAppShortcutActions`, the browser-zoom/omnibar-repeat helpers, and the
`matchShortcut*`/`numberedShortcutDigit*`/`matchDirectionalShortcut` family -- roughly lines
5778-8107 of `AppDelegate.swift` as of commit `ef75d77fb1`) is not a separable subsystem in the
sense the audit assumed. It is deeply and bidirectionally coupled to the rest of `AppDelegate`'s
private state and helper methods, not just to a few lookups it could receive through a small
protocol.

## Measurement method

1. Extracted lines 5778-8107 to a standalone file.
2. Grepped that extract for direct assignments (`name = ...`) to identify which AppDelegate
   stored properties this code mutates in place (not just reads).
3. Extracted every `name(` call site in that range, and every `func name(` declared anywhere in
   `AppDelegate.swift`, then diffed the two sets against the calls/declarations *inside* the
   range itself to find how many distinct method dependencies point at code living elsewhere in
   the (currently 8,961-line) file.

## Results

### 15 private/internal AppDelegate stored properties mutated in place

Not read-only lookups -- these are read-and-write within the same event-handling pass, several
of them (chord-prefix bookkeeping, escape-suppression bookkeeping) read then mutated on the same
incoming `NSEvent` as part of `handleCustomShortcut`'s single-threaded precedence chain:

- `shortcutMonitor`
- `shortcutDefaultsObserver`
- `ghosttyConfigObserver`
- `configuredShortcutChordActions`
- `pendingConfiguredShortcutChord` (plus its private nested type `PendingConfiguredShortcutChord`,
  declared at `AppDelegate` class scope)
- `activeConfiguredShortcutChordPrefixForCurrentEvent`
- `splitButtonTooltipRefreshScheduled`
- `ghosttyGotoSplitLeftShortcut`
- `ghosttyGotoSplitRightShortcut`
- `ghosttyGotoSplitUpShortcut`
- `ghosttyGotoSplitDownShortcut`
- `isQuitWarningConfirmed`
- `browserAddressBarFocusedPanelId`
- `browserOmnibarRepeatKeyCode`
- `browserOmnibarRepeatDelta`
- `browserOmnibarRepeatStartWorkItem`
- `browserOmnibarRepeatTickWorkItem`

### 68 distinct AppDelegate methods, defined outside the 5778-8107 range, called directly

Spanning essentially every subsystem AppDelegate owns, not just shortcut-adjacent helpers:

- **Window/workspace lifecycle**: `openNewMainWindow`, `addWorkspaceInPreferredMainWindow`,
  `createClaudeWorkspace`, `setActiveMainWindow`, `bringToFront`, `closeWindowWithConfirmation`,
  `windowForMainWindowId`, `mainWindowForShortcutEvent`, `preferredMainWindowContextForShortcuts`,
  `preferredMainWindowContextForShortcutRouting`, `synchronizeActiveMainWindowContext`
- **Command palette**: `activeCommandPaletteWindow`, `isCommandPaletteVisible`,
  `isCommandPalettePendingOpen`, `isCommandPaletteOverlayPresented`,
  `isCommandPaletteResponderActive`, `isCommandPaletteEffectivelyVisible`,
  `isCommandPaletteMultilineTextResponderActive`, `commandPaletteSnapshot`,
  `commandPaletteWindowForShortcutEvent`, `commandPaletteFieldEditorHasMarkedText`,
  `commandPaletteMarkedTextInput`, `commandPaletteSelectionDeltaForKeyboardNavigation`,
  `requestCommandPaletteCommands`, `requestCommandPaletteSwitcher`, `requestCommandPaletteRenameTab`,
  `requestCommandPaletteRenameWorkspace`, `requestCommandPaletteEditWorkspaceDescription`,
  `markCommandPaletteOpenRequested`, `updateCommandPaletteState`, `clearCommandPalettePendingOpen`,
  `beginCommandPaletteEscapeSuppression`, `shouldConsumeSuppressedEscape`,
  `recentCommandPaletteRequestAge`, `shouldConsumeShortcutWhileCommandPaletteVisible`,
  `shouldHandleCommandPaletteShortcutEvent`, `shouldRouteCommandPaletteSelectionNavigation`,
  `shouldSubmitCommandPaletteWithReturn`, `mainWindowId`
- **Browser/omnibar**: `browserPanel`, `cmuxOwningGhosttyView`, `shouldLetFocusedBrowserOwnFindShortcut`,
  `browserOmnibarSelectionDeltaForArrowNavigation`, `browserOmnibarSelectionDeltaForCommandNavigation`,
  `browserOmnibarNormalizedModifierFlags`, `browserZoomShortcutTraceActionString`,
  `browserZoomShortcutTraceCandidate`, `browserZoomShortcutTraceFlagsString`,
  `programaIsLikelyWebInspectorResponder`, `resolvedShortcutEventWindow`,
  `shortcutEventHasAddressableWindow`, `synchronizeShortcutRoutingContext`
- **Notifications**: `toggleNotificationsPopover`, `dismissNotificationsPopoverIfShown`,
  `isNotificationsPopoverShown`, `jumpToLatestUnread`
- **Preferences/folder/UI chrome**: `openPreferencesWindow`, `showOpenFolderPanel`,
  `toggleSidebarInActiveMainWindow`
- **Debug/telemetry**: `debugShortcutRouteSnapshot`, `debugWindowToken`, `debugManagerToken`,
  `writeChildExitKeyboardProbe`, `childExitKeyboardProbeHex`, `logWorkspaceCreationRouting`
- **Split-focus transient-state guard**: `shouldSuppressSplitShortcutForTransientTerminalFocusInputs`

Full raw list from the grep-diff is reproducible by re-running the method in "Measurement
method" above against the current `AppDelegate.swift`.

## Why this blocks a clean `ShortcutRouter` extraction

A protocol seam exposing ~83 members (68 methods + 15 mutable properties) back onto
`AppDelegate` isn't a seam -- it's re-exporting most of `AppDelegate`'s private surface through
an interface. Concretely, that would mean:

1. `ShortcutRouter` would still be coupled to essentially all of `AppDelegate`'s state, just
   through a wider door -- it doesn't produce the isolation the audit finding wants.
2. "Mechanical relocation first" isn't achievable in one pass: relocating just the shortcut code
   leaves ~68 undefined-symbol errors unless those methods (window management, command palette,
   browser panels, notifications, debug telemetry) move too -- which is a much bigger change
   than "extract the shortcut subsystem."
3. Real precedence-order risk: `handleCustomShortcut`'s phases are order-dependent (see the
   docblock above that function, refs #95) and several of the mutated properties above are
   read-then-written within a single event-handling pass. Splitting reader from writer across a
   class boundary is exactly the kind of seam that can silently reorder semantics.

## What shipped instead (this PR)

Option A, scoped entirely inside `AppDelegate.swift`:

1. `handleConfiguredAppShortcutActions`'s 578-line if-chain converted to two explicit
   precedence-ordered arrays of `KeyboardShortcutSettings.Action` plus an exhaustive `switch`
   (`handleConfiguredShortcutAction`) dispatching to one small private method per case (four
   genuinely-shared groups -- directional focus, split, browser-split, browser-zoom -- factored
   into one parameterized helper each). The compiler now forces every future `Action` case to be
   handled here.
2. `handleCustomShortcut`'s six-boolean command-palette preamble extracted into a
   `CommandPaletteInteractionState` struct with a `makeCommandPaletteInteractionState(for:)`
   factory. Existing local `let` bindings in `handleCustomShortcut` are kept (sourced from the
   struct) so none of the ~300 lines of downstream precedence logic that reference them by name
   needed to change.

No behavior change in either commit. Both are still `self`-scoped methods on `AppDelegate`, so
none of the 83-member coupling above needed to be exposed through a new type.

## Recommendation for a future full extraction (N1)

Treat it as its own planning pass, not a mechanical move:

1. Decide which of the 68 external methods are *actually* shortcut-specific (a handful, e.g.
   `resolvedShortcutEventWindow`, `mainWindowForShortcutEvent`) versus general AppDelegate
   window/command-palette/browser machinery that the shortcut layer merely calls into.
2. For the general machinery, either accept that `ShortcutRouter` depends on `AppDelegate`
   (weak `unowned`/delegate reference, not a duplicate-state seam) or plan a wider decomposition
   of `AppDelegate` itself (window management, command palette, browser omnibar, notifications
   each becoming their own owned subsystem) so `ShortcutRouter` has narrower things to depend on.
3. Whichever direction, budget for a dedicated regression pass against
   `AppDelegateShortcutRoutingTests` given the order-dependence noted above.
