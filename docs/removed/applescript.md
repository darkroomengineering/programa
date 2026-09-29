# AppleScript support

Removed 2026-09-02. Last present at commit 903027ccef. Restore with `git checkout 903027ccef -- Sources/AppleScriptSupport.swift Resources/programa.sdef`.

## What it did

Programa exposed an AppleScript dictionary (`programa.sdef`) so external scripts and Script
Editor could drive the app: list windows and tabs, read the frontmost window, create new
windows and tabs, send input text to a terminal, split a pane, and quit. Automation was gated
by a `macos-applescript` ghostty config key; when disabled, every AppleScript command returned
a localized "AppleScript is disabled" error instead of running. Third-party automation tools
(Keyboard Maestro, Shortcuts via `osascript`, custom `.scpt` files) were the target audience,
not end users clicking a menu.

## How it was wired

- `Info.plist` keys `NSAppleScriptEnabled` (true) and `OSAScriptingDefinition`
  (`programa.sdef`) registered the dictionary with the OS.
- `Resources/programa.sdef` declared the suite: `Application`, `Window`, `Tab`, `Terminal`
  classes and `perform action`, `new window`, `new tab`, `quit` commands.
- `Sources/AppleScriptSupport.swift` implemented the `NSApplication`/`NSWindow` scripting
  bridge classes (`ScriptWindow`, `ScriptTab`, `ScriptTerminal`) and the
  `ScriptInputTextCommand` handler, plus `AppleScriptStrings` for the error messages.
- `GhosttyApp.appleScriptAutomationEnabled()` read the `macos-applescript` ghostty config key
  and gated every handler; this function had no other caller and was removed with it.
- No menu item, shortcut, or command-palette entry called into this file — it was reachable
  only from external AppleScript/`osascript` callers.
- pbxproj: `AppleScriptSupport.swift` was a Sources build-phase member; `programa.sdef` was a
  Resources build-phase member. Both PBXBuildFile/PBXFileReference/group entries removed.
- 11 `applescript.error.*` keys removed from `Resources/Localizable.xcstrings`.

## Files removed and files edited

Removed:
- `Sources/AppleScriptSupport.swift`
- `Resources/programa.sdef`

Edited:
- `Resources/Info.plist`: dropped `NSAppleScriptEnabled` and `OSAScriptingDefinition` keys.
- `GhosttyTabs.xcodeproj/project.pbxproj`: dropped the 8 build-file/file-reference/group
  entries for the two deleted files.
- `Resources/Localizable.xcstrings`: dropped the 11 `applescript.error.*` string keys.
- `Sources/GhosttyApp.swift`: dropped the now-unused `appleScriptAutomationEnabled()` helper.

## What we learned

No test file existed for this feature and no CHANGELOG.md entry mentions AppleScript by name,
so there is no recorded bug history or design rationale to carry forward. No review finding
mentions AppleScript. The one design signal in the removed code itself: automation was
opt-in via a ghostty config key rather than a Settings toggle, and every failure path returned
a typed `enum` error with a specific localized message (missing action, missing target, window
unavailable, etc.) rather than a generic failure — a reasonable pattern if this is rebuilt.

## Why removed and what a future version should do differently

The user's reductive pass drops anything not essential to Programa's core terminal/browser
experience; AppleScript automation is a power-user integration surface with no evidence of
use (no tests, no changelog mentions, no referencing UI). If rebuilt, prefer exposing the same
capabilities through the existing socket/CLI/MCP command surface (`V2CommandCatalog`) instead
of a second, parallel automation API — that keeps one source of truth for "what can drive
Programa from outside the app" instead of two (AppleScript dictionary vs. socket commands).
