# Rebrand cmux → Programa — progress & remaining map

Branch: `feat/rebrand-cmux-to-programa`. Every commit below is **build-green** (compile-only
gate via `-scheme programa ... build`, or `build-for-testing` for the test phase). Runtime
contracts compile but need CI/manual verification before merge.

## Done (11 commits, off origin/main)

0. **docs** — cmux→Programa in docs, manaflow-ai→darkroomengineering, README promo cleanup.
1. **symbols** — `Cmux*`→`Programa*` (excl. AppleScript + DockTile files).
2. **source files** — 6 files `git mv` + pbxproj.
3. **test targets** — `cmuxTests`/`cmuxUITests`→`programaTests`/`programaUITests` + schemes' test labels.
4. **schemes/CLI target/scripts/CI** — schemes renamed, `programa-cli` target, bridging header,
   scripts `-scheme`/DerivedData prefix, CI scheme+test-target refs. (`PRODUCT_NAME` was already `programa`.)
5. **config paths** — `~/.config/programa/` + `programa.json` with dual-read legacy fallback.
6a. **DockTile** — `CmuxDockTilePlugin`→`ProgramaDockTilePlugin` (class+target+product+Info.plist NSDockTilePlugIn).
6b. **AppleScript** — `@objc(CmuxScript*)`→`ProgramaScript*` + `.sdef` cocoa-class + user-facing text; AE `code=` preserved.
6c. **browser JS bridge** — `__cmux*`→`__programa*` + handlers (`cmuxIMEState`/`cmuxAddressBarFocusState`/`cmuxReactGrab`) across 7 files.
6e. **CMUXCommit** — Info.plist commit key → `ProgramaCommit` (build writer + readers; no shim, regenerated per build).
6-UserDefaults. **migration shim** — version-gated startup copy of every `cmux`-prefixed default →
   `programa`-prefixed (never deletes legacy). Renamed standalone keys (welcomeShown, surfacePoolEnabled,
   devMutate…, debugBG, focusDebug, keyLatencyProbe, shortcutMonitorTrace, typingTimingLogs, settingsFile.backups).

6h. **release artifacts** — `cmux.entitlements`→`programa.entitlements` (git mv + 3 signing refs), nightly DMG/artifact names `cmux-nightly-*`→`programa-nightly-*`. Homebrew left (external/deprecated).
CI-fix. **tests/ guard scripts** — `test_ci_scheme_testaction_debug.sh` + `test_bundled_ghostty_theme_picker_helper.sh` pointed at the old `cmux.xcscheme`/`-scheme cmux` (Phase 4 miss). Fixed.

**PR: #48** — CI green except `tests-build-and-lag` (known runner flake; re-running).

## Remaining (each = its own build-gated commit; runtime = CI/manual)

### 6d — shell-integration lockstep (LARGE)
- Files: `Resources/shell-integration/cmux-{bash,zsh}-integration.{bash,zsh}` (~100+ `cmux_*` shell
  functions/vars, mostly internal to the scripts) + Swift/CLI refs in `GhosttyTerminalView.swift`,
  `KeyboardShortcutSettingsFileStore.swift`, `ProgramaApp.swift`, `Workspace.swift`, `CLI/programa.swift`.
- Cross-boundary protocol tokens (rename BOTH sides in lockstep): `$cmux_port`, `$cmux_tty`, `$cmux_pid`,
  `cmux_shell_dir`, `cmuxPortBase`/`cmuxPortRange` (injected window globals + `@AppStorage`), the
  `cmux-{bash,zsh}-integration` **filenames** (+ pbxproj Copy-Resources phase `CMUX_SHELL_*` vars, line 440),
  and any `cmux-integration.zsh` dest name.
- Approach: rename script filenames + `s/cmux_/programa_/g` inside the scripts, then rename every matching
  token on the Swift/CLI side. `cmuxPortBase/Range` covered by the UserDefaults migration already shipped.
- Verify: `tests_v2` shell/port tests on CI + manual (open terminal, PR sidebar, port detection).

### 6f — CLI command name + SSH (LARGE, 386 `cmux` refs in `CLI/programa.swift`)
- Binary is ALREADY `programa` (PRODUCT_NAME). Categorize the 386:
  - user-facing help/usage strings `cmux <sub>` → `programa` (command is already programa).
  - remote SSH bootstrap: `~/.cmux/`→`~/.programa/` (issue #15 partially done — verify), `cmux_remote_bootstrap`
    fn + remote `cmux` invocation → programa; socket paths (check already-programa).
  - internal fn/var names → cosmetic.
  - DO NOT blanket-sed (hits socket paths, env vars, remote tokens). Categorize per-occurrence.
- Verify: `tests_v2/test_ssh_remote_*.py` on CI.

### 6g — user-facing brand strings (`Resources/Localizable.xcstrings` + a few Swift defaults)
- Brand noun `cmux`→`Programa` ("Quit cmux", "About cmux", "cmux CLI", notifications, error text).
- CLI usage strings inside xcstrings ("Usage: cmux claude-teams", "Install 'cmux' in PATH") → `programa` (lowercase command).
- EN + JA. Distinguish brand (Programa) vs command (programa) per string — NOT a blanket sed.

### 6h — release artifacts
- `cmux.entitlements` → `programa.entitlements` (git mv + pbxproj `CODE_SIGN_ENTITLEMENTS` + `build-sign-upload.sh` + release/nightly yml).
- DMG names `cmux-nightly-macos*.dmg`/`cmux-release-*` → `programa-*` (release.yml, nightly.yml) so README's `programa-macos.dmg` link resolves.
- homebrew cask refs in `build-sign-upload.sh` (or delete per the board-sweep plan #7).

### Analytics (keep + note)
- PostHog `"platform": "cmuxterm"` (`PostHogAnalytics.swift:219`) and `com.cmuxterm.*` queue labels — KEEP the
  `cmuxterm` analytics value for historical continuity; add a comment. Queue labels are cosmetic (optional rename).

### Bulk internal identifiers (SAFE but voluminous — do last)
- Remaining lowercase `cmux*` camelCase Swift symbols (`cmuxAccentColor`, `cmuxOwning*`, `cmuxConfigStore`, …)
  and `cmux.*` os_log subsystems / dispatch-queue labels / in-process notification names. Pure internal, no
  contract → compile-verified. Big mechanical pass; exclude URLs, the analytics value, and anything already
  handled above. Consider delegating with a build gate.

## Build recipe
```
PROGRAMA_SKIP_ZIG_BUILD=1 xcodebuild -project GhosttyTabs.xcodeproj -scheme programa \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/programa-rebrand \
  PROGRAMA_SKIP_ZIG_BUILD=1 build 2>&1 | grep -iE "error:|BUILD (FAILED|SUCCEEDED)"
```
Never blanket-sed lowercase `cmux` (hits URLs, shell vars, command name, socket paths, analytics). Keep
`com.darkroom.programa` bundle IDs. Don't touch `ghostty/`.
