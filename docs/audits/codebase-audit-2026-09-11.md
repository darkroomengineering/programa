# Programa codebase audit — 2026-09-11

**NEEDS RESTRUCTURING.** The existing architecture has useful native-platform boundaries and substantial regression coverage, but several alternate paths bypass security, persistence, and targeting policy. Fix the security and data-loss findings before broad refactoring.

Audited the current working tree at `a0dbcc8826fefc006d92b64784d7c69f71734cc2`, including pre-existing uncommitted changes. Findings describe that tree, not necessarily a published release. Source remained unchanged. **CONFIRMED means traced statically, not reproduced at runtime.** No tests, builds, workflows, app launches, or exploit requests were run.

**42 grouped findings: 8 High, 31 Medium, 3 Low.** Unconfirmed candidates are separately listed and excluded from these counts.

| ID | Severity | Area | Issue | Location | Status |
|---|---|---|---|---|---|
| H1 | High | Browser security | Browser context-menu requests disclose unrelated profile cookies | `Sources/Panels/ProgramaWebView.swift:1360` | CONFIRMED |
| H2 | High | Terminal security | Terminal clipboard confirmation is automatically approved | `Sources/GhosttyApp.swift:431` | CONFIRMED |
| H3 | High | Privacy | Disabling scrollback persistence still records terminal output | `Sources/SettingsView.swift:585` | CONFIRMED |
| H4 | High | CLI targeting | Default CLI targeting can close or type into another pane | `CLI/programa.swift:2091` | CONFIRMED |
| H5 | High | Recovery | A bounded transcript can expand to gigabytes during restore | `Sources/SessionPersistence.swift:1316` | CONFIRMED |
| H6 | High | Durability | Failed session writes are acknowledged as successful autosaves | `Sources/AppDelegate.swift:2484` | CONFIRMED |
| H7 | High | Layout/data loss | Applying a layout can force-close a live terminal | `Sources/TerminalController+Layout.swift:64` | CONFIRMED |
| H8 | High | Socket authorization | Restricted socket mode permits same-user callers with no peer PID | `Sources/TerminalController.swift:1775` | CONFIRMED |
| M1 | Medium | CLI contracts | Independent CLI parsers disagree on valid commands and text | `CLI/programa.swift:1722` | CONFIRMED |
| M2 | Medium | Authentication | Alternate clients skip password authentication | `Resources/shell-integration/programa-zsh-integration.zsh:12` | CONFIRMED |
| M3 | Medium | MCP deadlines | MCP times out before its advertised wait deadline | `CLI-MCP/MCPSocketBridge.swift:57` | CONFIRMED |
| M4 | Medium | Input validation | Malformed selectors broaden destructive operations | `Sources/TerminalController+Notification.swift:141` | CONFIRMED |
| M5 | Medium | Browser references | Browser nth/last references do not identify the selected element | `Sources/TerminalController+BrowserAutomation.swift:4676` | CONFIRMED |
| M6 | Medium | Browser dialogs | Dialog accept/dismiss does not answer the original browser dialog | `Sources/Panels/BrowserPanelWebDelegates.swift:600` | CONFIRMED |
| M7 | Medium | Browser proxy | Switching browser profiles omits configured proxy policy | `Sources/Panels/BrowserPanel.swift:1255` | CONFIRMED |
| M8 | Medium | Escrow resources | Successful escrow handoff leaks the holder's PTY descriptor | `Sources/SessionEscrow.swift:1665` | CONFIRMED |
| M9 | Medium | History isolation | Automatic snapshot fallback can restore another bundle's layout | `Sources/SessionPersistence.swift:485` | CONFIRMED |
| M10 | Medium | Startup recovery | Missing snapshots also skip live orphan recovery | `Sources/AppDelegate.swift:1734` | CONFIRMED |
| M11 | Medium | Browser history | History persistence can exceed its own read limit | `Sources/Panels/BrowserHistoryStore.swift:216` | CONFIRMED |
| M12 | Medium | Review correctness | Reviews can show stale results or falsely show no changes | `Sources/Panels/ReviewPanel.swift:105` | CONFIRMED |
| M13 | Medium | Panel lifecycle | Moving a review panel loses its lifecycle subscription | `Sources/Workspace+Bonsplit.swift:759` | CONFIRMED |
| M14 | Medium | Workspace events | Most workspace creation paths omit the created event | `Sources/TabManager.swift:1615` | CONFIRMED |
| M15 | Medium | Workspace ordering | Relative workspace moves use the pre-removal index | `Sources/TabManager.swift:1858` | CONFIRMED |
| M16 | Medium | Agent state | Inferred agent state remains after detection ends | `Sources/AgentScreenDetectionEngine.swift:299` | CONFIRMED |
| M17 | Medium | Hook persistence | Hook state fails on a fresh home directory | `CLI/CLI+Hooks.swift:157` | CONFIRMED |
| M18 | Medium | Hook approval | EOF approves hook installation/removal | `CLI/HookInstallationCoordinator.swift:120` | CONFIRMED |
| M19 | Medium | Local tooling | Build-only reload removes a running tagged app's socket | `scripts/reload.sh:323` | CONFIRMED |
| M20 | Medium | CI readiness | Display-readiness exhaustion can leave CI green without tests | `.github/workflows/ci.yml:1005` | CONFIRMED |
| M21 | Medium | Updates | Update timeout is presented as “latest” | `Sources/Update/UpdateDriver.swift:236` | CONFIRMED |
| M22 | Medium | Notifications | Background-window notifications are suppressed | `Sources/TerminalNotificationStore.swift:350` | CONFIRMED |
| M23 | Medium | Markdown search | Markdown find counts matches but does not reveal them | `Sources/Panels/MarkdownPanelView.swift:51` | CONFIRMED |
| M24 | Medium | Markdown rendering | Markdown alert parsing ignores fenced-code context | `Sources/Panels/MarkdownDocumentView.swift:147` | CONFIRMED |
| M25 | Medium | Quota parsing | Invalid quota dates can trap the usage UI | `Sources/ClaudeQuotaMonitor.swift:47` | CONFIRMED |
| M26 | Medium | Recipes | Multiline recipe prefill submits before the promised Return | `Sources/ProgramaConfigExecutor.swift:38` | CONFIRMED |
| M27 | Medium | Document security | Mermaid source can escape the inline script | `Sources/Panels/MermaidDiagramView.swift:116` | CONFIRMED |
| M28 | Medium | Sidebar geometry | Sidebar autoscroll uses the wrong coordinate origin | `Sources/SidebarDragDrop.swift:686` | CONFIRMED |
| M29 | Medium | Debug profiler | Debug timing reporters access key codes on non-key events | `Sources/TypingProfiler.swift:213` | CONFIRMED |
| M30 | Medium | UI test harness | Notification UI-test preparation recursively subscribes | `Sources/AppDelegate+UITestHarnesses.swift:1591` | CONFIRMED |
| M31 | Medium | Layout identity | Saved layout identity can crash command-palette construction | `Sources/ProgramaLayoutStore.swift:143` | CONFIRMED |
| L1 | Low | Shortcut settings | Generated Return shortcut does not round-trip | `Sources/ProgramaSettingsFileStore.swift:1667` | CONFIRMED |
| L2 | Low | Release notes | Rolling release notes use a nonexistent milestone tag | `Sources/Update/UpdateViewModel.swift:500` | CONFIRMED |
| L3 | Low | Docs/localization | Onboarding and localized UI have source-backed drift | `CONTRIBUTING.md:6` | CONFIRMED |

