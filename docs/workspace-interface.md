# Workspace interface

This page covers the parts of the window you work in: the pane tab bar and pane header, moving
a tab to a new window, agent logos and edge fades on tabs, the sidebar rows, the ports, storage
and provider usage popovers in the sidebar footer, the helpers popover and turn checkpoints,
and resuming an agent session. The shortcuts that act on tabs and panes are listed in
[keyboard-shortcuts.md](keyboard-shortcuts.md), and the settings named here are in
[settings-json.md](settings-json.md).

## Pane tab bar

Every pane has its own tab bar along its top edge. Each tab is a terminal surface.

- Click a tab to select it. The close button on a tab closes it, and the "+" after the last
  tab opens a new terminal tab in that pane.
- Right-click a tab for its menu, including a tab color.
- Drag a tab to reorder it, or onto another pane to move it. A thin accent line marks where
  the tab will land.
- A mouse wheel scrolls a crowded tab row sideways. Trackpads scroll it with a horizontal swipe.
- The selected tab scrolls into view when the row is wider than the pane.

On macOS 26 the tab bar is native glass. Earlier macOS versions draw it without glass.

A workspace with one pane and one tab hides the tab bar and leaves an empty strip at the top,
so you can still drag the window from there. The bar comes back when the pane gets a second
tab or the workspace is split. In minimal mode with the sidebar hidden, the bar stays, because
it shares the titlebar row with the traffic lights.

## Pane header

On macOS 26 the trailing end of each pane's tab bar holds a row of quiet controls. They act on
that pane, not on the focused one, so you can split or close a pane without clicking into it
first:

- **New Tab**, shown only when the pane has one tab. A pane with more tabs keeps the "+" after
  its last tab instead.
- **Split Right** and **Split Down**. They dim, with the tooltip "Split limit reached", when the
  workspace cannot take another split.
- **Zoom Pane**, which reads **Exit Zoom** while the pane is zoomed. It dims when the workspace
  has only one pane.
- **Close Tab**, which closes the pane's selected tab. It dims when that tab is pinned.

