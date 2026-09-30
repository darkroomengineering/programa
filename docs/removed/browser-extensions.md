# Browser extensions

Removed 2026-09-02. Last present at commit 903027ccef. Restore with `git checkout 903027ccef -- Sources/Panels/BrowserExtensionManager.swift Sources/Panels/BrowserExtensionAdapters.swift`.

## What it did

Programa's embedded browser could load WebExtensions (Chrome/Safari-style browser extensions)
from `~/.config/programa/extensions/` — unpacked directories or ZIP archives — using WebKit's
native `WKWebExtensionController`. A puzzle-piece toolbar button opened a management popover that
listed installed extensions and let the user enable, disable, or revoke them. This shipped as a
proof of concept (the code's own comment called it that).

## How it was wired

Entry point: a puzzle-piece toolbar button in the browser panel (`browser.extensions.manage`),
gated `@available(macOS 15.4, *)` since `WKWebExtensionController` requires that OS version.
`BrowserExtensionManager.shared` was wired into `BrowserPanel`'s WebView configuration
(`configureWebViewConfiguration`), tab lifecycle (`registerTab`/`unregisterTab` on setup/close),
and active-tab tracking (`Workspace+Bonsplit.swift`'s selection funnel called `noteTabActivated`).
No settings key, shortcut, command-palette entry, or socket/CLI/MCP command existed for this
feature — it was reachable only through the toolbar button.

## Files removed and files edited

Removed: `Sources/Panels/BrowserExtensionManager.swift`, `Sources/Panels/BrowserExtensionAdapters.swift`.

Edited: `Sources/Panels/BrowserPanel.swift` (dropped the `webExtensionController` wiring in
`configureWebViewConfiguration`, and the `registerTab`/`unregisterTab` calls), `Sources/Panels/BrowserPanelView.swift`
(dropped the puzzle-piece toolbar button and its call site), `Sources/Workspace+Bonsplit.swift`
(dropped the `noteTabActivated` call in the pane-selection funnel), `programaTests/BrowserConfigTests.swift`
(dropped `BrowserExtensionConsentStoreTests`, restored a shared test helper actor that had been
defined between that class and the next one), `Resources/Localizable.xcstrings` (dropped 12
`browser.extensions.*` keys: change/consent.message/consent.title/disabled/enable/enabled/manage/
manage.message/manage.title/none.message/none.title/noneRequested).

## What we learned

A medium-severity review finding showed that installed extensions received every requested permission and
host match pattern permanently, with no consent step: "Opening the first browser loads every
unpacked directory/zip from `~/.config/programa/extensions` and grants every permission/match
pattern until `distantFuture`. A copied extension with `<all_urls>` silently reads every Programa
browser page." The fix required an enable/consent UI, visible requested-hosts display,
revocation support, and default-deny for new/changed permissions — CHANGELOG.md confirms this
shipped: "Browser extensions now require explicit permission consent and support revocation."

The review also asked whether browser extensions were a user-facing feature or a developer-only
experiment, since the code loaded them in production without an enable switch. That question was
never answered before this removal — the feature stayed a proof of
concept from introduction to removal, with no settings-visible on/off switch of its own beyond the
per-extension consent added afterward.

## Why removed and what a future version should do differently

The feature never left proof-of-concept status: no discovery UI beyond a filesystem convention, no
extension store or install flow, and a real security finding that had to be patched onto it
after the fact rather than designed in. It also only worked on macOS 15.4+, splitting the toolbar
UI with an availability check for a feature most users never used.

A future version should treat extension support as security-sensitive from the start — permission
consent, host-access visibility, and revocation designed in before shipping, not added after a
review — and should decide up front whether this is a user-facing feature (with a discovery/install
UI) or stays out of the product entirely.