## System map and expectation gaps

| Surface | Actual ownership | Expected behavior / observed gap |
|---|---|---|
| App and workspace lifecycle | AppDelegate, TabManager, Workspace, Bonsplit | Creation, transfer, restore, and layout application should share lifecycle rules; several paths omit events/subscriptions or close existing terminals. |
| Terminal rendering and process recovery | GhosttyApp, TerminalSurface, portals, SessionEscrow, SessionWALStore, SessionPersistence | Native renderer and process continuity are valuable; clipboard approval, content-persistence consent, durable-save acknowledgment, and descriptor transfer have gaps. |
| Automation | CLI registry/parsers → Unix socket → TerminalController; MCP has a separate transport | Implicit targets should remain the originating surface, invalid selectors should fail, and deadlines/auth should agree across clients. They do not consistently agree. |
| Browser | BrowserPanel, ProgramaWebView, profile stores, WebKit delegates, browser RPC | Native cookie/proxy/dialog ownership is bypassed by copied requests and synthetic automation state. |
| Agent and review UI | Hook state, screen detection, ReviewPanel, notification store | Agent state should clear when detection ends; reviews should show current results and follow moved panels; background windows should still notify. |
| Delivery | Tagged reload, CI readiness, sealed release payloads, Sparkle | Build-only reload should preserve the running app; unavailable display infrastructure should fail CI; update timeout should not claim the latest version. |

## Code-Judo Opportunities

These are restructuring directions supported by the findings below, not additional counted defects. No deletion or performance savings were measured.

1. **Make one CLI argument and target contract authoritative.** Delete the independent preflight allowlists and per-command environment-merging rules after command descriptors can parse the full request. H4 and M1 demonstrate real divergence. Preserve explicit-selector precedence and literal text after an argument terminator.
2. **Use one authenticated socket transport core for CLI, MCP, and shell telemetry.** Keep presentation/tool schemas separate; share framing, connection authentication, and deadline calculation. M2–M3 are failures caused by alternate transports. Do not weaken the server's authentication gate to accommodate them.
3. **Keep browser policy with WebKit.** Replace profile-wide cookie copying with browser-owned downloads/responses, apply proxy configuration when selecting a data store, and connect automation to native pending dialog completions. H1, M5–M7 identify the cost of parallel browser state.
4. **Make workspace/panel attachment the canonical lifecycle operation.** Creation and movement should install the same subscriptions and publish the same lifecycle events. Reuse the existing sidebar insertion-index conversion for relative moves. M13–M15 identify omissions in current alternate paths; H7 requires an explicit replacement policy before layout mutation.
5. **Separate process recovery from content persistence and acknowledge actual durable writes.** Retain escrow/WAL responsibilities that keep processes alive, but centralize the user's permission to record terminal contents. Replace accumulating ANSI escape history with bounded rendition state. H3, H5, H6, M8–M10 arise at these boundaries. Merely splitting large files would preserve the defects.

## High-priority findings

### H1 — Browser context-menu requests disclose unrelated profile cookies

**High · CONFIRMED · browser security.** `Sources/Panels/ProgramaWebView.swift:1360` and `:1572` fetch **all** profile cookies and serialize the entire array into the `Cookie` header of a clicked download/image URL. Native context-menu actions reach these paths through `:1758`, `:1853`, and `:2098`; no domain, path, or Secure filtering follows.

Sign into site A, then copy an image or download a linked file hosted on site B. B receives A's session cookies, including HttpOnly cookies; a permitted HTTP target can also receive Secure cookies. The request precedes the save dialog, so canceling that dialog does not prevent disclosure. The attacker needs to induce the relevant user action, not execute native code. Apple documents `requestHeaderFields(with:)` as conversion of the supplied cookies, not URL selection ([API documentation](https://developer.apple.com/documentation/foundation/httpcookie/requestheaderfields%28with%3A%29)).

**Direction:** prefer native WebKit download/response handling. If a separate request is necessary, use an isolated profile cookie store with URL-appropriate selection on every redirect; never copy all cookies. Verify with two controlled origins and an HTTP target, without real credentials.

### H2 — Terminal clipboard confirmation is automatically approved

**High · CONFIRMED · terminal security.** `Sources/GhosttyApp.swift:431` installs the clipboard confirmation callback; `:461` completes the request with `confirmed: true` without presenting a prompt or considering request kind. The pinned Ghostty code defaults clipboard reads to `ask` (`ghostty/src/config/Config.zig:2462`) and requires confirmation for OSC 52 reads (`ghostty/src/Surface.zig:6450`). No app-generated configuration overrides that policy.

A terminal program, including one in a remote shell, can request the system clipboard and receive its contents without the promised approval. The same callback bypasses the unsafe-paste confirmation path.

**Direction:** present a surface-scoped confirmation and complete positively only after approval, with denial/cancellation and surface lifetime handled according to the pinned Ghostty API. Preserve the existing pointer-identity guard; it does not substitute for user consent.

### H3 — Disabling scrollback persistence still records terminal output

**High · CONFIRMED · privacy.** `Sources/SettingsView.swift:586` promises that disabled persistence avoids writing scrollback to disk. `Sources/TerminalSurface.swift:1682` and `:2174` still register the WAL tee; `Sources/SessionWALStore.swift:874` gates testing, not the preference. Content logging therefore continues with the option disabled.

**Direction:** enforce the preference at every content-writing entry point, including escrow drain/frame capture, while keeping process identity and reattachment independent. Verification must inspect filesystem output from a tagged instance with a synthetic marker and the preference disabled; snapshot JSON alone is insufficient.

### H4 — Default CLI targeting can close or type into another pane

**High · CONFIRMED · automation/data loss.** `CLI/programa.swift:2091` merges `PROGRAMA_WORKSPACE_ID` into `workspaceArg`; `:2092` uses `PROGRAMA_SURFACE_ID` only if that merged workspace is nil. Normal sessions provide both. Equivalent logic appears in split, read, wait, prompt, send, send-key, scaffold, and test commands. The server falls back to the focused panel when surface is omitted (`Sources/TerminalController+Surface.swift:234`, `:837`, `:894`).

