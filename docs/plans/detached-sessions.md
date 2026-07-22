# Detached Sessions / Process Survival

Status: DRAFT (planning only, no code changes made). Modeled on herdr.dev's detached-session
UX. Companion doc to `docs/remote-daemon-spec.md` (SSH remote path) — this plan is the **local**
counterpart and explicitly reuses/extends that spec's `session.*` naming and resize semantics
rather than inventing a parallel scheme.

## 1. Problem Statement

Today, quitting or crashing Programa kills every terminal child process. `README.md` says it
plainly: relaunch "restores layout, directories, scrollback, and browser state — not live
processes (yet)" (`README.md:51`). Session persistence
(`Sources/SessionPersistence.swift`, `Sources/TabManager+SessionPersistence.swift`,
`Sources/Workspace+Layout.swift`) captures layout/cwd/scrollback-as-text and replays it into
**brand-new** shell processes on next launch (`SessionScrollbackReplayStore`,
`Sources/SessionPersistence.swift:460-518` — literally re-prints saved scrollback text as a
one-shot env-var replay file, not a live reconnect).

With agent features (`surface.wait`, `agent.prompt`, `agent_state` subscriptions —
`docs/v2-api-migration.md:161-446`) making long-running unattended agent processes the primary
use case, losing the process on every restart/crash is the single biggest gap between Programa
and its target workflow.

## 2. Constraints From the Actual Codebase (cited)

### 2.1 PTY/process ownership today: in-process, forked by the GUI

- `Sources/TerminalSurface.swift:1041-1051` — `createSurface()` calls
  `ghostty_surface_new(app, &surfaceConfig)` with
  `surfaceConfig.platform = .macos(nsview: <the AppKit NSView pointer>)`
  (`Sources/TerminalSurface.swift:868-871`). The C surface is created **synchronously on the
  main actor**, wired directly to a specific `NSView*`. There is no indirection layer between
  "a Ghostty surface" and "a specific window's view" in the current API.
- `ghostty/src/pty.zig:128` — `c.openpty(...)` allocates the actual PTY pair.
- `ghostty/src/Command.zig:189` — `posix.fork()` forks the child that execs the shell/command,
  a **direct child of the Programa app process** (GhosttyKit is linked in-process via the
  xcframework, not a separate process). Comment at `ghostty/src/Command.zig:14` even notes
  `posix_spawn` was considered for macOS and rejected for lacking needed control — reinforcing
  that Ghostty's process model assumes it fully owns spawn semantics itself.
- `Sources/AppDelegate.swift:1446-1498` — `applicationShouldTerminate`/`applicationWillTerminate`
  save a session **snapshot** (layout/cwd/scrollback text) but do nothing to detach or reparent
  child processes. When `NSApp.terminate` proceeds, the process tree dies with the app (no
  double-fork/setsid anywhere in this path).
- Net effect: **the PTY and its child process today have the same lifetime as the GUI process
  and are physically owned by it.** Any "survive app quit" design requires moving PTY ownership
  out of the GUI process, full stop — there is no flag or config that makes today's
  `ghostty_surface_new` path outlive the app.

### 2.2 What already exists that's directly reusable: `programad-remote`'s session RPC

`daemon/remote/cmd/programad-remote/` (Go, **not Zig** — despite this repo not having a
`programad/` directory at top level; the actual daemon lives here, see
`daemon/remote/README.md:1-3`) already implements, for the **SSH remote** path:

- `session.open/close/attach/resize/detach/status` RPC
  (`daemon/remote/cmd/programad-remote/main_sessions.go:1-357`) — but this is **pure
  attachment-bookkeeping metadata, not a PTY broker**. `handleSessionOpen`
  (`main_sessions.go:12-36`) creates a `sessionState{attachments: map[...]{}}` with **no PTY, no
  child process, no I/O plumbing at all** — it exists solely to implement the "smallest screen
  wins" resize-coordinator described in `docs/remote-daemon-spec.md:96-121`, tracking cols/rows
  per attachment and computing the effective min (`recomputeSessionSize`,
  `main_sessions.go:307-329`). This is a real, tested building block for **resize semantics**,
  but zero of the actual "keep a process alive and stream its output" problem is solved by it
  today. Do not assume `session.open` already spawns anything.
