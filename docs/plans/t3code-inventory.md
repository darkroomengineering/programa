# t3code inventory

Read-only pass over a shallow clone of github.com/pingdotgg/t3code (MIT) on 2026-09-15. Companion to `rust-core-spike.md`; kept as a reference for the core-plus-clients design and for features worth porting.


T3 Code is "an agent harness control surface": iOS/Android app, web app
(app.t3.codes), and Electron desktop app, all controlling Claude Code, Codex,
Cursor, Grok Build, OpenCode, and Antigravity running on a machine you own.
Stack: Effect (effect-ts) end to end, Vite+ (`vp`) monorepo tooling, SQLite
persistence, Clerk for cloud identity. This is the closest public reference
to the "thin client / server owns sessions" model Programa is evaluating.

## 1. Architecture: client/server split, transport, auth, bundling

**Split.** The server (`apps/server`, Node 22.16+/23.11+/24.10+) owns every
stateful thing: provider processes, PTYs, git, project files, durable event
log, SQLite. Clients (web `apps/web`, desktop renderer `apps/desktop`,
mobile `apps/mobile`) are pure RPC consumers and hold no filesystem or
provider state of their own — stated explicitly in
`docs/internals/overview.md:3-7`: "A remote client must never substitute its
own filesystem, provider credentials, or machine state for the environment's."
A running server instance is called an "environment" and keeps a stable ID
across restarts (`apps/server/src/environment/ServerEnvironment.ts`).

**Shared client logic.** `packages/client-runtime/src/` is a platform-agnostic
package (connection retry, RPC session, auth token refresh, cached
projections) that all three clients import; platform code only supplies
storage/credentials/lifecycle hooks (`docs/internals/connection-runtime.md`).
Key files: `packages/client-runtime/src/connection/supervisor.ts` (single
retry owner, exponential backoff, distinguishes offline/foreground/background
transitions), `.../connection/registry.ts` (per-environment connection scope),
`.../rpc/session.ts` (waits for initial server config before "ready"),
`.../rpc/client.ts` (resolves RPC calls against current session, subscriptions
survive reconnect, mutations are not auto-replayed), `.../state/threads.ts`
(subscription lifetime separated from a 5-minute idle cache).

**Transport & schema.** Effect RPC (`effect/unstable/rpc`) over WebSocket +
HTTP, not tRPC. The entire RPC surface (request/response schemas, ~1500
lines) lives in one file: `packages/contracts/src/rpc.ts`, built from
per-domain schema modules in `packages/contracts/src/` (`orchestration.ts`,
`git.ts`, `terminal.ts`, `provider.ts`, `auth.ts`, `filesystem.ts`,
`review.ts`, `relay.ts`, `worktreeSetup.ts`, `resourceTelemetry.ts`, etc — full
list of ~50 files in that dir). Everything is `effect/Schema`-typed end to
end, client and server share the exact same TS types from `@t3tools/contracts`.
Subscriptions are scoped (e.g. per-thread), so a client viewing one thread
doesn't pay for every thread's history (`overview.md:17-18`).

**Auth (device→server).** The server issues its own sessions; a separate
relay/cloud identity layer (Clerk) is a distinct trust boundary
(`docs/internals/environment-auth.md`). Mechanisms: (a) pairing — delegates a
scoped grant, cannot be widened by exchanging a bootstrap credential; (b)
bearer + DPoP (Demonstrating Proof-of-Possession) tokens — short-lived
WebSocket "tickets" obtained via authenticated HTTP so long-lived tokens never
sit in socket URLs; (c) browser cookie sessions. Every RPC method declares a
required scope, checked in `apps/server/src/auth/RpcAuthorization.ts`; a
successful socket handshake grants no extra authority. Desktop keeps one
reusable local bearer/bootstrap token across restarts
(`apps/server/src/persistence/AuthSessions.ts`). A dev-only
`T3CODE_DEV_AUTH_TOKEN` gives shared admin access across worktrees on one
host, ignored by desktop/production builds.