An agent runs in pane A while the user focuses B in the same workspace. `programa close-surface` closes B; `send-key ctrl+c` interrupts B; `send` types into B. `tests_v2/test_close_surface_env_precedence.py:1` documents this suppression as a deliberate fix for a stale surface inherited from another workspace. That protection is useful, but the broad rule also discards a valid originating surface. Existing stale-target, explicit-target, and environment-cleared tests do not establish the intended same-workspace/background-origin behavior.

**Direction:** resolve targets once, retain explicit-versus-environment provenance, and validate surface membership. Recommend preserving a valid originating surface while retaining the tested fallback for a foreign stale identifier. This refines an intentional compatibility policy; preserve its regression assertion and establish the same-workspace contract before changing behavior. Test the real CLI with both environment IDs and a different focused pane.

### H5 — A bounded transcript can expand to gigabytes during restore

**High · CONFIRMED · recovery availability.** `Sources/SessionPersistence.swift:1316` accumulates all nonreset SGR escapes into `currentSGR`; `:1347` emits that growing history per cell. Fresh-process restoration calls this parser (`Sources/Workspace+Persistence.swift:532`).

A single line of 60,000 repetitions of `ESC[31mA` is 360,000 ASCII bytes, within the 400,000-character cap. The emitted escape prefixes alone total **9,000,150,000 bytes**, calculated as `5 × 60000 × 60001 / 2`. This is a source-derived output-size calculation, not a measured memory or timing result. A bounded saved transcript can therefore freeze or exhaust memory during launch.

**Direction:** represent current rendition as bounded attributes and emit required transitions, or use an existing terminal parser capability. Verify linear output growth for long colored lines in addition to preserving overwrite/reset semantics.

### H6 — Failed session writes are acknowledged as successful autosaves

**High · CONFIRMED · durability.** `Sources/AppDelegate.swift:2484` returns success after enqueueing persistence; `:2542` discards `SessionPersistenceStore.save`'s result. `SessionAutosaveCoordinator` then records the successful fingerprint and suppresses unchanged-layout retries.

An ENOSPC or permission error leaves the old snapshot on disk, but a stable current layout is considered saved. A later exit can lose that layout. Coordinator tests that inject `false` do not exercise the production sink that masks failure.

**Direction:** propagate asynchronous persistence completion and advance the durable fingerprint only after successful writing. Exercise a failing storage sink, recovery of that sink, and retry of the unchanged layout.

### H7 — Applying a layout can force-close a live terminal

**High · CONFIRMED · data loss.** `Sources/TerminalController+Layout.swift:64` accepts an existing workspace. `Sources/Workspace+Layout.swift:227` and `:242` assume its first terminal is a disposable placeholder and force-close it when the first saved surface needs cwd/env customization or is a browser.

Apply such a layout to a workspace running a real command: the terminal is torn down without a destructive replacement guard. Existing splits also remain, so added splits and divider restoration can target the wrong tree.

**Direction:** restrict application to a pristine workspace or define an explicit, guarded replacement operation. Do not infer disposability from being the first panel. Verify busy terminals and already-split workspaces.

### H8 — Restricted socket mode permits same-user callers with no peer PID

**High · CONFIRMED · local authorization.** `Sources/TerminalController.swift:1775` enforces ancestry when a PID exists, but `:1797` accepts same-UID connections when it does not. A same-user process outside the app's descendants can connect, enqueue a command, and close before PID sampling. Apple XNU retains peer credentials while `LOCAL_PEERPID` can fail after disconnect ([XNU implementation](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/kern/uipc_usrreq.c)).

This bypasses the selected descendant-only mode; it does not grant a different OS user access. The compatibility comment for send-only clients explains intent but does not satisfy the restricted contract.

**Direction:** fail closed when ancestry cannot be established. Keep same-user compatibility in the already separate automation mode or require authentication. Verify a disconnected non-descendant with queued bytes, as well as legitimate descendants.

## Other confirmed behavior findings

Each item below is **Medium · CONFIRMED**, unless explicitly stated otherwise. Locations are current-tree line anchors; verification described here is recommended work, not work run during this audit.

### M1 — Independent CLI parsers disagree on valid commands and text

`CLI/programa.swift:1722` registers `snapshot`, but the preflight switch ending at `:6498` has no matching contract, so normal snapshot invocations fail before their handlers. `worktree open --all` is implemented at `:4840` but omitted from the boolean allowlist at `:6357`. Separately, `CLI/CLI+Browser.swift:439` assembles positional fill/type text while `--snapshot-after` remains in the arguments: `fill '#name' Alice --snapshot-after` types the flag into the field. Use one parsed command contract; test positive CLI invocations through a mock transport rather than raw RPC alone.

### M2 — Alternate clients skip password authentication

Raw telemetry in `Resources/shell-integration/programa-zsh-integration.zsh:12`, `Resources/shell-integration/programa-bash-integration.bash:16`, and `Resources/shell-integration/fish/config.fish:81` sends commands without authenticating. The server correctly requires authentication before dispatch (`Sources/TerminalController.swift:1851`); a password environment variable alone does not authenticate a frame. Some shell state is marked reported before a usable reply. `CLI/programa.swift:3890` similarly creates raw clients for `programa .` without the authentication used by `connectClient` at `:4030`. Route both through authenticated connections; verify telemetry and path shorthand in password mode.

### M3 — MCP times out before its advertised wait deadline

`CLI-MCP/MCPSocketBridge.swift:57` and `:349` impose a 15-second transport timeout, while `CLI-MCP/Tools/SurfaceTools.swift:376` defaults `surface_wait` to 30 seconds. A condition becoming true at 20 seconds fails through MCP despite being within the tool deadline. Derive transport deadlines from the operation timeout plus a response margin, using the CLI transport's existing deadline concept.

### M4 — Malformed selectors broaden destructive operations

`Sources/TerminalController+Notification.swift:141` treats an invalid `workspace_id` as omitted and clears all notifications. `Sources/TerminalController+Surface.swift:234` treats an invalid `surface_id` as omitted and closes the focused panel in an otherwise valid workspace. Introduce one absent/valid/invalid parser; preserve legitimate omitted-selector behavior while rejecting malformed supplied values. Verify no mutation after invalid input.

### M5 — Browser nth/last references do not identify the selected element

`Sources/TerminalController+BrowserAutomation.swift:4676` and `:4729` turn a global query-result index into CSS `:nth-of-type`, which is a sibling/type index. With one `.x` button in each of two sections, index 1 returns the second button's text but a selector matching neither. Reuse structural selectors for the actual element. Existing tests assert a reference prefix without dereferencing it; verify the returned reference by clicking and observing the intended element.

### M6 — Dialog accept/dismiss does not answer the original browser dialog

