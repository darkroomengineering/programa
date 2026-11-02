# Full audit 2026-10-28 (main @ 96325f7393)

Seven readers: codebase (CLI/core/CI, Sources/), performance (measured), process/UX (reproduced against a tagged build), threat model, tests, docs. Never commit this file.

## Ranked findings

| Rank | ID | Sev | Status | Finding | Where | Fix batch |
|---|---|---|---|---|---|---|
| 1 | R-H1 | High | Reproduced | An unresolvable `surface_id`/`tab_id` silently falls back to the focused tab and returns OK; `tab-action close_others --surface surface:99` closed an unrelated tab | `Sources/TerminalController+Workspace.swift:704`; same `v2UUID(...) ?? focusedPanelId` pattern at `+Surface.swift:52,1140`, `+Review.swift:184`, `+SurfaceWait.swift:334`, `+SurfaceWaitProgram.swift:106` | A: socket refs |
| 2 | P-H1 | High | Measured | Each `programa-mcp` sidecar wakes 100x/s polling stdin (swift-sdk 0.12.1 `StdioTransport` 10 ms `Task.sleep`): 0.68% CPU each, 10 sidecars = 4.9% of a core, ~5x the whole idle app | `CLI-MCP`, swift-sdk `StdioTransport.swift:120,166,216` | B: MCP transport |
| 3 | P-M1 | Medium | Measured, unattributed | Production 0.5.478 settles at 409-415 MB (peak 1.0 GB) vs 254 MB at 0.5.416; ~40 MB malloc fragmentation, 55 large `NSConcreteData` blobs, IOSurface 66 MB vs 23 MB fresh | production pid footprint/heap | C: memory investigation |
| 4 | C-M1 | Medium | Code-confirmed | Helper records of closed workspaces are only pruned by `agent.task.list`; unfinished ones never evict, 256 leaks block `agent.task.start` | `Sources/AgentSupervision.swift:388-399,536-547`; caller `TerminalController+AgentSupervision.swift:201` | D: helpers registry |
| 5 | C5-M2 / C-M3 | Medium | Code-confirmed | Resume (CLI and palette) types `cd … && <agent> --resume …\r` into any pane without an agent, including vim/ssh/REPL | `CLI/CLI+AgentResume.swift:166-168`; `CommandPaletteView+Commands.swift:706-718` | E: resume safety |
| 6 | C5-M1 | Medium | Code-confirmed | `resume --session <unrecorded id>` assumes Claude | `CLI/CLI+AgentResume.swift:173-175` | E |
| 7 | T-L1 | Low (RCE, unlikely) | Static | fish reads `\'` inside single quotes; a crafted directory name breaks the POSIX `cd '…'` quoting | `Sources/AgentResumeCommand.swift:51,62-68` | E |
| 8 | D-M1 | Medium | Confirmed | Agent Overview window removed (#477) but 6 places still point to it, including the agent skill installed into sessions and an MCP param description | `SKILL.md:148`, `CLI/CLI+Hooks.swift:2919`, `docs/keyboard-shortcuts.md:56-58`, `docs/notifications.md:9`, `CLI-MCP/Tools/WorkspaceTools.swift:113`, comments | F: docs |
| 9 | D-M2 / D-M3 | Medium | Confirmed | CHANGELOG Unreleased misses helpers popover, resume, checkpoints, review link, MCP/skill wiring; no user doc for popover/checkpoints | `CHANGELOG.md`, `docs/workspace-interface.md` | F |
| 10 | R-M1 | Medium | Reproduced | Not-found comes back as `error`, `not_found` or `invalid_params` with four messages | CLI ref pre-resolution in `CLI/programa.swift` vs server `v2Resolve*` | A |
| 11 | R-M2 | Medium | Reproduced | `--json` ignored by `clear-notifications`; `list-notifications --json` is a bare array | `CLI/programa.swift` | A |
| 12 | C-M2 | Medium | Plausible (carried from 10-19) | Per-keystroke focus repair may steal input from in-window text fields (sidebar rename) | `AppDelegate.swift:2337-2387`, `WindowSwizzles.swift:129-134` | G: verify first |
| 13 | X-M1..4, X-L1 | Medium | Confirmed unwired | 4 `tests_v2` files (~1.2k lines) and `MenuKeyEquivalentRoutingUITests` run nowhere | `tests_v2/test_cpu_occlusion_throttle.py`, `test_split_cmd_d_ctrl_d_*`, `test_windows_api.py` | H: tests |
| 14 | X-M5 | Medium | Confirmed | Nightly failures notify nobody; 5 reds went unfixed 4 days | nightly workflow | H |
| 15 | T-M1 | Medium, accepted | Confirmed | OSC 52 clipboard write is silent again by decision (#467) | `GhosttyApp.swift:710-712` | none (accepted); option: silent only for single-line from focused pane |
| 16 | T-L2 | Low | Plausible | MCP send/read tools reach any pane; allowlisting `surface_send_text` equals allowlisting Bash | `CLI-MCP/ToolCatalog.swift` | doc note |
| — | Lows | Low | mixed | C-L1 prompt resync publishes; C-L2 formatter per record; C-L3 multi-finish aborts on first error; C5-L1 fail-open default "Permission"; C5-L2 never-passing churn UI test on macos-26; C5-L3 programa-terminal outside the cargo workspace; R-L1 `--cwd` missing dir ignored; R-L2 resume error wording; R-L3 unknown action omits list; R-L4 short refs renumber across restart; D-L1 "Thirteen" focus tools (10); D-L2/L3/L4 doc refs | various | batched with A/D/F |

## Held from 10-19
U-H1, U-H2 (reproduced); T-M2 git probe hardening; WAL heartbeat (idle samples now 0.01-0.2% non-blocked); C-H1/H2/H4/H5, C-M1/M3/M53, P-M1; docs D-M1/D-L1/D-L2/D-M3; never-run tests 57 → 4. Nightly split-close blank frame (X-H1) likely fixed by #488: 3 green nightlies since.

## Measured baseline
Debug idle 1.0% (1 ws) / 0.74% (8 ws); prod quiet 1.0-1.27%; Debug settled 166 MB (1 ws), +4.5-7 MB per realized workspace, unrealized restored workspaces free; cold launch to socket 0.86 s. `cargo test`: core 33 pass/2 ignored, programa-terminal 42 pass.

## Not covered
Shell integration scripts, Windows app and programad auth, most of `scripts/`, `claude.yml` trigger gating and release secret scoping, SUFeedURL `latest` vs `rolling`, helpers popover UI contents, window close confirmation, concurrency of mutating CLI calls, localization/tooltips, source of the 1.0 GB production peak.

## Fix batches (Linear)
A INC-351 socket refs · B INC-352 MCP stdin · C INC-353 memory (investigation) · D INC-354 helpers registry · E INC-355 resume safety · F INC-356 docs · G INC-357 focus repair verify · H INC-358 tests/CI
Branches: fix/inc-NNN-<slug>; implementers leave changes uncommitted in their worktrees.

## C (INC-353) memory result
Prod 0.5.478: 424 MB (peak 1.0 GB), 10 surfaces, 1 realized. Gap vs 254 MB baseline is Malloc Small (+~90 MB; 57 MB fragmentation, ~30-45 MB est. ghostty page buffers). IOSurface 66 MB = 1 renderer x 3 frames, unchanged. Malloc Large holds a 28.7 MB empty cached slab. Scrollback: no limit injected; fork default scrollback-limit-bytes 50 MB/surface; GhosttyConfig.swift:18 has a dead 10000 default. Peak likely all renderers realized for 30-40 s after launch (est., unverified).
Follow-ups: launch-peak repro + MallocStackLogging attribution; idle malloc_zone_pressure_relief; scrollback cap (product decision).
