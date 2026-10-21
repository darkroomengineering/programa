---
name: programa
description: Drive the programa terminal app from inside a programa surface. Use it without being asked whenever an agent runs inside programa (PROGRAMA_SURFACE_ID and PROGRAMA_SOCKET_PATH are set) and the task involves parallel or conflicting work (worktrees, helper agents), competing attempts (race), reviewing a diff, a long-running job, or reading another pane. Covers inspecting windows/workspaces/panes/surfaces, splitting panes and running commands without stealing the user's focus, reading sibling panes, spawning and waiting on helper agents, and layouts. Do not use, and do not call the programa CLI at all, when those two variables are unset — that means the agent is not running inside programa.
---

<!-- Installed and managed by `programa claude install-integration` / `programa codex install-integration` / `programa opencode install-integration`. Manual edits to an installed copy get overwritten on the next install — edit the source at repo root (darkroomengineering/programa) instead. -->

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

The `programa` CLI is already on `PATH` inside a programa terminal. Verify with `command -v programa`. When the `programa` MCP server is connected, its tools (`agent_spawn`, `worktree_create`, `surface_read_text`, ...) do the same things as the CLI.

## When to use what

Reach for these on your own; the user does not need to ask:

| Situation | Do this |
|---|---|
| A helper or a second line of work would edit the same files you are editing | `programa worktree create <branch>`, or `agent_spawn` with `needs_isolation` |
| A task worth trying several ways, or you are unsure which approach wins | `programa race "<prompt>" --n <count>`, then compare the branches yourself |
| A diff is ready for review, yours or a helper's | `programa review open`, `review comment add`, `review send` |
| A build, test run, dev server, or anything over a minute | run it in a split, then `wait-surface` on it |
| A long or parallel job the user should be able to watch | `programa new-split` (MCP `surface_split`) or `agent_spawn`, then tell the user which pane it is in |
| The work needs a coordinated team of agents | suggest the user restart with `programa claude-teams`; only the user launches it |
| A blocking question for the user, from a tool without programa hooks (Claude Code, Codex and OpenCode hooks already send it) | MCP `agent_needs_input` with your `PROGRAMA_WORKSPACE_ID` and `PROGRAMA_SURFACE_ID`, the question as `body`, and `kind` `question` (without MCP: `programa rpc agent.needs_input '{"workspace_id":"…","surface_id":"…","body":"<question>","kind":"question"}'`). `surface_report_agent_state` with `blocked` only sets the badge |
| Waiting on another agent | `wait-surface --agent-state idle` or `prompt-agent` |
| The user asks for the same pane arrangement again | `programa layout save` / `layout apply` |
| You need output from another pane | `read-screen --surface <ref>` |
| Need another pane's output in your prompt | `programa handoff --from <pane>` |
| Hand text to another agent's prompt without submitting it | MCP `surface_send_paste`: one paste, Return is never pressed. `send` and `surface_send_text` turn each newline into Return |
| An agent in a pane exited, or Programa restarted, and its work should continue | `programa resume --surface <ref>` types its resume command at that pane's shell prompt |
| The user asks for a recap of a change | write `.programa/recaps/<slug>.md`, then `programa recap open <slug>` |

None of these move the user's focus. Only the focus-changing commands listed below do, so leave those alone unless the user asked to be moved.

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

Useful flags and narrower listings:

```bash
programa tree --all                       # every window, not just the current one
programa tree --workspace workspace:2     # scope to one workspace
programa --json tree                      # structured JSON (global --json flag goes before the subcommand)
programa list-workspaces                  # workspaces in the current window
programa list-panes                       # panes in the current workspace
programa list-pane-surfaces               # surfaces (tabs) in the focused pane; add --pane <id> for another
programa identify                         # your own window/workspace/surface IDs as JSON
programa list-ports                       # listening TCP ports per workspace, plus processes left running
```

## Splitting panes and running commands without stealing focus

programa's commands split cleanly into two groups:

- **Focus-preserving** — safe to call at any time from any agent: `new-split`, `new-pane`, `new-surface`, `send`, `send-key`, `send-panel`, `send-key-panel`, `read-screen` (alias `capture-pane`). None of these move the user's cursor, raise the window, or change the active tab.
- **Focus-changing** — only call these when you actually mean to move the user's attention: `focus-pane`, `focus-window`, `focus-panel`, `select-workspace`, `next-window`/`previous-window`/`last-window`.

Create a split without touching focus, then send it a command:

```bash
result=$(programa new-split right)            # prints: OK surface:6 workspace:2
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

A workspace holds at most 4 panes. A split or new pane past that fails with error code `limit_reached` (`data.max_panes` is 4) instead of creating anything. Fall back to `agent_spawn` (a helper gets its own nested workspace) or to a new workspace with `programa new-workspace`.

## Reading output from a sibling pane

`read-screen` (alias `capture-pane`, for tmux muscle memory) returns terminal text as plain text — the visible viewport by default, or scrollback on request:

```bash
programa read-screen --surface "$handle"                          # visible viewport
programa read-screen --surface "$handle" --scrollback --lines 200 # last 200 lines of scrollback
```

Treat a single read as a snapshot, not a completion signal — use `wait-surface` (below) to know when something finishes.

`handoff` pastes a pane's last lines into a prompt as context, headed `Context from <pane>:`. It arrives as one paste and Return is never pressed, so the text waits as a draft:

```bash
programa handoff --from "$handle"                                  # last 200 lines into your own pane
programa handoff --from "$handle" --to surface:4 --lines 50 --note "Why does this fail?"
```

`--lines` defaults to 200 (max 1000) and `--to` to `$PROGRAMA_SURFACE_ID`; `--from` must be a different pane than the target.

## Parallel or conflicting work: worktrees

Two agents editing the same checkout overwrite each other. When a second line of work would touch the files you are touching, give it its own git worktree:

```bash
programa worktree create fix-login --base main   # new branch + worktree, opened as its own workspace
programa worktree list                           # worktrees of this repo, [open] marks open workspaces
programa worktree remove fix-login               # removes the worktree (never the branch); add --force if it has uncommitted changes
```

`create` checks out `<branch>` if it already exists, otherwise creates it from `--base` (default `HEAD`). The workspace opens next to its repo in the sidebar without taking focus; pass `--focus` only when the user should jump to it, and `--layout <name>` to apply a saved layout into it. Text output is `OK worktree workspace=<ref> path=<dir> branch=<branch>`; pass that workspace ref to `send --workspace`, `read-screen --workspace`, or `wait-surface --workspace`.

## Spawning a helper agent and coordinating with it

When the `agent_spawn` tool is available, use it for helper agents. It opens the helper as a nested workspace under the current workspace, keeps the same folder, and does not move the user's focus. Set `needs_isolation` (with `repository_path` and `branch`) when the helper will make conflicting Git changes and needs a separate worktree. Programa then shows the helper in Agent Overview automatically.

Use a split for a long-running shell command, or as a fallback when `agent_spawn` is unavailable. Launch the command with `send`, then treat it like any other sibling pane:

```bash
result=$(programa new-split right)
handle=$(echo "$result" | awk '{print $2}')
programa send --surface "$handle" "claude 'fix the failing test in foo_test.go'\n"   # launch the helper
programa read-screen --surface "$handle" --scrollback --lines 100                  # check on it later
programa send --surface "$handle" "yes\n"                                           # answer it if it's waiting
```

Surface status through the sidebar and native notifications rather than only printing to your own pane:

```bash
programa set-status build "compiling" --icon hammer --color "#ff9500"
programa notify --title "Helper agent done" --body "Tests pass, ready for review" --surface "$handle"
```

`set-status` writes a pill into the sidebar tab row — use a unique key per tool (`build`, `claude_code`, ...) so entries don't collide. `notify` fires a native notification and lights up programa's unread ring/tab indicator for that surface.

## Competing attempts: race

When a task has several plausible approaches, race them instead of guessing:

```bash
programa race "fix the flaky upload test" --n 3 --base main
```

`race` creates one worktree and workspace per attempt on branches `<prefix>/<index>` (default prefix `race`, numbering continues after existing branches), then starts the agent in each with your prompt. Flags: `--n <count>` (1-8, default 3), `--agent <claude|opencode|codex>` (default claude), `--base <ref>`, `--prefix <slug>`, `--layout <name>`. It prints one `[<index>] branch=<branch> workspace=<ref>` line per attempt and never takes focus.

`race` only spawns the attempts. Comparing and merging is up to you: wait for each attempt (`programa wait-surface --workspace <ref> --agent-state idle --timeout 1800`), compare the branches (`git diff main...race/1`), merge the one you pick with normal git, and clean up the rest with `programa worktree remove <branch>`.

## Waiting on a server, a test run, or another agent

For anything that takes more than a minute, run it in a split and block on it instead of sleeping or polling. `wait-surface` waits server-side until a surface's output matches a regex, its process exits, or the agent in it reaches a state:

```bash
programa wait-surface --surface "$handle" --pattern 'BUILD (SUCCEEDED|FAILED)' --timeout 120
programa wait-surface --surface "$handle" --exit --timeout 600
programa wait-surface --surface "$handle" --agent-state idle --timeout 300
programa wait-surface --surface "$handle" --agent-state blocked --timeout 300
```

Exactly one of `--pattern <regex>`, `--exit`, or `--agent-state <idle|working|blocked|any_change>` is required; `--timeout` defaults to 30 seconds. Match on whatever the process actually prints ("PASS", "Server started", a prompt returning), not a fixed sleep. The app answers the moment the condition is met, so output that appears while the call is being issued is not missed. `--workspace <ref>` without `--surface` targets that workspace's focused terminal.

`--agent-state` watches the lifecycle state that Claude Code, Codex, and OpenCode report through their hooks. A surface that has never reported any state counts as idle for `--agent-state idle`; `blocked`/`working` require an actual report.

For two cooperating processes, `wait-for` (tmux-compatible) gives you a named rendezvous instead of scraping a log:

```bash
programa wait-for -S build-complete               # in the helper's pane, once it's done
programa wait-for build-complete --timeout 120    # in the coordinating agent
```

It signals that the other side finished, not whether it succeeded — pair it with a `read-screen` check.

## Prompting a helper agent and waiting for it, in one call

```bash
programa prompt-agent --surface "$handle" --timeout 300 "fix the failing test in foo_test.go"
```

It sends the text, waits briefly for the helper to report it started working, then waits for it to go idle again. If the helper never reports any activity, the JSON response carries a `warning` that its hooks may not be installed — check that field if `prompt-agent` returns suspiciously fast.

## Reviewing a diff

When a diff is ready, open it in the review panel instead of pasting it into chat. The panel opens beside the source terminal without taking focus, and comments go back into that terminal's agent as `path:line — comment`:

```bash
programa review open                                         # uncommitted changes of the focused terminal in this workspace
programa review open --workspace workspace:5 --mode branch --base-branch main   # a helper's or race attempt's whole branch
programa review comment add src/upload.ts 42-48 "this retry never backs off"
programa review comment list
programa review send --preamble "Fix these before I merge:"
```

`review open` reviews the terminal given by `--surface`, or the focused terminal of the target workspace. `--mode` is `uncommitted` (default) or `branch`; `--base-branch` defaults to `origin/main`. Pass the same `--workspace`/`--surface` to `comment` and `send` so they reach the same panel. `review refresh` reloads the diff after more edits.

Programa checkpoints the repo's files at the start of every agent turn (`refs/programa/checkpoints/...`); the user can revert a turn's file changes from the review panel, which does not rewind your conversation, so re-read files after a revert.

## Layouts

```bash
programa layout save fullstack-dev                # current workspace's split geometry and cwds (not running commands)
programa layout list
programa layout apply fullstack-dev               # into a new unfocused workspace; --workspace <ref> to reuse one, --cwd <dir> for its root
```

`layout save` refuses to overwrite an existing name without `--force`. `worktree create --layout <name>` and `race --layout <name>` apply a saved layout to each new workspace.

## Writing a recap

When the user asks for a recap or summary of a change, write it as markdown to `.programa/recaps/<slug>.md` (repo root resolved with `git rev-parse --show-toplevel` from your cwd), then open it:

```bash
programa recap open <slug>
```

Use the same panel that renders `programa markdown open` for it, so lean on its formatting:

- ` ```mermaid ` fenced blocks for flow diagrams (rendered offline, no network call)
- GitHub-style alerts (`> [!NOTE]`, `> [!TIP]`, `> [!IMPORTANT]`, `> [!WARNING]`, `> [!CAUTION]`) for callouts
- a `:::compare` block for before/after code, rendered side by side:

  ````
  :::compare
  ```swift before
  old code
  ```
  ```swift after
  new code
  ```
  :::
  ````