Native pending dialogs live in `Sources/Panels/BrowserPanelWebDelegates.swift:600`. RPC handling at `Sources/TerminalController+BrowserAutomation.swift:4853` instead installs script overrides and changes synthetic queue defaults. After those overrides are installed, confirm/prompt return immediately (`Sources/Panels/BrowserPanel.swift:157`); a later accept changes a future call, not the completed call. Normal browsing does not install these overrides automatically. Connect RPC to native pending completion handlers or explicitly report unsupported behavior; assert the page's actual confirm/prompt result, not only response flags.

### M7 — Switching browser profiles omits configured proxy policy

`Sources/Panels/BrowserPanel.swift:1255` selects a fresh data store without applying the proxy configuration used at initialization/reattachment. `BrowserProfileStore.swift:132` returns a bare store. With a configured proxy, the first navigation after switching to a fresh profile can route directly or fail for proxy-only hosts. Apply policy at canonical data-store creation/selection and verify the actual destination path.

### M8 — Successful escrow handoff leaks the holder's PTY descriptor

`Sources/SessionEscrow.swift:1665` sends the descriptor using SCM_RIGHTS, then `:1668` calls `markHandedOff`. That method (`:1289`) marks the wrapper closed without closing the sender descriptor, causing deinit to skip it. Sending transfers a duplicate, not ownership of the sender's descriptor; the registry entry is already removed at `:1629`. Keep another session/heartbeat alive and repeated restores accumulate descriptors until the holder exits. Close the sender's descriptor after successful handoff and verify holder descriptor counts and terminal-close behavior.

### M9 — Automatic snapshot fallback can restore another bundle's layout

`Sources/SessionPersistence.swift:485`, `:564`, and `:697` select the newest decodable archive from shared history without filtering the originating bundle. A corrupt production primary after a tagged build's newer archive can silently restore the tagged layout. Shared manual listing/pruning is documented at `docs/plans/snapshot-restore.md:98`; automatic startup selection is a different operation. Filter automatic fallback by current bundle while retaining explicit cross-bundle restore if desired.

### M10 — Missing snapshots also skip live orphan recovery

`Sources/AppDelegate.swift:1734` calls `completeStartupSessionRestore` only when a startup snapshot exists. Its completion at `:1789` is the only path that reconciles escrow orphans. With no readable primary/history snapshot, surviving sessions are never reconciled. Complete normal startup even without a snapshot, preserving the intentional explicit-open exception.

### M11 — History persistence can exceed its own read limit

`Sources/Panels/BrowserHistoryStore.swift:216` bounds entry count but not title/URL size; `:773` writes the result, while `:784` rejects files over 16 MiB. Five thousand pages with 4 KiB titles exceed that cap. Subsequent loading fails, and visits stop being recorded because load failure remains the gate. Enforce a consistent encoded-byte budget with bounded fields/eviction and explicit recoverable errors.

### M12 — Reviews can show stale results or falsely show no changes

`Sources/Panels/ReviewPanel.swift:105` launches overlapping probes and `:136` applies completions without a generation check. A slow branch-A request can overwrite a newer branch-B result and selection. Independently, `Sources/ReviewDiffProber.swift:105` converts command failure into an empty diff; an unborn repository with a staged file makes `git diff HEAD` fail, while untracked enumeration excludes that file, producing a false-clean result. Use request generations and explicit probe errors; handle unborn HEAD with the empty tree. Verify out-of-order completion and staged files before the first commit.

### M13 — Moving a review panel loses its lifecycle subscription

`Sources/Workspace+Bonsplit.swift:759` removes subscriptions on detach; `Sources/Workspace.swift:1732` reinstalls attachment behavior for terminal/browser only. A review moved through generic `AppDelegate.moveSurface` no longer refreshes when its source agent goes idle; workspace identity and the weak source lookup also remain tied to its former workspace. Centralize attachment for every supported panel type and define source identity across transfers.

### M14 — Most workspace creation paths omit the created event

The lifecycle publish exists in the `addTab` wrapper (`Sources/TabManager.swift:1615`), while direct `addWorkspace` callers in `TerminalController+Workspace.swift:118`, `+Layout.swift:78`, `+AgentSupervision.swift:462`, and `+Pane.swift:536` bypass it. Subscribers miss workspaces created by public automation. Publish once at canonical creation, keeping acknowledgment/event ordering explicit.

### M15 — Relative workspace moves use the pre-removal index

`Sources/TabManager.swift:1858` derives an anchor index from the original array and passes it to a final-index move at `:1842`. Moving A before C or after B in `[A,B,C]` yields `[B,C,A]`. Reuse the insertion/final-index conversion already present in `Sources/SidebarDragDrop.swift:537`; verify moves in both directions and pinned boundaries.

### M16 — Inferred agent state remains after detection ends

`Sources/AgentScreenDetectionEngine.swift:299` demotes internal candidates and `:100` clears them when disabled, but neither clears the workspace's inferred agent state/source. After an agent exits and the matching grace expires, its last working/blocked badge can remain indefinitely. Clear only state still owned by inference, preserving newer hook-owned updates.

### M17 — Hook state fails on a fresh home directory

`CLI/CLI+Hooks.swift:157` opens a lock under `~/.programa` before creating the directory at `:188`. On a fresh installation, lock acquisition fails and `try?` drops state updates; session-end cleanup relying on a consumed session can be skipped. Create the parent before locking, as the existing tmux store does. Existing temporary-directory tests start with the parent already present.

### M18 — EOF approves hook installation/removal

`CLI/HookInstallationCoordinator.swift:120` and `CLI/CLI+Hooks.swift:3083`, `:3158`, `:4179`, `:4233` fall through when `readLine()` returns nil. `programa codex install-hooks </dev/null` without `--yes` can rewrite integration/trust settings. Reject EOF; reserve noninteractive approval for the explicit flag. Test actual stdin EOF as well as affirmative/negative input.

### M19 — Build-only reload removes a running tagged app's socket

`scripts/reload.sh:323` unlinks the socket outside the `--launch` guard at `:367`. Rebuilding an already running tag without launching keeps the app alive but makes new socket clients unable to connect. Preserve the socket in build-only mode and unlink only after stopping the matching instance for launch.

### M20 — Display-readiness exhaustion can leave CI green without tests

`.github/workflows/ci.yml:1005` continues the attempt loop on readiness timeout, including the final attempt. Tests only run at `:1092`; the failure exit at `:1105` handles executed tests, not exhausted readiness. The loop can end successfully at `:1111` with no test invocation. Explicitly fail when no attempt reaches execution; verify the runner with a helper that never becomes ready.

### M21 — Update timeout is presented as “latest”

`Sources/Update/UpdateDriver.swift:236` schedules a timeout that sets the no-update state without a server result. A slow/unresponsive update check therefore claims the installed version is current. Use the existing error/timeout state and reconcile late callbacks with the same check generation.