- `daemon/remote/cmd/programad-remote/tmux_*.go` — a large tmux-compat **CLI command
  translator** (tmux-style commands like `split-window`, `send-keys` mapped to Programa's own
  `surface.*`/`pane.*` v2 RPCs against the *local* app socket via CLI relay). This is a syntax
  shim, not a session host — it does not run its own PTYs either; it forwards to the existing
  in-process Ghostty surfaces over the relay.
- `daemon/remote/cmd/programad-remote/main_proxy.go` — proves the daemon-as-persistent-process
  pattern already works in this codebase (long-lived `serve --stdio` process, hello handshake,
  stream RPC with async push events) for browser proxying. That's the shape (long-lived daemon,
  JSON-RPC over a persistent transport, async push frames) this feature should follow, just for
  PTY data instead of proxy bytes.
- **Bootstrap/distribution machinery already exists**: pinned per-platform binaries embedded in
  `Info.plist` with SHA-256 manifests, local cache + verification, `programa
  remote-daemon-status` (`daemon/remote/README.md:41-60`). A **local** daemon binary can reuse
  this exact trust/distribution pipeline instead of inventing a new one.

### 2.3 v2 socket API: additive, no existing local session verbs

`docs/v2-api-migration.md` has zero `session.*` methods scoped to the **local** socket today —
the existing `session.*` family lives entirely inside `programad-remote`'s stdio RPC, reachable
only via the SSH bootstrap path, not the local Unix socket that `TerminalController` serves
(`docs/v2-api-migration.md` method table, §"Surfaces / Splits" etc. — no `session.list/attach/
detach/kill`). Any new local `session.*` verbs are net-new surface area on
`TerminalController`, following the same envelope/threading conventions already documented:
off-main parse/validate, `v2MainSync` only around the final state mutation (per `docs/
v2-api-migration.md`'s worktree/layout section, and per root `CLAUDE.md`'s "Socket command
threading policy").

### 2.4 Typing-latency constraint (hard requirement, not a suggestion)

Root `CLAUDE.md` pitfalls section names three keystroke-hot paths that must not gain new work:
`WindowTerminalHostView.hitTest()`, `TabItemView`'s `Equatable` fast path, and
`TerminalSurface.forceRefresh()` — "no allocations, file I/O, or formatting." Any design that
proxies live keystrokes through an extra process hop (broker) must keep that hop off these three
paths, or add a **separate**, new fast path that bypasses them entirely for input write().
Ghostty's own renderer is vsync/wakeup-driven (see `CLAUDE.md`'s "do not add an app-level
display link" pitfall) — introducing a broker must not reintroduce a polling draw loop to make a
proxied stream "look alive."

### 2.5 Existing resize semantics to inherit, not reinvent

`docs/remote-daemon-spec.md` §5 already specifies "smallest screen wins" multi-attachment resize
(min cols/rows across attachments, never force-reset on zero attachments, recompute on
attach/detach/resize/reconnect) and it's implemented + tested
(`main_sessions.go`, RZ-001..RZ-005 in the acceptance matrix). The local detached-sessions design
should use the **identical** rule so a session behaves the same whether it's attached from one
local window, two local windows, or an SSH client — one mental model instead of two.

## 3. Architecture Options

### Option A — Daemon-owned PTY broker (recommended)

A new local daemon (call it `programad-local`, sibling to `programad-remote`, same Go toolchain
and distribution pipeline) owns the PTY and forked child for every "detached-capable" surface.
The Programa app becomes a **client**: it opens a connection to the broker, gets a byte
stream + resize channel, and feeds/reads it into/from a Ghostty surface that is reconfigured to
NOT fork its own child.

- **Ghostty-side change required**: Ghostty's surface today always forks its own PTY child
  (`ghostty/src/pty.zig` + `ghostty/src/Command.zig`). This is a **submodule change** (governed
  by the "Ghostty submodule workflow" in root `CLAUDE.md` — commit + push to the Darkroom fork
  before updating the parent pointer): add a surface mode where the PTY fd is supplied
  externally (a fd inherited/passed from the broker via a Unix-domain socket + `SCM_RIGHTS` fd
  passing) instead of `openpty`-ing internally. Ghostty's terminal *emulation* (VT parsing,
  scrollback, rendering) stays exactly as-is and keeps running in-process for rendering
  performance — only PTY *ownership* moves out.