`programa recap list` shows the slugs already saved. Keep the recap itself short and plain, the same way you'd summarize the change in chat.

## Browser work

Do not reach for a Chrome extension. Programa has no built-in browser; browser work goes through Aside.

- **Previews, smoke tests, screenshots, DOM checks, console errors, logged-in sites, private dashboards, CI logs:** use Aside through its MCP server if it is registered (tools from the `aside` server, or `aside-devtools` for raw Chrome DevTools control), or delegate a whole task from the shell:

  ```bash
  aside "Open the staging dashboard and tell me whether the last deploy is green"
  ```

  `programa aside status` says whether Aside is installed and registered; `programa aside install-mcp` registers it with Claude Code and Codex. Do not run the installer yourself unless the user asks, it edits their agent config.

## Reference

- `--workspace`/`--surface`/`--pane`/`--window` accept either a short ref (`workspace:2`, `surface:4`) or a raw UUID; omitted, they default to `$PROGRAMA_WORKSPACE_ID`/`$PROGRAMA_SURFACE_ID`.
- `--json` and `--id-format <refs|uuids|both>` are global flags and go before the subcommand: `programa --json tree`, `programa --id-format both list-panes`.
- Full command list: `programa help`; one command's flags: `programa <command> --help`.
- Anything not wrapped by a dedicated subcommand is reachable directly: `programa rpc <method> [json-params]` calls any socket API method.
- `watch-events` streams a live feed of agent-state/output/workspace events over one long-lived connection — it's for dashboards and orchestrators watching many surfaces at once, not for a normal agent loop; use `wait-surface`/`prompt-agent` for "wait for one thing" instead.
- Longer walkthrough and the full socket API reference: `docs/agent-skill.md` and `docs/socket-api.md` in the programa repo.