### M22 — Background-window notifications are suppressed

`Sources/TerminalNotificationStore.swift:350` checks that the app has a key main window and that the emitting workspace/panel is selected in its own manager, without requiring that manager's window to be key. With window A foreground and B background, B's selected terminal can emit a notification that is incorrectly suppressed. Compare the owning window, not merely any key app window; verify two main windows.

### M23 — Markdown find counts matches but does not reveal them

`Sources/Panels/MarkdownPanelView.swift:51` connects find actions to model counters, while the renderer receives content/base URL/presentation only at the `MarkdownPanelView.swift:73` callsite. There is no highlight or reveal integration. Cmd-F can report matches and change the current index without moving to or marking a match. Add a renderer-backed search/reveal contract and verify an offscreen match, not only counts.

### M24 — Markdown alert parsing ignores fenced-code context

`Sources/Panels/MarkdownDocumentView.swift:147` recognizes `> [!NOTE]` blocks without tracking code fences. A Markdown example containing that text inside a fenced block is split and rendered as an alert. Use parser-derived block context or fence-aware segmentation and preserve literal fenced examples.

### M25 — Invalid quota dates can trap the usage UI

`Sources/ClaudeQuotaMonitor.swift:47` accepts a numeric reset-time string without finite/range validation. `Sources/SidebarQuotaFooter.swift:289` converts the resulting duration to `Int`. An otherwise valid cache containing `resets_at: "1e309"` reaches an out-of-range conversion when the quota UI renders. Use the finite/bounded parsing already applied to the other provider and verify malformed cache input through parsing and formatting.

### M26 — Multiline recipe prefill submits before the promised Return

`Sources/ProgramaConfigExecutor.swift:38` and its confirmation text promise insertion without submission. `:66` sends the execution-sanitized prompt, which preserves LF/CR (`:431`). `Sources/TerminalSurface.swift:2463` converts those characters into Return key events. A recipe prompt `echo first\necho second` executes the first line immediately; multiline agent prompts similarly submit early. The trust prompt exists, but its described behavior is false. Use a multiline insertion path with explicit submission/unsafe-paste handling, or reject submission characters if insertion without submission cannot be guaranteed. The existing `sendText` path uses paste handling but pre-confirms it; blindly switching to it would not establish the promised safety, especially with bracketed paste disabled.

### M27 — Mermaid source can escape the inline script

`Sources/Panels/MermaidDiagramView.swift:116` escapes JavaScript template delimiters but not HTML script termination, then interpolates the source at `:147`. A Mermaid fence containing `</script><script>…</script>` executes script in the document renderer before Mermaid's strict mode parses anything. The bundled resource is present; default WebKit configuration does not enforce the comment's claimed offline restriction. No native host execution or credential access was demonstrated. Pass source as data without executable-HTML interpolation, escape HTML-significant characters, and enforce the intended resource/navigation policy.

### M28 — Sidebar autoscroll uses the wrong coordinate origin

`Sources/SidebarDragDrop.swift:686` converts the pointer into a scrolled clip view, then compares its Y value against zero-based viewport height at `:704`. Scrolling changes the clip view's bounds origin ([AppKit documentation](https://developer.apple.com/documentation/appkit/nsclipview/scroll%28to%3A%29)). At nonzero offset, a top-edge drag may fail to scroll upward or be classified as bottom-edge. Compare bounds min/max or subtract the origin; verify a substantially scrolled sidebar visually.

### M29 — Debug timing reporters access key codes on non-key events

`Sources/TypingProfiler.swift:213` and `:337` access `NSApp.currentEvent.keyCode` without checking event type, despite the same file's safe formatter at `:105` documenting AppKit's exception for this access. With timing enabled, a slow mouse/AppKit turn can crash the debug session. Reuse the safe event formatter in both reporters. This finding is limited to opt-in profiling.

### M30 — Notification UI-test preparation recursively subscribes

`Sources/AppDelegate+UITestHarnesses.swift:1591` subscribes to `workspace.$panels` inside `attemptFocus`; its synchronous initial emission reenters `attemptFocus` before assignment/readiness checks. `programaUITests/MultiWindowNotificationsUITests.swift:242` enables that harness. Install the subscription once outside the evaluator, or guard the observed workspace as the adjacent helper does. This is a test-harness execution defect, not a normal production startup path.

### M31 — Saved layout identity can crash command-palette construction

`Sources/ProgramaLayoutStore.swift:143` derives the summary identity from the JSON envelope rather than the filename. Copy `foo.json` to `bar.json`: both summaries can produce `palette.applyLayout.foo` contributions (`Sources/ContentView.swift:4208`), which trap in `Dictionary(uniqueKeysWithValues:)` at `:3076`. Renaming only the file instead leaves a palette entry loading the old path. Choose filename identity or reject envelope/filename mismatch and duplicates before publishing summaries; verify copied and renamed files.

## Lower-priority contract and documentation drift

### L1 — Generated Return shortcut does not round-trip

**Low · CONFIRMED.** `Sources/ProgramaSettingsFileStore.swift:1667` returns the raw shortcut key; the Return binding from `KeyboardShortcutSettings.swift:214` becomes a CR token that the parser trims away at `ProgramaSettingsFileStore.swift:935`. Uncommenting the generated default fails to manage that action. Serialize Return/Tab/Space with the named tokens the parser accepts.

### L2 — Rolling release notes use a nonexistent milestone tag

**Low · CONFIRMED.** `Sources/Update/UpdateViewModel.swift:500` constructs `releases/tag/v<displayVersion>`, but rolling builds are not tagged with those display versions. `scripts/sparkle_generate_appcast.sh:40` and `:101` already provide the real release-notes URL. Use the feed's link and verify both rolling and milestone releases.

### L3 — Onboarding and localized UI have source-backed drift

**Low · CONFIRMED.** `CONTRIBUTING.md:6` names Xcode 15 although the pinned Swift TOML requires Swift 6/Xcode 16; its test instructions at `:56` and `docs/v2-api-migration.md:594` reference removed paths such as `tests_v2/programa.py`. The current testing layout is documented elsewhere. Notification-permission labels in `Sources/SettingsView.swift:261` and `Sources/TerminalNotificationStore.swift:85` remain English literals used in the Japanese UI. Consolidate onboarding commands against current scripts and localize the displayed permission labels.

## Design tensions

