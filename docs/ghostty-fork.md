# Ghostty Fork Changes (Darkroom Engineering/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) In `ghostty/`, branch off the SHA the parent repo pins, not off the fork's `main`. The fork's
   `main` is far ahead of the pin.
2) Commit and push the branch to `origin`, which is the Darkroom Engineering ghostty fork.
3) Update this file with the new change summary and conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

The pinned fork head is `bccfc8333fecf707dd918d46e3849fc8ed72cca0` on fork `main`. It is built on
`ghostty-org/ghostty` `main` at `c8634f3fce12f8189ed058e018195eb693f8562b` and Zig 0.16.0, and
carries the ten patch groups below: display-link restart, resize stale-frame mitigation, OSC 99
notifications, theme picker hooks, color scheme mode 2031, keyboard copy mode selection API,
layer-background flag, occluded-surface throttle, offscreen renderer realization, and session
introspection and revival APIs (which include the PTY tee).

Prebuilt framework for the pinned head:

- Release: `xcframework-bccfc8333fecf707dd918d46e3849fc8ed72cca0`
- Asset SHA-256: `26441b6e038523b9c6223bfbb73535a727d5c7c26c225326dc85122bda30881f`

### 1) macOS display link restart on display changes

- Commit: `05cf31b38` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 2) macOS resize stale-frame mitigation

The resize commits are grouped by feature because they touch the same stale-frame replay path and
tend to conflict together during rebases.

- Commits:
  - `a3588ac53` (macos: reduce transient blank/scaled frames during resize)
  - `9ba54a68c` (macos: keep top-left gravity for stale-frame replay)