- **Rendering/latency**: unchanged for the render path — Ghostty still parses/renders in-process
  from the fd it's handed. Input write() goes straight to the fd (no broker round-trip needed
  for keystrokes once the fd is handed over) — the broker's job is fd lifecycle + reattach, not
  steady-state I/O relay. This directly satisfies the CLAUDE.md typing-latency constraint
  because after attach, hot-path I/O bypasses the broker entirely.
- **Detach**: on workspace-close-without-kill or app quit, the broker keeps the child alive
  (it's the process's real parent/session leader via `setsid`), Ghostty's in-process surface
  tears down cleanly (already-supported teardown path, `TerminalSurface.teardownSurface()`,
  `Sources/TerminalSurface.swift:650-685`), broker keeps buffering output into a ring-buffer
  scrollback store.
- **Reattach**: new/relaunched app asks broker for the session's fd again (broker re-passes the
  fd via `SCM_RIGHTS`), replays buffered scrollback since last-seen offset, and Ghostty surface
  attaches to the "live" fd going forward. This is much closer to a *live* reconnect than today's
  literal text replay-file trick (`SessionScrollbackReplayStore`).
- **Crash recovery**: broker survives the app crashing (separate process, `launchd`-managed).
  On next launch, app queries broker for orphaned sessions and offers to reattach — this is the
  actual "process survival" ask.
- **Trade-offs**: highest implementation cost (real Ghostty/Zig surgery + new daemon + fd
  passing + a new local socket protocol). Biggest behavior change to the code that most directly
  touches the typing-latency pitfalls, so it needs the most careful spike work first. Also the
  only option that gives remote-machine attach (`programa attach <session>` from a plain
  terminal) a real backend, since the daemon can expose a plain-text attach mode independent of
  Ghostty's GUI entirely (same shape as tmux `attach`).

### Option B — tmux-style embedded server

Programa spawns (or reuses) a single per-user server process that behaves like a tmux server:
it runs a pty-hosting event loop and all shells live under it; the GUI app is one of possibly
several "clients" (a tmux client is exactly what herdr.dev is UX-inspired by, and it's also what
`tmux_*.go` already partially fakes at the *command* level today).

- **Difference from Option A**: the server does the terminal emulation too (VT state, scrollback
  buffer, resize) — not just PTY custody — the same way tmux's server, not just the shell, keeps
  running. Programa's GUI would then be a *pure renderer* of a remote (to it) terminal buffer,
  receiving already-parsed screen updates over the socket instead of raw PTY bytes.
  - **This conflicts hardest with the typing-latency pitfall.** Ghostty's entire raison d'être
    (and Programa's, per `CLAUDE.md`'s typing-latency section) is that VT parsing + rendering
    happen in the same process, close to the keystroke, with `forceRefresh()` avoiding any
    extra hop. Moving VT parsing into a separate server means every draw is now proxied state,
    not a local Ghostty surface reading a local fd — likely a rendering-latency regression
    unless the client keeps *some* local terminal emulation duplicated, which is exactly the
    "dual emulation" complexity tmux/screen users already know about (it's precisely why
    ligatures/images/some escape sequences are famously flaky through tmux).
  - **Rejects Ghostty's design premise.** Ghostty surfaces are the emulator; asking Programa to
    also *not* use Ghostty's emulator for detached sessions means either (a) shipping two
    terminal emulators, or (b) running a headless Ghostty surface inside the server process
    (doable — Ghostty already separates libghostty core from apprt — but this is a bigger lift
    than Option A's "just don't openpty, take an external fd" change).
- **Upside**: matches tmux/herdr's mental model most closely, and scrollback/resize become
  server-owned by construction (no replay-file hack needed at all, ever). Good stretch-goal
  shape for true `programa attach` from a bare SSH shell with zero Programa GUI running, since
  the server can render directly to a raw TTY (this is what tmux itself does).
- **Verdict**: valuable *long-term* target for the "attach from a plain terminal" stretch goal,
  but too large + too risky for v1 given today's Ghostty-in-GUI-process architecture. Consider
  as a v3+ direction once Option A's fd-passing plumbing exists (it's a superset).

