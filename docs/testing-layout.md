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