- Files:
  - `pkg/macos/animation.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
- Summary:
  - Replays the last rendered frame during resize and keeps its geometry anchored correctly.
  - Reduces transient blank or scaled frames while a macOS window is being resized.

### 3) OSC 99 (kitty) notification parser

- Commits:
  - `2033ffebc` (Add OSC 99 notification parser)
  - `a75615992` (Fix OSC 99 parser for upstream API changes)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.
  - Adapts the parser to upstream's newer capture API so the Programa OSC 99 hook survives the March 30 upstream sync.

### 4) Programa theme picker helper hooks

- Commits:
  - `1da7281fd` (Add Programa theme picker helper hooks)
  - `ea482b73e` (Fix Programa theme picker preview writes)
  - `c7ab66056` (Improve Programa theme picker footer contrast)
  - `c49f69f7b` (Respect system theme in Programa picker)
  - `599b0ff43` (Skip theme detection in Programa picker)
  - `b75388d95` (Match Ghostty theme picker startup)
  - `f985d2d04` (Harden Programa theme override writes)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so Programa can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a Programa-managed mode via env vars, writing the Programa theme override file and posting the existing Programa reload notification for live app-wide preview.
  - Keeps the preview UI readable in light mode, matches upstream picker startup behavior, and hardens writes to the Programa-managed theme override file.

### 5) Color scheme mode 2031 reporting

- Commits:
  - `2be58ee0e` (Fix DECRPM mode 2031 reporting wrong color scheme)
  - `74709c29b` (Send initial color scheme report when mode 2031 is enabled)
- Files:
  - `src/Surface.zig`
  - `src/termio/stream_handler.zig`
- Summary:
  - Keeps Ghostty's mode 2031 color-scheme response aligned with the surface's actual conditional state after config reloads.
  - Sends the initial DSR 997 report as soon as mode 2031 is enabled, which Programa relies on for immediate color-scheme awareness.

### 6) Keyboard copy mode selection C API

- Commit: `0b231db94` (Re-export Programa selection APIs removed from upstream)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Restores `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection`.
  - Keeps Programa keyboard copy mode working against the refreshed Ghostty base after upstream removed those exports.

### 7) macos-background-from-layer config flag

- Commit: `ae3cc5d29` (Restore macOS layer background hook)
- Files:
  - `src/config/Config.zig`
  - `src/renderer/generic.zig`
- Summary:
  - Adds a `macos-background-from-layer` bool config (default false).
  - When true, sets `bg_color[3] = 0` in the per-frame uniform update so the Metal renderer skips the full-screen background fill.
  - Allows the host app to provide the terminal background via `CALayer.backgroundColor` for instant coverage during view resizes, avoiding alpha double-stacking.
  - Replays the layer-background restore on top of the refreshed Ghostty base so Programa keeps the resize-coverage fix after the upstream sync.

### 8) Occluded-surface frame-generation throttle

- Commit: `08bac45e9` (perf(renderer): throttle instead of skip frame generation for occluded surfaces)
- Files:
  - `src/renderer/Thread.zig`
- Summary:
  - `renderCallback` calls `updateFrame` on every wakeup (every PTY output burst), even for surfaces the app has told us are fully occluded. That call locks the terminal mutex, consumes dirty tracking, and rebuilds render state, which is the dominant idle-CPU cost for hidden-but-busy surfaces such as background agent panes.
  - A hard skip of `updateFrame` while occluded is wrong: part of the scrollbar state machine lives inside `updateFrame` (`scrollbar_dirty` is set there in generic.zig but cleared only inside `drawFrame`), and `drawFrame` is also gated off while invisible. With every surface permanently occluded (as on CI's virtual display), `ghostty_surface_read_text` (locks `renderer_state.mutex`; used by the app's socket event-subscription polling) hangs indefinitely.
  - The implementation throttles instead of skipping: both upstream call sites, `renderCallback` and `renderNow`, run `updateFrame` on every wakeup while visible and at most once per `OCCLUDED_UPDATE_INTERVAL_MS` (250ms / 4Hz) while occluded. The monotonic timestamp resets on the visible-to-occluded transition so the first occluded update fires immediately. This keeps renderer and Kitty-animation state moving forward without restoring the hard-skip deadlock.
  - `drainMailbox`'s `.visible` false→true transition still calls `renderer.markDirty()` to force one full rebuild at un-occlude, unchanged from the original skip implementation. Terminal-side dirty tracking is level-triggered (bits accumulate until consumed; dimensions/viewport compared directly), so this remains correctness-optional but cheap insurance against renderer-side cache staleness.

### 9) Offscreen renderer realization API

- Commits:
  - `858e257f0` (add `ghostty_surface_set_renderer_realized`)
  - `d39ba5d84` (return the renderer-mailbox enqueue result)
  - `5697db813` (make the enqueue non-blocking)
- Files:
  - `include/ghostty.h`
  - `src/apprt/embedded.zig`
  - `src/renderer/Thread.zig`
  - `src/renderer/message.zig`
- Summary:
  - Lets the embedder release an occluded surface's Metal swap chain and IOSurfaces while leaving its PTY, terminal state, and scrollback alive.
  - Recreates the renderer before the surface is shown again.
  - Uses a non-blocking mailbox push and reports whether it was enqueued, so Programa never stalls the main actor or advances its mirror state after a dropped message.

### 10) Programa session introspection and revival APIs

- Commit: `96316fc50` (reconcile Programa session APIs on fork main)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/termio/Exec.zig`
- Summary:
  - Restores read-only child PID, PTY path, and PTY master-fd accessors used by Programa's durable session machinery.
  - Restores surface revival through an existing PTY master fd and running child PID without taking ownership of or signaling that process.
  - Programa uses the fork's `ghostty_surface_set_pty_tee_cb` callback for its session WAL. That callback runs before VT parsing. There is no separate output-tap API.

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

### zsh prompt redraw follow-ups

- Were local in the fork as `8ade43ce5`, `0cf559581`, `312c7b23a`, and `404a3f175`.
- Dropped during the March 30, 2026 rebase because newer Ghostty prompt-marking changes on the refreshed base superseded these fork-only zsh redraw patches, so Programa no longer carries them separately.

### initial focus seeding and DECSET 1004 startup behavior

- The older Programa-only surface-config plumbing was local as `c19c82bfd` and
  was dropped when Programa returned to post-create focus synchronization.
- The reconciled tree preserves the current core behavior: surfaces start with
  Ghostty's default focused state, a later host focus callback reports real
  transitions, and enabling DECSET 1004 immediately reports the terminal's
  current focus state before subsequent transition reports.

## Merge conflict notes

When syncing with upstream, re-check these areas.

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser and keep
    the newer `capture`/`captureTrailing()` API usage intact.

- `src/terminal/osc/parsers.zig`
  - Ensure `kitty_notification` stays imported after upstream parser reorganizations.

- `src/cli/list_themes.zig`
  - Programa now relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    If upstream reorganizes the preview loop or key handling, re-check the Programa mode path and keep the
    stock Ghostty behavior unchanged when the Programa env vars are absent.

