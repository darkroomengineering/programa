# Core seam

Status: in progress, 2026-09-15. Motivation: `docs/plans/rust-core-spike.md`
("Reframe" section, and step 2 of its "Sequence") and
`docs/removed/ssh-remote-workspaces.md` ("Why removed and what a future
version should do differently") both land on the same conclusion — a future
out-of-process core (local `programad`, later a remote one) should be a
seam the app already has, not a rewrite of the workspace model with
`if isRemote` branches threaded through it. The SSH-remote removal's own
postmortem states the rule directly: "make the RPC contract the product
boundary... keep the remote surface behind one narrow interface instead of
branching the whole workspace model." This plan puts that seam in place now,
years before any process boundary actually moves, so the mistake documented
in that removal cannot recur.

This work does **not** move anything out of process. `InProcessCore` wraps
exactly the code that already runs today. Behavior is unchanged; only the
call path gains one indirection.

## Rule

The UI layer (SwiftUI views, AppKit view controllers, `ContentView.swift`,
`VerticalTabsSidebar.swift`, etc.) calls the seam. The seam's own file
(`Sources/ProgramaCore.swift`) never imports `SwiftUI` or `AppKit` and never
references a view type. `TabManager`, `Workspace`, and `TerminalController`
are orchestration/model layer, not "UI" in this sense, and are expected to
hold a reference to a core and call through it.

## Interface shape

One namespace, several narrow protocols, so a future out-of-process
implementation can adopt them independently instead of one fat interface
that forces every method to become async/RPC on day one:

```swift
enum ProgramaCore {
    protocol GitMetadataProbing {
        func probeInitialWorkspaceGitMetadata(
            directory: String
        ) -> GitMetadataProber.InitialWorkspaceGitMetadataSnapshot
    }

    protocol PortScanning {
        func registerTTY(workspaceId: UUID, panelId: UUID, ttyName: String)
        func unregisterPanel(workspaceId: UUID, panelId: UUID)
        func kick(workspaceId: UUID, panelId: UUID)
        func refreshAgentPorts(workspaceId: UUID, agentPIDs: Set<Int>)
    }

    protocol SessionSnapshotting {
        func load() -> AppSessionSnapshot?
        func loadWithHistoryFallback() -> AppSessionSnapshot?
        func save(_ snapshot: AppSessionSnapshot) -> Bool
    }

    protocol SessionAutosaving {
        func startTimerIfNeeded()
        func stopTimer()
        func recordTypingActivity()
        func requestPromptSave(source: String, after delay: TimeInterval)
    }

    protocol AgentActivityReporting {
        func aggregateState(for workspace: Workspace) -> AgentActivityState?
    }
}

protocol ProgramaCoreProviding {
    var git: ProgramaCore.GitMetadataProbing { get }
    var ports: ProgramaCore.PortScanning { get }
    var sessionSnapshots: ProgramaCore.SessionSnapshotting { get }
    var agentActivity: ProgramaCore.AgentActivityReporting { get }
}

final class InProcessCore: ProgramaCoreProviding {
    static let shared = InProcessCore()
    // each property wraps today's static/singleton implementation.
}
```

`SessionAutosaving` is deliberately left as a per-window-controller object
(`AppDelegate` still owns one `SessionAutosaveCoordinator` instance, not a
core singleton) — see "Session snapshot, autosave, WAL, escrow" below for
why it is not folded into `ProgramaCoreProviding` the same way as the
others.

Every protocol method signature uses only value types and `Codable`
model types already in the codebase (`AppSessionSnapshot`,
`GitMetadataProber.InitialWorkspaceGitMetadataSnapshot`, `AgentActivityState`,
plain `UUID`/`String`/`Set<Int>`) — nothing here requires `ghostty_surface_t`,
an `NSView`, or any AppKit type to cross the seam. That is what makes an
out-of-process implementation (same method, but backed by a socket RPC
instead of a direct call) a drop-in swap later.

## Core-owned concerns

### 1. Git metadata probes

- **Current entry points**: `Sources/TabManager+GitMetadataPolling.swift`
  (`startWorkspaceGitMetadataPollTimer`, `refreshTrackedWorkspaceGitMetadata`,
  `refreshSelectedWorkspaceGitMetadata`); `Sources/TabManager.swift:1373-1397`
  (`scheduleWorkspaceGitMetadataRefresh`, the timer loop that calls
  `GitMetadataProber.initialWorkspaceGitMetadataSnapshot(for:)` off-main);
  `Sources/GitMetadataProber.swift:471` (`initialWorkspaceGitMetadataSnapshot`,
  the actual `git`/`gh` subprocess work).
- **Seam**: `ProgramaCore.GitMetadataProbing.probeInitialWorkspaceGitMetadata(directory:)`.
- **Status**: done (commit 2). `TabManager.scheduleWorkspaceGitMetadataRefresh`
  calls `core.git.probeInitialWorkspaceGitMetadata(directory:)` instead of
  `GitMetadataProber` directly.

### 2. Port scanning

- **Current entry points**: `Sources/PortScanner.swift:17` (`PortScanner`,
  a `@unchecked Sendable` singleton, `registerTTY`/`unregisterPanel`/`kick`
  /`refreshAgentPorts`); called from `Sources/TabManager+GitMetadataPolling.swift:235`
  (`sweepStaleAgentPIDs` → `PortScanner.shared.refreshAgentPorts`) and from
  several other sites (`TerminalSurface.swift`, `TerminalController.swift`)
  not touched in this pass — see "What is not yet behind the seam" below.
- **Seam**: `ProgramaCore.PortScanning`, forwarding straight to
  `PortScanner.shared`.
- **Status**: done (commit 2) for the `TabManager`-owned call site
  (`sweepStaleAgentPIDs`). Other `PortScanner.shared` call sites are
  cataloged, not yet routed — see below.

### 3. Session snapshot / autosave / WAL / escrow

- **Current entry points**:
  - Snapshot read/write: `Sources/SessionPersistence.swift`
    (`SessionPersistenceStore.load`, `.loadWithHistoryFallback`, `.save`).
  - Autosave orchestration: `Sources/SessionAutosaveCoordinator.swift`
    (owned per-`AppDelegate`, not a singleton — see below).
  - WAL: `Sources/SessionWALStore.swift` (`SessionWALStore.shared`,
    `register`/`unregister`/`readFallbackScrollbackText`).
  - Escrow: `Sources/SessionEscrow.swift` (`SessionEscrowClient.shared`,
    `.escrow`/`.retrieve`/`.release`).
- **Seam**: `ProgramaCore.SessionSnapshotting` wraps
  `SessionPersistenceStore`'s three read/write entry points (the ones
  `AppDelegate` and the CLI's `snapshot` commands actually call). The WAL
  and escrow machinery is **not** wrapped in this pass: it is written
  entirely as free functions/singletons parameterized by session id and
  already has no dependency on any specific process boundary (it already
  talks over a Unix-domain socket to a *second* process — the escrow
  holder — today). Folding it into the seam now would just rename call
  sites without changing anything observable; the honest seam-worthy move
  is `SessionSnapshotting`, which is what a UI-layer caller (`AppDelegate`,
  `CLI/CLI+Snapshot.swift` if it exists) actually reaches for.
- **Why `SessionAutosaving` is not a singleton on `ProgramaCoreProviding`**:
  `SessionAutosaveCoordinator` is constructed once per `AppDelegate`
  instance with injected closures (`snapshotProvider`, `saveSnapshot`) that
  close over `AppDelegate`'s own window/workspace state — see its doc
  comment at `Sources/SessionAutosaveCoordinator.swift:56-62` explaining the
  two-phase-init reason for that shape. It is core-owned *conceptually*
  (a future out-of-process core would run its own autosave loop against its
  own state, not the app's), but mechanically it is already the right shape
  to become a protocol conformance without a new global singleton: declaring
  `SessionAutosaveCoordinator: ProgramaCore.SessionAutosaving` records the
  seam membership without disturbing its existing per-`AppDelegate`
  lifetime. Done as a conformance-only change (no call-site rewrite needed
  since `AppDelegate` already goes through its own instance, not a global).
- **Status**: done (commit 3).

### 4. Agent activity state

- **Current entry points**: `Sources/AgentActivityState.swift`
  (`AgentActivityState`, `AgentStateSource`, `Workspace.aggregateAgentState`
  computed property at line 59, `Workspace.hasBlockedAgentSurface` at line 66).
  Writers: `Workspace+SidebarTelemetry.swift`'s `updatePanelAgentState`
  (not modified here — the hook-report *write* path stays on `Workspace`
  itself, since it is workspace-instance state, not a core service).
- **Seam**: `ProgramaCore.AgentActivityReporting.aggregateState(for:)` wraps
  the existing `Workspace.aggregateAgentState` computed property. This is
  the thinnest possible wrap: the aggregation logic
  (`AgentActivityState.aggregating(with:)`) is pure and already lives
  outside any specific process, so the seam here is purely a routing
  exercise — proof that a *read* of core-owned per-surface state can go
  through the same interface as everything else, even though today's
  "read" is a same-process property access.
- **Status**: done (commit 4).

### 5. PTY / child process lifecycle

- **Current entry points**: `Sources/TerminalSurface.swift:1239`
  (`createSurface(for:)`, calls `ghostty_surface_new` synchronously on the
  main actor with a raw `NSView*`), `Sources/TerminalSurface.swift:1088`
  (`teardownSurface()`), `Sources/TerminalSurface.swift:2843` (`deinit`).
- **Decision: not done, plan only.** `docs/plans/detached-sessions.md`
  section 2.1 already establishes that PTY/child lifecycle is
  synchronous-on-main-actor and wired directly to a specific `NSView*` at
  `ghostty_surface_new` call time — there is no indirection layer between
  "a Ghostty surface" and "a specific window's view" today. Introducing a
  `ProgramaCore.SurfaceLifecycle` protocol here would require either (a)
  making `createSurface`/`teardownSurface` reachable from something other
  than `TerminalSurface` itself (a real refactor of the view/model coupling
  in that file, touching the exact call graph that produces keystrokes),
  or (b) a protocol whose only conformance takes an `NSView` parameter,
  which would violate this doc's own "the seam never imports AppKit" rule
  and give a future out-of-process core a method signature it can never
  implement. Per the task's own instruction: only do this "if it can be
  done without touching the typing-latency paths listed in CLAUDE.md
  (`WindowTerminalHostView.hitTest`, `NSWindow.programa_sendEvent`,
  `TabItemView`, `TerminalSurface.forceRefresh`)". `createSurface` and
  `teardownSurface` are not literally those four functions, but they are
  immediately upstream of them in the same file, guarded by the same
  "no allocations, file I/O, or formatting" discipline documented at
  `TerminalSurface.forceRefresh()`, and `TerminalSurface` is already ~2,900
  lines of tightly-coupled AppKit/Ghostty/session-machinery code with no
  existing seam to lean on. A rushed extraction here risks exactly the kind
  of typing-latency regression CLAUDE.md exists to prevent, for a
  refactor with zero behavior change and no near-term out-of-process
  consumer.
- **What a future slice should do instead**: introduce
  `ProgramaCore.SurfaceLifecycle` with signatures shaped around already-
  process-boundary-safe primitives — session id (`String`), working
  directory (`String?`), and a byte-stream handle — mirroring what
  `SessionEscrowClient`/`SessionWALStore` already pass across their own
  Unix-domain-socket boundary today. Concretely: `createSurface`'s job
  splits into "resolve a PTY fd + child pid for this session id" (core-side,
  socket-shaped, exactly what escrow retrieval already does in
  `SessionEscrowClient.retrieve`) and "hand that fd to a Ghostty surface
  bound to a specific `NSView`" (app-side, stays exactly where it is). The
  natural seed for this is `TerminalSurface.resolveSessionWALIdentity`
  (`Sources/TerminalSurface.swift:1853`) and `attemptSessionEscrow`
  (`Sources/TerminalSurface.swift:1960`), which already resolve
  `childPID`/`ptyPath` from a live surface — a future slice can extend
  that same resolution path in reverse (core hands the app an fd; app
  binds it to a view) without re-touching the keystroke-hot code in this
  file. Do this only once there is a real second core implementation to
  validate the split against; a same-process-only "seam" here has no way
  to prove it drew the line in the right place.

## What is not yet behind the seam (explicit follow-ups)

- `PortScanner.shared` is still called directly from `TerminalSurface.swift`
  and `TerminalController.swift` (the `surface.report_tty`/`surface.ports_kick`
  socket handlers). Routing those through `ProgramaCore.PortScanning` is
  mechanical (same signatures) but was left out of commit 2 to keep that
  commit's diff reviewable and to respect the "off-limits" list — several of
  those call sites are adjacent to files other agents own
  (`AgentScreenDetectionEngine.swift`, `TerminalController+AgentDetection.swift`).
- `Workspace+SidebarTelemetry.swift`'s `updatePanelAgentState` (the *write*
  side of agent activity state) still writes directly to
  `Workspace.panelAgentStates`. Only the *read* side
  (`aggregateAgentState`) is behind the seam. A future core that owns agent
  detection out-of-process would need the write side wrapped too, but that
  write path is a workspace-instance mutation driven by CLI+Hooks.swift,
  which is off-limits territory adjacent to files this task must not touch.
- `SessionWALStore`/`SessionEscrow` are not wrapped (see "Session snapshot"
  above for why) — they already look like the shape a core RPC boundary
  would take, so wrapping them today would be renaming, not seaming.
- PTY/child lifecycle (see step 5 above): planned, not started.

## Commits

1. `docs: plan the core seam` — this file.
2. `refactor: route git probes and port scanning through the core seam` —
   `Sources/ProgramaCore.swift` (new), `Sources/TabManager.swift`,
   `Sources/TabManager+GitMetadataPolling.swift`.
3. `refactor: route session snapshot persistence through the core seam` —
   `Sources/ProgramaCore.swift`, `Sources/AppDelegate.swift`,
   `Sources/SessionAutosaveCoordinator.swift`.
4. `refactor: route agent activity state through the core seam` —
   `Sources/ProgramaCore.swift`, one read call site.
