# Tabs, agent logos and the ports panel

Four parts of the window show what is running without opening anything: the pane tab bar,
the agent logo on a tab, the edge fades on an overflowing tab bar, and the ports panel in the
sidebar footer. None of them has a settings key. The shortcuts that act on tabs are listed in
[keyboard-shortcuts.md](keyboard-shortcuts.md).

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
