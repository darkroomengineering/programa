# Rust core spike: decide with numbers, not a rewrite

Status: spike complete, decision recorded (2026-09-15)

## Question

Two questions came up together and have different answers:

1. Programa feels slower than it should. Where does the time go, and how much of it is the Swift/SwiftUI shell versus the Ghostty core?
2. A Windows version is wanted. Ghostty (libghostty) has no Windows support and no roadmap, so any Windows build needs a different terminal core regardless of UI toolkit.

The candidate for both is a Rust core on gpui-kit (Longbridge's framework on Zed's GPUI, Apache-2.0, macOS/Windows/Linux, no terminal widget) plus alacritty_terminal (the VT engine Zed's terminal uses).

## Decision rule

The Rust core becomes the long-term base only if the spike beats the current app on the same Mac on all of:

See "Spike results" for the filled table.

If the spike loses on latency or memory, Windows waits and the macOS app keeps its narrow perf fixes. If it wins, GPUI is the Windows and Linux client toolkit. Either way the macOS app is not rewritten; see "Reframe" below for why the client toolkit is now the smaller question.

## Workstreams (parallel)

1. Perf attribution and easy fixes on the Swift app. Branch and results: see "Perf findings".
2. Spike at `~/Developer/@darkroom/programa-spike`: tabs, splits, PTY, measurements.
3. Concept inventory: what a replacement core has to reproduce, see "Concepts a new core must carry".

## Perf findings

Measured 2026-09-15 on a tagged Debug build (`perf-attrib`) with `sample`, `ps -M`, and the CPU occlusion harness. Debug numbers overstate production.

| Scenario | Result | Attribution |
|---|---|---|
| Idle, 3 panes | app 0.95 % CPU, total 2.15 % | over 99.9 % of samples in kernel wait; 12 of about 275k samples in SwiftUI AttributeGraph; no Programa or Ghostty frames above noise |
| 4 hidden busy panes, 20 s | app 6.9 % CPU, total 20.5 % | consistent with the occluded-render throttle; remaining Swift cost is ANSI parsing and string splitting, no single hotspot |
| Churn, 20 cycles new workspace / split / split / close | dominated by `posix_spawn`, `stat`, `open`, `rename` | per-workspace git metadata and port-scan probes, spread across `GitMetadataProber`, `PortScanner`, `TerminalThemeStore`, `GhosttyConfig`; no single Programa function above noise |
| Keystroke path, 312 real key events via System Events | `app.sendEvent` elapsed p50 0.45 ms, p95 1.11 ms; prelude 0.10, shortcut check 0.26, dispatch 0.71 ms average | no main-thread turn crossed the 3 ms logging threshold; sample during the burst was over 99.9 % kernel wait. The 24 to 60 ms event-to-log delay is System Events queueing a burst far faster than a human, not app cost. Note: socket `send-key` bypasses NSEvent (`Sources/TerminalSurface.swift:2505`), so the CLI cannot measure this path |

Conclusions so far:

- The shell is not burning CPU at idle or with hidden output. The "slow" feeling, if it is real, has to be on the keystroke path or in churn, both of which are latency, not throughput.
- The one recurring main-thread cost at idle is session autosave (every ~8 s, 1 to 5 ms), already debounced and fingerprint-skipped.
- Git and port probes on workspace creation are already scheduled off-main with a generation token and cancelled on close (`Sources/TabManager.swift:1378-1439`, `Sources/PortScanner.swift:111-176`). The churn cost is one `git branch` and `git status` per new workspace, by design.
- A `new-workspace` CLI call timed out once right after a relaunch and did not reproduce in five tries. Cold-start artifact.

No fixes were applied in either pass because no hotspot existed. Conclusion: the shell is not the source of a perf problem on any measured path. If the app still feels slow, the next measurements are frame pacing during resize and split drags (the resize stale-frame mitigation lives in the Ghostty fork) and first-window startup time, neither of which was in scope here.

## Spike results

Repo: `~/Developer/@darkroom/programa-spike` (5 commits, `cargo build --release` clean). Pinned: `gpui-kit 0.6.1` (which pulls `gpui-pre 0.3.5`, Longbridge's private republish of a Zed gpui snapshot; the `gpui` crate on crates.io is unrelated), `alacritty_terminal 0.26.0`.

Works: PTY-backed shells, canvas grid render with 256 and truecolor, cursor, keyboard including Ctrl and Alt-as-Meta, wheel scrollback, tabs with Cmd+T/W/1-9, recursively nested splits with Cmd+D and Cmd+Shift+D, click focus, reflow on resize. Screenshot in the spike repo at `docs/screenshot.png`. Cut: drag-resize of splits, dock panels, terminfo, IME, native menu, accessibility, any socket API.

| Metric | Programa (tagged Debug, today) | Spike (release) | Caveat |
|---|---|---|---|
| Keystroke cost | `sendEvent` elapsed p95 1.11 ms, real NSEvents | PTY write to wakeup p95 0.27 ms | not the same path: the spike number excludes OS key delivery and the compositor frame; both say the layer measured is not the bottleneck |
| Memory, 4 tabs idle | not measured today; production known to hold 3 IOSurface frames (about 23 MB each at 2x) per realized renderer | 63 MB footprint, 82 MB RSS; 84 MB with 8 PTYs | |
| CPU, 4 hidden busy panes, 20 s | app 6.9 % (Debug) | 1.25 % | the spike never repaints an inactive tab, Programa throttles to about 4 Hz; not apples to apples |
| Idle CPU, 20 s | 0.95 % | 0.85 % | equal within noise |
| Startup to first frame | not measured | 171 to 206 ms warm, 437 ms cold | |
| Binary | | 8.2 MB stripped | |
| Windows | n/a | dependency graph resolves for `x86_64-pc-windows-msvc` (505 crates); cross-compile from macOS stops at gpui's build script needing `llvm-rc`; a native Windows runner with MSVC should pass but this is inferred, not verified | alacritty_terminal ships ConPTY |

Rough edges recorded by the spike: published crates strip examples, so real signatures had to be read from the cargo registry source; documentation summaries were wrong often enough to not compile from. One real bug: the PTY event channel is multi-consumer, so a second consumer starves the first. Rule for the real build: one task per PTY event channel.

Effort estimate from the spike author, labelled est.: tab and split polish 1 to 2 weeks, a socket and CLI API 3 to 4 weeks, terminal-protocol tail (terminfo, IME, ligatures, images, accessibility) 2 to 3 months. The rendering core is not the long pole; the control API and protocol completeness are.

## Decision

- **No rewrite of the macOS app.** Every measured path in the Swift shell is clean; there is no perf case for it, and the concept inventory shows what a rewrite would have to reproduce.
- **GPUI is viable as the Windows and Linux client toolkit.** Rendering, memory, and startup are fine, the dependency graph resolves for Windows, and the cut features are all tractable. The unverified item is a real Windows CI build; the first action on that track is a `windows-latest` GitHub Actions job on the spike repo.
- **The VT engine for non-macOS clients should be `libghostty-vt`, not alacritty_terminal**, so every client shares the fork's parser. Swap it in the spike before building further.
- **The core-plus-clients shape is the plan.** Steps 1 and 2 (contract schema, one seam in the app) start now and are worth doing regardless. Step 3 (Rust core) is sized after those land. Org mode waits for a product decision.

## Concepts a new core must carry

Full inventory with every command, tool, key, and file path: `rust-core-concepts.md`. The parts that decide effort:

- **Object model**: window > workspace > pane (bonsplit split tree) > surface (terminal or browser). Public handles are ordinal refs (`workspace:1`, `surface:1`); internally everything is UUIDs and the names are inconsistent (`TabManager.tabs` holds workspaces, bonsplit's `Tab` is a split leaf, the API's `surface` is the internal `panel`). A new core should fix the naming once.
- **Sessions are two mechanisms, deliberately separate**: a layout plus scrollback-text snapshot that replays into new processes, and process-survival escrow that hands PTY fds to a detached holder over `SCM_RIGHTS` and revives them through the VT parser. The escrow half depends on fork-only Ghostty APIs (fork item 10) and has no Windows equivalent as designed; ConPTY has no fd to hand off.
- **Socket API v2, CLI, MCP**: about 36 socket commands across window/workspace/pane/surface/browser/notification areas, the dev CLI mirrors them, and the MCP server exposes a subset as tools. This is the contract agents and tests depend on; it is toolkit independent and should be the first thing a new core implements, so `tests_v2/` can run against it unchanged.
- **Agent integration**: agent detection manifests, OSC 99 notifications, attention/status/progress metadata, provider usage display, diff review panel. All shell-side, all portable.
- **Browser panel**: WebKit only. No GPUI equivalent today.
- **Configuration**: `~/.config/programa/settings.json`, `programa.json`, shortcut registry, terminal themes, English and Japanese localization. Portable as data.
- **Ghostty fork delta, 10 patches**: three are load-bearing for perf (resize stale-frame mitigation, occluded-render throttle at 250 ms, offscreen renderer realization that releases the swap chain while keeping PTY and scrollback), one for detached sessions (revival API plus the pre-parse PTY tee callback that feeds the session WAL), and the rest are OSC/DECRPM/selection C-API details. Each needs an alacritty_terminal counterpart; alacritty_terminal has no renderer, so the swap-chain items become the spike's own rendering code.
- **Release**: auto-ship on green CI to a rolling GitHub release, Sparkle in-app updates, always-on diagnostics log. A Windows build needs its own signing, notarization equivalent, and updater.

## Reframe: a core that runs anywhere, and clients that only draw

Added 2026-09-15 after the question "should every Programa terminal be a dumb terminal running elsewhere, with an org mode and a personal mode?"

### What this is not

It is not the SSH remote workspaces feature removed on 2026-09-02 (`docs/removed/ssh-remote-workspaces.md`). That design bolted a remote branch onto a local app: 17,000 lines of Swift plus an 8,600-line Go daemon, four hand-written socket clients that drifted apart, and remote conditionals threaded through workspaces, persistence, sidebar, browser, and drag-and-drop. The removal note's own conclusion is the design rule here: make the RPC contract the product boundary, generate every client from it, and keep remote behind one seam instead of branching the model.

### The shape

Two processes, one contract.

- **Core** (`programad`, one per user, local or hosted): owns PTYs and child processes, the session WAL and snapshots, escrow and revival, agent detection and attention state, git and port probes, settings, and the socket API v2 plus the MCP server. It has no UI. It runs on the developer's Mac, on a Linux box they own, or on org infrastructure.
- **Client** (the macOS app today, a GPUI app for Windows and Linux later, a web or phone client if wanted): draws terminals, tabs, splits, sidebar, and the browser panel, and routes input. It holds no session state that the core does not also hold, so any client can attach to any core and get the same workspaces.

The terminal stays "dumb" in the ssh sense: the client keeps the VT state (Ghostty on macOS), the core keeps the PTY. Bytes flow raw in both directions. Reattach replays the WAL tail through the client's own parser, which is what detached sessions already do.

### Two attach modes, one client

| | Personal | Organization |
|---|---|---|
| Where the core runs | localhost, spawned by the app; or a machine you own over SSH | org-hosted, one core per user or per workspace |
| Identity | none needed | org login (OIDC), device pairing |
| Transport | Unix socket; PTY fds handed to the client over `SCM_RIGHTS`, so the local keystroke path has no extra hop | mTLS or WebSocket, bytes over the network |
| "Brain" | the user's own settings, skills, MCP servers, provider accounts | shared skills and memory, org MCP servers, managed provider credentials, permission policies, audit |
| Windows and Linux clients | need a local core built for that OS (ConPTY, no fd handoff) | work immediately, the PTYs live on Linux |

The org column is a product and business decision (hosting cost, who pays, what "org brain" contains). The personal column is pure engineering and is the same code path with a different transport.

### Why this answers both original questions

- **Performance.** Everything the churn sample blamed (git probes, port scans, spawn, autosave) leaves the UI process. The UI process becomes render plus input. Local latency is unchanged because the client still holds a PTY fd directly, exactly as escrow revival works today.
- **Windows.** The first Windows product is a client only. It does not need ConPTY, escrow, or a Windows session story; it needs a terminal renderer and the generated RPC client. That is what the GPUI spike measures. A local Windows core can come later.
- **The rewrite question dissolves.** Nothing is thrown away. The macOS app keeps shipping and becomes the first client. The core is new code, in Rust, sized by the socket API v2 surface that already exists and is already covered by `tests_v2/`.

### What already exists toward this

- Socket API v2 with ordinal handles, a command catalog (`Sources/V2CommandCatalog.swift`), and a Python test suite that only speaks the socket. This is the contract; it needs to become a schema that generates clients.
- The escrow holder (`Sources/SessionEscrow.swift`, `Sources/SessionWALStore.swift`) already is a second process that holds PTY fds and a WAL across app death. It is the seed of the core.
- The Ghostty fork already revives a surface from an existing fd and child pid (fork item 10). That is the local attach path.
- The MCP server and CLI already talk to the app only through the socket.

### Sequence

1. **Contract first.** Turn the v2 command catalog into a machine-readable schema (JSON Schema or similar) and generate the Swift CLI, the MCP bridge, and the Python test client from it. Any drift becomes a build error. Small, independent of everything else, pays off even if nothing below happens.
2. **One seam in the app.** Route every core-owned concern in the Swift app through one interface, so the app can talk to an in-process core or an out-of-process one without `if isRemote` branches. This is the refactor the removal note asked for.
3. **Core in Rust, local first.** Grow the escrow holder into `programad`: PTY ownership, WAL, snapshots, agent detection, probes, socket API v2. The macOS app attaches over the Unix socket and receives PTY fds. `tests_v2/` runs unchanged against the new core. Ship this as the default local mode with no user-visible change.
4. **Remote transport.** Same core on a Linux box you own, mTLS, reattach from any client. This is the removed SSH feature rebuilt as one seam.
5. **Windows and Linux client** on GPUI, against a remote or local core. The spike in this document decides the toolkit.
6. **Org mode.** Login, hosted cores, shared brain. Product decision; the engineering above makes it possible without another rewrite.

Steps 1 and 2 are weeks and are worth doing regardless. Step 3 is the real investment, on the order of months, and is the thing to size after the spike numbers land.

### Watch list

- **t3code** (`github.com/pingdotgg/t3code`, MIT). Full inventory with file citations: `t3code-inventory.md`. What matters for us:
  - Same shape as the reframe above, shipping today: a Node server owns providers, PTYs, git, files, and an event log; Electron, web, iOS, and Android are thin RPC clients sharing one client runtime. The desktop app has a `localEnvironmentEnabled` toggle, so pure thin-client mode against a remote server already exists.
  - Contract-first: every RPC method is declared once in `packages/contracts/src/rpc.ts` (Effect RPC over WebSocket) with a required auth scope. This is step 1 of our sequence, done.
  - Remote pairing without a proxy: "T3 Connect" uses a Clerk-backed relay only to broker a one-time bootstrap credential; app traffic then goes direct to the environment over DPoP-bound tokens. The relay never sees session tokens. This is the personal-mode-over-internet design to copy. No organization concept exists anywhere in the repo.
  - Agent output is structured events, not PTY scraping: `session.*`, `thread.*`, `turn.*`, `item.*`, `content.delta`, `request.opened/resolved`, `user-input.requested/resolved`. Providers: Claude via the official Agent SDK in-process, Codex via its app-server protocol, Cursor via ACP, OpenCode via its SDK. Permission modes are just event handling on the same stream.
  - Shell panels use node-pty on the server (ConPTY on Windows) and render client-side with `libghostty-vt`, Ghostty's VT parser as a C ABI, compiled to WASM for web and native for Android.
  - Features worth porting, ranked by the inventory: structured provider events instead of terminal scraping for agent turns; capability-flag negotiation between client and server instead of version lock; the DPoP relay bootstrap for pairing; hidden-git-ref checkpoints per turn; running native telemetry as an isolated child. Avoid: their five-way Linux screenshot backends, a five-provider PR API matrix, and the dual-backend WSL design on Windows.

## Known losses with a GPUI core

- GPUI draws everything itself: no native macOS menus, sheets, glass, or accessibility tree for free.
- No webview: the browser panel does not carry over.
- The Ghostty fork delta splits in two. Parser-side patches (OSC 99 notifications, DECRPM 2031, selection API) carry over if the client uses `libghostty-vt`, which our fork already builds with explicit Windows and WASM targets (`ghostty/build.zig:131-165`, `ghostty/src/lib_vt.zig`). Renderer-side patches (occluded-render throttle, offscreen realization, resize stale-frame mitigation) have to be reimplemented in whatever draws the grid on Windows and Linux, because libghostty's Metal renderer does not exist there.
- The running spike uses alacritty_terminal as its VT engine. A follow-up should swap in `libghostty-vt` over FFI so every client shares one parser; the spike's GPUI rendering and memory numbers stay valid either way.
- gpui tracks Zed's internal API; gpui-kit pins a matching crate set to absorb breakage, so upgrades happen on gpui-kit's cadence.
