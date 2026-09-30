# Documentation index

## Using Programa

- [keyboard-shortcuts.md](keyboard-shortcuts.md): default shortcuts, action ids and chord syntax for custom bindings.
- [settings-json.md](settings-json.md): every key in `~/.config/programa/settings.json`.
- [programa-json.md](programa-json.md): `programa.json` commands and recipes, the layout schema, and saved layouts.
- [terminal-themes.md](terminal-themes.md): terminal themes, opacity, blur and font.
- [notifications.md](notifications.md): notifications, the sidebar agent indicator, and agent hook examples.
- [troubleshooting.md](troubleshooting.md): log locations, finding the socket, and what to put in a bug report.
- [diagnostics.md](diagnostics.md): the always-on local diagnostics log.
- [environment-variables.md](environment-variables.md): every `PROGRAMA_*` and `PROGRAMAD_*` variable.

## Automation and agents

- [socket-api.md](socket-api.md): the control socket, its security model, discovery, and every method.
- [mcp-server.md](mcp-server.md): the MCP server and its tools.
- [agent-skill.md](agent-skill.md): the installable agent skill.
- [agent-detection-manifests.md](agent-detection-manifests.md): the manifest format for screen-based agent detection.
- [aside-browser.md](aside-browser.md): Programa's browser panel next to the Aside browser.

## Building, testing and releasing

- [testing-layout.md](testing-layout.md): the four test harnesses and how to run them.
- [cpu-harness.md](cpu-harness.md): the CPU occlusion measurement harness.
- [release.md](release.md): how a commit becomes a release, and the required secrets.
- [ghostty-fork.md](ghostty-fork.md): the patches Programa carries on Ghostty and how to update the fork.
- [windows-testing.md](windows-testing.md): testing the Windows build.
- [windows-signing.md](windows-signing.md): signing the Windows executable.

## Removed features

- [removed/README.md](removed/README.md): features deleted on purpose, with what to keep in mind if they return.

## Plans

Design and planning documents. Each starts with a `Status:` line.

- [plans/agent-events.md](plans/agent-events.md): normalized agent lifecycle events.
- [plans/agent-state-unification.md](plans/agent-state-unification.md): one source of agent state and one sidebar indicator.
- [plans/appdelegate-shortcut-coupling.md](plans/appdelegate-shortcut-coupling.md): why shortcut routing stays in `AppDelegate`.
- [plans/core-foundations-resume-2026-09-16.md](plans/core-foundations-resume-2026-09-16.md): recovery log for the core foundation work.
- [plans/core-seam.md](plans/core-seam.md): the seam between the app and a replaceable core.
- [plans/detached-sessions.md](plans/detached-sessions.md): sessions that survive quit and crash.
- [plans/diff-review-panel.md](plans/diff-review-panel.md): the agent diff review panel.
- [plans/dual-platform-rolling-release-2026-09-16.md](plans/dual-platform-rolling-release-2026-09-16.md): macOS and Windows assets on one rolling release.
- [plans/main-window-appkit-ownership.md](plans/main-window-appkit-ownership.md): moving main window ownership to AppKit.
- [plans/native-frontends-shared-core-2026-09-16.md](plans/native-frontends-shared-core-2026-09-16.md): native frontends over one shared core.
- [plans/native-sidebar-owner-experiment.md](plans/native-sidebar-owner-experiment.md): the native sidebar owner experiment and its no-go result.
- [plans/reliability-2026-09-13.md](plans/reliability-2026-09-13.md): the session reliability release.
- [plans/rust-core-concepts.md](plans/rust-core-concepts.md): inventory of concepts a replacement core must reproduce.
- [plans/rust-core-spike.md](plans/rust-core-spike.md): the Rust core spike and its decision.
- [plans/screen-manifest-detection.md](plans/screen-manifest-detection.md): screen-based agent detection.
- [plans/settings-mcp-tools.md](plans/settings-mcp-tools.md): reading and writing settings over the socket and MCP.
- [plans/snapshot-restore.md](plans/snapshot-restore.md): session snapshot history and restore.
- [plans/t3code-inventory.md](plans/t3code-inventory.md): inventory of the t3code project.
- [plans/windows-frontend-tab-drag-2026-09-16.md](plans/windows-frontend-tab-drag-2026-09-16.md): draggable tabs in the macOS and Windows frontends.
- [plans/worktree-and-layouts.md](plans/worktree-and-layouts.md): git worktree workflow and named layouts.