1. **Recovery guarantees versus privacy boundaries.** Process continuity, frame capture, transcript replay, snapshots, and history have different purposes. Keep those purposes explicit so “do not persist contents” is a reliable policy without discarding process survival.
2. **Target selection versus focus.** Global CLI `--window` calls `window.focus` before read commands (`CLI/CLICommandDispatcher.swift:238`), and `tests/test_cli_registry_behavior.py:520` explicitly expects this. AGENTS requires nonfocus commands to preserve selection. This is a tested contract conflict requiring a product decision, not a test to weaken opportunistically. Carrying window identity through requests is the alternative.
3. **Native browser ownership versus automation emulation.** Copied URLSession requests and synthetic dialogs duplicate browser state and policy. Prefer native lifecycle/data-store ownership, with explicit unsupported automation capabilities where WebKit offers no reliable bridge.
4. **Shared history versus isolated app identities.** Shared manual discovery is documented and useful; automatic fallback and pruning need a clearly stated scope. Keep manual cross-bundle restore explicit instead of treating every archive as equally suitable at startup.
5. **Single large coordinators versus canonical operations.** AppDelegate, CLI main, browser automation, and workspace code centralize knowledge but contain independent creation/validation paths. Extract around stable operations and invariants; file splitting alone would multiply places to understand the same policy.

## Dependency review

The pinned dependencies have distinct demonstrated uses; no removal is recommended merely to reduce the dependency count. Context7 and primary documentation were consulted for the principal Swift dependencies. No bundle footprint, vulnerability scan, or dependency-upgrade build was run.

