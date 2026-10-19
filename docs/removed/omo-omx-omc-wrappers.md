# omo, omx and omc agent wrappers

Removed 2026-10-19. Last present at commit ab2e3c394b. Restore with `git checkout ab2e3c394b -- CLI/CLI+AgentWrappers.swift CLI/CLICommandDispatcher.swift CLI/programa.swift Resources/Localizable.xcstrings docs/environment-variables.md tests_v2/test_tmux_compat_geometry.py`. Those files have changed since, so prefer `git show ab2e3c394b:<path>` and copy the removed pieces back by hand.

## What it did

Three CLI commands launched a third-party agent add-on inside a Programa terminal and turned the add-on's tmux panes into Programa splits:

- `programa omo [opencode-args...]` ran OpenCode with the oh-my-openagent plugin (npm package `oh-my-opencode`).
- `programa omx [omx-args...]` ran Oh My Codex (`omx`, npm package `oh-my-codex`).
- `programa omc [omc-args...]` ran Oh My Claude Code (`omc`, npm package `oh-my-claude-sisyphus`).

Each command put a private `tmux` shim first on `PATH`. The shim answered `tmux -V` locally and forwarded everything else to `programa __tmux-compat`, so the add-on's team mode, HUD and agent panes became Programa workspaces and splits. They shared one launcher (`runAgentWrapper`) with `programa claude-teams`, which stays.

Command-specific parts:

- `omo` wrote a shadow OpenCode config under `~/.programa/omo-config` (the user's `opencode.json` plus the plugin entry, a symlink to the user's `node_modules`, its own `package.json` pinning `oh-my-opencode` to an exact version, and a `tmux` block with smaller pane minimum widths), installed the plugin with bun or npm on first run, and pointed `OPENCODE_CONFIG_DIR` at it. It picked an `OPENCODE_PORT` (4096 if free, else a free loopback port) and passed `--port` to OpenCode. Its shim directory also held a `terminal-notifier` shim that routed notifications to `programa notify`.
- `omc` also injected the `NODE_OPTIONS` restore module that `claude-teams` uses, because it wraps Claude Code.
- Environment overrides: `PROGRAMA_OMO_PROGRAMA_BIN`, `PROGRAMA_OMO_TERM`, `PROGRAMA_OMX_PROGRAMA_BIN`, `PROGRAMA_OMX_TERM`, `PROGRAMA_OMC_PROGRAMA_BIN`, `PROGRAMA_OMC_TERM`.

## Files removed and files edited

No files were deleted. The wrappers were cut out of `CLI/CLI+AgentWrappers.swift` (about 670 lines), the three dispatch cases in `CLI/CLICommandDispatcher.swift`, the command descriptors and the local-command list in `CLI/programa.swift`, the `cli.omo.usage`, `cli.omx.usage` and `cli.omc.usage` strings in `Resources/Localizable.xcstrings`, the environment variable row in `docs/environment-variables.md`, and a stale `PROGRAMA_OMO_PROGRAMA_BIN` assignment in `tests_v2/test_tmux_compat_geometry.py`. The shared launcher lost the hooks only `omo` used (plugin setup, port selection, not-found check).

## What we learned

No test or doc covered these commands, so nothing verified them after the add-ons changed upstream. The `omo` plugin version was pinned (5.1.7) on purpose: a floating `latest` would run every new npm release's install scripts as the user, so bump a pin only after reviewing the release. The `tmux -V` probe has to be answered without a socket connection, and only when `-V` or `-v` is the first argument; `split-window -v` is a vertical split. Machines that ran `omo` keep `~/.programa/omo-config`; nothing deletes it.

## Why removed

The commands were undocumented and untested, and the regular `programa claude`, `codex` and `opencode` integrations cover the supported agent flows.
