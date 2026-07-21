---
name: programa
description: Drive the programa terminal app from inside a programa surface — inspect windows/workspaces/panes/surfaces, split panes and run commands without stealing the user's focus, read output from sibling panes, spawn and coordinate a helper agent, and wait on it. Use whenever an agent is running inside programa (PROGRAMA_SURFACE_ID and PROGRAMA_SOCKET_PATH are set) and needs to control the app itself, not just the shell inside one pane. Do not use, and do not call the programa CLI at all, when those two variables are unset — that means the agent is not running inside programa.
---

<!-- Installed and managed by `programa claude install-integration` / `programa codex install-hooks` / `programa opencode install-integration`. Manual edits to an installed copy get overwritten on the next install — edit the source at repo root (darkroomengineering/programa) instead. -->

# programa

programa is a native macOS terminal built for running many coding agents in parallel. Every terminal surface it creates is scriptable through a `programa` CLI that talks to a local Unix socket — split panes, read a sibling pane's output, send it keystrokes, and get notified, all without the terminal UI itself.

## Guard: confirm you're actually inside programa

Check this before anything else in this skill:

```bash
if [ -z "$PROGRAMA_SURFACE_ID" ] || [ -z "$PROGRAMA_SOCKET_PATH" ]; then
  echo "Not running inside programa (PROGRAMA_SURFACE_ID/PROGRAMA_SOCKET_PATH unset) — skipping programa CLI use."
fi
```

If either variable is unset, stop here. Don't guess a socket path, don't fall back to a default location, don't try anyway — just say you're not running inside programa and continue with normal shell commands.

Both variables are exported automatically by programa on every terminal surface it creates (no shell integration or setup required), along with `PROGRAMA_WORKSPACE_ID`. Every command below defaults its `--workspace`/`--surface` flags to those env vars when you omit them, so most calls need no flags at all when you're operating on your own pane.

The `programa` CLI is already on `PATH` inside a programa terminal. Verify with `command -v programa`.

## Inspecting your surroundings

Run `programa tree` first — it prints the whole hierarchy (windows → workspaces → panes → surfaces) with markers for where you and the user actually are:

```
$ programa tree
window window:1 [current] ◀ active
└── workspace workspace:2 "api-server" [selected] ◀ active
    ├── pane pane:1 [focused] ◀ active
    │   └── surface surface:3 [terminal] "zsh" [selected] ◀ active ◀ here
    └── pane pane:4
        └── surface surface:5 [terminal] "npm run dev"
```

