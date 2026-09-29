# Browser developer tools and the hosted inspector dock

**Status: NOT removed.** This sub-feature was scoped for removal in the same pass as browser data
import, browser extensions, and React Grab, but the implementer stopped before touching it and is
reporting back instead of guessing. Nothing under this heading has been deleted; this doc records
why, so the next attempt does not repeat the discovery work.

## What it does (still present)

Cmd+Option+I (Safari default) toggles WebKit's native Web Inspector attached to (or detached from)
a browser panel's page. A palette command, a `showBrowserJavaScriptConsole` shortcut, and an
AppDelegate-routed shortcut all reach it. When docked, the inspector shares the same NSView
hierarchy as the page content, and the app actively manages the divider between them (drag-resize,
side detection, layout reflow on window/pane changes). The automation API and this feature are
independent — nothing under `surface.browser.*` depends on `toggleBrowserDeveloperTools`.

## Why the implementer stopped

The prompt estimated the hosted-inspector code as roughly lines 67-772 of
`Sources/Panels/WebViewRepresentable.swift`. Grepping the actual file found `inspector`-related
identifiers as late as line 2160 of a 2251-line file — the docking/geometry logic is not confined
to a clean sub-range, it is threaded through the same `HostContainerView` coordinator code that
positions and resizes the page's own WKWebView. `Sources/BrowserWindowHostView.swift` (1,067
lines) is almost entirely one class, `WindowBrowserHostView`, that both hosts the browser page
portal (a file explicitly listed as must-keep-working for this cluster) and manages inspector dock
geometry — the two are not separable into distinct files or extensions the way React Grab's panel
routing was. `Sources/BrowserWindowPortal.swift` (2,061 lines) and `Sources/WebKitSubviewTransfer.swift`
are in the same position. `Sources/Panels/InspectorDock.swift` is a small (116-line) namespace of
pure geometry/detection helpers, but it is called from all three of the files above, so deleting it
requires reworking call sites inside code paths explicitly marked as must-stay-working, not just
deleting a self-contained file.

`Sources/Panels/BrowserPanel+DeveloperTools.swift` (707 lines) is itself a `BrowserPanel` extension
that calls into `InspectorDock` and into members defined on `WindowBrowserHostView`
(`setPreferredHostedInspectorWidth`, `setHostedInspectorFrontendWebView`,
`scheduleHostedInspectorDividerReapply`, `scheduleHostedInspectorDockConfigurationSync`) — deleting
it without also removing those `WindowBrowserHostView` members leaves dead public API on a
must-keep-working class; removing those members requires editing the geometry/layout code in
`BrowserWindowHostView.swift` directly.

Given the size (roughly 6,300 combined lines across the five files above) and the risk of
regressing the core browser panel — which this cluster's brief explicitly requires to keep working
— the implementer judged this outside what could be done reliably without extensive manual and
automated testing of browser panel layout, focus, and resize behavior, and stopped per the
brief's own guardrail: "STOP and report instead of guessing when... a removal would change the
behavior of a feature outside this cluster."

## What a future attempt should do differently

1. Budget this as its own task, separate from the other three sub-features in this cluster — it is
   larger than all three combined.
2. Start from `Sources/Panels/InspectorDock.swift`'s own doc comment, which already names every
   call site that duplicated its logic before consolidation (`BrowserPanel.swift`,
   `BrowserPanelView.swift`'s `WebViewRepresentable.Coordinator.HostContainerView`, and
   `BrowserWindowPortal.swift`'s `WindowBrowserHostView`) — that comment is close to a complete map
   of what needs to change.
3. Decide up front whether to (a) keep WebKit's native Web Inspector fully wired but delete only
   the app's UI entry points (shortcut, palette command, toolbar button), leaving the dock-geometry
   code in place as dead-but-safe, or (b) do the full removal including geometry code. Option (a)
   is much lower risk and still satisfies "remove everything not essential" from the user's
   perspective, since WebKit's own right-click "Inspect Element" is the only remaining way in.
4. If doing (b), write or run the existing `BrowserPanelTests.swift` `WindowBrowserHostViewTests`,
   `BrowserPanelHostContainerViewTests`, and `BrowserWindowPortalLifecycleTests` classes before and
   after each edit — they are the closest thing to a regression safety net for this code.

## Shared portal code

`WebKitSubviewTransfer.swift` is shared browser/terminal portal infrastructure that replaced earlier
duplicated transfer code. It is not inspector-specific and should not be deleted wholesale.