A pane with a single tab shows that tab as a plain header: a small icon and the title, drawn
without the glass tab shape and with no close button on the tab itself. When a pane is too
narrow for every control, they drop out in this order: Split Down, Split Right, New Tab, then Zoom Pane. Close Tab always
stays. The same actions have shortcuts (⌘ D, ⌘ ⇧ D and ⌘ ⇧ ↩ for split and zoom); see
[keyboard-shortcuts.md](keyboard-shortcuts.md#split-panes). Earlier macOS versions do not have
the pane header.

## Move a tab to a new window

Drag a tab out past the edge of every Programa window and release it. The tab opens in a new
window placed under the release point, and its shell keeps running with its scrollback intact,
because the terminal moves instead of starting over. Press Escape during the drag to cancel and
keep the tab where it was. The last tab of the last workspace in the last window stays put, so
no window is left empty.

## Agent logos on tabs

A terminal tab shows the logo of the agent running in it, in place of the terminal icon. The
logo appears when Programa detects the agent and disappears when the agent exits. Detection
comes from the first of these that names a known agent:

1. The agent's hook session (see [notifications.md](notifications.md)).
2. Screen-based detection (see [agent-detection-manifests.md](agent-detection-manifests.md)).
3. The `app` field of an OSC 7501 program status (see [program-status.md](program-status.md)).

Logos exist for Claude Code, Codex, GitHub Copilot, Cursor, Gemini CLI, and OpenCode. A tab
running any other agent keeps the terminal icon. Logos keep their full color on tab bars of
unfocused panes.

## Edge fades

When a tab row holds more tabs than fit, the edge that hides tabs fades to transparent over
about 24 points. A fade on the left edge means tabs are hidden to the left, and a fade on the
right means tabs are hidden to the right. A row that fits shows no fade. Edge fades belong to
the native glass tab bar on macOS 26.

## Sidebar rows

Each workspace has one row in the sidebar. From left to right, its first line holds:

- the logo of the agent running in the workspace, or a terminal symbol when no agent reports
  (a worktree folder row shows a folder and its collapse arrow instead);
- the workspace title, which fades out at the right edge instead of being cut off;
- a branch badge for a git worktree workspace, a pin for a pinned workspace, and the unread
  notification count;
- how long ago the status line below last changed ("now", "3m", "2h", "4d"), updated once a
  minute.

Under the title sits one status line. It shows the first of these that applies:

1. The agent's state while it is working or waiting for you, as a colored pill.
2. The latest notification text.
3. The agent's resting state (Idle, Done or Error), as a pill.
4. The latest log line from `programa log`.

The agent states and the "(stale)" label are described in
[notifications.md](notifications.md#sidebar-agent-indicator). Below the status line come the
workspace description, the helpers line (see [Helpers popover](#helpers-popover)), status and
metadata entries, the latest log line when the status line shows something else, a progress
bar, the branch and directory lines, and pull requests. A directory line is left out when it is
`~` or repeats the title.

Hovering a row replaces the elapsed time with a ••• button that opens the same menu as a
right-click. The selected row is a raised white pill with a soft shadow while the window is
active, and flat gray when it is not. A custom sidebar selection color keeps a flat fill.

## Ports panel

The Ports button sits in the sidebar footer and shows a count of listening TCP ports. It
appears only while something is listening, and it counts every Programa workspace in every
window.

Click it to open the Listening Ports panel. Rows are grouped by workspace and show the
command, port, and pid. Each row has these actions:

- **Open in browser** opens `http://localhost:<port>` in your default browser.
- **Copy URL** copies that address.
- **Reveal in workspace** selects the workspace and focuses the terminal that owns the process.
- **Stop** asks for confirmation, then sends SIGTERM and sends SIGKILL if the process is still
  running 3 seconds later. Cancel is the default button, so a stray Return stops nothing.

A **Left running** section lists processes that still hold a port after their terminal closed.
They have no workspace to reveal, but you can open, copy, and stop them. The list keeps the 50
most recent.

The same data is available from the command line and the socket:

```sh
programa list-ports [--json]
programa stop-port 3000
programa stop-port --pid 4242
```

`stop-port <port>` fails and lists the processes when more than one listens on that port; pick
one with `--pid`. Only processes that `list-ports` shows can be stopped. The socket methods are
`ports.list` and `ports.stop`; see [socket-api.md](socket-api.md).

## Storage

The Storage drive icon in the sidebar footer shows available and total space on your home
volume, removable worktrees, and any developer cache categories found by Programa. Scans run
in the background when you open the panel; worktree and cache results stay cached for five minutes.
Live sessions list disk usage by workspace directory, with large build and dependency folders
shown below each session; these measurements stay cached for two minutes and skip home and root directories.

Each **Clean** button previews the items and total size before asking for confirmation.
Worktree cleaning ignores the automatic cleanup grace period but keeps dirty, unmerged,
open, or busy worktrees. Cache rows list blocked items with the reason they are kept.
After cleaning, the panel reports the removed items and reclaimed space.

Programa checks available space 60 seconds after launch and every 15 minutes. When it falls
below 20 GB, a notification opens Storage when clicked, revealing the sidebar if needed.
Warnings re-arm after space rises above the threshold plus 5 GB. Set
`storage.lowDiskWarningGB` in [settings.json](settings-json.md#storage) to change the threshold
or use `0` to disable warnings.

## Provider usage

The gauge button in the sidebar footer, labeled Provider Usage, opens a popover with how much of
your Claude and OpenAI rate limits is left. It reads the numbers each time you open it and
shows "Loading usage…" until the first answer arrives.

- **Claude** appears when the `claude` command is installed and signed in, and Claude Code has
  written `~/.claude/tmp/rate-limits.json` within the last hour. Some Claude Code setups never
  write that file, and then the Claude section is left out. The rows are **Current session**
  (the 5 hour window) and **Weekly**, whichever the file has.
- **OpenAI** appears when the `codex` command (or the Codex app) is installed and signed in.
  Its header shows your plan and credits, and its rows are the windows Codex reports, such as
  **Current window** and **Weekly**.

Each row shows the percentage left, a bar of what remains, and when the window resets. The bar
turns orange once 60% is used and red at 85%. A provider that could not be read shows an error
line instead of rows. With neither provider available, the popover says "No usage available".

Turn the button off with **Show Provider Usage** in Settings > Sidebar, or
`sidebarAppearance.showClaudeQuota` in [settings.json](settings-json.md#sidebarappearance).
Token counts per session are a different feature: see `programa usage` in
[agent-usage.md](agent-usage.md).

## Helpers popover and checkpoints

### Helpers popover

A helper is a subagent or subtask that runs inside its parent agent or program and shares its
terminal. A workspace's sidebar row shows "1 helper running" or "N helpers running" while it has any, and "N helpers
finished" once all of them have stopped. Three sources report helpers:

- Claude Code subagents, through the `claude` wrapper's SubagentStart and SubagentStop hooks.
- OSC 7501 child records written by a program (see [program-status.md](program-status.md)).
- `agent.task.start` over the socket, or the `agent_task_start` MCP tool, with the default
  `runs_with_parent` placement.

A helper started with `agent.spawn` gets its own workspace instead, nested under its parent in
the sidebar, and does not appear in the popover.

Click the helpers line to open the popover. Running helpers come first. Finished helpers follow
under a **Finished** header, newest first. Each row shows:

- a state icon: Idle, Working, Needs input, Done, Stopped or Failed;
- the helper's task, or its agent type when no task was given, with the agent type underneath
  when it differs;
- a progress bar while the helper runs, when its program reports progress;
- how long it has run, counting up while it runs.

Click a row to show a preview of its final report, up to 8 lines of markdown.
**Copy** puts the whole report on the clipboard, and **Open Report** opens it in a markdown
pane beside the focused pane. A helper that is still running, or that finished without a
report, says so instead. **Clear** next to the Finished header removes the finished helpers from
the list, along with finished OSC 7501 child records in the workspace's terminals. The popover
refreshes once a second while it is open.

### Turn checkpoints

Each time an agent starts a turn in a pane, Programa saves the files of that pane's git
repository as a checkpoint. A prompt answered in the middle of a turn does not start a new
one. The checkpoint holds tracked and untracked files and respects `.gitignore`; it lives under
`refs/programa/checkpoints/` and never touches the repository's index, `HEAD` or branches.
Programa keeps the newest 20 checkpoints per pane. It skips a checkpoint when more than 500
paths have changed or an untracked file is larger than 10 MB. Closing the workspace deletes
its checkpoints. Saving a checkpoint also deletes any other workspace's checkpoints in the same
repository that are more than 7 days old, which covers workspaces from before a restart.

To undo an agent's last turn, open the review panel for that pane (the sidebar's Review link,
`programa review open`, or the command palette) and click **Revert Files to Before Last Turn**
in its header. After you confirm, the files go back to how they were when the turn started:
changed files are restored and files created since then are deleted. The agent's conversation is
not rewound. Programa saves your current files first, so the same button then reads **Undo File
Revert** and puts them back. A revert never changes the index, `HEAD`, ignored files or
submodules. If the current files cannot be saved first (over the same limits), nothing changes
and the panel says why.

## Resume an agent session

When an agent exits in a pane, its session-end hook keeps the session id in
`~/.programa/agent-last-sessions.json`, one entry per pane and per directory, for 7 days.
`programa resume` types that agent's resume command into the pane's shell and presses Enter:

```sh
programa resume                      # the pane you run it from
programa resume --surface surface:3
programa resume --print              # print the command, type nothing
programa resume --session <id>       # a specific session id
programa resume --session <id> --provider claude   # when the id is not recorded
programa resume --force              # type even when the pane is not at a prompt
```

It takes the newest session that ended in the pane, or else the newest one that ended in the
pane's current directory. If that session ran in another directory that still exists, the
command starts with `cd <dir> &&`. Claude Code (`claude --resume <id>`), Codex
(`codex resume <id>`) and OpenCode (`opencode --session <id>`) are supported. OpenCode starts a
new session when it no longer knows the id. `resume` refuses while an agent is still
running in the pane, and only types into a pane whose `shell_state` is `promptIdle`; `--force`
skips the prompt check but not the running-agent check.
`--provider` (`claude`, `codex` or `opencode`) names the agent for a `--session` id that was not
recorded.

After a restart, each terminal pane remembers the last agent session it ran. Focus the pane and
run **Resume Agent Session** from the command palette (`⌘ ⇧ P`). The action appears only for a
terminal that has a resumable session and no running agent.
