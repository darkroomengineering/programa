# React Grab

Removed 2026-09-02. Last present at commit 903027ccef. Restore with `git checkout 903027ccef -- Sources/Panels/ReactGrab.swift`.

## What it did

React Grab was a click-to-select element picker injected into the embedded browser's page (via the
open-source `react-grab` npm package, fetched over the network and integrity-checked against a
pinned SHA-256 hash). A toolbar button or Cmd+Shift+G let a user pick a page element; the picker
copied a description of the selection and, when triggered from a terminal panel with exactly one
browser panel in the workspace, pasted that description into the terminal ("pasteback"). It shared
its round-trip architecture (panel routing, WKScriptMessageHandler bridge, NotificationCenter
pasteback) with Design Mode, which was modeled on it and is not removed.

## How it was wired

Entry points: a toolbar button in the browser panel, the `toggleReactGrab` keyboard shortcut
(default Cmd+Shift+G), a "Toggle React Grab" View-menu item, and a `palette.browserReactGrab`
command-palette command. Routing: `TabManager.toggleReactGrabFromCurrentFocus()`, called from
`AppDelegate`'s shortcut dispatch and the command palette. One automation-adjacent mention: a doc
comment in `TerminalController+BrowserAutomation.swift` describing Design Mode's routing as
"the same rule React Grab's keyboard shortcut uses" — no actual socket/CLI/MCP command existed for
React Grab itself. Settings: no persisted settings key (version pin and hash list were compiled
constants in `ReactGrabSettings`).

## Files removed and files edited

Removed: `Sources/Panels/ReactGrab.swift`.

Moved (not removed): `ReactGrabShortcutPanelSnapshot`, `ReactGrabShortcutRoute`, and
`resolveReactGrabShortcutRoute` moved from `ReactGrab.swift` into `Sources/Panels/DesignMode.swift`
before deletion, because Design Mode's `activateDesignModeRoute(in:)` depends on that same
panel-routing rule (focused browser routes directly; focused terminal routes to the workspace's
single browser panel). The identifiers keep their React-Grab-derived names since Design Mode
already referenced them extensively; a comment now explains the origin.

Edited: `Sources/Panels/BrowserPanel.swift` (dropped `isReactGrabActive`, `reactGrabMessageHandler`,
and related `@Published` state, and the `setupReactGrabMessageHandler`/`ReactGrabScriptLoader.prefetch()`
call sites), `Sources/Panels/BrowserPanelView.swift` (dropped the toolbar button and its
`resetReactGrabState` call on URL change), `Sources/TabManager.swift` (dropped
`toggleReactGrabFromCurrentFocus`, kept the sibling `toggleDesignModeFromCurrentFocus`),
`Sources/AppDelegate.swift` (dropped the `handleReactGrabDidCopySelection` notification handler
and its observer registration, the `toggleReactGrab` shortcut-action routing; left the shared
`sendTextWhenReady` pasteback function and its `isReactGrabPasteback`-named debug logging alone —
Design Mode uses that same function), `Sources/TerminalController.swift` (dropped the
`.reactGrabDidCopySelection` notification name), `Sources/ContentView.swift` and
`Sources/ContentView+CommandPalette.swift` (dropped the `palette.browserReactGrab` command),
`Sources/KeyboardShortcutSettings.swift` and `Resources/settings.schema.json` (dropped the
`toggleReactGrab` shortcut action), `Sources/ProgramaApp.swift` (dropped the View-menu item),
`Sources/TerminalController+BrowserAutomation.swift` (reworded a doc comment that referenced React
Grab as a still-existing feature), `Resources/Localizable.xcstrings` (dropped 3 keys:
`browser.reactGrab`, `menu.view.toggleReactGrab`, `shortcut.toggleReactGrab.label`),
`programaTests/ShortcutAndCommandPaletteTests.swift` (kept `ReactGrabShortcutRouteTests` — it
tests the routing function, which still exists and now backs Design Mode; dropped the two
`ReactGrabPastebackTargetTests` methods that called the removed `toggleReactGrabFromCurrentFocus`),
`programaTests/BrowserPanelTests.swift` (dropped `BrowserPanelReactGrabBridgeTests`),
`programaTests/BrowserConfigTests.swift` and `programaTests/AppDelegateShortcutRoutingTests.swift`
(dropped React-Grab-only shortcut default/routing tests).

`Sources/Panels/DesignMode.swift` was not removed and was not otherwise changed beyond the moved
routing helper — it keeps its own `armDesignModeRoundTrip`/`toggleOrInjectDesignMode` etc.,
separate from React Grab's equivalents, and remains reachable from `toggleDesignModeFromCurrentFocus`,
the `palette.browserDesignMode` command, and the `surface.browser.design_mode.toggle` automation
command. Design Mode had no in-app keyboard shortcut of its own before this removal (it shared no
actual shortcut binding with React Grab, despite the code comment describing them as parallel), so
no new shortcut was added.

## What we learned

No CHANGELOG.md entry and no review finding mentions React Grab by name. The code's own comments
are the only source of design rationale: the pasteback flow explicitly distinguished "focused
browser panel, no return target" from "focused terminal panel, route to the workspace's single
browser panel, remember where to paste back" — and refused to route at all when zero or more than
one browser panel existed in the workspace, to avoid guessing. That routing rule is exactly what
Design Mode reused and is the reason it could not be deleted outright.

## Why removed and what a future version should do differently

React Grab depended on fetching a third-party npm package's script over the network at runtime
(pinned by hash, but still an external dependency for a core interaction), and Design Mode already
covers the same "point at something on the page and bring it into the terminal" use case without
that network dependency. Keeping both was duplicate surface for one job.

If element-picking from a fetched script is wanted again, prefer vendoring the script (no runtime
fetch) or keep it entirely inside Design Mode's self-contained picker rather than reintroducing a
second parallel implementation.
