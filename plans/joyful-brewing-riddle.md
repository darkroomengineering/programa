# Board sweep — fix or clean every open issue

## Context

The `darkroomengineering/programa` board has **13 open issues**. The user asked to "ultracode all the issues missing or clean the board" — i.e. for each open issue, either implement the missing fix or remove it from the board. A 13-agent read-only triage (one explore agent per issue, evidence-grounded against current code) produced a disposition for each. User decisions on scope:

- **Execute the full sweep** — all 9 actionable fixes **plus** #27 (browser proxy), including the typing-latency hot-path #20 done carefully.
- **Close #25 and #24** as deferred/wontfix-for-now (clean the board).
- **Delete the broken Homebrew workflow** and close #7.
- **Implement #27 now** — I own the SSH-relay merge policy (decided below).

Delivery follows the established pattern: **one PR per issue**, branch → fix → push → PR → CI. Each fix is implemented by an `implementer` in an **isolated git worktree** (`isolation: worktree`) so file overlaps between issues don't collide; I review every diff before it is committed/pushed.

## Disposition summary

| # | Title | Disposition | Risk | Primary files |
|---|---|---|---|---|
| 9 | iframe/subframe downloads silently dropped | FIX | low | `BrowserPanel.swift`, `BrowserPopupWindowController.swift` |
| 26 | split dividers near-invisible | FIX | low | `vendor/bonsplit/.../TabBarColors.swift` (submodule) |
| 15 | SSH relay `~/.cmux`→`~/.programa` split-brain | FIX | low | `CLI/cmux.swift` |
| 23 | VS Code popup shows `about:blank` first | FIX | low | `BrowserPopupWindowController.swift` |
| 32 | regression test for #6618 dedup race | FIX (2-commit) | low | `TerminalController.swift`, new test |
| 28 | no scrollback-persistence privacy toggle | FIX | low | `cmuxApp.swift`, `TerminalPanel.swift`, `Localizable.xcstrings` |
| 19 | Cmd+F ignored in MarkdownPanel | FIX | low | new overlay + `TabManager.swift`, `MarkdownPanel*.swift` |
| 21 | VS Code auth lost on restart | FIX | medium | `AppDelegate.swift`, test |
| 20 | sidebar pays full snapshot cost per keystroke | FIX | medium ⚠️ hot path | `ContentView.swift`, `Workspace.swift` |
| 27 | no `browser.proxy` config | FIX | low | `settings.schema.json`, `KeyboardShortcutSettingsFileStore.swift`, `BrowserPanel.swift`, new settings file |
| 7 | broken Homebrew workflow | CLOSE (delete) | — | `.github/workflows/update-homebrew.yml` |
| 25 | scp fails on sftp-chroot | CLOSE (defer) | — | none |
| 24 | main-thread scrollback readback | CLOSE (defer) | — | none |

## Per-issue fix specs

Full evidence + exact diffs live in the triage output (`tasks/wuyvdp58w.output`). Condensed here:

### Wave A — trivial/low-risk (parallel worktrees)

**#9 — iframe downloads.** In both `BrowserPanel.swift` (~6257) and `BrowserPopupWindowController.swift` (~588), the `!navigationResponse.isForMainFrame` early-`return .allow` fires *before* the `Content-Disposition` check. Guard it: if the subframe response is an `HTTPURLResponse` whose `Content-Disposition` starts with `attachment`, return `.download` instead of `.allow`. Existing `BrowserDownloadDelegate` handles the rest.

**#26 — split divider contrast.** In `vendor/bonsplit/Sources/Bonsplit/Internal/Styling/TabBarColors.swift:162–165`, raise alpha `0.26/0.36 → 0.50/0.65` and darken/lighten `0.12/0.16 → 0.20/0.28`. **Submodule flow:** commit in `vendor/bonsplit`, `git push darkroom main`, then `git add vendor/bonsplit && git commit` in parent. Verify ancestry before pointer commit.

