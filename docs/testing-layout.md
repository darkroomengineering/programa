# Where tests live

Four directories, because there are four harnesses. They are not versions of
each other, and `tests_v2` is not "the second attempt at `tests`".

| Directory | Language | Needs a running app? | Run by |
|---|---|---|---|
| `tests/` | shell + python | no | `workflow-guard-tests`, CLI steps in `ci.yml` |
| `tests_v2/` | python | **yes** | `socket-integration-tests`, lag/perf jobs |
| `programaTests/` | Swift (XCTest) | launches its app test host | `unit-tests` (`programa-unit` scheme) |
| `programaUITests/` | Swift (XCUITest) | launches its own | `ui-regressions` |

## What `_v2` means

The v2 **socket API** — the JSON-RPC surface in `Sources/V2CommandCatalog.swift`,
whose methods look like `debug.command_palette.visible` or `snapshot.restore`.
Those tests connect to a running Programa over its control socket and drive the
app through that API. The name is about the protocol, not about a previous
generation of tests. There is no `tests_v1`.

## Which one to write in

**`tests/`** — the thing under test is a script or a build artifact, and no app
is involved. Shell scripts here guard `scripts/*.sh`, the CI workflows, DMG
creation, and release assets. The three python files here drive the `programa`
CLI binary as a subprocess via `PROGRAMA_CLI_BIN`.

**`tests_v2/`** — the thing under test is app behaviour you can observe over the
socket. Everything here talks to a live instance, whether through `cmux.py` or
by speaking JSON-RPC directly. The lag/perf/CPU harnesses live here for that
reason. See `docs/cpu-harness.md` for the CPU measurement harness specifically.

**`programaTests/`** — policy types, decision functions, snapshot encoding,
layout maths, and AppKit integration through the configured app test host.
Cheapest and fastest, so prefer it when a behaviour can be reached this way.
When it cannot, add a small seam so it can, rather than reaching for a socket
test. See the test-quality policy in `CLAUDE.md`.

**`programaUITests/`** — behaviour that only exists through real event
delivery and AppKit: clicks, drags, menus, focus.

## Running them

Per `CLAUDE.md`, tests are **not run locally** — they run on CI or the VM.
`programa-unit` is the local unit-test exception, but it is **app-hosted**:
the project's default `TEST_HOST` points to the untagged Debug app. Use tagged
bundle-name/identifier overrides and isolated derived data with `build-for-testing`,
then inspect a copy of its generated `.xctestrun` before `test-without-building`.
Its `TestHostBundleIdentifier` must match the built tagged app; Xcode can leave
the original identifier in that field. If moving the copy out of `Build/Products`,
resolve its `__TESTROOT__` paths to absolute product paths. Overriding `TEST_HOST`
to the app copied by `reload.sh` fails Xcode's scheme build-graph validation.
Do not run the default untagged test host. XCTest disables WAL/escrow, but the
host can still create windows, start shells, and mutate its own preferences.
`tests_v2` in particular will attach to whatever socket it
finds, which is why running it locally risks driving your real Programa
instance rather than a build under test.

## Display resolution churn regression (`programaUITests`)

`DisplayResolutionRegressionUITests.testRapidDisplayResolutionChangesKeepTerminalResponsive`
churns a virtual display through four resolutions while the app's window sits
on it, and asserts the terminal keeps presenting frames. It never passed on
any green `main` run before 2026-09-17: `ui-regressions` masked its own exit
code until PR #334 (2026-09-16) unmasked it, and every run since then failed
with "Failed to create CGVirtualDisplay" — the step created a second
`CGVirtualDisplay` while the job's own persistent one was still alive, and a
headless CI session only reliably holds one at a time.

Fixed on `macos-26` runners, in order:
- The churn step now attaches to the job's persistent virtual display
  (`--attach-id`) instead of creating a second one.
- The app is externally activated via System Events after launch, since the
  in-process `NSRunningApplication.activate()` call silently fails without a
  real WindowServer frontmost app on headless CI.
- The UI test's own diagnostics file — which the churn step polls for render
  present counts — is refreshed on every
  `NSApplication.didChangeScreenParametersNotification`, the notification
  that fires when a stationary window's screen changes mode underneath it
  (the render path itself already relies on this same notification; the
  diagnostics observer set didn't).

What is still broken, and not fixed here: on `macos-26` runners the app's
window cannot reliably be kept on the virtual display once its mode starts
churning. It lands there once at launch (`targetDisplayMoveSucceeded` in the
launch diagnostics briefly reads `"1"`), but AppKit reassigns the window to
another screen — observed landing back on the real primary display, and once
on no screen at all — as soon as `CGDisplaySetDisplayMode` recalculates the
virtual display's global bounds. A window re-homing pass tied to the same
notification made this worse (moved the window off every screen), not
better, and was reverted.

Because of that, the churn step reads the app's launch diagnostics after
launch and self-skips with `SKIPPED: the runner could not place the app
window on the virtual display; the display churn regression cannot be
exercised here` (exit 0) when `targetDisplayMoveSucceeded` never reaches
`"1"`. When it does reach `"1"` — a runner where placement genuinely works —
the step runs the regression exactly as before, so a real rendering
regression on a working harness still fails the job.
