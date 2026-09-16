# Agent skill

Agents running inside programa (Claude Code, Codex, OpenCode, or anything else that reads Anthropic-style `SKILL.md` files) can drive the app itself, not just the shell inside their own pane — inspect the window/workspace/pane/surface hierarchy, split panes and run commands without stealing the user's focus, read output from a sibling pane, spawn a helper agent, and coordinate with it.

The skill is [`SKILL.md`](../SKILL.md) at the repo root. This page is the longer version — background, the install flow, and the full command reference the skill points at.

## Install

`SKILL.md` gets dropped automatically by the existing integration installers, so a normal `programa claude install-integration` / `programa codex install-hooks` / `programa opencode install-integration` is enough — there's no separate skill-install step.

| Tool | Install command | Skill location |
| --- | --- | --- |
| Claude Code | `programa claude install-integration` | `~/.claude/skills/programa/SKILL.md` (or `$CLAUDE_CONFIG_DIR/skills/programa/SKILL.md`) |
| Codex | `programa codex install-hooks` (alias `install-integration`) | `~/.agents/skills/programa/SKILL.md` |
| OpenCode | `programa opencode install-integration` | `~/.config/opencode/skills/programa/SKILL.md` (or `$OPENCODE_CONFIG_DIR/skills/programa/SKILL.md`) |

`~/.claude/skills` and `~/.agents/skills` are also both read by OpenCode's own global skill discovery, so running any one of the three installers above already covers OpenCode for most setups — the OpenCode-specific install just makes it explicit and respects `OPENCODE_CONFIG_DIR`.

Uninstalling (`programa claude uninstall-integration`, `programa codex uninstall-hooks`, `programa opencode uninstall-integration`) removes the matching copy the same way it already removes hooks/plugin files, and refuses to touch a file that isn't marked as programa-managed.

## Why this exists

Every terminal surface programa creates already exports `PROGRAMA_SURFACE_ID`, `PROGRAMA_WORKSPACE_ID`, and `PROGRAMA_SOCKET_PATH` (see `TerminalSurface.swift`), and the `programa` CLI is already on `PATH`. An agent running in that pane has everything it needs to call the socket API — it just has no reason to know that unless something tells it. The skill is that something.

## Guard

The first thing the skill does is check `PROGRAMA_SURFACE_ID` and `PROGRAMA_SOCKET_PATH`. If either is unset, it stops and reports that it isn't running inside programa — no socket call, no guessed path. This matters because the same `SKILL.md` gets installed globally (`~/.claude/skills/...`) and loaded by every session that tool runs, including ones in a plain Terminal.app window with no programa socket to talk to.

## What the skill covers

- **Inspecting your surroundings** — `programa tree` (the hierarchy, with `◀ active`/`◀ here` markers), plus `list-workspaces` / `list-panes` / `list-pane-surfaces` / `identify` for narrower queries.
- **Splitting and running without stealing focus** — `new-split` / `new-pane` / `new-surface` create UI without moving the user's cursor; `send` / `send-key` / `send-panel` / `send-key-panel` run commands in another pane the same way. Only `focus-pane`, `focus-window`, `focus-panel`, `select-workspace`, and the `next/previous/last-window` triad actually move focus — see the socket focus policy in the root `CLAUDE.md`.
- **Reading a sibling pane** — `read-screen` (alias `capture-pane`), with `--scrollback`/`--lines` for history beyond the visible viewport.
- **Spawning and coordinating a helper agent** — split, `send` a command like `claude ...` into the new surface, then read its output and answer it the same way you'd talk to any other pane. `set-status` and `notify` report progress through the sidebar instead of a pane the user isn't looking at.
- **Waiting** — `wait-surface` gives a server-owned blocking wait on a surface: `--pattern <regex>` resolves when new output matches, `--exit` when the process exits, both with `--timeout`. Waiting on *agent state* (idle/working/blocked) is implemented too — the underlying `surface.wait` socket method takes an `agent_state` condition (see `docs/v2-api-migration.md`), and `prompt-agent` is built directly on it to send a prompt and wait for the agent to go idle again. The tmux-compatible `wait-for` / `wait-for -S` named-signal rendezvous covers two cooperating processes.
- **Authoring screen-detection manifests for an unsupported agent** — programa's agent-state detection reads a pane's own lifecycle hooks when available (Claude Code, Codex, OpenCode), and otherwise falls back to regex-matching visible screen text against a manifest. For any other agent, `programa agent-detection scaffold <agent-id>` captures the current screen and writes a starter manifest to `~/.config/programa/agent-detection/<agent-id>.json`; fill in its `patterns` arrays, then `programa agent-detection test <agent-id>` to check them against the live screen. `programa agent-detection list` shows every loaded manifest (bundled + your overrides).
- **Reporting a normalized lifecycle event** — `programa agent-event --event <event_type> [--provider <p>] [--session-id <id>] [--workspace <id|ref>] [--surface <id|ref>]` reports one of the structured events documented in `docs/plans/agent-events.md` (`session.started`, `turn.started`, `request.opened`, `user-input.requested`, `turn.completed`, `session.exited`, and the rest) instead of a bare `working`/`blocked`/`idle` string. It's what the shipped Claude Code/Codex/OpenCode hooks call internally; use it directly only if you're wiring a new provider's hook or testing the event path by hand — reach for `set-status` for everything else.
- **Writing a recap** — when the user asks for a summary of a change, write markdown to `.programa/recaps/<slug>.md` and open it with `programa recap open <slug>` (`programa recap list` shows what's saved). The markdown panel renders mermaid diagrams, GitHub-style alerts, and `:::compare` before/after blocks, so the skill tells the agent to reach for those instead of plain prose when they fit.
- **Browser work** — two browsers for two jobs. `programa browser open-split` / `snapshot` / `click` / `screenshot` drive programa's embedded browser for local previews and smoke tests without moving focus; Aside (via its MCP server, or `aside "<task>"` from the shell) handles logged-in sites. `programa aside install-mcp` registers Aside with Claude Code and Codex. See [`docs/aside-browser.md`](aside-browser.md).

## Verifying it

There's no automated test for "does an agent actually behave correctly" — this is prompt content, not code. Manually verify by starting a fresh Claude Code (or Codex/OpenCode) session inside a programa pane with the skill installed and asking it to open a split and tail a dev server log; it should do so via the `programa` CLI, and the user's focus should stay on the pane they were already in.

## Command reference

The skill only covers the commands relevant to agent coordination. For the full CLI surface (the in-app browser, tmux-compat commands, hooks) run `programa help`, see [`aside-browser.md`](aside-browser.md) for the browser split between programa's panel and Aside, or see [`docs/v2-api-migration.md`](v2-api-migration.md) for the underlying socket API.