**#15 — SSH relay split-brain.** In `CLI/cmux.swift`, replace ~12 stale remote-host `~/.cmux/...` literals with `~/.programa/...` and remote `cmux` binary refs with `programa` (lines ~1065, 4431, 4439–4440, 4473–4474, 4480–4481, 4524–4525, 4558, 4635, 4757–4758, 4763–4764). Mechanical; matches `Workspace.swift` + `cli.go` which already use `~/.programa`. Verify via `tests_v2/test_ssh_remote_*.py` on CI.

**#23 — VS Code popup `about:blank`.** In `BrowserPopupWindowController.swift`: remove `panel.makeKeyAndOrderFront` from `init()` (~242); add `hasShownPanel` flag + `showPanelIfNeeded()`; reveal from a new `PopupNavigationDelegate.webView(_:didCommit:)` once `url != about:blank`, with a 300 ms `asyncAfter` fallback so the panel never stays hidden. **Overlaps #9 in this file** — sequence #23 after #9 (rebase) or hand both to one implementer.

**#32 — regression test for #6618.** Two-commit per CLAUDE.md policy. Commit 1: add `cmuxTests/SocketFastPathStateDedupTests.swift` instantiating `TerminalController.SocketFastPathState()` — fails to compile (type is `private`) → red. Commit 2: widen `SocketSurfaceKey` (`TerminalController.swift:435`) and `SocketFastPathState` (`:440`) from `private` → `internal` → compiles, asserts absent-panel does not suppress the next identical report. Verify with `xcodebuild -scheme programa-unit` (safe) or CI.

### Wave B — multi-file, low-risk (parallel worktrees)

**#28 — scrollback privacy toggle.** Add `ScrollbackPersistenceSettings` enum in `cmuxApp.swift` (mirror `QuitWarningSettings`, key `sessionPersistScrollback`, default `true`); `@AppStorage` binding + Settings toggle row + reset entry. Gate the single chokepoint `TerminalPanel.shouldPersistScrollbackForSessionSnapshot()` (`:210`) with `guard ScrollbackPersistenceSettings.isEnabled() else { return false }`. Add 3 localized keys (EN+JA) to `Localizable.xcstrings`.

**#19 — MarkdownPanel find.** New `Sources/Find/MarkdownSearchOverlay.swift` mirroring `BrowserSearchOverlay`; add `MarkdownSearchState` + find methods to `MarkdownPanel.swift`; mount overlay in `MarkdownPanelView.swift`; add `focusedMarkdownPanel` to `TabManager.swift` and a markdown branch in `isFindVisible`/`startSearch`/`findNext`/`findPrevious`/`hideFind`. Also delete the unreachable duplicate terminal block in `startSearch()` (`TabManager.swift:1230–1243`).

**#27 — browser proxy config.** Add `browser.proxy` object (`host`, `port` 1–65535, `type` enum `socks5|httpConnect`) to `settings.schema.json`; parse it in `KeyboardShortcutSettingsFileStore.parseBrowserSection()` into a new `BrowserUserProxySettings` (new file, mirror `BrowserThemeSettings`); consume in `BrowserPanel.applyRemoteProxyConfigurationIfAvailable()`. **Merge policy (decided):** SSH-relay proxy wins whenever a relay endpoint is active (remote panels depend on it); the user proxy applies only when `remoteProxyEndpoint == nil`. The existing `proxyConfigurations = []` clear (`:2807–2809`) must be replaced by "apply user proxy if set, else clear", so a user proxy is no longer clobbered. Config-file only (no Settings UI) this pass.

### Wave C — sensitive (own worktree, careful review)

**#21 — VS Code auth persistence.** In `AppDelegate.swift`: add stable `vscodeServerDataDir` under Application Support; make `makeConnectionTokenFile()` reuse a persistent `connection-token` file (only generate when absent); pass `--server-data-dir`; add `--port` stability or document the trade-off; set `VSCODE_CLI_USE_FILE_KEYRING=1`; guard cleanup in `stop()`/`terminationHandler` so only temp-dir tokens are deleted (`hasPrefix(NSTemporaryDirectory())`). Keep `testStopRemovesOrphanedConnectionTokenFiles` green; add a complementary test that the persistent token survives.

