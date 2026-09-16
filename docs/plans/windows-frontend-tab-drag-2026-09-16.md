## Functional DAG

```text
Sources/WindowPaneChromePortal.swift ────────┐
BonsplitPaneChromePortalBridge.swift ───────┼── add native strip drop handling ──┐
PaneContainerView.swift ────────────────────┘                                    │
programaTests/WindowAndDragTests.swift ───────── cover insertion and dispatch ──┤
programa-spike/src/workspace.rs ────────────┐                                    ├── builds + VM tests + review
programa-spike/src/tab_order.rs ────────────┴── finish workspace tab reorder ────┤
programa-spike/src/terminal_view.rs ──────────── select Windows font ────────────┘
```

The user requested draggable tabs within a workspace in both the macOS app and
the Windows frontend. Changes are saved in this checkout and the sibling
`../programa-spike`. No changes are committed or pushed.

The macOS 26 Liquid Glass strip now receives native drops, computes insertion
positions, and shows an accent marker. It reuses Bonsplit's existing reorder and
cross-pane move operations, restricts the new path to the current controller,
honors pinned boundaries, and clears feedback on cancellation or completion.
The existing legacy strip and sidebar workspace dragging remain as before.

The Rust frontend now validates workspace identity and stale/no-op drops. Its
feedback and mutation share the same position resolver. Moving a tab preserves
its terminal entities and split layout, and selection follows the stable tab
ID. Windows uses Consolas; macOS keeps Menlo. Each tab still owns its split
layout in the prototype's single workspace. This is not full macOS feature
parity: settings, socket integration, persistence, packaging, and complete
Windows shortcut behavior remain outside this pass.

Verification:

- Four Rust ordering tests passed in an isolated Linux VM: left/right/end moves
  and stale/self/adjacent rejection. No tests were ignored. The VM was removed
  after saving its results.
- Rust formatting, default check/release build, and optional Ghostty check
  passed on macOS. The existing `block v0.1.6` future-incompatibility warning
  remains.
- The tagged macOS integration app and `programa-unit` test bundle compiled.
  The test bundle was not executed, following the host test policy.
- Independent review found no blockers in either implementation.
- The first working-checkout rebuild reused the integration tag and failed on
  a stale Ghostty precompiled header. The final working-checkout build passed
  with the fresh `workspace-tabs-final` tag. The app was not launched.

Native Windows builds and real pointer dragging on both platforms remain
unverified. The Swift tests cover insertion geometry and callback dispatch,
but not the complete native destination/model interaction. Native Liquid Glass
tests require the macOS 26 SDK/runtime. No assertions were relaxed and no tests
were marked `.only` or newly disabled.

The macOS changes were developed in `/private/tmp/programa-core-foundations`
and applied only after the four source files matched saved baseline hashes.
The Windows changes were built in `/private/tmp/programa-windows-tabs` and
copied back after all original sibling files matched saved hashes. Existing
unrelated edits and recovered foundation work were preserved.
