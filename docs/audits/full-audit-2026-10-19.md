# Full audit, 2026-10-19

main @ ab2e3c394b (after #435). Seven readers, one per mode. Nothing in the repo was changed. This file stays uncommitted.

Priorities from the maintainer, in order: (1) runtime cost (memory, idle CPU, GPU, startup) for the lean-and-speedy goal, (2) codebase weight, (3) UX friction in the stock defaults.

## Coverage

| Mode | Reader | Status | Verdict / note |
|---|---|---|---|
| Performance | P | Done, measured (tagged Debug `audit`, xctrace + `ps` deltas) | One measured Medium: WAL heartbeat is most of idle CPU |
| Codebase (Sources/) | C-H/C-M/C-L | Done | NEEDS RESTRUCTURING (dead conditionals, compat shims, god files) |
| Codebase (CLI, build, CI) | C-M5x/C-L5x | Done | NEEDS RESTRUCTURING (light) |
| Tests | X | Done | Half of tests_v2 never runs in CI |
| UX (Process) | U | Done, two findings reproduced on a tagged build | Two High |
| Docs | D | Done | CHANGELOG still lists removed browser features |
| Threat-Model | T | Partial: hit its turn limit; "Not traced" list is NOT cleared | Two Medium |
| Debt | grep | Done | Zero `SHORTCUT:` markers in the repo |
| Motion, SEO | n/a | Skipped | Not applicable to a native terminal |

Cross-model pass: see the "Codex cross-check" section at the end. Team-knowledge reconciliation: 4 programa notes checked. None documents a decision that covers a finding below; the escrow postmortem constrains how P-M1 is fixed (noted there).

Severity counts after merging duplicates (P-L1 into C-M3, C-L1 into P-M1) and the Codex adjustments: **High 9, Medium 18, Low 30** (C-M4, C-M5, C-M52 downgraded; includes 3 Codex-found Lows).

## First 10 to act on (impact vs effort)

| # | ID | What | Effort | Executor |
|---|---|---|---|---|
| 1 | P-M1 | Stop the WAL writer's 10 Hz drain timer and 5 s per-surface `meta.json` fsync+rename at idle; gate it on the scrollback setting | M | implementer |
| 2 | U-H2 | Notifications stop moving their workspace to the top of the sidebar (breaks Cmd+1..9 and spatial memory) | S | implementer |
| 3 | U-H1 | Sidebar scrolls the selected workspace into view | S | implementer |
| 4 | T-M1 | OSC 52 clipboard write: make it ask (with preview and allow-for-session), as the CHANGELOG already claims | S-M | implementer, then security-reviewer |
| 5 | C-M3 | WAL orphan sweep: a snapshot file idle past a cutoff (e.g. 14 days) stops pinning its session dirs | S | implementer |
| 6 | C-H1 | Delete the dead sidebar-row layouts left by the #415 knob removal | S | deslopper |
| 7 | X-L2 | Drop the `ui-regressions` dependency on `unit-tests` (ci.yml:1041), ~4 min off the 21-25 min CI wall | S | implementer |
| 8 | X-H2 | Pull the failing run's log, then fix the MCPSocketBridgeTests shard-2 flake (fake server closes right after write and ignores partial writes) | S | implementer |
| 9 | D-M1 | Remove browser entries from CHANGELOG [Unreleased]; fix README.md:36 label (D-L1) | S | direct |
| 10 | T-M2 | Disable repo-local filter drivers in background git probes (`-c filter.*` / `GIT_CONFIG_*` guard) | S | implementer, then security-reviewer |

Needs a maintainer decision before work starts: C-H2 and C-H5 (oldest build that must upgrade cleanly), C-M50 (drop the bundled 6.1 MB ghostty CLI helper), X-H1 (wire or delete 57 never-run tests_v2 files), C-L55 (omo/omx/omc wrappers).

## Merged ranked summary

| ID | Sev | Area | Issue | Evidence | Status |
|---|---|---|---|---|---|
| P-M1 | M (top priority) | Perf | WAL drain timer at 10 Hz + per-surface `meta.json` heartbeat (lock, read, encode, fsync, rename every 5 s) is 79% of idle CPU samples at 8 workspaces and 58% with a visible spinner; runs even with persistence off | Sources/SessionWALStore.swift:152-159, 586-600, 1446-1456, 1591-1620, 1660-1672 | CONFIRMED (measured, Debug) |
| U-H2 | H | UX | Every notification moves its workspace to the top, including the selected one | Sources/TabManager.swift:1787-1799 | CONFIRMED |
| U-H1 | H | UX | Sidebar never scrolls the selected workspace into view (25 workspaces, select last: stays at top) | Sources/VerticalTabsSidebar.swift:256-345 | CONFIRMED (repro) |
| C-H1 | H | Code | Sidebar row keeps layouts for removed knobs; all always-true guards and an unreachable compact branch (~150 LOC) | Sources/TabItemView.swift:395-425, 662-714, 1435-1525; VerticalTabsSidebar.swift:63-155 | CONFIRMED |
| X-H1 | H | Tests | 57/108 tests_v2 files (~10.9k LOC) and 9/15 UI classes (~4k LOC) never run in CI | tests_v2/ci_subset.txt, .github/workflows/ci.yml | CONFIRMED |
| X-H2 | H | Tests | Shard-2 flake: fake server closes clientFD right after write | programaTests/MCPSocketBridgeTests.swift:89-134 (run 38943517971) | PLAUSIBLE |
| C-H2 | H | Code | v1 escrow migration + pre-reason-holder compat (~350 LOC); a "legacy" failure key silently disables scrollback persistence | Sources/SessionEscrow.swift:762-1010, 1260; SettingsModels.swift:95-160; Workspace+Persistence.swift:664-715 | CONFIRMED code, deletion safety PLAUSIBLE |
| C-H3 | H | Code | AppDelegate.swift is 8125 lines; ~45 shortcut handlers + 300-line switch could be a table; ~1600 DEBUG lines | Sources/AppDelegate.swift:5365-7260, 6189-6296 | CONFIRMED |
| C-H4 | H | Code | Test-only code in production; "browser" zoom helpers misnamed after browser removal | Sources/AppDelegate.swift:166-196, 323-428; TabManager.swift:198-208 | CONFIRMED |
| C-H5 | H | Code | Hidden-window snapshot compat; nothing writes `isHidden` any more (~70 LOC + 3 tests) | Sources/AppDelegate.swift:1508-1650; SessionPersistence.swift:439-441, 723-735 | CONFIRMED |
| T-M1 | M | Security | OSC 52 clipboard write defaults to silent allow; CHANGELOG says it asks | ghostty/src/config/Config.zig:2463; Sources/GhosttyApp.swift:599-601, 782-790 | CONFIRMED (static) |
| T-M2 | M | Security | Background git probes run repo-local `filter.<x>.clean`; OSC 7 cwd unvalidated | Sources/GitMetadataProber.swift:447-466, 630; ReviewDiffProber.swift:144, 166; GhosttyApp.swift:2089-2098 | PLAUSIBLE |
| C-M3 | M | Perf/Code | WAL orphan sweep pinned by any `session-*.json` of any bundle/tag; dev machine had 434 dirs / 334 MB | Sources/SessionWALStore.swift:1688-1706; SessionPersistence.swift:491-509 | CONFIRMED (this machine) |
| C-M50 | M | Weight | Bundled 6.1 MB ghostty CLI helper (~15% of 42 MB app) only for `programa themes`; second zig build per app build + CI job | scripts/build-ghostty-cli-helper.sh; pbxproj:816-827; ci.yml:785 | CONFIRMED |
| C-M52 | L (downgraded) | CI | Informational macOS 15 unit suite, 407 s per main push, `continue-on-error` so nobody sees it fail: make it gate or drop it | .github/workflows/ci-macos-compat.yml:218, 247 | CONFIRMED |
| C-M1 | M | Code | ContentView.swift 5083 lines, ~65% command palette state on the root view | Sources/ContentView.swift:1591-4900 | PLAUSIBLE |
| C-M2 | M | Code | TabManager.swift opens with ~545 lines of settings types incl. legacy color keys | Sources/TabManager.swift:8-545 | CONFIRMED |
| C-M51 | M | CLI | Dead `singleLine:false` mode; v2 envelope encode copied 3x; sockaddr_un path truncated silently | CLI/SocketClient.swift:109-175, 395, 448; CLI-MCP/MCPSocketBridge.swift:140-232 | CONFIRMED |
| C-M53 | M | Code | Bonsplit dead knobs and `ContentViewLifecycle` plumbed through 5 layers, only one case used | vendor/bonsplit PaneContainerView.swift:668-688 | CONFIRMED |
| C-M54 | M | CLI | Six CLI arg parsers disagree; a flag can be taken as an id; `--` ignored | CLI/programa.swift:1458, 3931, 3981, 4017 | CONFIRMED |
| D-M1 | M | Docs | CHANGELOG [Unreleased] lists browser features that no longer exist | CHANGELOG.md ~11, 30, 32, 43 | CONFIRMED |
| D-M2 | M | Docs | README hero image shows a browser pane and old tab bars | README.md:18; docs/assets/main-first-image.png | CONFIRMED |
| D-M3 | M | Docs | Agent logos, edge fades, tab bar, ports panel undocumented | docs/ | CONFIRMED |
| U-M1 | M | UX | No tooltip on truncated workspace or tab titles | Sources/TabItemView.swift:474-479; bonsplit tabs | CONFIRMED |
| U-M2 | M | UX | ~13 Bonsplit context-menu / a11y strings not localized to Japanese | vendor/bonsplit PaneContainerView.swift:425-483; BonsplitView.swift:89 | CONFIRMED |
| U-M3 | M | UX | Socket listener failure invisible to the user | Sources/TerminalController.swift:1096; AppDelegate.swift:1079, 2301 | PLAUSIBLE |
| X-M1 | M | Tests | No tests for #432 single-tab hide, #430 idle park, #434 badge | — | CONFIRMED |
| X-M2 | M | Tests | Idle-CPU test allows 15% and is not in CI | tests_v2/test_cpu_usage.py:23 | CONFIRMED |
| C-M4 | L (downgraded) | Perf | Each session save rewrites a UserDefaults key, waking ~7 main-thread observers | Sources/AppDelegate+SessionSnapshotPersistence.swift:119-128 | Mechanism CONFIRMED; idle main thread measured at 14 ms / 20 s, so small |
| C-M5 | L (downgraded) | Perf | 8 s autosave builds/encodes/hashes snapshot on main even when unchanged | Sources/SessionAutosaveCoordinator.swift:80-92, 134-215 | Same measurement: small |
| Low | L | various | See per-mode sections | | |

## Per-mode sections

### Performance (measured)

Environment: tagged Debug build, M-series MacBook Pro, macOS 27; other agents' tagged apps were running (noise). Debug inflates CPU and memory. Production is hardened (no xctrace/sample), so production numbers stay the 2026-10-15 baseline (254 MB, ~5.6% CPU with 8 workspaces and a spinner).

Measurement log (`ps -o cputime=` deltas over 30 s, footprint after 15 s settle):

| Label | Config | CPU % runs | Median | Threads | Footprint |
|---|---|---|---|---|---|
| A | 1 ws idle | 0.27, 0.17, 0.17 | 0.17 | 13 | 106 MB |
| B | 8 ws idle | 0.93, 0.67, 0.47 | 0.67 | 48 | 152 MB |
| B2 | 8 ws idle (later) | 0.53, 0.80, 0.70 | 0.70 | 47 | 156 MB |
| C | 8 ws, 10 Hz spinner in hidden ws | 1.17, 1.37, 1.27 | 1.27 | 48 | 156 MB |
| D | 8 ws, spinner in selected ws, app not frontmost | 3.33, 3.27, 3.20 | 3.27 | 48 | 161 MB |
| E | 8 ws, spinners stopped | 0.57, 0.47, 0.43 | 0.47 | 48 | 158 MB |
| G | spinner visible, app frontmost (20 s) | 2.65, 2.45, 2.55 | 2.55 | 49 | 164 MB |
| H | persistScrollback=false, 1 realized surface, focused quiet | 1.67, 1.70, 1.67 | 1.67 | 13 | 107 MB |
| Cold launch | `open -n` to first window | 1.11, 1.02, 1.27 s | 1.11 s | | |
| No-op rebuild | `reload.sh --tag audit` | 14.0 s (1 run) | | | |

**P-M1 (Medium, top of the list): WAL idle work.** Time Profiler, 20 s windows: 8 idle workspaces = 139 ms CPU, ~110 ms of it in `SessionWAL*` frames (`persistMetaUnlocked`, `atomicRename`, `withProcessLock`, `readMetaUnlocked`) on the `session-wal` queue; main thread 14 ms. With a visible spinner: 292 of 502 ms. `sample` shows `drainAllWriters -> writeMeta -> persistMeta`. Cost scales with surfaces (0.17% at 1 ws, ~0.67% at 8). Frames persist with `sessionPersistScrollback=false` after relaunch, so the heartbeat ignores the setting.
- Direction: drain only when the ring has bytes (kick from the tee callback); keep liveness in memory or as an mtime touch and write `meta.json` only on identity/escrow/generation change; cache generation and size instead of re-reading meta and stat on every append; gate everything on `capturePolicy.enabled`.
- Constraint from team knowledge (programa-escrow-handoff-loss-postmortem): the holder liveness signal used by reclaim must stay; replace the fsync'd JSON rewrite, not the signal.
- Unexplained 4%: this is the largest non-render idle consumer found, but whether it accounts for the production residue is unproven. Next step: `ps -M` per-thread deltas on the production pid.

Memory: ~7 MB and 5 Ghostty threads (`renderer`, `io`, `io-reader`, `io-gather`, `cf_release`) per realized surface. Footprint at 8 ws: Malloc Small 66 MB, graphics 31 MB, IOSurface 14 MB.

Unmeasured leads: Release-arm64 bench of the WAL share; sidebar hidden vs visible; agent badge cost; full timer sweep; run H (1.67% focused quiet) is higher than expected and unexplained.

Rejected (measured fine): cold launch ~1.1 s; `AgentScreenDetectionEngine` ~0.05%; idle main thread 14 ms / 20 s; hidden spinner adds ~0.6 pp.

### Codebase: app Sources/ (verdict NEEDS RESTRUCTURING)

Code-judo opportunities:
- **C-H1** sidebar dead layouts (above). After #415 `SidebarTabItemSettingsSnapshot` hard-codes `usesVerticalBranchLayout`, `showsNotificationMessage` and six auxiliary flags to true, so `compactGitBranchSummaryText`, `compactDirectorySummaryText`, `branchDirectoryRow` and `SidebarWorkspaceAuxiliaryDetailVisibility` are dead. The store also rebuilds a 13-key snapshot on every `UserDefaults.didChangeNotification` per window.
- **C-H2** escrow v1 + pre-reason holder compat. Delete once the oldest supported build has the v2 holder. Removes a silent scrollback-disable failure mode.
- **C-H3** AppDelegate: table-drive shortcuts (`[Action: handler]` next to the action definition), move DEBUG blocks to `*+Debug.swift`, predicates at 83-540 to their own file, window-context registry to its own file.
- **C-H4** test-only `shouldToggleMainWindowFullScreenForCommandControlFShortcut`, `startOrFocusTerminalSearch`, color `setColor`/`currentColorHex`; rename `browserZoom*` to `terminalZoom*`.
- **C-H5** hidden-window snapshot compat.
- **C-M1** move the command palette out of `ContentView` into its own view + model.
- **C-M2** move settings types out of TabManager; drop legacy color keys with C-H2's decision.

Correctness:
- **C-M3** WAL sweep pinning (above). Do not simply ignore other bundles' snapshots: every bundle shares the `sessions/` root, so a STAGING or Release build's recoverable scrollback would be swept (Codex). Fix with an age cutoff on the snapshot file's mtime, or per-bundle roots (design tension 2). On this machine the maintainer deleted 392 stale dirs (278 MB) by hand on 2026-10-19; it will grow back until fixed.
- **C-L2** (PLAUSIBLE) `repairFocusedTerminalKeyboardRoutingIfNeeded` runs on every non-Command keyDown and may pull focus from in-window text inputs whose panel is not `focusedPanelId` (candidate: review comment composer, ReviewPanelView.swift:500). Also not in CLAUDE.md's typing-latency list. WindowSwizzles.swift:114-118; AppDelegate.swift:3335-3396.
- **C-L3** ClaudeQuotaMonitor.swift is really the provider-usage store; parser runs twice per read (:218-262, :335-340).
- **C-L4** agent PID sweep every 30 s per window with no visibility check (TabManager+GitMetadataPolling.swift:12-27); per-surface `object: nil` observers (GhosttySurfaceScrollView.swift:547, 573, 596).

### Codebase: CLI, build, CI

- **C-M50** ghostty CLI helper: replace `programa themes` with a Swift list/set, or ship it only in Release. Product call.
- **C-M51, C-M53, C-M54** above.
- **C-M52** the compat unit suite is the only macOS 15 unit run (main CI is macOS 26), so it has some unique signal, but `continue-on-error` hides it. Either let it gate or drop it.
- Lows: C-L55 omo/omx/omc wrappers ~550 LOC undocumented (CLI+AgentWrappers.swift:329-889); C-L56 CI/release xcodebuild lacks `COMPILER_INDEX_STORE_ENABLE=NO`; C-L57 "universal" naming on arm64-only release (release.yml:258); C-L58 theme-picker job is a file-exists check on its own runner; C-L59 `readEventLine` 2 syscalls per byte, no line cap (SocketClient.swift:473-499); C-L60 unlocked `waitForConnectableSocket` race (SocketClient.swift:330, PLAUSIBLE); C-L61 two connects per hook call (SocketPathResolution.swift:76-84); C-L62 CLI+Hooks.swift 3399 lines, Codex hooks block :1705-2700 extractable; C-L63 mermaid.min.js 3.2 MB with a comment saying it is not bundled (MermaidDiagramView.swift:23-25); C-L64 swift-markdown-ui maintenance status unverified.

### Tests

- **X-H1** wire the 57 never-run tests_v2 files and 9 UI classes into a nightly, or delete them.
- **X-H2** fake server: keep clientFD open until the reader finishes (same lesson as the SCM_RIGHTS sender-close race memory).
- **X-M1** add behavior tests for #432, #430, #434. **X-M2** informational CI idle-CPU gate (~8%) to replace the 15% local-only budget.
- Lows: X8-1 delete tests_v2/test_signals_auto.py (never touches Programa); X9-1 pass-through `*ForTesting` wrappers (GhosttyTerminalSupport.swift:465-476, GhosttyTerminalView+DragDrop.swift:14); X3-1 test restating 7 debug offsets (PLAUSIBLE); X6-1 palette tested 3 ways (PLAUSIBLE); X-L1 "FixSweep" file names; X-L2 `ui-regressions` needs `unit-tests` (ci.yml:1041), dropping it saves ~4 min of the 21-25 min CI wall.

### UX

- **U-H1, U-H2** above. U-H2 also breaks index-based Cmd+1..9 because positions shift under the user.
- **U-M1** tooltips on truncated titles. **U-M2** localize Bonsplit strings. **U-M3** surface socket listener failure (PLAUSIBLE).
- Lows: U-L1 Agent Overview, Open Review and move-workspace actions have no default shortcut (KeyboardShortcutSettings.swift:213-218); U-L2 Cmd+Shift+W closes a workspace where macOS/Ghostty close a window (inherited design).
- Open: `TerminalNotificationStore` has no cap on stored notifications (unmeasured).
- Rejected: defaults are sane (glass off, local quota footer, no always-on timers besides Agent Overview while open); palette results capped at 48.

### Docs

- **D-M1, D-M2, D-M3** above.
- Lows: D-L1 README.md:36 calls plain splits and the new-Claude-workspace shortcut "agent splits"; D-L2 docs/README.md index misses program-status.md and plans/local-attention-classification.md; D-L3 dead out-of-repo link in that plan. CLAUDE.md:141/210 still mention the browser (minor).

### Threat model (partial)

- **T-M1** OSC 52: inject `clipboard-write = ask` inline like the padding default (GhosttyApp.swift:782-790). A bare yes/no will fire on every tmux/Neovim yank; ship it with a content preview and "allow for this session".
- **T-M2** git filter drivers and unvalidated OSC 7 cwd. Needs a user-owned directory with a crafted `.git/config` (cloning does not copy it).
- Holds: `programa.json` trust hash, ExternalOpenPolicy, socket 0600 + Programa-ancestry check, OSC 52 read asks, no `pull_request_target`, Sparkle HTTPS + EdDSA.
- Resolved during merge: no agent integration adds the Programa socket to an agent sandbox allowlist (grep of CLI/, Sources/, Resources/ for sandbox configuration finds nothing).
- Not traced (not cleared): hook installers, MCP tool surface, ConfigExecutor after trust, `SURequireSignedFeed`, full socket method surface, CLI /tmp fallback, escrow socket auth, OSC 9/777 notification spoofing, design-mode bridge.

## Design tensions

1. **Crash durability vs idle quiet.** Every terminal is escrowed (holder process 7-18 MB RSS) and tee'd to a WAL (up to 8 MB per terminal on disk, 128 KB RAM buffer), on by default. P-M1 shows the liveness bookkeeping, not the durability itself, is the idle cost; fix the bookkeeping first, then re-measure whether the default is still worth its weight.
2. **One `sessions/` root shared by every bundle id.** Ownership is per snapshot file, so cleanup is conservative and dev machines leak. Per-bundle roots or owner metadata in `meta.json` would make the sweep exact.
3. **God files absorbing test seams.** ~60 `*ForTesting`/`debug*` seams live in production files; AppDelegate (8125), ContentView (5083), TabManager (3517), CLI+Hooks (3399). The structural budget script caps growth but not current size.
4. **`programaOnly` socket trust.** Any process in any pane can drive every pane. That is the product (agents controlling the terminal), but it makes T-M1 and T-M2 more valuable to an attacker.
5. **5 Ghostty threads per surface.** Clean isolation, 48 threads at 8 terminals. Fork/upstream question.

## Open questions (maintainer)

1. What is the oldest rolling build that must still upgrade cleanly? Decides C-H2, C-H5 and the legacy color keys.
2. Should `sessionPersistScrollback=false` stop all WAL work, including the heartbeat?
3. Keep the bundled ghostty CLI helper for `programa themes` (C-M50)?
4. Wire or delete the 57 never-run tests_v2 files (X-H1)?
5. Keep omo/omx/omc wrappers (C-L55)?
6. Does production's per-thread CPU show the same WAL share? (`ps -M` delta on the production pid.)
7. Does Cmd+Ctrl+F need app-level handling, or does the system menu cover it (C-H4)?

## Considered and rejected

- Release build settings, Sparkle as the only framework, no orphan scripts.
- Settings and shortcut docs match code (checker passes); socket method names all in the contract; env vars real.
- `ProgramaSettingsFileStore` reapply (early-outs), Agent Overview 1 s timer (only while visible), subscription 100 ms poll (only with subscribers), renderer realization 20 s timer, quota monitor (on demand).
- Escrow SCM_RIGHTS / SIGPIPE protections and autosave typing-quiet handling look correct.
- App bundle 42 MB is reasonable apart from C-M50 and C-L63.

## Codex cross-check

Codex (static review only) checked the first 10 against the cited code.
- AGREE: P-M1, U-H2, U-H1, T-M1, C-H1 (dead layouts), D-M1, T-M2. Convergent, so high conviction.
- DISAGREE, folded in: C-M3's first proposed fix would sweep other bundles' recoverable scrollback (direction changed to an mtime cutoff); C-M52 does have unique macOS 15 signal (downgraded to Low, replaced in the top 10 by X-L2). Also: the `@AppStorage` swap in C-H1 is a design choice, not a measured win, so it was dropped from the action.
- UNSURE: X-H2. The immediate close is real, but not proven to be the flake's cause; pull run 38943517971's log first.

Missed issues Codex found (new, Low, CONFIRMED by Codex citation, not re-verified here):
- **K-L1** Review panel can silently omit untracked files: failed enumeration becomes an empty list and a successful snapshot with `error: nil`. Sources/ReviewDiffProber.swift:85, 201.
- **K-L2** CLI subprocess completion can hang after the parent exits when background descendants keep the pipes open, blocking `pipe-pane`. CLI/programa.swift:324; CLI/CLI+TmuxCompat.swift:1733.
- **K-L3** `pipe-pane` drops output past 8 MiB per stream without reporting truncation. CLI/programa.swift:242; CLI/CLI+TmuxCompat.swift:1951.
