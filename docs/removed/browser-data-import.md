# Browser data import wizard

Removed 2026-09-02. Last present at commit 903027ccef. Restore with `git checkout 903027ccef -- Sources/Panels/BrowserDataImport.swift Sources/Panels/BrowserImportWizardView.swift programaTests/BrowserImportMappingTests.swift programaUITests/BrowserImportProfilesUITests.swift`.

## What it did

A three-step wizard let a user pick an installed browser (Safari, Chrome, Firefox, Arc, Brave,
Edge, and about 20 others), choose which of its profiles to pull from, and import cookies,
history, or both into a Programa browser profile. It scored each installed browser's on-disk
profile directories to decide what to offer, supported merging multiple source profiles into one
destination or keeping them separate, and showed a summary of what was imported. A dismissible
"Import browser data" hint chip appeared on blank browser tabs pointing users at the same flow,
with its own visibility toggle in Settings > Browser > Data.

## How it was wired

Entry points: "Import Browser Data…" menu item (View menu), a button in Settings > Browser > Data,
a button in the browser profile popover menu, a toolbar hint chip on blank tabs, and a sidebar help
menu item. All of them called `BrowserDataImportCoordinator.shared.presentImportDialog()`.
Settings keys: `browserImportHintShowOnBlankTabs` (default true) and `browserImportHintDismissed`
(default false), also configurable via `settings.json`'s `browser.showImportHintOnBlankTabs`.
UI-test hooks: `PROGRAMA_UI_TEST_BROWSER_IMPORT_HINT_SHOW`, `_DISMISSED`, `_OPEN_BLANK_BROWSER`,
`_OPEN_SETTINGS`, `_AUTO_OPEN` env vars in `AppDelegate.swift`. `SettingsNavigationTarget.browserImport`
routed Settings deep links to the Browser tab. No socket/CLI/MCP command existed for this feature.

## Files removed and files edited

Removed: `Sources/Panels/BrowserDataImport.swift`, `Sources/Panels/BrowserImportWizardView.swift`,
`programaTests/BrowserImportMappingTests.swift`, `programaUITests/BrowserImportProfilesUITests.swift`.

Added: `Sources/Panels/BrowserAvailability.swift` — extracted from `BrowserDataImport.swift` before
deletion. It holds `BrowserAvailability` and the parts of `InstalledBrowserDetector` it depends on
(`allBrowserDescriptors`, `resolveApplicationPresence`), because the `app.browsers` socket command
(`TerminalController+System.swift`) and the `PROGRAMA_DEFAULT_BROWSER`/`PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID`
env vars (`TerminalSurface.swift`) depend on that code and are not part of this feature — they stay.

Edited: `Sources/SettingsView.swift` (dropped the whole "Import Browser Data" block from the Data
section, its `@AppStorage`/`@State` properties, and the hint-visibility helpers), `Sources/ProgramaApp.swift`
(menu item, `SettingsNavigationTarget.browserImport`, a stale debug-window identifier),
`Sources/AppDelegate.swift` (UI-test env var hooks, still keeps the general "force a window" UI-test
safety net), `Sources/SidebarVisuals.swift` (help menu item), `Sources/Panels/BrowserPanelView.swift`
(blank-tab hint chip, its state, and the profile-menu import action), `Sources/Panels/BrowserToolbarViews.swift`
(profile-menu import button, `BrowserImportHintContentView`), `Sources/Panels/BrowserSettings.swift`
(`BrowserImportHint*` types/settings), `Sources/DebugWindows.swift` (stray label in a debug preview),
`Sources/ProgramaSettingsFileStore.swift` and `Resources/settings.schema.json` (`showImportHintOnBlankTabs`
config key), `Sources/SettingsModels.swift` (`SettingsTab.owning` switch), `programaTests/GhosttyConfigTests.swift`
(`BrowserInstallDetectorTests`, `BrowserImportScopeTests`), `docs/socket-api.md` (pointed the
`app.browsers` doc at the new file, dropped the reference to the removed wizard).
`Sources/Panels/BrowserProfileStore.swift` was not touched — none of its members existed only for import.

## What we learned

CHANGELOG.md records one correctness fix in this code: Unicode domains and their Punycode forms
were treated as different filters, so internationalized domains silently imported zero matching
cookies or history entries until fixed. A future re-implementation needs to normalize domains
before filtering, not after.

`docs/audits/codebase-audit-2026-08-31.md` does not mention the import wizard specifically. No
audit finding was found for this feature; if one exists it was not surfaced by this search.

The code's own comments document two deliberate boundaries worth keeping in a rebuild:
`BrowserAvailability` (installed/running browser detection for `app.browsers`) was kept
independent of `InstalledBrowserDetector`'s leftover-profile-data scoring specifically so that
adding a browser to one list never changes what the other offers. `BrowserImportPlanResolver`'s
`realize(plan:)` and `BrowserDataImporter.importData(...)` were documented as a frozen call
contract for the SwiftUI wizard, evidence that an AppKit-to-SwiftUI port of this wizard happened
once already (`BrowserImportWizardView.swift`'s header comment) and preserved that contract rather
than reworking it.

## Why removed and what a future version should do differently

The wizard was a large (3,000+ line), self-contained, low-traffic feature: browser cookie/history
import is a one-time setup action, not a daily workflow, and its surface (three-step flow, source
profile detection, separate-vs-merged destination modes) was disproportionate to that usage. It
also grew a whole secondary promotional UI (the blank-tab hint chip, its own settings, its own
dismissal state) to get users to notice it.

If this comes back, keep it much smaller: a single "Import from Browser…" action with sane
defaults (merge into current profile, cookies + history) and drop the separate-profiles/merge-mode
choice and the hint-chip promotion machinery unless usage data shows people need them.
