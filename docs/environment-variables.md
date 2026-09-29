# Environment variables

Every `PROGRAMA_*` and `PROGRAMAD_*` variable that Programa's app, CLI, MCP server, shell
integration, scripts and daemon read or set. Variables marked "Debug builds" are compiled out of
Release builds.

## Set in every Programa terminal

Programa exports these into each terminal it spawns. The CLI, shell integration and agent hooks use
them to find the app and the terminal they run in.

| Variable | Meaning |
|---|---|
| `PROGRAMA_SURFACE_ID` | UUID of the surface (terminal) the shell runs in. The CLI uses it as the default `--surface`. |
| `PROGRAMA_PANEL_ID` | The same UUID as `PROGRAMA_SURFACE_ID`, under its older name. |
| `PROGRAMA_WORKSPACE_ID` | UUID of the workspace. The CLI uses it as the default `--workspace` for commands such as `send`, `notify` and `new-split`. |
| `PROGRAMA_TAB_ID` | The same UUID as `PROGRAMA_WORKSPACE_ID`, under its older name. `tab-action` and `rename-tab` use it as the default `--tab`. |
| `PROGRAMA_SOCKET_PATH` | Path of the control socket of the app that started the terminal. See [socket-api.md](socket-api.md#where-the-socket-lives). |
| `PROGRAMA_SOCKET` | The same path, kept for older scripts. |
| `PROGRAMA_BUNDLED_CLI_PATH` | Absolute path of the `programa` CLI inside the app bundle. Set only when that file is executable. |
| `PROGRAMA_BUNDLE_ID` | Bundle identifier of the running app. |
| `PROGRAMA_DEFAULT_BROWSER` | Short key of the system default browser (`chrome`, `safari`, `arc`, ...). Unset when it cannot be resolved. |
| `PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID` | Bundle identifier of the system default browser. Unset when it cannot be resolved. |
| `PROGRAMA_PORT`, `PROGRAMA_PORT_END`, `PROGRAMA_PORT_RANGE` | First port, last port and size of the port range reserved for this terminal. The range comes from `automation.portBase` and `automation.portRange`. |
| `PROGRAMA_SHELL_INTEGRATION` | `1` when shell integration is on (`sidebarShellIntegration`, on by default). |
| `PROGRAMA_SHELL_INTEGRATION_DIR` | Folder that holds the shell integration scripts. |
| `PROGRAMA_ZSH_ZDOTDIR` | The user's original `ZDOTDIR`, which the zsh integration restores after it loads. |
| `PROGRAMA_LOAD_GHOSTTY_ZSH_INTEGRATION`, `PROGRAMA_LOAD_GHOSTTY_BASH_INTEGRATION` | `1` when the integration should also load Ghostty's own zsh or bash integration. |
| `PROGRAMA_FISH_INTEGRATION_FILE`, `PROGRAMA_FISH_USER_CONFIG_ALREADY_LOADED`, `PROGRAMA_FISH_CONFIG_HOME` | Hand-off state between the app and the fish integration. |
| `PROGRAMA_CLAUDE_HOOKS_DISABLED` | `1` when Claude Code integration is off (`automation.claudeCodeIntegration`). The `claude` wrapper then runs the real binary untouched. |
| `PROGRAMA_CUSTOM_CLAUDE_PATH` | Value of `automation.claudeBinaryPath`. The `claude` wrapper runs this binary instead of searching `PATH`. |

The zsh, bash and fish integrations also keep internal state in shell variables named
`_PROGRAMA_*` (git and pull request polling, tty reporting, tmux key syncing). They are not a
configuration surface.

## Control socket and authentication

Read by the app, the CLI and `programa-mcp`. Modes and discovery are described in
[socket-api.md](socket-api.md#security-and-discovery).

| Variable | Read by | Meaning |
|---|---|---|
| `PROGRAMA_SOCKET_PATH` | CLI, MCP, app | Socket path to use. The app honors it for Debug and Staging builds, or when `PROGRAMA_ALLOW_SOCKET_OVERRIDE` is truthy. |
| `PROGRAMA_SOCKET` | CLI, MCP | Second choice for the socket path. `PROGRAMA_SOCKET_PATH` wins when both are set. The app never reads it. |
| `PROGRAMA_SOCKET_PASSWORD` | CLI, MCP, app | Socket password for `password` mode. The CLI checks `--password` first. The app checks it before the saved password file. |
| `PROGRAMA_SOCKET_MODE` | app | Socket mode for this launch: `off`, `cmuxOnly`, `automation`, `password` or `allowAll`. Overrides the setting. |
| `PROGRAMA_SOCKET_ENABLE` | app | `1`/`true`/`yes`/`on` or `0`/`false`/`no`/`off`. `0` turns the socket off regardless of the mode. |
| `PROGRAMA_ALLOW_SOCKET_OVERRIDE` | app | Truthy value lets `PROGRAMA_SOCKET_PATH` move the socket in a Release build or a tagged Debug build. |
| `PROGRAMA_TAG` | app, CLI | Name of a tagged build. The app uses it for the tag badge (at most 10 characters), for the tagged socket path, and to allow a Debug launch. The CLI adds `/tmp/programa-debug-<tag>.sock` to its socket search. An untagged Debug build refuses to launch. |

## Reading by the CLI and its wrappers

| Variable | Meaning |
|---|---|
| `PROGRAMA_PANE_ID` | Default pane target for the tmux-compatible commands when they are given none. |
| `PROGRAMA_COMMIT` | Commit hash the CLI and the About box show when the build has no embedded value. |
| `PROGRAMA_RESPECT_EXTERNAL_OPEN_RULES` | Truthy value makes `programa browser open` apply the `browser.urlsToAlwaysOpenExternally` rules. The `open` wrapper sets it. |
| `PROGRAMA_CLI_TTY_NAME`, `PROGRAMA_TTY_NAME` | Terminal device name that the agent hooks report for the surface. They fall back to `TTY` and `SSH_TTY`. |
| `PROGRAMA_CLAUDE_HOOK_STATE_PATH` | Overrides where the Claude, Codex and OpenCode hooks keep their session state file. |
| `PROGRAMA_CLAUDE_PID` | Process id of the Claude Code instance a hook belongs to. Set by the `claude` wrapper. |
| `PROGRAMA_CLAUDE_HOOK_PROGRAMA_BIN` | `programa` binary the `claude` wrapper's hooks call. |
| `PROGRAMA_CLAUDE_SESSION_ID_CACHE_KEY`, `PROGRAMA_CLAUDE_SESSION_ID_CACHE_VAL` | Session id cache shared between the `claude` wrapper invocations. |
| `PROGRAMA_ORIGINAL_NODE_OPTIONS`, `PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT` | The caller's `NODE_OPTIONS`, saved so the wrappers can restore it. |
| `PROGRAMA_CLAUDE_TEAMS_PROGRAMA_BIN`, `PROGRAMA_CLAUDE_TEAMS_TERM` | `programa` binary and `TERM` for the Claude teams wrapper. |
| `PROGRAMA_OMO_PROGRAMA_BIN`, `PROGRAMA_OMO_TERM`, `PROGRAMA_OMX_PROGRAMA_BIN`, `PROGRAMA_OMX_TERM`, `PROGRAMA_OMC_PROGRAMA_BIN`, `PROGRAMA_OMC_TERM` | The same pair for the OpenCode, Codex and Claude agent wrappers. |
| `PROGRAMA_OPEN_WRAPPER_SYSTEM_OPEN`, `PROGRAMA_OPEN_WRAPPER_DEFAULTS`, `PROGRAMA_OPEN_WRAPPER_PYTHON3` | Paths the `open` wrapper uses for `/usr/bin/open`, `defaults` and `python3`. They exist so tests can substitute fakes. |
| `PROGRAMA_THEME_PICKER_CONFIG`, `_BUNDLE_ID`, `_TARGET`, `_COLOR_SCHEME`, `_INITIAL_LIGHT`, `_INITIAL_DARK` | Set by `programa themes` for Ghostty's `+list-themes` helper so it edits Programa's managed theme override. |

## Set for the notification command

When `notifications.command` runs, Programa sets `PROGRAMA_NOTIFICATION_TITLE`,
`PROGRAMA_NOTIFICATION_SUBTITLE` and `PROGRAMA_NOTIFICATION_BODY` in its environment.

## App behavior and diagnostics

| Variable | Meaning |
|---|---|
| `PROGRAMA_DISABLE_SESSION_RESTORE` | `1` skips session restore at launch. |
| `PROGRAMA_DIAGNOSTICS_LOG` | Overrides the diagnostics log path. The default is `~/Library/Logs/Programa/diagnostics.log`. See [troubleshooting.md](troubleshooting.md). |
| `PROGRAMA_DEBUG_LOG` | Debug builds. Path of the debug event log. Also turns on the background event log. |
| `PROGRAMA_DEBUG_BG` | Debug builds. `1` turns on the background event log. |
| `PROGRAMA_DEBUG_BG_LOG` | Debug builds. Path of the background event log. The default sits next to the debug log with `-bg` before `.log`. |
| `PROGRAMA_TYPING_TIMING_LOGS` | Debug builds. `1` logs typing-path timings. |
| `PROGRAMA_KEY_LATENCY_PROBE` | Debug builds. `1` turns on the verbose key latency probe (and the typing timing logs). |
| `PROGRAMA_FOCUS_DEBUG` | `1` logs focus changes. |
| `PROGRAMA_SHORTCUT_MONITOR_TRACE` | `1` traces the keyboard shortcut monitor. |
| `PROGRAMA_FORCE_OCCLUDED` | Debug builds. `1` makes every terminal behave as occluded, for tests. |
| `PROGRAMA_DEV_MUTATE_WORKSPACE_SELECTION_DURING_CREATION` | `1` or `true` changes the selection while a workspace is created, to exercise a race in tests. |
| `PROGRAMA_RUNTIME_DEBUG_BASE_URL`, `PROGRAMA_RUNTIME_DEBUG_TOKEN`, `PROGRAMA_RUNTIME_DEBUG_SESSION_ID` | All three together point the app at a runtime debug collector. Without all three the feature is off. |
| `PROGRAMA_SESSION_ESCROW_HOLDER_SOCKET` | Socket path handed to the session escrow holder process, so it stays out of the process command line. |
| `PROGRAMA_TEST_FORCE_WINDOW_GLASS`, `_TAB_BAR_GLASS`, `_SIDEBAR_GLASS`, `_OVERLAY_GLASS`, `_BROWSER_TOOLBAR_GLASS` | Force a glass surface on or off for `scripts/run-glass-perf-gate.sh`. |
| `PROGRAMA_UI_TEST_*` | Launch switches that the XCUITest suites in `programaUITests/` pass to the app. The app reads them only under test; the names live in `Sources/AppDelegate+UITest*.swift`. |

## `programad`

The standalone daemon in `core/` is described in `core/docs/programad.md`.

| Variable | Meaning |
|---|---|
| `PROGRAMAD_PASSWORD` | Requires `auth.login` with this password. `--password-file PATH` is the file-based alternative. |

`PROGRAMAD_AUTH_TOKEN`, `PROGRAMA_SOCKET_PASSWORD` and `PROGRAMA_SOCKET_AUTH_TOKEN` are removed
from the environment of every child process the daemon starts. `PROGRAMAD_UNIX_PATH`,
`PROGRAMAD_SOCKET` and `PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD` still appear in
`scripts/reload.sh`, `scripts/reloads.sh`, `scripts/launch-tagged-automation.sh` and the shell
integration, but no app, CLI or daemon code reads them.

## Build, reload and CI scripts

| Variable | Read by | Meaning |
|---|---|---|
| `PROGRAMA_SKIP_ZIG_BUILD` | `reload.sh`, `build-ghostty-cli-helper.sh` | `1` skips the Zig builds. |
| `PROGRAMA_ENSURE_GHOSTTYKIT_COMMAND` | `reload.sh`, `reloadp.sh`, `reloads.sh` | Command to run instead of `scripts/ensure-ghosttykit.sh`. |
| `PROGRAMA_GHOSTTYKIT_CACHE_DIR` | `ensure-ghosttykit.sh` | GhosttyKit cache folder. Default `~/.cache/programa/ghosttykit`. |
| `PROGRAMA_GHOSTTYKIT_LOCK_TIMEOUT`, `PROGRAMA_GHOSTTYKIT_LOCK_POLL_INTERVAL` | `ensure-ghosttykit.sh` | Seconds to wait for the cache lock (default 300) and between polls (default 1). |
| `PROGRAMA_RELOAD_CACHE_MANAGED` | `reload.sh`, `tagged-build-cache.py` | `1` marks a reload that the tagged build cache already wraps. |
| `PROGRAMA_PREBUILT_APP_PATH` | `tests/test_bundled_ghostty_theme_picker_helper.sh` | Path of an already built `Programa DEV.app` to test. |
| `PROGRAMA_DERIVED_DATA_DIR` | CI scripts | DerivedData folder of the job. Required by `run-tests-v2-ci.sh` and `smoke-test-ci.sh`. |
| `PROGRAMA_XCODEBUILD_COMMAND`, `PROGRAMA_SOURCE_PACKAGES_DIR`, `PROGRAMA_SWIFTPM_CACHE_DIR`, `PROGRAMA_TEST_OUTPUT_FILE`, `PROGRAMA_RESULT_BUNDLE_ROOT` | `ci-run-unit-tests.sh` | `xcodebuild` command, Swift package and cache folders, output file and `.xcresult` folder. |
| `PROGRAMA_UNIT_TEST_SCOPE`, `PROGRAMA_UNIT_TEST_SHARD`, `PROGRAMA_UNIT_TEST_SHARD_COUNT`, `PROGRAMA_UNIT_TEST_QUARANTINE` | `ci-run-unit-tests.sh` | Which unit tests to run, and the quarantine list. |
| `PROGRAMA_BUN_COMMAND`, `PROGRAMA_NPM_COMMAND` | `install-create-dmg.sh` | Commands used to install `create-dmg`. |
| `PROGRAMA_LIPO_COMMAND` | `verify-release-architectures.sh` | `lipo` command. |
| `PROGRAMA_ALLOW_MUTABLE_ENCLOSURE` | `sparkle_generate_appcast.sh` | `1` allows a mutable Sparkle enclosure. For local experiments that never publish. |
| `PROGRAMA_PROVISION_PROFILE` | `sign-release-app.sh` | Path of the provisioning profile to embed. Release verification fails without one. |
| `PROGRAMA_WINDOWS_SIGN_SCRIPT` | `build-windows.ps1` | Script that signs the Windows executable. The build ships unsigned when it is unset. |
| `PROGRAMA_CI_BUILD`, `PROGRAMA_CI_COMMIT` | `ci.yml` | Build number and commit passed to `build-windows.ps1`. |
| `PROGRAMA_CLI_BIN` | `tests/test_cli_*.py` | Path of the `programa` CLI binary under test. |
| `PROGRAMA_MCP_BIN`, `PROGRAMA_MCP_E2E` | `tests_v2/test_mcp_server_e2e.py` | Path of `programa-mcp` under test, and the switch for the end-to-end run. |

## Test harness tuning

The Python suites in `tests_v2/` read prefixed knobs for loop counts, timeouts and budgets. Read
the top of each file for names and defaults.

| Prefix | File |
|---|---|
| `PROGRAMA_LAG_*` | `tests_v2/test_workspace_churn_up_arrow_lag.py` |
| `PROGRAMA_REFRESH_COST_*` | `tests_v2/test_text_input_refresh_cost.py` |
| `PROGRAMA_CPU_HARNESS_*` | `tests_v2/test_cpu_occlusion_throttle.py` (see [cpu-harness.md](cpu-harness.md)) |
| `PROGRAMA_SPLIT_2PANE_*`, `PROGRAMA_SPLIT_FUZZ_*` | `tests_v2/test_split_cmd_d_ctrl_d_two_pane_frame_guard.py`, `tests_v2/test_split_cmd_d_ctrl_d_geometry_fuzz.py` |
| `PROGRAMA_PORTAL_ORPHAN_*` | `tests_v2/test_split_cmd_shift_d_ctrl_d_no_portal_orphans.py` |
| `PROGRAMA_WORKSPACE_STRESS_*` | `programaTests/WorkspaceStressProfileTests.swift` |

The `*_ALLOW_MAIN_SOCKET` variants (`PROGRAMA_LAG_`, `PROGRAMA_REFRESH_COST_`,
`PROGRAMA_CPU_HARNESS_`) let a harness run against the default production socket. Leave them unset
unless you mean it.