- `◀ active` — the true focused window/workspace/pane/surface path (where the user's cursor is right now)
- `◀ here` — the surface this `programa tree` call was invoked from (you)
- `[selected]` / `[focused]` — that level's current UI selection (not necessarily "active" — the user may be in a different window)

Useful flags:

```bash
programa tree --all                       # every window, not just the current one
programa tree --workspace workspace:2     # scope to one workspace
programa --json tree                      # structured JSON (global --json flag goes before the subcommand)
```

Narrower listings, when you don't need the whole tree:

```bash
programa list-workspaces          # workspaces in the current window
programa list-panes               # panes in the current workspace
programa list-pane-surfaces       # surfaces (tabs) in the focused pane; add --pane <id> for another
programa identify                 # your own window/workspace/surface IDs as JSON
```

All of the above default to your own window/workspace via the env vars when you don't pass `--workspace`/`--window`.

## Splitting panes and running commands without stealing focus

programa's commands split cleanly into two groups:

- **Focus-preserving** — safe to call at any time from any agent: `new-split`, `new-pane`, `new-surface`, `send`, `send-key`, `send-panel`, `send-key-panel`, `read-screen` (alias `capture-pane`). None of these move the user's cursor, raise the window, or change the active tab.
- **Focus-changing** — only call these when you actually mean to move the user's attention: `focus-pane`, `focus-window`, `focus-panel`, `select-workspace`, `next-window`/`previous-window`/`last-window`.

Create a split without touching focus:

```bash
programa new-split right                        # split the current pane
programa new-split down --workspace workspace:2  # split in a different workspace
```

Text output is `OK surface:6 workspace:2` — the new surface's handle. Send it a command without focusing it:

```bash
result=$(programa new-split right)
handle=$(echo "$result" | awk '{print $2}')   # surface:6
programa send --surface "$handle" "npm run dev\n"
```

`\n` (or `\r`) sends Enter, `\t` sends Tab, inside the text argument to `send`/`send-panel`. Use `send-key` when you need a literal key event instead of typed text (`ctrl+c`, `enter`, arrow keys):

```bash
programa send-key --surface "$handle" ctrl+c
```

`new-pane` / `new-surface` work the same way when you want a brand-new pane or an extra tab rather than splitting the current one:

```bash
programa new-pane --direction down --workspace workspace:2
programa new-surface --pane pane:4              # new tab in an existing pane
```

## Reading output from a sibling pane

`read-screen` (alias `capture-pane`, for tmux muscle memory) returns terminal text as plain text — the visible viewport by default, or scrollback on request:

```bash
programa read-screen --surface "$handle"                          # visible viewport
programa read-screen --surface "$handle" --scrollback --lines 200 # last 200 lines of scrollback
```

Use this to check a build log, a test runner, or another agent's output without switching to its pane. Treat a single read as a snapshot, not a completion signal — poll it (see "Waiting" below) if you need to know when something finishes.

## Spawning a helper agent and coordinating with it

Split a pane, launch an agent CLI into it with `send`, then treat it like any other sibling pane: read its output, send it follow-up input, report on it through the sidebar instead of the pane the user isn't looking at.

```bash
# 1. Split and capture the new surface's handle
result=$(programa new-split right)
handle=$(echo "$result" | awk '{print $2}')

# 2. Launch the helper agent in it
programa send --surface "$handle" "claude 'fix the failing test in foo_test.go'\n"

# 3. Check on it later without focusing it
programa read-screen --surface "$handle" --scrollback --lines 100

# 4. Answer it if it's waiting on you
programa send --surface "$handle" "yes\n"
```

Surface status through the sidebar and native notifications rather than only printing to your own pane:

```bash
programa set-status build "compiling" --icon hammer --color "#ff9500"
programa notify --title "Helper agent done" --body "Tests pass, ready for review" --surface "$handle"
```

`set-status` writes a pill into the sidebar tab row — use a unique key per tool (`build`, `claude_code`, ...) so entries don't collide. `notify` fires a native notification and lights up programa's unread ring/tab indicator for that surface.

## Waiting on a server, a test run, or another agent

`wait-surface` blocks server-side until a surface's output matches a regex or its process exits, so you don't have to poll:

```bash
# Block until the build in a sibling pane finishes, up to 2 minutes
programa wait-surface --surface "$handle" --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120

# Block until the process in a surface exits
programa wait-surface --surface "$handle" --exit --timeout 600
```

Exactly one of `--pattern <regex>` or `--exit` is required. Match on whatever the process actually prints ("PASS", "Server started", a prompt returning), not a fixed sleep duration. The wait is answered by the app the moment the condition is met — there is no missed-event window even if the output appears while the call is being issued.

For two cooperating processes, `wait-for` (tmux-compatible) gives you a named rendezvous instead of scraping a log — one side signals, the other blocks until it does:

```bash
# In the helper agent's pane, once it's done:
programa wait-for -S build-complete

# In the coordinating agent:
programa wait-for build-complete --timeout 120
```

This is a filesystem-based signal, not a verdict on *why* the other side signaled — pair it with a `read-screen` check if you need to confirm success vs. failure.

A "block until the agent in this surface goes idle / blocked" wait (on agent state, not raw output) is planned but not shipped yet — use `--pattern`/`--exit` or `wait-for` until that lands.

## Reference

- `--workspace`/`--surface`/`--pane`/`--window` accept either a short ref (`workspace:2`, `surface:4`) or a raw UUID; omitted, they default to `$PROGRAMA_WORKSPACE_ID`/`$PROGRAMA_SURFACE_ID`.
- `--json` and `--id-format <refs|uuids|both>` are global flags and go before the subcommand: `programa --json tree`, `programa --id-format both list-panes`.
- Full command list: `programa help`.
- Anything not wrapped by a dedicated subcommand is reachable directly: `programa rpc <method> [json-params]` calls any socket API method.
- Longer walkthrough and the full socket API reference: `docs/agent-skill.md` and `docs/v2-api-migration.md` in the programa repo.
