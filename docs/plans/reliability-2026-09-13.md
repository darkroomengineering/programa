## Functional DAG

```text
Snapshot ownership + durable write results ── preserve close/reopen + safe quit ──────┐
ANSI replay + renderer visibility ─────────── bound retained resources ───────────────┤
Workspace identity + parent IDs ───────────── restore nesting and color ──────────────┤
Claude renderer defaults ──────────────────── native terminal selection ─────────────┤
Native chrome hit routing + usage layout ──── expected drag and compact UI ───────────┴── tagged build + unit/CI/UI checks + signed release
```

# Reliability release plan

User authorized implementing all items and pushing for a new version. Base: `1636122cff`.
Keep unrelated dirty user work intact; release checkout: `/private/tmp/programa-reliability-release`,
branch `release/session-reliability-20260914`. Source writers have finished.

1. **Preserve sessions — implemented.** Ordinary window close hides and retains its window, workspaces and PTYs. Dock/New Window/Cmd-N reopen hidden sessions. Explicit workspace/panel/socket disposal still terminates owned resources.
2. **Durable saves and trustworthy quit — implemented.** Autosave completes only after disk writes, retries failures and coalesces prompt saves. Failed saves cancel quit. Initial startup arbitration precedes snapshot reads/writes; replacement instances wait for authenticated older processes to exit. Acknowledged slow quits remain monitored, and failed/cancelled quits revoke only their own acknowledgement.
3. **Fix verified save deadlock — implemented and tested.** A new quit test caught the main thread waiting for a disk queue whose preference notification waited for main. Preference geometry updates now run on main; snapshot disk writes remain serialized.
4. **Recovery ownership — implemented.** Snapshot-owned escrow sessions do not expire solely from age. Shared WAL cleanup preserves all known owners. Reconnect failures are explicitly labeled as new shells; no blanket promise that every process survives every crash.
5. **Bound resource use — implemented.** Replay stores effective shared ANSI styles instead of unbounded style history. All hidden terminal renderers become reclaimable after the existing idle delay. No measured CPU/RSS delta claimed.
6. **Workspace clarity — implemented.** Worktrees retain explicit parent IDs through creation/restoration and detach safely if parents disappear. Active solid-fill rows retain custom color rails.
7. **Claude selection — pushed.** cc-settings stops forcing fullscreen, defaults to classic, and preserves explicit renderer choices. Installed user settings were narrowly migrated with a private backup. PR: https://github.com/darkroomengineering/cc-settings/pull/159 ; signed head `7e095ebda4416e6590d6582cef1b7abef6280feb`.
8. **Native UI — implemented.** Usage popover is flat and compact, with bar/label both indicating remaining capacity. Native pane and legacy tab-strip backgrounds support dragging and system double-click behavior. Coordinate conversion respects AppKit parent-coordinate hit testing and preserves control precedence.
9. **Verification and release — in progress.** Both repositories are signed and pushed. Run full PR CI plus macOS 26 close/reopen and native-window-drag UI checks. Fix failures, merge only verified heads, then watch main CI and rolling release publication.

## Current verification — September 14

- Tagged reload build passes in shared and isolated release checkouts. Installed Xcode's missing Metal Toolchain to build the pinned Ghostty helper in the clean checkout.
- **155 focused Programa tests pass, zero failures/skips**, including failed-save quit recovery, startup handoff, persistence, autosave, renderer visibility, workspace restore, drag hit testing, native drag dispatch and quota presentation.
- UI-test compilation passed before the final additional window-drag test; its updated compilation is running. UI tests run in CI, not locally.
- Independent final code review found no concrete P0/P1 issues; structural budgets and diff checks pass. The new startup helper is included in the existing family budget without increasing its ceiling.
- Native double-click selection was observed via accessibility selected text. The simplified popover was visually inspected. CUA drag did not move either the new top strip or the known sidebar control case, so physical window movement remains for XCTest CI. An independent screenshot review had a tool timeout; retry pending.
- cc-settings: 1,877 local tests, typecheck and Biome pass. CI macOS/Linux and other checks passed. Windows was cancelled after a long run; its logs show slow progress and an existing install-test timeout, so the Windows job is retrying. Do not describe all CI as green.
- Earlier broad local window-suite execution was interrupted on existing key-window preconditions. A subsequent new quit-test timeout exposed the now-fixed preference deadlock. No assertions were weakened to make the gate pass.

## Release refs

- Programa PR: https://github.com/darkroomengineering/programa/pull/336
- Signed Programa head: `0ff00a1d1b06d4b399f3d9b3d5b32c74fb130582`; isolated checkout clean.
- Full CI: `34788918434`; compatibility: `34788918467`.
- macOS 26 close/reopen UI: `34788919340`; native top-strip drag UI: `34788922828`.
- Final UI-test compilation passed, including the window-movement test. Both repositories are pushed; merge/release still pending green checks.

## Latest verification update

- Programa signed head `d1c8d3a9479e6992f08542eecbc204754917c37b`: both tagged builds pass and 156 focused tests pass, zero failures/skips.
- Close/reopen UI run `34788919340` passed both tests. Native drag run `34788922828` failed because raw native tab controls were missing from the accessibility tree before any drag. Explicit accessibility participation, selected state and press action now have runtime coverage; unchanged E2E query remains the release gate.
- Current exact-head gates: CI `34789949982` PASS, native drag UI `34789967807` PASS (1 test), close/reopen UI `34789972581` PASS (2 tests). Compatibility `34789949919`: macOS 26 PASS, macOS 15 pending. Prior broad CI was superseded by the follow-up push, not all green. CI retains 3 existing headless responder skips; main-only lag/UI jobs are conditionally skipped on the PR.
- cc-settings head `4a59f8df254ee28212be72ab57cdf2a255a245d6`: CI `34790599915`; only Windows test job remains. A second installer test exceeded Bun's default 5-second timeout. The Codex installer test file now uses a documented file-scoped 120-second integration deadline, preserving explicit overrides and all assertions. 178 installer tests, both final rollback cases, typecheck and lint pass. Windows retains 72 existing platform-specific skips.
- Fresh review approved the native accessibility follow-up, contingent on the unchanged UI test passing.

## Pending release actions

- Programa final head `d1c8d3a9479e6992f08542eecbc204754917c37b` is green: PR CI, macOS 15/26 compatibility, native dragging and close/reopen UI tests. No source changes pending.
- User explicitly authorized merging both PRs after the initial automatic-review rejection. Programa #336 merged as `01cd644e275e87ddaa0804664f88604c3311a704`; main CI `34791518963` PASSED all jobs including lag and UI regressions. Automatic release `34792943661` SUCCEEDED: signed and notarized **Programa 0.4.317** is published at https://github.com/darkroomengineering/programa/releases/tag/rolling with the DMG and Sparkle appcast.
- cc-settings #159 merged as `812a13804f0bf60329a8734ce3599aeddf5e465b` after all 15 CI jobs passed on head `4a59f8df254ee28212be72ab57cdf2a255a245d6`.
- Shared Programa main is reconciled to `01cd644e27`; all 1,151 working paths retained byte-for-byte, leaving only the 23 unrelated dirty cleanup paths plus untracked audit/plan files.
- Required implementation, verification, merges and publication are complete. Remaining measurement limitations: no controlled memory/CPU delta, no end-to-end crash/quit escrow reconnection exercise, and no fresh Claude Code session selection exercise. Close/reopen same-shell continuity and native window dragging are exercised and green.
