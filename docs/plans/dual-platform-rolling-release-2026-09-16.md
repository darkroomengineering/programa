## Functional DAG

```text
.github/workflows/release.yml ──────┐
scripts/release_build_identity.js ┴── derive one build/version/revision ──┐
macOS app ─────────────────────────── build signed/notarized DMG ─────────┤
Windows frontend + build script ───── build Windows EXE ──────────────────┼── seal both platforms ──┐
release candidate/payload modules ─── enforce complete asset contract ────┘                        │
README.md + docs/windows-testing.md ─ document support and local checks ──────────────────────────┼── builds + VM tests + release review
release publication tests ─────────── cover incomplete/mismatched candidates ─────────────────────┘
```

Request: provide `.dmg` and `.exe` assets on the same rolling GitHub release,
document Windows support, match Windows-native behavior, and explain local
Windows testing on the user's Mac.

Release integration is approved for implementation. Existing unrelated
working-tree changes, tab-drag changes, and recovered foundation work must be
preserved. Do not publish a partial release or mix revisions across platforms.

The pipeline will produce stable aliases `programa-macos.dmg` and
`programa-windows.exe`, with matching build-specific payloads in the retained
candidate archive. Both platform builds must succeed before sealing. Existing
macOS signing, notarization, Sparkle, provenance, monotonicity, and publication
serialization protections remain required.

New candidate manifests use a dual-platform schema. Historical macOS-only
manifests remain readable but cannot satisfy the new candidate creation or
promotion requirements. Restore, milestone, dry-run, exact-asset-set validation,
and interrupted-publication handling must follow the same contract.

The release workflow calls `scripts/build-windows.ps1` with `-Version`,
`-Build`, `-Commit`, and `-OutputDirectory`. Its output directory contains only
the stable and build-specific EXEs, which are byte-identical. The executable's
version output must identify the same version/build/commit.

## Windows UI decision

The existing frontend uses GPUI custom-drawn controls with a real Win32 frame
and ConPTY. The user superseded the GPUI choice: Windows will use WinUI 3,
macOS will retain AppKit/SwiftUI, and shared core logic will own application
behavior. GPUI-specific implementation is stopped and preserved as reference.
The dual-platform release contract remains applicable, but its Windows build
script must be migrated before it can ship the selected frontend.

Native frontends own platform controls, input, accessibility, rendering, and
window management. Shared core owns workspace/tab/split semantics, session
lifecycle, commands, and events. Existing core implementations and transport
limits must be inspected before introducing a bridge or duplicating state.
No performance improvement from changing UI frameworks has been measured.

The audit identified missing Windows app shortcuts and visible creation
controls, terminal selection/clipboard, IME hookup, terminal accessibility,
theme/high-contrast behavior, and recoverable shell startup errors. Windows
remains a preview until implemented behavior is exercised on Windows.

## Verification

Release model and black-box publication tests run in an isolated Linux VM,
following the repository's prohibition on host test execution. Windows builds
and runtime checks require Windows CI or a Windows VM. Actual pointer, IME,
theme, DPI, and accessibility checks need a desktop session. Parallels with
Windows 11 Arm can test the x64 release via emulation; physical x64 coverage
remains separate.

No test assertion may be relaxed to hide a regression. Tests that assert the
old four-asset schema must change with the explicit six-asset contract.
