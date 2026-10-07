# Built-in browser

Removed 2026-10-05. Last present at commit 835c026e10. Restore the deleted files with:

```bash
git checkout 835c026e10 -- 'Sources/Browser*.swift' 'Sources/Panels/Browser*.swift' 'Sources/Find/Browser*.swift' \
  'Sources/Panels/Omnibar*.swift' Sources/Panels/DesignMode.swift Sources/Panels/IMECompositionMessageHandler.swift \
  Sources/Panels/InspectorDock.swift Sources/Panels/ProgramaWebView.swift Sources/Panels/WebViewRepresentable.swift \
  Sources/ClosedBrowserPanelRestoreSnapshot.swift Sources/TabManager+Browser.swift \
  Sources/TerminalController+BrowserAutomation.swift Sources/WebKitSubviewTransfer.swift \
  Sources/WindowBrowserSlotView.swift Sources/AppDelegate+IncomingWebURLs.swift Resources/programa-browser-snapshot.js \
  CLI/CLI+Browser.swift CLI-MCP/Tools/BrowserTools.swift 'programaTests/Browser*.swift' 'programaUITests/Browser*.swift' \
  'tests_v2/test_browser_*.py'
```

`Sources/Panels/BrowserAvailability.swift` stayed, so skip it. The call sites in shared files (window swizzles, AppDelegate shortcuts, workspace and tab manager, session persistence, socket contract, CLI and MCP tables) have to be rewired by hand; `git show <removal commit>` lists them.

## What it did

Programa could open web pages as a pane next to terminals: a WKWebView panel with an omnibar (address bar with history and search suggestions), back, forward and reload, per-workspace browser profiles, find in page, developer tools and a JavaScript console, download handling, popups, and a DesignMode element picker. Sidebar port chips and pull request links opened in a browser split by default, and links clicked in a terminal could open there too. From 2026-10-04 Programa could also be set as the system default browser.

Agents drove it through 72 `browser.*` socket methods (navigate, click, fill, type, find by role/text/label, snapshot, screenshot, eval, cookies, storage, tabs, frames, dialogs, downloads), the `programa browser ...` CLI and 72 MCP tools.

## How it was wired

- Panel: `BrowserPanel` and its extensions in `Sources/Panels/`, hosted outside the SwiftUI tree by `BrowserWindowPortal` / `WindowBrowserSlotView` so the web view survived split and workspace churn, the same portal pattern terminals use.
- Focus and keys: `NSWindow` swizzles in `WindowSwizzles.swift` decided when the web view could take first responder, forwarded Return to web forms, and pre-routed Find-family shortcuts to web content. AppDelegate had 13 browser shortcut handlers (split browser, address bar, back/forward/reload, zoom, devtools, console, reopen closed browser panel).
- Automation: `BrowserRPCDispatcher` mapped method names to `v2Browser*` handlers in `TerminalController+BrowserAutomation.swift` (the largest file in the app, about 6,000 lines), which injected `programa-browser-snapshot.js` into pages.
- Persistence: session snapshots stored browser panels (URL, profile, history); `programa.json` layouts accepted `browser` surfaces.
- Drag and drop: `FileDropOverlayView` forwarded file drags into the web view under the cursor.

## What stayed, and compatibility

- External browser detection (`app.browsers`, `PROGRAMA_DEFAULT_BROWSER`) and the Aside integration (`programa aside`) stayed; agents that need a browser use an external one.
- Every link now opens through `ExternalOpenPolicy.open`, which hands http, https and mailto to macOS and asks first for anything else.
- Saved sessions decode their panels one at a time, so an old snapshot with a browser pane restores everything else and drops that pane. `programa.json` layouts skip `browser` surfaces; a pane left empty becomes a terminal so the split keeps its shape.
- Markdown panels still use their own plain WKWebView for Mermaid diagrams.

## What we learned

The browser was the most expensive feature in the app to keep correct. Most of its cost sat in code that was not about browsing: focus guards in the window event swizzles, keyboard routing exceptions, a second portal registry next to the terminal one, drag-and-drop forwarding, and per-keystroke work in `sendEvent` that checked whether a web view owned first responder. Three earlier removals (data import, extensions, React Grab) trimmed its edges without changing that.

Usage did not justify the weight: the team's verdict was that it was "not really clicking for anyone". The integrations people did use, opening a dev server port or a pull request, work in the default browser. Agents that need to drive a page can use an external browser over MCP, such as Aside.

A future version should start from that: if agents need a browser, integrate an external one rather than embedding WebKit, and if an embedded view returns, keep it out of the terminal's focus and key paths entirely instead of teaching every window-level hook about web content.