### Option C — Minimal v1: opt-in "keep alive" per surface, no broker daemon yet

Don't move PTY ownership out of the GUI process at all. Instead, when a surface is marked
"keep alive" (opt-in per surface, likely agent-designated surfaces first), on workspace
close/app quit:
1. `setsid`/re-parent the forked child so it isn't in the app's own process group and won't get
   a `SIGHUP` when the app's controlling terminal/session goes away (Ghostty's `Command.zig`
   fork already runs `posix.fork()` — reparenting after fork instead of during app quit is a
   smaller Zig change than full fd-passing).
2. On next launch, the app doesn't get the PTY fd back at all (a `fork()`ed fd across process
   restarts is not recoverable through the OS) — so what actually "survives" is **only the
   process** (e.g., a long agent run keeps computing/writing to disk), not a live terminal
   reattach with output backfill. The app can only detect "still running" (`kill(pid, 0)`) and
   show it in the sidebar, and on relaunch offer either (a) a fresh terminal surface next to the
   still-running orphan with no scrollback continuity, or (b) require the orphan to redirect its
   stdout to a file the new terminal can `tail -f` into on relaunch (a poor-man's scrollback,
   with no true PTY reattach — no window resize forwarding, no interactive control of the
   original session).
- **Trade-offs**: cheapest possible v1, zero new daemon, zero Ghostty submodule changes, ships
  fast. But it's a materially weaker feature than what herdr/tmux offer — it saves the *process*,
  not the *session* (no true interactive reattach, no live scrollback). Given agent workflows are
  explicitly the target, "the agent keeps running and I can tail its log" may honestly satisfy a
  large fraction of real user need (most agent monitoring today is via `surface.wait`/
  `agent_state` polling anyway, not live pty interaction) — but it does not deliver the actual
  "detached sessions" feature as specified (interactive reattach with scrollback + live output).

### Decision: Option A, with Option C as the literal Phase 0/v1 fallback path if the fd-passing spike fails

Option A is the only option that delivers real interactive reattach with scrollback/live output
while (a) reusing `programad-remote`'s daemon/distribution/session-RPC/resize-coordinator
patterns nearly verbatim and (b) keeping Ghostty's in-process VT rendering — the thing that makes
Programa fast — completely untouched; only PTY *custody* moves. Option B is architecturally
purer but requires either duplicating a terminal emulator or running headless Ghostty inside a
server process, which is strictly more Zig/Swift surgery than Option A for the same v1 outcome;
park it as a v3+ direction once Option A's daemon and fd-passing exist (Option A's daemon is a
strict subset of what Option B's server would need). Option C is kept as the **de-risked
fallback**: if the Phase 0 spike shows fd-passing between a Go daemon and Ghostty's Zig PTY layer
is unworkable in the spike window, ship Option C's process-survival-only version first and layer
Option A on top later without throwing away the daemon/socket-API work (the RPC shape is
designed below to be a strict superset either way).

## 4. Phased Roadmap

### Phase 0 — Spike: fd-passing feasibility (2-3 eng-days)

**Riskiest assumption to validate first**: *that a PTY fd opened by `openpty()` in one process
(the new Go daemon) can be handed to Ghostty's Zig runtime in the Swift app process via
`SCM_RIGHTS`, and that Ghostty's `Command.zig`/`Surface.zig` can be adapted to consume an
already-open fd instead of forking+`openpty`-ing itself, without breaking the existing
in-process (non-detached) path.* This is the load-bearing assumption for Option A; if it's
false, Option A collapses toward Option B's cost (duplicate emulation) or Option C's reduced
scope.

Spike tasks:
1. Standalone Go program: `openpty()` equivalent via cgo or manual syscalls, pass master fd over
   a Unix socket via `SCM_RIGHTS` to a tiny Zig test harness that just reads/writes it. Prove the
   fd survives the passing round-trip and both ends can read/write.
