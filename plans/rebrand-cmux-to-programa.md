# Rebrand: cmux → Programa (execution plan)

Status: **not started** (an automated attempt was reverted — it produced an unverified,
duplicated, inconsistent 96-file diff and did risky out-of-scope churn). Tree is clean.
This is a large, multi-subsystem migration best done in a fresh session with full context,
in build-gated phases. Branch to use: off latest `main`.

## Why it's hard: 5 runtime-coupled contracts (NOT locally verifiable — CI/manual only)

1. **AppleScript** — `Resources/programa.sdef` references `@objc(CmuxScriptWindow/Tab/Terminal/InputTextCommand)`
   by string (`Sources/AppleScriptSupport.swift`). Rename the `@objc` name → must update the `.sdef` in lockstep,
   or keep the `@objc(Cmux…)` name and only rename the Swift symbol.
2. **Dock Tile plugin** — `CmuxDockTilePlugin` (`Sources/AppIconDockTilePlugin.swift`) is a separate Xcode target
   loaded by principal-class name (`NSDockTilePlugIn`). Rename class + target + `.plugin` product + principal class together.
3. **Browser bridge** — `__cmux*` JS injection tokens in `Sources/Panels/BrowserPanel.swift` + `ReactGrab.swift`
   must match the injected JS and `WKScriptMessageHandler` names exactly, both sides.
4. **Shell-integration protocol** — `$cmux_port`, `$cmux_tty`, `$cmux_pid`, `__cmux_t/_v`, etc. are a contract between
   Swift and `Resources/shell-integration/cmux-{bash,zsh}-integration.{bash,zsh}`. Rename both sides in lockstep.
5. **CLI command + SSH** — `CLI/cmux.swift` (~6700 lines): `cmux` is the command name in hundreds of user strings AND
   runtime SSH remote-bootstrap (`cmux_remote_bootstrap`, remote `cmux` invocation, socket paths). Also stale
   `manaflow-ai/cmux` release-repo refs (lines ~4998-5004) that should already be `darkroomengineering/programa`.

## Safe bucket (compile-verifiable) vs deferred bucket (runtime-coupled)

- **Safe now:** all `Cmux*` PascalCase types → `Programa*` EXCEPT the two runtime-coupled files above
  (`AppleScriptSupport.swift`, `AppIconDockTilePlugin.swift` — each references its Cmux types only within itself,
  so excluding them is clean). Source-file renames (`cmuxApp.swift`, `CmuxConfig.swift`, `CmuxConfigExecutor.swift`,
  `CmuxDirectoryTrust.swift`, `CmuxWebView.swift`, `CLI/cmux.swift`) + pbxproj refs. `cmuxTests/`→`programaTests/`.
  Xcode schemes (`cmux{,-unit,-ci}.xcscheme` → `programa*`) + `cmux-cli`→`programa-cli` target + `PRODUCT_MODULE_NAME cmux_cli`→`programa_cli`.
  Scripts (`reload*.sh`, `test-unit.sh`, `run-tests-v{1,2}.sh`, `build-sign-upload.sh`) + `.github/workflows/*` scheme refs.
  Log-prefix strings (`[CmuxConfig]` etc.). Config path migration `~/.config/cmux`→`~/.config/programa` (+ `cmux.json`)
  WITH a legacy-fallback shim in `ProgramaConfig.swift` + `KeyboardShortcutSettingsFileStore.swift`.
- **Deferred (needs CI/manual verification):** AppleScript `.sdef` + `@objc` names; DockTile target/principal class;
  `__cmux*` JS tokens; `$cmux_*` shell-integration vars + script filenames; the `cmux` CLI command name + SSH bootstrap;
  runtime `UserDefaults` keys with `cmux` prefixes (renaming orphans stored prefs).

## Phased order (build-gate each phase; commit buildable milestones)

- **Phase 1 — types:** `perl -pi -e 's/Cmux/Programa/g'` across `Sources/** CLI/** cmuxTests/**` EXCLUDING
  `AppleScriptSupport.swift` + `AppIconDockTilePlugin.swift`. Build with the EXISTING `cmux` scheme (no structural change yet). Commit.
- **Phase 2 — file renames:** `git mv` the Cmux-named sources + update every `project.pbxproj` ref. Build (cmux scheme). Commit.
- **Phase 3 — test dir:** `git mv cmuxTests programaTests` + pbxproj group/paths/target name. Build + run unit tests. Commit.
- **Phase 4 — scheme/targets/scripts/CI:** rename schemes (files + `BlueprintName`/`BuildableName`/`BlueprintIdentifier`),
  `cmux-cli`→`programa-cli`, module name; update `reload*.sh` (`-scheme cmux`→`programa`) + CI. Build with NEW `programa` scheme. Commit.
- **Phase 5 — config migration:** paths + legacy shim. Build. Commit.
- **Phase 6+ (deferred, CI-verified):** welcome banner + CLI command rename (couple together), shell-integration lockstep,
  browser JS tokens, AppleScript, DockTile, UserDefaults-key migration.

## Build recipe (local zig is 0.16.0; ghostty pins 0.15.2)

```
rm -rf ghostty/zig-pkg
PROGRAMA_SKIP_ZIG_BUILD=1 xcodebuild -project GhosttyTabs.xcodeproj -scheme <cmux|programa> \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/programa-rebrand \
  PROGRAMA_SKIP_ZIG_BUILD=1 build 2>&1 | grep -iE "error:|BUILD (FAILED|SUCCEEDED)"
```
Never blanket-sed lowercase `cmux` (hits URLs, shell vars, JS tokens, command name, UserDefaults keys). Keep `com.darkroom.programa` bundle IDs. Don't touch the `ghostty/` submodule or root `*.md` files.
