## Functional DAG

```text
Existing workspace/tab/split behavior ── portable Rust model + commands ──┐
Existing protocol and Swift core seam ── explicit bridge ownership ───────┼── native frontend integration ──┐
WinUI 3 controls + Windows terminal APIs ── Windows presentation adapter ─┤                                │
AppKit/SwiftUI + Ghostty ───────────────── macOS presentation adapter ────┘                                ├── core tests + platform builds + desktop validation
Dual-platform release contract ────────── native Windows EXE packaging ────────────────────────────────────┘
```

# Native frontends, shared behavior

Decision: the user superseded the GPUI direction on September 16, 2026.
Programa uses AppKit/SwiftUI on macOS and WinUI 3 on Windows. The shared core
owns application semantics; frontends own platform presentation and interaction.
This decision targets native behavior, not an unmeasured performance improvement.

## Ownership

| Shared core | Native frontend and platform adapters |
| --- | --- |
| Workspace, tab, pane identifiers and layout state | Windows, controls, menus, dialogs, styling |
| Commands, validation, tab ordering, selection, split rules | Pointer and keyboard translation into commands |
| Session identity and lifecycle policy | ConPTY on Windows; existing macOS terminal integration |
| Agent events, status and persistence policy as extracted | Accessibility, IME, clipboard, terminal drawing |

Views project core state. A tab move changes order without recreating a terminal
session or losing its split tree. Workspace ownership is validated in the core;
native drag affordances do not authorize cross-workspace movement.

## Existing implementation limits

- The sibling `programa-core` contains a portable protocol crate, but its daemon
  is Unix-only and relies on Unix sockets and file-descriptor passing. It is not
  currently a Windows backend.
- The recovered macOS `ProgramaCoreProviding` seam is an in-process Swift facade.
  It still exposes application objects and descriptors, not a portable ABI.
- The GPUI prototype contains reusable terminal/model behavior, but its UI
  ownership must not become the shared core API.
- WinUI supplies native tab and application controls, not a stock terminal
  viewport. Terminal drawing and text accessibility require explicit integration.

## First implementation boundary

Extract the existing tab/split model into a portable Rust crate, with explicit
commands and snapshots. Introduce a narrow versioned C ABI with opaque handles,
documented buffer ownership, error results, and no cross-boundary unwinding.
Use it from a WinUI shell and a macOS adapter before describing the behavior as
shared. Keep the existing macOS renderer and session path working during extraction.

The first executable slice must open a real terminal, create and close tabs,
split panes, and reorder tabs within a workspace while preserving session
identity. A decorative shell or duplicated C# workspace model is insufficient.
Additional agent/browser/persistence capabilities remain migration work and must
not be advertised as implemented by that slice.

## Release and validation

Keep the dual-platform six-asset release contract. Replace the GPUI Windows build
path with a verified WinUI build before publishing it. Investigate unpackaged,
self-contained single-file deployment; native dependency extraction at startup
must be tested, along with version/build/commit reporting from the shipped EXE.

Core tests run in CI or an isolated VM. WinUI builds require Windows tooling;
interactive Windows validation covers tab dragging, ConPTY, IME, DPI, clipboard,
theme changes and accessibility. Windows compilation and automated runtime
checks have passed; desktop interaction tests remain outstanding.

## References

- [Microsoft TabView documentation](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/tab-view)
- [Unpackaged WinUI deployment](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)
- [Native interoperability guidance](https://learn.microsoft.com/en-us/dotnet/standard/native-interop/best-practices)

The stopped GPUI work is archived at
`.claude/native-winui-20260916/gpui-prototype.tgz`; its 17 files were verified
against the archive before removal from the shipping source tree.

## Implementation and verification checkpoint

- Portable domain/FFI: `core/crates/programa-domain` and `programa-ffi`, with
  the contract in `core/ABI.md`. Terminal parsing/PTY ownership is a separately
  buildable `core/crates/programa-terminal` library.
- WinUI: `windows/Programa`, managed runtime tests in `windows/Programa.Tests`.
  Native tabs, within-workspace pane moves, split resize/collapse, localized
  settings, ConPTY/Win2D viewport and native text input are implemented but
  pass Windows compilation and automated runtime checks. Interactive validation
  remains outstanding.
- macOS: `SharedWorkspaceCore.swift` projects the existing pane through shared
  ordering commands; full macOS workspace/session lifecycle migration remains
  separate. Xcode statically links the Rust core through `build-shared-core.sh`.
- Isolated Linux VM: 12 domain tests, 1 FFI test, 6 terminal tests (including a
  real PTY lifecycle) passed, with none skipped. A scratch managed-to-Rust
  executable passed creation, reordering, identity preservation, rejection and
  split checks. The strengthened PTY test also passed independently.
- Tagged macOS app and test bundle compile. No macOS app or UI tests were
  launched locally. Tag: `native-core-winui`.
- Source and verification logs are saved in `.claude/native-winui-20260916`.
- Windows/Linux CI exposed final PTY output loss in `alacritty_terminal`
  0.26.0 under snapshot lock contention. `core/vendor/alacritty_terminal`
  contains the documented minimal patch and a deterministic regression. The
  unpatched regression failed in the isolated VM; the patched regression and
  25 consecutive immediate-shell-exit checks passed. The subsequent shared-core
  GitHub CI job passed on Linux x64.
- User explicitly approved a temporary verification branch as an exception to
  the pre-commit Windows build requirement. Isolated checkout:
  `/private/tmp/programa-native-winui-verify`, branch
  `verify/native-winui-shared-core-20260916`. Main and releases must remain
  untouched. `CI` with `windows_only=true` passed in run
  [35104587262](https://github.com/darkroomengineering/programa/actions/runs/35104587262)
  on `f58e29d58040352d4b4a00afbd0127662e1ba2fd`: 20 Windows Rust tests,
  three managed tests, WinUI publish, version identity and native extraction
  checks. The packaged EXEs are unsigned. macOS CI and desktop interaction
  checks were not run, and no release was published.