| Dependency | Pin / role | Review result |
|---|---|---|
| Sparkle | 2.9.6 / updates | Official [2.9.6 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) matches the reviewed pin; app timeout/link handling needs correction, not a speculative upgrade. |
| swift-markdown-ui | 2.4.1 / native Markdown | Official [2.4.1 release](https://github.com/gonzalezreal/swift-markdown-ui/releases/tag/2.4.1) matches; custom segmentation/find bridges are the concrete gaps. |
| MCP Swift SDK | 0.12.1 / MCP server | Official [0.12.1 release](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1) matches; transport deadline duplication is local. |
| swift-toml | 2.0.0 / configuration and trust | [Maintainer documentation](https://github.com/mattt/swift-toml) recommends 2.0.0 and requires Swift 6/Xcode 16. Latest release-tag currency was not independently established. Arbitrary TOML parsing is a justified dependency. |
| create-dmg | 8.0.0 / packaging | [Maintainer project](https://github.com/sindresorhus/create-dmg) inspected; latest version unverified. No upgrade claim. |
| Ghostty / Bonsplit | submodule / vendored native panes | Distinct rendering and layout roles. Preserve native render scheduling and portal lifetime guards. Bonsplit source was additionally read; Ghostty internals were limited to relevant API traces. |
| Bundled Mermaid | vendored minified asset | Integration read; upstream parser internals, current version, and vulnerability status were not audited. M27 is in the host interpolation, independent of Mermaid strict mode. |

## Open questions and unconfirmed candidates

- Should `--window` select a window, or only target it? Resolve the documented/tested focus conflict before changing either side.
- Should applying a layout to a nonempty workspace be rejected, additive, or an explicit replacement? Current placeholder destruction is unsafe under any implicit interpretation.
- What is the intended automatic history isolation policy across production and tagged builds? Manual shared-history intent does not answer this.
- **PLAUSIBLE, not counted:** the sidebar resize monitor (`ContentView+SidebarResizer.swift:111`, `:166`) projects the global pointer into a background window and can consume hover events over an overlapping foreground window. Verify window ownership/occlusion in the UI before grading.
- **PLAUSIBLE, not counted:** portal recovery can repeatedly schedule synchronization for a persistently invalid visible anchor; no sustained reachable state was established. Do not infer an infinite loop from the generic retry helper alone.
- **PLAUSIBLE, not counted:** asynchronous escrow completion can arrive after teardown; verify token ownership, undo grace, and holder cleanup before claiming orphan processes.
- Scripted external-scheme navigation is handed to NSWorkspace without a proven user gesture. Desired browser policy and concrete impact need investigation before grading.

## Considered and rejected

- The prior `2026-09-04` audit and local design documents were checked. This report does not treat already repaired historical findings as new defects.
- The coordinator's false-result handling is sound in isolation; that does **not** disprove H6 because the production closure masks the storage result.
- `gh pr checks --json` does not fail solely because checks fail: the exporter returns before counts-based status handling in the [official CLI implementation](https://raw.githubusercontent.com/cli/cli/trunk/pkg/cmd/pr/checks/checks.go). No false-clean finding was retained for that path.
- A generic SIGPIPE server crash was rejected: the app ignores SIGPIPE and clients configure corresponding socket protection.
- Authentication revocation and per-frame checks exist. H8 is the specific nil-peer-PID exception, not a general absence of authorization.
- Browser snapshots have isolated collection, bounds, and generation-bound references; browser-state restore includes origin, lease, and identity validation. These safeguards should be retained.
- Release publication includes final monotonic checks, sealed payload verification, and ordered promotion. A proposed milestone downgrade finding was rejected. Archive retention behavior is intentional in existing tests.
- CLIProcessRunner's descendant-pipe timeout concern had no production caller using that timeout, so it was not promoted as a reachable defect.
- Recipe/command contribution IDs are prefixed, encoded, and deduplicated; the general palette collision suspicion was rejected. M31 is the separate saved-layout envelope identity path.
- The portal focus-classification helper's only caller uses the same yielding predicate; no incorrect persisted focus state was established.
- Recovery machinery and RPC catalogs have live dynamic entry points. Low lexical caller counts are not evidence that they are dead.

## Coverage and verification limits

Full reads were reconciled against filesystem inventories and per-reader path ledgers, rather than inferred from search hits. Counts include comments and blank lines and describe the current files, not executed coverage.

| Surface read in full | Files | Lines |
|---|---:|---:|
| Application `Sources/` | 204 | 141,530 |
| CLI | 15 | 18,926 |
| CLI-MCP | 20 | 3,503 |
| Scripts, script tests, packaging manifest/lock | 54 | 9,362 |
| GitHub workflows/templates | 11 | 3,414 |
| Native unit-test sources | 46 | 54,803 |
| Native UI-test sources | 17 | 9,886 |
| Shell/CLI/release tests in `tests/` | 18 | 4,893 |
| Socket/E2E tests and helper in `tests_v2/` | 116 | 24,676 |
| Bundled command wrappers | 2 | 704 |
| Shell integration, including hidden startup files | 8 | 2,923 |
| Additional vendored Bonsplit source | 34 | 7,668 |
| Additional Bonsplit tests | 3 | 1,340 |

Also read the agent-detection manifests, C escrow bridge, relevant root metadata, Swift package lock, app plist/entitlements/schemes, prior audit, README, CONTRIBUTING, and relevant API/settings/recovery/testing documents. Xcode project membership/build/dependency sections were inspected selectively; the entire project metadata file and historical documentation corpus were not read. Excluded upstream Ghostty internals except specific bridge/API traces, generated/minified dependencies, dependency caches, binary assets, theme data, and the full localization catalog. Bonsplit was read beyond the normal vendored-code exclusion because Programa modifies its pane behavior in-tree.

### Test review: what existing tests do and do not prove

These are supplementary coverage/maintenance observations, separate from the 42 prioritized findings. They do not report a test run or authorize weakening an assertion.

| Existing test surface | Static observation | Required interpretation |
|---|---|---|
| Release publication shell/JS tests | Exercise exact bytes, interruptions, attestations, monotonic gates, and retry convergence through disposable fixtures. | Meaningful contracts worth preserving; no live publication was tested here. |
| Browser native tests | Include real DOM snapshot and profile/portal lifecycle checks. | Do not generalize isolated string-based tests into “browser behavior is untested.” Proxy switching and dialog result gaps remain specific. |
| `tests_v2/test_browser_api_extended_families.py:688` and `:742` | nth/last check reference shape; dialog tests check reply flags. Some wait tests fall back to eval after timeout. | These assertions do not prove returned references or native dialog/wait outcomes. |
| `programaUITests/BrowserOmnibarSuggestionsUITests.swift:168` | Escape can replace a failed click-outside interaction before the final assertion. | A passing result can conceal broken click-outside behavior. |
| `programaUITests/AutomationSocketUITests.swift` | Socket discovery can select an unrelated `/tmp/cmux*.sock`; the named toggle case checks launch availability without toggling. | Bind to the tested app's identity and exercise the named state transition. |
| `programaUITests/MultiWindowNotificationsUITests.swift:739` | Bundled-only CLI resolution looks for retired `bin/cmux`; the current bundle contains `bin/programa`. | The CLI notification test can stop before reaching its intended behavior, independently of M30. |
| `programaUITests/CloseWorkspaceCmdDUITests.swift:28` versus `programaTests/TabManagerUnitTests.swift:949` | UI test expects last-tab close to preserve the workspace; newer unit contract closes it. | Resolve the intentional contract change and then update the superseded assertion, not simply whichever one fails. |
| `tests_v2/test_layout_save_apply_roundtrip.py:55` | Captures the baseline before selecting a new source workspace, then expects apply to preserve the earlier baseline. | A correctly nonfocus apply can fail this assertion; capture the state immediately before the operation. |
| `tests_v2/test_pane_resize_preserves_ls_scrollback.py:83` and `test_pane_resize_preserves_visible_content.py:76` | The first uses undefined `_must`; the second uses `time.sleep` without importing `time`. | Both can stop with NameError before resize assertions. |
| `tests_v2/test_new_tab_interactive_after_splits.py:124` and `test_new_tab_render_after_splits.py:148` | Direct-send fallbacks replace failed simulated typing; a failed side-effect check can be only a warning, and rendering can be accepted while inactive. | These paths cannot certify the full typing/rendering interaction stated by the tests. |
| Visual/CPU scripts | Legacy CPU scripts search old cmux process names and can exit successfully without measuring Programa; visual checks tolerate screenshot failures; the tab-dragging runner does not perform a drag. | Treat them as instruments with explicit limitations, not comprehensive regression gates. New measurement-only scripts without budgets are not defects merely for lacking pass/fail limits. |
| `tests/test_homebrew_sha.sh:10` | Skips successfully when the old `homebrew-cmux` path is absent. | This is not evidence that the current Programa cask matches the release. |

Existing native CI skips include focus-repair cases in `AppDelegateShortcutRoutingTests.swift:5830`, `:5920`, `:6030`; reparent-focus coverage in `WorkspaceUnitTests.swift:3153`; terminal first-responder cases in `TerminalAndGhosttyTests.swift:1138`, `:1228`, `:3434`; and the workspace stress profile. Some additional tests require a live surface or explicit UI environment. No executed skip/pass/fail count is available because no tests ran. The current prohibition on local testing means comments saying a skipped case is “covered locally” are not a substitute for an active VM/CI lane.


Source reads and caller traces establish mechanisms; they do not certify end-to-end behavior. No local tests ran, honoring project policy. No CI/VM runs were dispatched, no UI was exercised, and no assertions were changed, relaxed, or skipped by this audit. Existing conditional test skips are described with the test-review results. No build, performance profile, automated dead-code scan, secret scan, or package vulnerability scan was run; none is claimed to have passed. Team-knowledge remote reconciliation was unavailable, so intent was reconciled against the local prior audit and project documentation only.

When findings are implemented, update the affected CLI/API/settings/onboarding documentation in the same change and follow the repository's regression-test/CI policy. This audit leaves all implementation and publication untouched.

## Files over 1,000 lines

Every inventoried file crossing the threshold is listed below. Production coordinators should be split at the canonical operations identified above; test files should be organized by observable behavior without deleting coverage. Generated/minified assets and project membership metadata are size waivers, not independent behavior defects. The inventory excludes the Ghostty submodule, dependency caches, binaries, and historical documentation/assets; it includes the additionally inspected Bonsplit tree.

73 files cross the threshold.

| File | Lines | Disposition |
|---|---:|---|
| `Sources/AppDelegate.swift` | 10,778 | Split by coherent behavior; retain runtime contracts |
| `CLI/programa.swift` | 7,286 | Split by coherent behavior; retain runtime contracts |
| `programaTests/AppDelegateShortcutRoutingTests.swift` | 6,528 | Organize tests by behavior; preserve assertions |
| `Sources/TerminalController+BrowserAutomation.swift` | 6,153 | Split by coherent behavior; retain runtime contracts |
| `programaTests/TerminalAndGhosttyTests.swift` | 5,775 | Organize tests by behavior; preserve assertions |
| `Sources/ContentView.swift` | 5,651 | Split by coherent behavior; retain runtime contracts |
| `programaTests/WorkspaceUnitTests.swift` | 5,132 | Organize tests by behavior; preserve assertions |
| `programaTests/BrowserConfigTests.swift` | 4,532 | Organize tests by behavior; preserve assertions |
| `CLI/CLI+Hooks.swift` | 4,249 | Split by coherent behavior; retain runtime contracts |
| `programaTests/BrowserPanelTests.swift` | 4,045 | Organize tests by behavior; preserve assertions |
| `programaTests/GhosttyConfigTests.swift` | 3,973 | Organize tests by behavior; preserve assertions |
| `Sources/TabManager.swift` | 3,560 | Split by coherent behavior; retain runtime contracts |
| `programaTests/TerminalControllerSocketSecurityTests.swift` | 3,474 | Organize tests by behavior; preserve assertions |
| `Sources/TerminalController.swift` | 2,996 | Split by coherent behavior; retain runtime contracts |
| `Sources/TerminalSurface.swift` | 2,858 | Split by coherent behavior; retain runtime contracts |
| `Sources/GhosttySurfaceScrollView.swift` | 2,740 | Split by coherent behavior; retain runtime contracts |
| `programaTests/SessionPersistenceTests.swift` | 2,713 | Organize tests by behavior; preserve assertions |
| `Sources/Panels/BrowserPanel.swift` | 2,656 | Split by coherent behavior; retain runtime contracts |
| `Sources/GhosttyApp.swift` | 2,378 | Split by coherent behavior; retain runtime contracts |
| `GhosttyTabs.xcodeproj/project.pbxproj` | 2,263 | Waived: project metadata or minified vendor asset |
| `Sources/Panels/WebViewRepresentable.swift` | 2,251 | Split by coherent behavior; retain runtime contracts |
| `programaTests/TabManagerUnitTests.swift` | 2,238 | Organize tests by behavior; preserve assertions |
| `Sources/Workspace.swift` | 2,191 | Split by coherent behavior; retain runtime contracts |
| `CLI/CLI+TmuxCompat.swift` | 2,179 | Split by coherent behavior; retain runtime contracts |
| `Sources/Panels/ProgramaWebView.swift` | 2,162 | Split by coherent behavior; retain runtime contracts |
| `Sources/TabItemView.swift` | 2,149 | Split by coherent behavior; retain runtime contracts |
| `Sources/SettingsView.swift` | 2,070 | Split by coherent behavior; retain runtime contracts |
| `Sources/SessionEscrow.swift` | 2,063 | Split by coherent behavior; retain runtime contracts |
| `Sources/BrowserWindowPortal.swift` | 2,061 | Split by coherent behavior; retain runtime contracts |
| `Sources/ProgramaApp.swift` | 2,037 | Split by coherent behavior; retain runtime contracts |
| `Resources/mermaid.min.js` | 2,029 | Waived: project metadata or minified vendor asset |
| `Sources/ProgramaSettingsFileStore.swift` | 1,931 | Split by coherent behavior; retain runtime contracts |
| `Sources/TerminalController+Debug.swift` | 1,925 | Split by coherent behavior; retain runtime contracts |
| `Sources/SidebarVisuals.swift` | 1,866 | Split by coherent behavior; retain runtime contracts |
| `programaTests/WindowAndDragTests.swift` | 1,863 | Organize tests by behavior; preserve assertions |
| `Sources/AppDelegate+UITestHarnesses.swift` | 1,822 | Split by coherent behavior; retain runtime contracts |
| `Sources/DebugWindows.swift` | 1,691 | Split by coherent behavior; retain runtime contracts |
| `programaTests/CJKIMEInputTests.swift` | 1,658 | Organize tests by behavior; preserve assertions |
| `Sources/Update/UpdateTitlebarAccessory.swift` | 1,639 | Split by coherent behavior; retain runtime contracts |
| `Sources/Panels/BrowserPanelView.swift` | 1,589 | Split by coherent behavior; retain runtime contracts |
| `programaUITests/BrowserPaneNavigationKeybindUITests.swift` | 1,512 | Organize tests by behavior; preserve assertions |
| `Sources/SessionWALStore.swift` | 1,479 | Split by coherent behavior; retain runtime contracts |
| `tests_v2/test_visual_screenshots.py` | 1,471 | Organize tests by behavior; preserve assertions |
| `Sources/SessionPersistence.swift` | 1,455 | Split by coherent behavior; retain runtime contracts |
| `CLI/CLI+Browser.swift` | 1,400 | Split by coherent behavior; retain runtime contracts |
| `tests/test_rolling_release_publication.sh` | 1,377 | Organize tests by behavior; preserve assertions |
| `Sources/TabManager+UITestHarness.swift` | 1,366 | Split by coherent behavior; retain runtime contracts |
| `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabBarView.swift` | 1,350 | Split by coherent behavior; retain runtime contracts |
| `programaTests/ProgramaConfigTests.swift` | 1,342 | Organize tests by behavior; preserve assertions |
| `programaTests/ShortcutAndCommandPaletteTests.swift` | 1,290 | Organize tests by behavior; preserve assertions |
| `tests_v2/test_tab_dragging.py` | 1,278 | Organize tests by behavior; preserve assertions |
| `Resources/shell-integration/programa-zsh-integration.zsh` | 1,261 | Split by coherent behavior; retain runtime contracts |
| `Sources/GhosttyTerminalView+Keyboard.swift` | 1,233 | Split by coherent behavior; retain runtime contracts |
| `programaUITests/MenuKeyEquivalentRoutingUITests.swift` | 1,225 | Organize tests by behavior; preserve assertions |
| `programaUITests/MultiWindowNotificationsUITests.swift` | 1,196 | Organize tests by behavior; preserve assertions |
| `Sources/TerminalController+Telemetry.swift` | 1,190 | Split by coherent behavior; retain runtime contracts |
| `Sources/TerminalController+Surface.swift` | 1,165 | Split by coherent behavior; retain runtime contracts |
| `.github/workflows/ci.yml` | 1,132 | Split by coherent behavior; retain runtime contracts |
| `CLI-MCP/Tools/BrowserTools.swift` | 1,118 | Split by coherent behavior; retain runtime contracts |
| `Resources/shell-integration/programa-bash-integration.bash` | 1,115 | Split by coherent behavior; retain runtime contracts |
| `programaTests/NotificationAndMenuBarTests.swift` | 1,110 | Organize tests by behavior; preserve assertions |
| `Sources/Workspace+Bonsplit.swift` | 1,095 | Split by coherent behavior; retain runtime contracts |
| `programaTests/ClaudeQuotaSnapshotParserTests.swift` | 1,081 | Organize tests by behavior; preserve assertions |
| `Sources/BrowserWindowHostView.swift` | 1,067 | Split by coherent behavior; retain runtime contracts |
| `tests_v2/cmux.py` | 1,059 | Organize tests by behavior; preserve assertions |
| `vendor/bonsplit/Tests/BonsplitTests/BonsplitTests.swift` | 1,053 | Split by coherent behavior; retain runtime contracts |
| `programaUITests/SidebarHelpMenuUITests.swift` | 1,051 | Organize tests by behavior; preserve assertions |
| `Sources/WindowPaneChromePortal.swift` | 1,050 | Split by coherent behavior; retain runtime contracts |
| `Sources/Panels/Omnibar.swift` | 1,049 | Split by coherent behavior; retain runtime contracts |
| `Sources/TerminalWindowPortal.swift` | 1,048 | Split by coherent behavior; retain runtime contracts |
| `programaTests/SidebarOrderingTests.swift` | 1,030 | Organize tests by behavior; preserve assertions |
| `Sources/ClaudeQuotaMonitor.swift` | 1,017 | Split by coherent behavior; retain runtime contracts |
| `Sources/CommandPaletteSearchEngine.swift` | 1,015 | Split by coherent behavior; retain runtime contracts |