- `build.zig`
  - Upstream's new wasm/libghostty work touched the same build graph. Keep the Programa-only `cli-helper`
    step wired in without regressing the upstream `lib-vt` or wasm build paths.

- `include/ghostty.h`, `src/Surface.zig`, `src/apprt/embedded.zig`, `src/termio/Exec.zig`
  - Upstream removed Programa-used selection exports. Preserve the re-exported
    `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection` functions.
  - Preserve the child/PTY accessors and revival configuration described in section 10.
    If upstream changes subprocess ownership or watcher semantics, revived processes must
    remain non-owned: Programa may observe their exit but Ghostty must never signal them.
  - Prefer the current PTY tee callback over reintroducing the retired output-tap API.

- `src/renderer/generic.zig`
  - The `macos-background-from-layer` check sits next to the glass-style check in `updateFrame`.
    If upstream refactors the bg_color uniform update or the glass conditional, re-check that both
    paths still zero out `bg_color[3]` correctly.

- `src/Surface.zig`, `src/apprt/embedded.zig`, `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
  - Keep host focus callbacks aligned with the core surface state. If upstream
    refactors surface creation or focus synchronization, re-check the initial
    DECSET 1004 report and later transition reports together.

- `src/renderer/Thread.zig`
  - The occluded-render throttle guards both current `updateFrame` call sites,
    `renderCallback` and `renderNow`. On future syncs, apply the same throttle to
    every new caller. Do not go back to a hard `flags.visible` skip; see section
    8 for why that broke `ghostty_surface_read_text` polling on CI's
    permanently occluded virtual display. Keep the `markDirty()` force on the
    occluded-to-visible transition in `drainMailbox`.

- `src/termio/stream_handler.zig`
  - Keep DECSET 1004 aligned with the terminal's current focus flag. Enabling
    the mode reports the current state immediately; later `CSI I` / `CSI O`
    reports follow actual focus transitions.

If you resolve a conflict, update this doc with what changed.

## Fork history

Notes for maintainers who need the chronology behind the current state.

- The fork's `main` once lacked the accessor and revival changes that older Programa commits carried
  on a temporary feature branch, because those commits reached `main` only through
  retain-ancestry merges. `96316fc50` reconciled those required APIs onto the actual fork `main`
  tree.
- `bccfc8333` reconciled the fork with `ghostty-org/ghostty` `main` (August 21, 2026), moved it to
  Zig 0.16.0, and brought in upstream's complete Kitty graphics implementation (validation and
  deletion fixes, relative placements, margin clipping, animation parsing, storage and playback,
  and renderer-driven frame scheduling).
- The occluded-render hard skip (`c25020f99`) was pinned and reverted on August 4, 2026 because
  of the `ghostty_surface_read_text` hang described in section 8. The throttle (`08bac45e9`)
  landed on August 5, 2026. Its merge gate was three consecutive green CI runs, because the
  failure mode was probabilistic and one green run is not enough evidence. A separate use-after-free through
  stale surface userdata in the `.scrollbar` mailbox path was found and fixed app-side during
  that investigation.

### August 21, 2026 upstream sync

The August 21, 2026 upstream reconciliation had literal conflicts in:

- `src/Surface.zig`
- `src/cli/list_themes.zig`
- `src/cli/toggle_quick_terminal.zig`
- `src/config/url.zig`
- `src/crash/dir.zig`
- `src/font/shaper/coretext.zig`
- `src/os/TempDir.zig`
- `src/renderer/generic.zig`
- `src/termio/Termio.zig`

Semantic reconciliation was also required in `src/App.zig`,
`src/apprt/embedded.zig`, `src/config/CApi.zig`, and
`src/renderer/Thread.zig`. The important resolutions were:

- Migrate fork APIs to Zig 0.16's explicit `std.Io` mutex, event, environment,
  file, mailbox, resize, and allocator interfaces without removing exports.
- Preserve manual IO, mobile render-grid and tmux hooks, PTY tee and revival,
  selection and process accessors, layer-background alpha behavior, renderer
  realization, display-link restart, and resize fixes.
- Export render-grid rows through `pagePreservingState` so compressed
  scrollback is decoded at most once per page without changing PageList storage.
- Apply the 4 Hz occlusion throttle to every upstream `updateFrame` caller and
  retain `markDirty()` when a surface becomes visible.
- Keep the upstream Kitty graphics animation scheduler active through the
  throttle rather than restoring upstream's hard invisible skip.