**#20 — sidebar keystroke cost ⚠️ typing-latency hot path.** `TabItemView` is `Equatable`/`.equatable()` and is on the typing path (CLAUDE.md). Add three `@State` caches (`cachedOrderedPanelIds`, `cachedBranchDirectoryLines`, `cachedPullRequestRows`); read them in `body` instead of recomputing `sidebarOrderedPanelIds()` / `verticalBranchDirectoryLines()` / `pullRequestDisplays()` each generation; populate the caches **only** from the debounced `sidebarObservationPublisher` handler plus `onAppear` + `onChange(of: settings)`. `sidebarImmediateObservationPublisher` keeps incrementing the generation for title/pin/color but no longer triggers the bonsplit tree walk. **Do not** add stored props that break the `==` (caches are `@State`, excluded from equality — keep it that way). Verify typing latency unchanged via debug event log + the tests-build-and-lag CI job (known flaky — re-run before investigating).

### Board cleanup

- **#7** — delete `.github/workflows/update-homebrew.yml`; close #7 with reason "no Homebrew tap maintained; workflow targeted a non-existent repo and failed every release." (Bundle the deletion into the close, or its own tiny PR.)
- **#25** — close as deferred/wontfix: the whole SSH bootstrap chain (probe + mkdir + scp + chmod/mv) is incompatible with strict sftp-chroot, not just scp; no milestone planned.
- **#24** — close as deferred tech-debt: main-thread `surface.read_text` readback; revisit only if it demonstrably starves the UI.

## Execution order

1. **Wave A** (5 issues) — fan out 5 `implementer` agents in isolated worktrees in one message. Each: apply the fix, build with `./scripts/reload.sh --tag issue-<n>` (compile-only `xcodebuild -derivedDataPath /tmp/programa-<tag>` acceptable), leave uncommitted. #26 follows the submodule push flow; #23 sequences after #9 (shared file).
2. **Review + ship Wave A** — review each diff, commit per-issue, push branch, open PR, let CI run. Close each issue via its PR ("Fixes #n").
3. **Wave B** (3 issues) — same pattern.
4. **Wave C** (2 issues, #21 then #20) — individually, with extra review on the hot path. For #20, confirm no `==`/`.equatable()` regression and typing-latency parity.
5. **Cleanup** — delete Homebrew workflow + close #7; close #25 and #24 with the reasons above.

## Verification

- **Build:** every fix must build via `./scripts/reload.sh --tag issue-<n>` (never bare `xcodebuild`/untagged `open`). Provide the `file://` App path link per CLAUDE.md when a runtime check is warranted (#26 divider contrast, #23/#9 browser, #19 Cmd+F, #28 toggle, #20 sidebar).
- **Tests:** never run locally. #32 unit test → `xcodebuild -scheme programa-unit` or CI; #15 → `tests_v2/test_ssh_remote_*.py` via `gh workflow run test-e2e.yml`; #21 → unit test on CI. Other UI behavior verified by tagged build + debug event log.
- **Submodule (#26):** confirm `cd vendor/bonsplit && git merge-base --is-ancestor HEAD origin/main` (or `darkroom/main`) before committing the parent pointer.
- **Per-PR CI:** watch each PR to green (`gh run watch`) before merge, matching #29/#30/#31.
- **Localization (#28):** all new strings in `Localizable.xcstrings` with EN + JA.

## Risks / notes

- **#20** is the only fix on a documented typing-latency hot path — highest regression risk; isolate it, review the `==` contract, and verify latency parity before merge.
- **#9 + #23** edit `BrowserPopupWindowController.swift` near the same region — sequence them.
- **#21** changes VS Code launch flags; verify the inline VS Code panel still launches and that Settings Sync auth survives a restart.
- **#27** changes proxy application order; verify SSH-remote browser panels (relay proxy) still work and a user proxy applies only when no relay is active.
- Closing #24/#25 and deleting the Homebrew workflow are reversible (reopen / revert).
