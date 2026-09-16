# Testing Programa on Windows

Test the actual Windows release executable on Windows. A successful macOS
build or cross-compile does not verify Windows keyboard input, rendering,
accessibility, or window behavior.

## Local testing from an Apple Silicon Mac

Use Windows 11 Arm in Parallels Desktop, with a Parallels version that supports
your host macOS. Parallels provides a Windows installation assistant and
virtualized graphics. Windows licensing is separate.

Windows 11 Arm can run x64 applications through emulation, so you can test the
same x64 executable distributed by Programa. This is useful for local
iteration; also verify releases on an x64 Windows PC before claiming native
x64 hardware coverage.

Sources: [Parallels Windows 11 guide](https://www.parallels.com/products/desktop/microsoft-authorized-solution-windows-11-arm/),
[Microsoft x64 emulation documentation](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation).

UTM is another VM option, but validate its Windows graphics support before
using it as a UI test environment. Its newer Triton graphics work is evolving;
a VM without a working accelerated graphics stack is a poor reference for
terminal rendering or latency. See the [UTM graphics development notes](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/).

## Test the release artifact

1. For unreleased changes, download the Windows artifact from the relevant
   GitHub Actions run. Use the build from the commit under review.
2. For a published release, download `programa-windows.exe` from the
   [rolling release](https://github.com/darkroomengineering/programa/releases/tag/rolling).
3. Copy it into the Windows VM and run it there. Record the release version,
   build number, commit, Windows version, CPU architecture, graphics driver,
   and display scaling with the test results.
4. Keep a Windows terminal open to capture diagnostic output when a launch or
   shell session fails. Use the same executable for every comparison.

The WinUI build bundles the Windows App SDK, .NET runtime, and Rust libraries.
Test the single downloaded EXE in a fresh folder on a clean Windows VM, with
no developer runtime or adjacent DLLs. Check first-launch extraction, a second
launch, and `--version`/`--verify-native-libraries` before testing the UI.

The rolling aliases are `programa-macos.dmg` and `programa-windows.exe`.
Retained candidate releases contain the build-specific filenames, allowing
the exact tested bytes to be recovered after rolling advances.

## Required interaction checks

| Area | Check |
| --- | --- |
| Window frame | Alt+Space system menu, minimize/maximize/restore/close, caption double-click, resize borders, Windows 11 snap layouts, taskbar and Alt+Tab |
| Displays | 100%, 125%, 150%, and 200% scaling; move between monitors with different scaling; reconnect a display |
| Tabs | Create, select, close, reorder first/middle/last, cancel a drag, reject another workspace's drop, preserve the terminal session and split layout |
| Splits | Create both orientations, resize, focus each pane, preserve terminal dimensions and input routing |
| Keyboard | Windows shortcuts, terminal Ctrl+C/D/W, navigation keys, function keys, US and AltGr layouts; no interception of Windows-reserved shortcuts |
| Text input | Japanese/Chinese/Korean IME composition, candidate placement, committed text, dead keys, accents, emoji, wide and combining characters |
| Clipboard | Selection, copy, paste, multiline paste, bracketed paste, context menu, clipboard sharing with the Mac |
| Appearance | Windows light/dark mode, contrast themes, readable selection/cursor, font fallback, theme changes while running |
| Accessibility | Keyboard-only navigation, visible focus, Narrator labels and terminal text, selection/cursor announcements, usable control sizes |
| Lifecycle | Shell startup failure, normal shell exit, app close with live sessions, repeated tab open/close, no orphaned child processes |

Use [Accessibility Insights for Windows](https://accessibilityinsights.io/docs/windows/overview/)
and Narrator alongside manual input checks. Microsoft's
[accessibility testing guidance](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-testing)
describes the relevant tools and test methods.

## What automation proves

GitHub Actions should build the executable and run Windows unit/integration
tests. Release tests must reject missing platform assets, mismatched versions
or commits, and aliases whose bytes differ from their build-specific payloads.
Interactive checks above need a Windows desktop session; passing a headless
build does not establish UI parity or accessibility compliance.

Record actual results and unresolved failures. Do not mark a check as passed
because the underlying UI framework supports it: Programa must connect and
exercise that behavior itself.

## Current verification status

The [verification run on September 16, 2026](https://github.com/darkroomengineering/programa/actions/runs/35104587262)
passed on commit `f58e29d58040352d4b4a00afbd0127662e1ba2fd`. Windows CI passed
20 Rust tests (including a real ConPTY lifecycle and the focused terminal read
regression), three managed tests, WinUI compilation and single-file publishing,
the exact version check, and extraction/loading of both native libraries.
The artifact contains byte-identical stable and build-numbered EXEs. The EXE
is unsigned; no Windows publisher-signing certificate is configured.

The macOS app and its test bundle compile with the shared ordering adapter.
Mac test jobs were deliberately excluded from this Windows verification run;
no desktop UI was launched. The dependency regression run intentionally filters
its other upstream unit tests, and its large reference-fixture suite is not
vendored. No test assertions were relaxed.

This is a CI artifact, not a published release. GPU rendering, drag behavior,
IME, Narrator, and clean-machine deployment still need the interactive checks
above. Full macOS feature parity and migration of macOS workspace/session
lifecycle into the shared core remain incomplete.