**Phone ↔ laptop over the internet: three real transports, no built-in relay
proxying of app traffic.**
1. **Direct/LAN pairing** — client and server on the same network, endpoint
   advertised by the server; the connecting device is the only one that can
   prove a route actually works (`remote.md:22-25`), so there's no blind
   trust of advertised addresses.
2. **Tailscale** — just supplies a reachable endpoint; not a distinct
   environment type, auth still goes through the normal environment auth
   path (`remote.md:42-44`).
3. **SSH tunnel** — desktop main process can spawn `ssh` to forward a port
   and/or launch a remote server; renderer only ever talks to the local
   forwarded endpoint (`packages/ssh/src/tunnel.ts`). Desktop main owns
   the SSH process lifecycle because it needs to handle interactive auth
   prompts (`packages/ssh/src/tunnel.ts`, `apps/desktop/src/ssh/`).
4. **T3 Connect (cloud relay)** — `docs/internals/t3-connect.md`. Clerk
   provides cloud identity; a Cloudflare Worker relay
   (`infra/relay/src/environments/EnvironmentConnector.ts`,
   `ManagedEndpointProvider.ts`) manages environment *links* and mints
   managed tunnel hostnames, but **application traffic (HTTP/WebSocket) goes
   directly client→environment tunnel hostname; the relay Worker does not
   proxy it** ("the relay Worker does not proxy their HTTP or WebSocket
   sessions", `t3-connect.md:6`). The relay's only job in the data path is a
   one-time bootstrap: it asks the environment to mint a credential bound to
   the client's DPoP key; the relay never sees the resulting session token
   (`t3-connect.md:13-16`). So it's "relay for pairing/discovery, direct/
   tunnel for data" — not a full reverse-proxy relay. SSH device-authorization
   grant handles headless/CLI pairing without a local browser listener
   (`t3-connect.md:81-86`).

**Electron bundling/startup.** `apps/desktop/src/main.ts` is the Electron
main entry. The server ships *inside* the desktop app and is started as a
child process, managed per-instance by
`apps/desktop/src/backend/DesktopBackendManager.ts` (factory,
`makeBackendInstance(spec)`) and pooled by `DesktopBackendPool.ts` — the pool
can run more than one backend at once (primary + a Windows WSL backend via
`apps/desktop/src/wsl/DesktopWslBackend.ts`). Desktop-specific server config
resolution is `DesktopBackendConfiguration.ts`; local auth for the
desktop↔bundled-server pair is `DesktopLocalEnvironmentAuth.ts`; LAN exposure
toggle is `DesktopServerExposure.ts`. The desktop *renderer* is not served by
the bundled server — a custom `t3code://` scheme serves the bundled web
client from disk (Vite dev server in development); only API/RPC traffic goes
over HTTP/WS to the environment (`remote.md:69-71`). A desktop setting,
`localEnvironmentEnabled` (`apps/desktop/src/settings/DesktopAppSettings.ts`),
lets desktop run with **no** bundled/local server at all — pure thin client
mode, connecting only to saved remote/paired/relay environments
(`remote.md:61-71`). This is effectively the exact "thin client" mode
Programa is evaluating, already shipped as a toggle rather than a rewrite.

**"Remote-ready" today, concretely:** any client (web, desktop, mobile) can
attach to any environment (local machine, LAN, Tailscale, SSH-tunneled
remote, or cloud-relay-linked) using the same RPC/auth stack, with capability
negotiation (`overview.md:21-38` — environments advertise flags like
`threadPullRequests`; older/newer client-server pairs degrade gracefully
instead of assuming a coordinated release). A remote server can outlive
several client releases (`remote.md:55-59`).

## 2. Terminal rendering

Two different mechanisms depending on what's being shown:

- **Agent output (the actual conversation with Claude/Codex/etc.) is
  structured events, not PTY bytes.** See §3's event list — there is no
  terminal emulator involved in rendering agent turns/tool calls; it's a
  typed event stream rendered as native UI components.
- **A literal shell/terminal panel** (for running arbitrary commands, seeing
  raw agent CLI passthrough, etc.) **is PTY-backed and does use a terminal
  emulator.** Server side: `node-pty` via
  `apps/server/src/terminal/NodePtyAdapter.ts`, spawning through
  `apps/server/src/terminal/Manager.ts`, which owns PTY lifecycle, session
  retention, and incremental output persistence
  (`docs/internals/terminal-runtime.md`). On Windows this goes through
  ConPTY; `NodePtyAdapter.ts:162-165` has a comment noting "the ConPTY path
  leaves the environment untouched" and compensates by injecting `TERM` when
  absent. Client rendering uses **`libghostty-vt`**, a C ABI terminal engine
  (Ghostty's VT parser/renderer core) shared between Android and web —
  `native/libghostty-vt/`, pinned by `native/libghostty-vt/VERSION`, consumed
  by the web renderer at `apps/web/src/terminal/ghostty/core.ts` as
  WebAssembly (one WASM instance per browser tab, each terminal owns/frees
  its own handle) and natively on Android. React does not touch terminal
  frames directly — platform adapters own drawing/input
  (`terminal-runtime.md:30-34`). Server-side history is capped (5,000 lines /
  8 MiB per terminal; client buffer cap 512 KiB) and strips terminal
  query/response escape sequences from replayed history so restoring
  scrollback can't provoke junk replies at the live prompt
  (`terminal-runtime.md:40-44`).

**Structured provider event types** (from
`packages/contracts/src/providerRuntime.ts:204-232`, the `ProviderRuntimeEvent`
discriminated union — this is the full canonical list):

```
session.started
session.configured
session.state.changed
session.exited
thread.started
thread.state.changed
thread.metadata.updated
thread.token-usage.updated
thread.realtime.started
thread.realtime.item-added
thread.realtime.audio.delta
thread.realtime.error
thread.realtime.closed
turn.started
turn.completed
turn.aborted
turn.plan.updated
turn.proposed.delta
turn.proposed.completed
turn.diff.updated
item.started
item.updated
item.completed
content.delta
request.opened
request.resolved
user-input.requested
user-input.resolved
task.started
```
(plus more `task.*` entries — list truncates at the read window; grep
`packages/contracts/src/providerRuntime.ts` for the full `Type` block if you
need the tail). Item/request typing is further split by
`CanonicalItemType` and `CanonicalRequestType` (lines 116-149 of the same
file) — worth reading directly if Programa builds an analogous typed-event
model, since it already encodes tool-lifecycle items, plans, diffs, and
realtime (voice) audio deltas as first-class event kinds.

## 3. Agent harness integration (one paragraph per provider)

All five adapters live in `apps/server/src/provider/Layers/*Adapter.ts`
(pattern: `Layers/XAdapter.ts` is the live Effect implementation,
`Services/XAdapter.ts` is the service interface/contract). All normalize into
the same `ProviderRuntimeEvent` stream above via the
`ProviderAdapter` boundary (`apps/server/src/provider/Services/ProviderAdapter.ts`,
referenced from `docs/internals/providers.md:5`) — provider-specific logic is
supposed to stay entirely inside the adapter, never leak into orchestration
or clients.

- **Claude** — `apps/server/src/provider/Layers/ClaudeAdapter.ts`. Uses the
  **official `@anthropic-ai/claude-agent-sdk`** package directly (`query`,
  `forkSession`, `getSessionMessages`, `CanUseTool`, `PermissionMode`,
  `SDKMessage` types imported straight from the SDK) — this is an in-process
  SDK integration, not a CLI subprocess wrapping JSON output.
- **Codex** — `apps/server/src/provider/Layers/CodexAdapter.ts`, backed by an
  in-repo package `packages/effect-codex-app-server` (own `schema.ts`,
  `errors.ts`) that wraps Codex's app-server protocol as a typed Effect
  service; the adapter spawns/talks to it via
  `effect/unstable/process/ChildProcessSpawner`. So: CLI subprocess, but with
  a structured/typed IPC protocol (Codex's own JSON-RPC-like app-server
  mode), not raw stdout scraping. Notably, Codex "async questions" arrive as
  notifications with no pending RPC response — answered by sending a new
  user message rather than a reply (`providers.md:81-85`), a protocol quirk
  worth knowing if Programa ever integrates Codex directly.
- **Cursor** — `apps/server/src/provider/Layers/CursorAdapter.ts`, doc
  comment: *"Cursor CLI (`agent acp`) via ACP."* This is the **Agent Client
  Protocol** (ACP, the emerging cross-editor agent protocol) — the adapter
  uses an in-repo `effect-acp` package (`packages/effect-acp/src`,
  `schema.ts`/`errors.ts`) to speak ACP to the `agent acp` CLI subprocess.
- **OpenCode** — `apps/server/src/provider/Layers/OpenCodeAdapter.ts`, uses
  the official `@opencode-ai/sdk/v2` client (`OpencodeClient`, `Part`,
  `PermissionRequest`, `QuestionRequest` types). Per `providers.md:14-19`,
  T3 runs **one OpenCode server per thread** (directory-scoped MCP vs.
  thread-scoped T3 MCP connection — sharing a server across threads in one
  directory would let threads swap each other's MCP connection). Idle
  instance-owned helper servers close after a timeout
  (`apps/server/src/provider/OpenCodeServerOwner.ts`). Persistent per-directory
  approval grants exist; automatic full-access replies use a one-shot
  `once` grant so they can't silently widen permissions on an externally
  shared server (`providers.md:20-23`).
- **Antigravity** (Google) — `apps/server/src/provider/Layers/AntigravityAdapter.ts`
  + `AntigravityProvider.ts`. No CLI login; uses native sign-in
  (`AntigravityAuth.ts`) with per-instance file-based credential storage
  (forced, because macOS Keychain entries would otherwise be shared across
  instances) and an installer with immutable, leased releases
  (`AntigravityInstallation.ts`). Antigravity can capture workspace
  checkpoints but **cannot roll back its own conversation state**, so revert
  is rejected up front rather than silently desyncing filesystem and
  conversation (`providers.md:92-95`).
- **Grok Build** — `apps/server/src/provider/Layers/GrokAdapter.ts` /
  `GrokProvider.ts`, present in the README's provider list; adapter avoids
  triggering auth/session-creation as a side effect of health probes
  (`providers.md:40-42`).

**Permission modes → approval flow**
(`docs/user/permission-modes.md`, `apps/server/src/auth`/orchestration):
four user-facing modes — **Supervised** (approve every command/file change),
**Auto-accept edits** (edits auto-approved, other actions still gated),
**Auto** (defers to the provider's own automatic-review; only Claude, Codex,
Cursor implement that — OpenCode and Antigravity fall back to asking), **Full
access** (no prompts, though Antigravity can still push native approval
requests even here). Default mode is set per-environment
(Settings → General) and per-project override; new threads take the
environment default, not whatever mode you were last viewing. Mechanically,
approvals are just `request.opened` / `request.resolved` /
`user-input.requested` / `user-input.resolved` events in the same
`ProviderRuntimeEvent` stream — the UI renders a pending request inline in
the conversation and a resolve command flows back through the same
orchestration command path as any other user action (`overview.md`'s
event-sourced command/decider/projector model, `providers.md` "Protocol
traps" section for edge cases like Codex's notification-only async
questions).

## 4. Feature list (grouped, one line + owning directory each)

**Sessions / threads**
- Threads = one durable conversation entity with a provider, event-sourced —
  `apps/server/src/orchestration/` (engine, decider, projector — see
  `overview.md` "Durable intent and side effects").
- Thread search/snapshot/full-diff RPCs — `packages/contracts/src/orchestration.ts`
  (`OrchestrationSearchThreadsInput`, `OrchestrationGetFullThreadDiffInput`, etc).
- Client-side thread cache/subscription lifecycle —
  `packages/client-runtime/src/state/threads.ts`.
- Thread sidebar UI doc — `docs/user/thread-sidebar.md`.

**Projects / workspaces**
- Project entity + settings — `packages/contracts/src/project.ts`,
  `apps/server/src/project/`.
- Project-scoped agent session import/scan (importing existing CLI sessions
  into T3) — `apps/server/src/project/AgentSessionScanner.ts`,
  `packages/contracts/src/agentSessions.ts`.
- Project setup script runner — `apps/server/src/project/ProjectSetupScriptRunner.ts`.
- Project cloning — `apps/server/src/projectClone.ts` (server contracts side),
  `packages/contracts/src/projectClone.ts`... actually contract is
  `apps/server` side per grep; project file format —
  `packages/contracts/src/t3ProjectFile.ts`.

**Git worktrees**
- Worktree create/remove/setup-stream RPCs —
  `packages/contracts/src/worktreeSetup.ts`, `packages/contracts/src/git.ts`
  (`VcsCreateWorktreeInput/Result`, `VcsRemoveWorktreeInput`).
- Server implementation — `apps/server/src/git/GitManager.ts`,
  `GitWorkflowService.ts`.

**Diff review / checkpoints**
- Turn/thread diff RPCs — `OrchestrationGetTurnDiffInput`,
  `OrchestrationGetFullThreadDiffInput` in `packages/contracts/src/orchestration.ts`.
- Review diff preview/file-contents RPCs — `packages/contracts/src/review.ts`,
  server side `apps/server/src/review/`.
- **Checkpointing**: hidden Git refs capture workspace state per-turn without
  polluting the user's branch history — `apps/server/src/checkpointing/CheckpointStore.ts`,
  `CheckpointDiffQuery.ts`, `Diffs.ts` (see `overview.md` "Turn completion and
  checkpoints" — revert coordinates workspace + provider conversation state,
  and providers that can't roll back their own conversation must reject
  revert before touching files).

**Source control**
- Multi-host PR/MR support: GitHub, GitLab, Bitbucket, Azure DevOps, Forgejo
  — `apps/server/src/pullRequest/{GitHubPullRequestProvider,GitLabPullRequestProvider,
  BitbucketPullRequestProvider,AzureDevOpsPullRequestProvider,ForgejoPullRequestProvider}.ts`,
  each with a CLI-backed and JSON/API-backed variant (e.g.
  `GitHubPullRequestCli.ts` vs `gitHubPullRequestJson.ts`).
  Multi-link/stacked-PR support negotiated via environment capability flags
  `threadPullRequests` / `threadPullRequestLinking` (`overview.md:21-38`).
- Generic VCS status/ref RPCs — `packages/contracts/src/vcs.ts`
  (`VcsStatusInput/Result`, `VcsListRefsInput`, `VcsSwitchRefInput`,
  `VcsPullInput`).
- Forgejo CLI wrapper — `apps/server/src/sourceControl/ForgejoCli.ts`.
- Docs: `docs/user/source-control.md`.

**Notifications**
- Desktop dock/taskbar badge — `apps/desktop/src/ipc/methods/notificationBadge.ts`.
- Mobile push: permission handling, payload schema, deep-link navigation from
  a push, response consumption — all under
  `apps/mobile/src/features/agent-awareness/` (`notificationPermissions.ts`,
  `notificationPayload.ts`, `notificationNavigation.ts`,
  `notificationResponseConsumer.ts`).
- Sound cues — `apps/web/src/assets/notification-{completion,input}.mp3`.
- Settings UI — `apps/web/src/components/settings/NotificationSettings.tsx`.
- Docs: `docs/user/mobile-notifications.md`,
  `docs/operations/android-notifications.md`.

**Multi-account**
- Provider account/instance model (a "driver kind" = integration type, an
  "instance" = one account/config, so two accounts on the same driver never
  share session/catalog state) — `apps/server/src/provider/Services/ProviderInstanceRegistry.ts`,
  `ProviderInstanceRegistryMutator.ts`, doc: `providers.md:8-11`.
- Per-provider multi-account user docs: `docs/user/providers-codex.md`,
  `docs/user/providers-claude.md`.

**Settings**
- Client-local vs. environment/project-owned settings split, explicitly
  documented as a design rule (`overview.md:44-51` "Settings ownership") —
  contracts in `packages/contracts/src/settings.ts`,
  `packages/contracts/src/keybindings.ts`.
- Desktop-specific app settings — `apps/desktop/src/settings/DesktopAppSettings.ts`,
  `DesktopClientSettings.ts`, `DesktopSavedEnvironments.ts`.

**Keyboard shortcuts**
- Contract — `packages/contracts/src/keybindings.ts`.
- User doc — `docs/user/keybindings.md`, `docs/user/keyboard-focus.md`.

**Mobile-specific**
- Native modules/plugins — `apps/mobile/modules/`, `apps/mobile/plugins/`.
- Voice input — `docs/internals/voice-input.md`.
- Push notification stack — see Notifications above.
- Composer context references / attachments — `docs/internals/composer-context-references.md`,
  `docs/user/question-attachments.md`.
- Mobile navigation architecture — `docs/internals/mobile-navigation.md`.

**Browser panel (Programa-relevant, T3 has an equivalent)**
- Desktop embeds a live preview/browser panel with element-pick and
  Playwright-driven automation — `apps/desktop/src/preview/`
  (`Manager.ts`, `PlaywrightInjectedRuntime.ts`, `PickPreload.ts`,
  `Annotation.css`/`AnnotationKeyboard.ts`, `BrowserSession.ts`,
  `FaviconCapture.ts`). Browser import/profile handling —
  `packages/contracts/src/browserImport.ts`, `browserProfile.ts`.

## 5. Windows/Linux specifics

- **ConPTY** — `apps/server/src/terminal/NodePtyAdapter.ts:162-165`, Windows
  path via node-pty's ConPTY backend; comment notes ConPTY "leaves the
  environment untouched" so the adapter injects `TERM` manually when absent.
- **Windows foreground/focus handling** uses native FFI (`ffi-rs`) loaded
  lazily, isolated from Electron main startup —
  `apps/desktop/src/electron/WindowsForeground.ts`,
  `WindowsForegroundFocusThread.ts`, `WindowsForegroundFocusWorker.ts`
  (`overview.md:105-110`: native modules never load on the main-process
  startup path; `ffi-rs` loads lazily just for a few Win32 calls).
- **Windows Subsystem for Linux (WSL) backend** — Desktop can run a *second*
  bundled server instance inside WSL alongside the native Windows primary:
  `apps/desktop/src/wsl/DesktopWslBackend.ts`, `DesktopWslEnvironment.ts`,
  `DesktopWslServerTree.ts`, `wslPathParsing.ts`. Windows packages currently
  ship only a Windows resource-monitor binary, so WSL-backend process
  telemetry is unavailable even though the Electron power feed still works
  (`resource-telemetry.md:47-49`).
- **Linux desktop-entry / portal identity** — must be set *before* Chromium
  init via `DesktopPreReadyPlatform.layer`, because Chromium caches the first
  desktop-entry registration including failures
  (`overview.md:94-103`); AppImage updates can invalidate the entry's `Exec`
  path, refreshed just before portal registration. Handler:
  `apps/desktop/src/app/DesktopLinuxUrlHandler.ts`,
  `apps/desktop/src/app/DesktopPreReadyPlatform.ts`.
- **Linux screenshot capture per-compositor**: separate implementations for
  GNOME (`apps/desktop/src/snapShot/GnomeCaptureSetup.ts`,
  `gnomeCaptureBundle.ts`, plus a native `apps/desktop/gnome-extension/`),
  KDE (`KdeSnapShot.ts`, native crate `native/kde-snap-shot/`), Hyprland
  (`HyprlandSnapShot.ts`, native crate `native/hyprland-snap-shot/`), Niri
  (`NiriSnapShot.ts`), and a generic xdg-desktop-portal path
  (`PortalCaptureShortcut.ts`, `LinuxSnapShot.ts` dbus-based).
- **Linux secret storage** — `apps/desktop/src/linuxSecretStorage.ts`
  (libsecret-style, distinct from macOS Keychain / Windows DPAPI paths used
  elsewhere).
- **macOS-specific**: accessibility permission flow
  (`apps/desktop/src/permissions/MacPermission*.ts`,
  `mac-permission-preload.ts`), macOS window lookup shells out to
  `osascript` rather than a native addon (`overview.md:109`), macOS-specific
  screenshot capture and modifier-pair global shortcut
  (`snapShot/MacSnapShot.ts`, `MacModifierPairShortcutProcess.ts`).
- **Native snapshot workers run out-of-process** — `@crowecawcaw/xa11y`
  (accessibility tree access for screenshot annotation) only runs inside
  forked Node child processes (`SnapShotAccessibilityWorker.ts`,
  `RegionSnapShotWorker.ts`) or a worker thread, never in Electron main, so a
  crash there can't take the app down (`overview.md:105-110`).
- **Packaging**: found only Arch Linux AUR PKGBUILDs in-repo —
  `packaging/aur/t3code-bin/PKGBUILD` (stable) and
  `packaging/aur/t3code-nightly-bin/PKGBUILD` (nightly). README documents
  `winget install T3Tools.T3Code` for Windows and `brew install --cask
  t3-code` for macOS, but no `electron-builder` config or winget manifest is
  checked into this shallow clone — likely generated by CI
  (`.github/workflows/release.yml`, `release-desktop.yml`) or lives in a
  separate winget-pkgs/homebrew-cask submission repo, not in this monorepo.
  Could not find an `electron-builder.yml`/`.json` in the tree at all in
  this shallow clone — desktop build config may be inline in
  `apps/desktop/package.json` or generated; didn't locate it definitively.

## 6. Team/org/cloud

- **T3 Connect** (`docs/internals/t3-connect.md`) is the only multi-user/cloud
  surface found: Clerk-based cloud identity + a relay
  (`infra/relay/`, Cloudflare Worker judging by `Worker` terminology and
  `wrangler`-style migrations dir `infra/relay/migrations/`) that links a
  cloud user account to one or more owned environments and brokers pairing
  credentials. This is **account-to-own-machine linking**, not
  organization/team multi-tenancy — no "org" concept, shared project, or
  hosted multi-tenant server surfaced in docs or contracts searched.
- No README/AGENTS.md/issue-tracker mention of "organization" as a product
  concept found in this clone (repo doesn't ship a GitHub Issues export;
  only the code+docs are available offline). If Programa specifically needs
  "log in as org," t3code's relay model (client-owns-credentials,
  server-mints-scoped-session, relay-never-sees-session-token) is a
  reasonable pattern to borrow but there's no org-scoping precedent to copy
  directly — you'd be extending their per-user link model, not reusing an
  existing org layer.
- Relay observability/ops docs exist (`docs/operations/relay-observability.md`,
  `docs/operations/connect-setup.md`) confirming it's a real production
  service, not a stub.

## 7. Rust components (Resource Monitor)

- `native/resource-monitor/` — standalone Rust binary (`Cargo.toml`:
  `t3-resource-monitor`, edition 2024), single dependency of substance:
  `sysinfo = "0.39.3"` (+ serde/serde_json for the wire format), built with
  `panic = "abort"`, `lto = "thin"`, `codegen-units = 1`, `strip = true`
  (small, crash-isolated binary, not a library).
- **Why Rust, explicitly stated** (`docs/internals/resource-telemetry.md:3-8`):
  "Keeping native collection outside Node isolates collector crashes and
  avoids a Node/Electron addon ABI matrix." I.e., not performance — it's
  process isolation (a crash in the monitor can't take the Electron/Node
  process down) and avoiding native Node addon rebuilds across Electron/Node
  ABI versions. It's driven as a child process over a private protocol,
  same protocol for desktop and CLI/headless server
  (`apps/server/src/resourceTelemetry/ResourceMonitorBinary.ts`).
- **What it does**: continuous or on-demand snapshots of process CPU/memory/IO
  and host power, with independently bounded history (age, snapshot count,
  process-row count, retained bytes — a naive count cap doesn't bound memory
  because command lines vary in size). Linux per-thread (`/proc/<pid>/task/<tid>`)
  enumeration is explicitly disabled because it makes sampling itself
  expensive. Windows process I/O counters include more than disk traffic
  (a documented measurement trap, `resource-telemetry.md:39-40`). Electron
  main separately supplies host power + Electron-process metrics over a
  private inherited pipe, independent of the renderer/RPC connection, so
  power telemetry survives even with no client connected.

## 8. Judgment: what Programa should port, and what to avoid

**Port, ranked by user value:**

1. **Structured provider-event model instead of (or alongside) raw PTY
   passthrough for agent turns.** T3's `session.*/turn.*/item.*/request.*`
   event taxonomy (`packages/contracts/src/providerRuntime.ts`) is the
   single biggest architectural lever here — it's what makes diff review,
   checkpoints, approval UI, notifications, and multi-client sync all
   possible without scraping terminal text. Programa already renders agent
   output through PTY bytes; a typed event layer (even sourced by parsing
   Claude Code's/Codex's own structured hooks/JSON output rather than a raw
   VT stream) would unlock diff review and reliable notification triggers
   that don't depend on regex-matching terminal text.
2. **Environment capability negotiation instead of version-pinned
   client/server assumptions** (`overview.md:21-38`). If Programa moves to
   a client/server split, this pattern (advertise flags, clients branch on
   flags not versions, servers keep emitting legacy fields) avoids forcing
   synchronized client/server releases — directly relevant since Programa
   ships via auto-rolling CI releases already and would otherwise need to
   coordinate app-store review lag against server releases.
3. **DPoP-bound bootstrap credentials for remote pairing**
   (`t3-connect.md`, `environment-auth.md`) — the relay-mints,
   client-redeems-with-proof-key, relay-never-sees-session-token pattern is
   a solid, already-battle-tested design for "log in on phone, reach your
   laptop" without trusting the relay with actual session authority. Worth
   copying almost exactly if Programa builds a phone/companion client.
4. **Checkpointing via hidden Git refs per turn** (`CheckpointStore.ts`,
   `overview.md` "Turn completion and checkpoints") — cheap, git-native
   undo/revert per agent turn without commit pollution; directly reusable
   for a "revert this agent turn" feature, and pairs naturally with
   Programa's existing git-heavy workflows.
5. **Out-of-process, isolated Rust telemetry/native-capability children**
   (`overview.md:105-110`, resource monitor) — the general policy ("new
   native capability goes in a child with a deadline, not an `import` in
   main") is a good rule to adopt verbatim for any future native addon in
   Programa's Swift/AppKit + Ghostty stack, especially cross-platform Rust
   utilities if Programa goes to Windows/Linux.

**Avoid, with reasons:**

1. **Per-compositor Linux screenshot capture sprawl** (GNOME extension +
   KDE/Hyprland/Niri native crates + generic portal path, `apps/desktop/src/snapShot/*`).
   This is a lot of platform-specific surface area (5+ separate
   implementations) for one feature; it's a maintenance tax that only pays
   off once you're already committed to a broad Linux desktop-environment
   matrix. Programa should not replicate this breadth unless/until Linux
   support is a firm commitment, and even then should scope down to the
   generic xdg-desktop-portal path first.
2. **Five-way pull-request provider matrix maintained in-house**
   (GitHub/GitLab/Bitbucket/Azure DevOps/Forgejo, each with both a CLI- and
   API-backed implementation, `apps/server/src/pullRequest/`). Real
   maintenance surface (10 provider files, ongoing API drift risk) for
   modest incremental value beyond GitHub, which is almost certainly what
   matters most for Programa's actual usage; start with GitHub only and
   resist widening until there's clear demand.
3. **WSL-as-a-second-backend architecture on Windows**
   (`apps/desktop/src/wsl/DesktopWslBackend.ts`, WSL server tree, separate
   telemetry gap already documented as a known hole). Running two
   full backend server instances (native Windows + WSL) from one Electron
   shell is architecturally heavy and, per their own docs, has an
   unresolved telemetry gap. If Programa targets Windows, prefer picking
   one execution environment (native Windows via ConPTY, matching their own
   NodePtyAdapter approach) rather than shipping a dual-backend model from
   day one.
