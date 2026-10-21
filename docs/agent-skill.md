# Agent skill

Agents running inside programa (Claude Code, Codex, OpenCode, or anything else that reads Anthropic-style `SKILL.md` files) can drive the app itself, not just the shell inside their own pane — inspect the window/workspace/pane/surface hierarchy, split panes and run commands without stealing the user's focus, read output from a sibling pane, spawn a helper agent, and coordinate with it.

The skill is [`SKILL.md`](../SKILL.md) at the repo root. This page is the longer version — background, the install flow, and the full command reference the skill points at.

## Install

`SKILL.md` gets dropped automatically by the existing integration installers, so a normal `programa claude install-integration` / `programa codex install-integration` / `programa opencode install-integration` is enough — there's no separate skill-install step.

| Tool | Install command | Skill location |
| --- | --- | --- |
| Claude Code | `programa claude install-integration` | `~/.claude/skills/programa/SKILL.md` (or `$CLAUDE_CONFIG_DIR/skills/programa/SKILL.md`) |
| Codex | `programa codex install-integration` | `~/.agents/skills/programa/SKILL.md` |
| OpenCode | `programa opencode install-integration` | `~/.config/opencode/skills/programa/SKILL.md` (or `$OPENCODE_CONFIG_DIR/skills/programa/SKILL.md`) |