2. In a throwaway Ghostty submodule branch, find the exact seam in `ghostty/src/termio/Exec.zig`
   and `ghostty/src/Command.zig:189` where `posix.fork()`/`openpty` happens, and confirm (read
   the code, don't guess) whether `Surface.zig`'s init path can accept a pre-opened fd instead
   (look at how `termio` abstracts over the pty — is there already a `Pty` vs `pipe`-based
   backend split that could add a third "externally supplied fd" backend?).
3. Confirm `SIGWINCH`/resize (`ghostty_surface_set_size` today drives Ghostty's own internal
   pty ioctl `TIOCSWINSZ`) still works when the daemon, not Ghostty, is the actual pty-master fd
   holder — does Ghostty's ioctl call need the fd, or can it be done via a resize RPC to the
   daemon instead (needed either way since the resize-coordinator model in
   `docs/remote-daemon-spec.md` §5 is daemon-side already)?
4. Kill criteria (stop and fall back to Option C if any hold after the 2-3 day box):
   - fd-passing round-trip works but Ghostty's Zig termio layer has no seam for an externally
     supplied fd without a rewrite bigger than "add a backend" (i.e., touches VT parsing, not
     just I/O plumbing).
   - Passing a live fd across `fork()`+exec boundaries interacts badly with macOS's App Sandbox/
     hardened runtime entitlements (verify: does the shipped `.app` run sandboxed today? grep
     entitlements — if sandboxed, cross-process fd passing may need an XPC service instead of a
     bare Unix socket, which is a different and larger daemon architecture).
   - Typing-latency regression appears in the spike's crude prototype even before real
     integration (if a naive fd-passed surface already feels laggier than the current in-process
     path in a side-by-side manual test, the "hot path unaffected" claim in §3 is wrong and the
     whole recommendation needs revisiting).

Delegate: `explore` (or human) to read `ghostty/src/termio/*.zig` in full for the backend-seam
question; this plan does not have that answer yet and it gates everything downstream.

### Phase 1 — v1: opt-in keep-alive, daemon skeleton, local `session.*` RPC (8-12 eng-days)

Assumes Phase 0 succeeds. If Phase 0 fails, Phase 1 becomes Option C's scope instead (process
survival + `kill(pid,0)` liveness only, no fd reattach) — re-estimate at 4-6 eng-days for that
reduced scope.