Inside a Programa pane, the `claude` wrapper also appends a short system prompt to every Claude Code session telling it to read this skill and prefer worktrees, `race`, `review`, and `wait-surface` where the skill says so, and passes the bundled `programa-mcp` server (see [`mcp-server.md`](mcp-server.md#automatic-setup)). So a session uses these features without the user asking, as long as the skill is installed.

`~/.claude/skills` and `~/.agents/skills` are also both read by OpenCode's own global skill discovery, so running any one of the three installers above already covers OpenCode for most setups — the OpenCode-specific install just makes it explicit and respects `OPENCODE_CONFIG_DIR`.

Uninstalling (`programa claude uninstall-integration`, `programa codex uninstall-integration`, `programa opencode uninstall-integration`) removes the matching copy the same way it already removes hooks/plugin files, and refuses to touch a file that isn't marked as programa-managed.

## Why this exists

Every terminal surface programa creates already exports `PROGRAMA_SURFACE_ID`, `PROGRAMA_WORKSPACE_ID`, and `PROGRAMA_SOCKET_PATH` (see `TerminalSurface.swift`), and the `programa` CLI is already on `PATH`. An agent running in that pane has everything it needs to call the socket API — it just has no reason to know that unless something tells it. The skill is that something.

## Guard

The first thing the skill does is check `PROGRAMA_SURFACE_ID` and `PROGRAMA_SOCKET_PATH`. If either is unset, it stops and reports that it isn't running inside programa — no socket call, no guessed path. This matters because the same `SKILL.md` gets installed globally (`~/.claude/skills/...`) and loaded by every session that tool runs, including ones in a plain Terminal.app window with no programa socket to talk to.

## What the skill covers

- **When to use what**: a table near the top maps situations to features, so an agent reaches for them unprompted: conflicting parallel work goes to a worktree (`programa worktree create`, or `agent_spawn` with `needs_isolation`), competing attempts to `programa race`, a finished diff to `programa review`, long jobs to a split plus `wait-surface`, work the user should watch to a split or `agent_spawn` (naming the pane), a coordinated team to a suggestion that the user restart with `programa claude-teams`, a blocking question from a tool without hooks to `programa rpc agent.needs_input`, and a repeated pane arrangement to `programa layout`.
- **Inspecting your surroundings** — `programa tree` (the hierarchy, with `◀ active`/`◀ here` markers), plus `list-workspaces` / `list-panes` / `list-pane-surfaces` / `identify` / `list-ports` for narrower queries.
- **Splitting and running without stealing focus** — `new-split` / `new-pane` / `new-surface` create UI without moving the user's cursor; `send` / `send-key` / `send-panel` / `send-key-panel` run commands in another pane the same way. Only `focus-pane`, `focus-window`, `focus-panel`, `select-workspace`, and the `next/previous/last-window` triad actually move focus — see the socket focus policy in the root `CLAUDE.md`.
- **Reading a sibling pane** — `read-screen` (alias `capture-pane`), with `--scrollback`/`--lines` for history beyond the visible viewport. `programa handoff --from <ref> [--lines <n>] [--note <text>] [--to <ref>]` pastes a pane's last lines (default 200, max 1000) into a prompt as context without pressing Return; the command palette's "Paste Context From Pane…" does the same for the focused terminal.
- **Spawning and coordinating a helper agent** — split, `send` a command like `claude ...` into the new surface, then read its output and answer it the same way you'd talk to any other pane. `set-status` and `notify` report progress through the sidebar instead of a pane the user isn't looking at.
- **Worktrees**: `programa worktree create <branch> [--base <ref>] [--layout <name>]` opens a branch in its own worktree and workspace without taking focus; `worktree list` and `worktree remove` (never deletes the branch) manage them.
- **Racing**: `programa race "<prompt>" [--n <count>] [--agent <claude|opencode|codex>] [--base <ref>] [--prefix <slug>] [--layout <name>]` starts one agent per worktree on branches `<prefix>/<index>`. It only spawns them; the agent waits on each, compares the branches, merges the winner, and removes the rest.
- **Reviewing a diff**: `programa review open [--workspace <ref>] [--mode uncommitted|branch] [--base-branch <ref>]` opens the review panel beside a terminal without taking focus; `review comment add <file> <line|start-end> <text>`, `review comment list`, and `review send [--preamble <text>]` send line comments into that terminal's agent.
- **Resuming an agent**: `programa resume [--surface <ref>] [--print]` types the resume command for the last Claude Code or Codex session that ended in a pane, once that pane is back at its shell prompt. See [`docs/workspace-interface.md`](workspace-interface.md#resume-an-agent-session).
- **Layouts**: `programa layout save <name>`, `layout apply <name>`, and `layout list` keep named split arrangements (geometry and cwds, not running commands).
- **Waiting**: `wait-surface` gives a server-owned blocking wait on a surface: `--pattern <regex>` resolves when new output matches, `--exit` when the process exits, and `--agent-state <idle|working|blocked|any_change>` when the agent in it reaches that state (the `surface.wait` `agent_state` condition, see `docs/socket-api.md`), each with `--timeout`. If the surface closes first, the wait ends with the `closed` outcome. `prompt-agent` is built on the same condition to send a prompt and wait for the agent to go idle again. The tmux-compatible `wait-for` / `wait-for -S` named-signal rendezvous covers two cooperating processes.
- **Authoring screen-detection manifests for an unsupported agent** — programa's agent-state detection reads a pane's own lifecycle hooks when available (Claude Code, Codex, OpenCode), and otherwise falls back to regex-matching visible screen text against a manifest. For any other agent, `programa agent-detection scaffold <agent-id>` captures the current screen and writes a starter manifest to `~/.config/programa/agent-detection/<agent-id>.json`; fill in its `patterns` arrays, then `programa agent-detection test <agent-id>` to check them against the live screen. `programa agent-detection list` shows every loaded manifest (bundled + your overrides).
- **Reporting a normalized lifecycle event** — `programa agent-event --event <event_type> [--provider <p>] [--session-id <id>] [--workspace <id|ref>] [--surface <id|ref>]` reports one of the structured events documented in `docs/plans/agent-events.md` (`session.started`, `turn.started`, `request.opened`, `user-input.requested`, `turn.completed`, `session.exited`, and the rest) instead of a bare `working`/`blocked`/`idle` string. It's what the shipped Claude Code/Codex/OpenCode hooks call internally; use it directly only if you're wiring a new provider's hook or testing the event path by hand — reach for `set-status` for everything else.
- **Writing a recap** — when the user asks for a summary of a change, write markdown to `.programa/recaps/<slug>.md` and open it with `programa recap open <slug>` (`programa recap list` shows what's saved). The markdown panel renders mermaid diagrams, GitHub-style alerts, and `:::compare` before/after blocks, so the skill tells the agent to reach for those instead of plain prose when they fit.
- **Browser work** — Aside (via its MCP server, or `aside "<task>"` from the shell) handles previews, smoke tests and logged-in sites. `programa aside install-mcp` registers Aside with Claude Code and Codex. See [`docs/aside-browser.md`](aside-browser.md).

## Verifying it

There's no automated test for "does an agent actually behave correctly" — this is prompt content, not code. Manually verify by starting a fresh Claude Code (or Codex/OpenCode) session inside a programa pane with the skill installed and asking it to open a split and tail a dev server log; it should do so via the `programa` CLI, and the user's focus should stay on the pane they were already in.

## Command reference

The skill only covers the commands relevant to agent coordination. For the full CLI surface (tmux-compat commands, hooks) run `programa help`, see [`aside-browser.md`](aside-browser.md) for browser work through Aside, or see [`docs/socket-api.md`](socket-api.md) for the underlying socket API.