1. **New daemon: `programad-local`** (Go, new dir `daemon/local/cmd/programad-local/`,
   mirroring `daemon/remote/`'s structure/build scripts). Responsibilities:
   - Own PTY lifecycle for opt-in "keep alive" surfaces only (per Option A's fd model).
   - Persist a session table to disk (`~/.programa/sessions/<id>.json` — pid, fd-passing socket
     path, cwd, command, created_at, last_attached_at) so it survives its own restart too
     (daemon should be `launchd`-managed, not re-spawned by the app each launch).
   - Expose local JSON-RPC (reuse `docs/remote-daemon-spec.md`'s stdio-RPC framing, but over a
     Unix socket instead of stdio, since this is not an SSH-bootstrapped process): `session.list`,
     `session.create` (open + spawn), `session.attach` (hands back fd via `SCM_RIGHTS` +
     scrollback-since-offset), `session.resize` (reuse the exact "smallest screen wins" logic
     from `main_sessions.go:307-329` — same function, new home, or share the package if the Go
     module layout allows importing `daemon/remote` code, evaluate during Phase 1 step 1), 
     `session.detach` (mark app-side surface torn down, keep child alive),
     `session.kill` (deliberate, explicit user action — SIGTERM then SIGKILL after grace period).
   - Ring-buffer scrollback capture (bound it the same way `SessionPersistencePolicy` already
     bounds saved scrollback — `Sources/SessionPersistence.swift:20-21`,
     `maxScrollbackLinesPerTerminal`/`maxScrollbackCharactersPerTerminal` — reuse those
     constants' values as the daemon's buffer cap so behavior is consistent pre/post this
     feature).
2. **Ghostty submodule change**: add the externally-supplied-fd surface backend identified in
   Phase 0 step 2. Push to Darkroom fork per `CLAUDE.md`'s submodule workflow *before* bumping
   the parent pointer.
3. **Swift integration** (`Sources/TerminalSurface.swift`, new file
   `Sources/TerminalSurface+DetachedSession.swift`):
   - New per-surface opt-in flag (`keepAliveOnClose: Bool`), surfaced as a context-menu action
     ("Keep Running When Closed") on terminal panels — likely first exposed only for
     agent-detected surfaces (`AgentScreenDetectionEngine.swift` already classifies agent
     surfaces; reuse that signal for a sane default) rather than every terminal by default.
   - On workspace/panel close with the flag set: instead of `teardownSurface()`'s normal free
     path, hand the fd to `programad-local` via `session.create`/detach and let the daemon adopt
     it; local surface object still tears down its Ghostty-side state normally.
   - On app launch, alongside existing `SessionPersistenceStore.load()`
     (`Sources/SessionPersistence.swift:381-389`), query `programad-local` for
     `session.list` and offer/attempt `session.attach` for any workspace whose persisted snapshot
     references a still-alive daemon session id (new field on `SessionTerminalPanelSnapshot`,
     `Sources/SessionPersistence.swift:226-229`: `detachedSessionId: String?`).
4. **New local v2 socket methods** (`TerminalController+Surface.swift` or a new
   `TerminalController+Sessions.swift`, following the off-main-parse / `v2MainSync`-mutate
   convention documented in `docs/v2-api-migration.md`'s worktree section):
   - `session.list` -> `{"sessions": [{"session_id", "surface_id"?, "workspace_id"?, "pid",
     "created_at", "last_attached_at", "attached": bool, "command", "cwd"}]}`.
   - `session.detach` (`surface_id` -> detach without kill; distinct from the daemon-internal
     RPC of the same name — this is the **app-facing** verb; app translates it into the daemon
     call transparently).
   - `session.attach` (`session_id` -> reopens a workspace/surface bound to that daemon session).
   - `session.kill` (`session_id`, explicit, never implicit — matches the "Always ask" spirit of
     destructive actions in root `CLAUDE.md`'s Autonomy Contract, though this is app-internal not
     cross-repo).
   - Naming deliberately mirrors `docs/remote-daemon-spec.md`'s existing `session.*` RPC verbs
     (`open/attach/resize/detach/status/close`) so the mental model and eventual code sharing
     between local and remote daemons stay aligned — do not invent divergent verb names.
5. **CLI**: `programa attach <session>` per the feature ask's stretch goal — for v1 scope this
   can just be a thin wrapper that calls the new `session.attach` v2 method through the existing
   CLI relay machinery already built in `daemon/remote/cmd/programad-remote/cli.go` (reuse the
   busybox-dispatch pattern, don't build a second CLI framework).
6. **Migration/compat**: existing `AppSessionSnapshot`/`version` (`Sources/
   SessionPersistence.swift:6-8,374-378`) bumps `SessionSnapshotSchema.currentVersion` to 2 with
   the new optional `detachedSessionId` field — old snapshots (`version == 1`) still decode fine
   for everything except live-reattach (no daemon session existed, so it silently falls back to
   today's "new process + scrollback replay" path, i.e., **zero regression for non-opted-in
   surfaces**, which is the majority case in v1).

### Phase 1 test strategy

- `tests_v2/` python suite is the CI gate (per `docs/v2-api-migration.md`'s closing note); add
  `tests_v2/test_detached_session_attach_reattach.py` following the existing structure/harness in
  `tests_v2/cmux.py`. Cover:
  - create keep-alive surface, close workspace, `session.list` shows it detached/alive.
  - relaunch (simulated via killing + relaunching the tagged debug app in the test harness, same
    pattern already used for reconnect tests like `test_ssh_remote_docker_reconnect.py`),
    `session.attach`, verify live output continues (write a marker into the still-running shell
    before relaunch, confirm it's visible post-reattach — same "marker-in-echo" pattern documented
    in the `tests-v2-authoring-rules` memory).
  - resize during detached state (no attachments) does not force a reset — mirrors RZ-003 from
    `docs/remote-daemon-spec.md` §7.4, reuse that test's assertions against the new local daemon.
  - `session.kill` actually terminates the child (verify via `kill(pid, 0)` failing after).
- Daemon-level Go unit tests (`daemon/local/cmd/programad-local/*_test.go`), same pattern as
  `main_test.go`/`cli_test.go` in the remote daemon — test the RPC handlers directly without a
  real PTY where possible, real PTY only in a smaller integration subset.
- CI must NOT run these against an untagged app instance — reuse the tagged-socket pattern from
  the `tests-v2-socket-hijack` memory (`PROGRAMA_SOCKET_PATH` override) since these tests
  specifically need to kill/relaunch the app under test.

### Phase 2 — v2: crash recovery, multi-window resize coordination, remote attach (10-15 eng-days)

1. **Crash recovery**: today only `applicationWillTerminate`/`applicationShouldTerminate`
   (`Sources/AppDelegate.swift:1446-1498`) save state — a hard crash (SIGSEGV, forced quit) skips
   both. Since `programad-local` is a separate long-lived process (Phase 1), crash recovery is
   nearly free by construction: on any launch (not just clean-quit-then-relaunch), query
   `session.list` and reconcile against the last-known snapshot rather than only doing so on the
   "restore" code path — this closes the crash gap that `AppSessionSnapshot`-only persistence
   cannot.
2. **Multi-attachment resize**: port the exact "smallest screen wins" semantics
   (`docs/remote-daemon-spec.md` §5) so a session attached from two local windows simultaneously
   (or one local + one remote-SSH-relayed attach) behaves identically to the already-tested
   remote-daemon resize coordinator — ideally by literally sharing the Go package between
   `daemon/local` and `daemon/remote` rather than reimplementing `recomputeSessionSize`.
3. **Remote attach stretch goal**: extend `programad-local`'s socket to also be reachable via the
   existing SSH reverse-relay/CLI-relay transport already built for `programad-remote`
   (`daemon/remote/README.md`'s "CLI relay" section) — `programa attach <session>` from a plain
   remote shell becomes "dial the relay, same auth (HMAC-SHA256 challenge, `~/.programa/relay/
   <port>.auth`), send `session.attach`." This reuses 100% of the existing relay auth/transport
   work instead of inventing a new remote-attach protocol.
4. **Sandbox/signing verification** (do this **before** committing to fd-passing as the
   permanent transport, not after): confirm whether the shipped `.app` runs under App Sandbox —
   if `com.apple.security.app-sandbox` is present in the entitlements, raw `SCM_RIGHTS` fd
   passing between the sandboxed app and an unsandboxed daemon may be restricted or require an
   XPC service wrapper. This directly informs whether Phase 1's daemon transport choice (bare
   Unix socket) survives into a notarized/sandboxed release build or needs replacing with XPC —
   check this in Phase 0, ideally, since it changes the whole daemon's IPC shape; listed here
   too because Phase 2's remote-relay reuse assumes the local transport question is already
   settled.

## 5. Risk Register

| Risk | Likelihood | Impact | Mitigation / Kill Criteria |
|---|---|---|---|
| Ghostty termio has no seam for externally-supplied fd (Phase 0's core risk) | Medium | Blocks Option A entirely | Phase 0 spike is scoped exactly to answer this first; fallback is Option C |
| App Sandbox blocks `SCM_RIGHTS` fd passing to daemon | Medium | Requires XPC service instead of Unix socket, larger daemon rewrite | Verify entitlements + sandbox status in Phase 0/2, before Phase 1 locks in transport |
| fd-passed input path regresses typing latency | Medium | Violates the app's core value prop (CLAUDE.md pitfalls) | Manual latency A/B in Phase 0 prototype before Phase 1 starts; kill criterion listed in §4 Phase 0 |
| Daemon becomes a new single point of failure (daemon crash kills all detached sessions) | Low-Medium | Defeats the entire feature's purpose | Daemon must be simpler/more stable than the GUI app by design (no UI, no rendering, minimal deps); `launchd` auto-restart; sessions table persisted to disk so daemon restart can re-adopt orphaned ptys by fd re-scan if the OS allows it (verify feasibility) |
| Scope creep into Option B (headless Ghostty / full tmux replacement) mid-implementation | Medium | Blows the estimate, delays shippable v1 | This plan explicitly scopes Phase 1/2 to Option A only; Option B stays a documented v3+ direction, not folded into v1/v2 tickets |
| Existing session-persistence snapshot format regresses for non-opted-in surfaces | Low | User-visible regression on every relaunch, not just the new feature | Schema bump is additive-only (`detachedSessionId` optional field); explicit test asserting version-1 snapshots still restore via the old replay path unchanged |
| Multi-window/multi-machine resize thrash (two attachments fighting over size) | Low | Confusing UX, already-solved problem re-broken | Reuse `docs/remote-daemon-spec.md` §5's exact algorithm + its existing RZ-* test suite as the acceptance bar, don't reinvent |

## 6. Effort Summary

| Phase | Scope | Estimate |
|---|---|---|
| Phase 0 | fd-passing spike + sandbox/entitlement check | 2-3 eng-days |
| Phase 1 | Daemon skeleton, Ghostty backend seam, opt-in keep-alive, local `session.*` RPC, CLI attach, tests | 8-12 eng-days (or 4-6 eng-days if Phase 0 fails and scope drops to Option C) |
| Phase 2 | Crash recovery, shared multi-attachment resize, remote attach, sandbox-safe transport hardening | 10-15 eng-days |
| **Total (Option A path)** | | **20-30 eng-days** |
| **Total (Option C fallback path)** | | **6-9 eng-days**, materially weaker feature (process survival, no live reattach) |

**Single riskiest assumption to validate first**: whether Ghostty's Zig termio/pty layer
(`ghostty/src/termio/Exec.zig`, `ghostty/src/pty.zig`, `ghostty/src/Command.zig`) can be given an
externally-opened PTY fd instead of always forking+`openpty`-ing itself, without a rewrite that
touches VT parsing/rendering — this is exactly Phase 0's scope and it gates whether Option A is
buildable at all versus falling back to Option C's reduced "process keeps running, no live
reattach" scope.

## 7. Files Referenced (for implementer handoff)

- `Sources/TerminalSurface.swift` (PTY/surface creation, `createSurface()` at line 833,
  `ghostty_surface_new` call at 1041-1051, teardown at 650-685)
- `Sources/SessionPersistence.swift` (snapshot schema, scrollback replay store, policy constants)
- `Sources/TabManager+SessionPersistence.swift` (snapshot capture/restore orchestration)
- `Sources/Workspace+Layout.swift` (custom layout apply/capture, unrelated to detach but adjacent
  restore machinery an implementer will touch)
- `Sources/AppDelegate.swift` (quit lifecycle, lines 1446-1498)
- `ghostty/src/pty.zig`, `ghostty/src/Command.zig`, `ghostty/src/termio/Exec.zig`,
  `ghostty/src/Surface.zig` (submodule — PTY fork/exec, child-exit action)
- `daemon/remote/cmd/programad-remote/main_sessions.go`, `tmux_store.go`, `main.go`,
  `main_proxy.go` (existing Go daemon patterns to mirror for `daemon/local`)
- `daemon/remote/README.md`, `docs/remote-daemon-spec.md` (prior-art spec and naming to align
  with)
- `docs/v2-api-migration.md` (v2 socket method conventions, threading policy references)
- `tests_v2/cmux.py` and sibling `test_ssh_remote_*` files (test harness patterns to extend)
- `CLAUDE.md` (root) — typing-latency pitfalls, submodule workflow, socket threading/focus
  policy — all binding constraints on this feature's implementation

## 8. Open Questions For The User Before Implementer Handoff

1. Is app-sandbox status of the shipped `.app` already known, or does that need to be checked
   as literally the first Phase 0 task (it changes the daemon's IPC transport choice)?
2. Should "keep alive" default on for agent-detected surfaces (via
   `AgentScreenDetectionEngine`), or should it always be a manual per-surface opt-in for v1 to
   minimize surprise (an agent surface unexpectedly surviving quit could be confusing before
   users trust the feature)?
3. Is a brand-new `daemon/local/` Go module acceptable, or is there a preference to fold this
   into `daemon/remote/` as a mode flag on the same binary (shares more code, but couples two
   currently-independent release/versioning stories)?
