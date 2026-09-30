# MCP Server

Programa ships an MCP (Model Context Protocol) server so coding agents can drive the
app directly: list and switch workspaces, split panes, send text to a terminal, and
**read the output of a pane they are not running in**.

It is a separate binary, `programa-mcp`, embedded in the app bundle. It talks to the
running app over the same v2 JSON control socket the `programa` CLI uses
(see [socket-api.md](socket-api.md)). It is not part of the app process,
so it cannot affect terminal rendering or typing latency.

## Setup

Point your MCP client at the binary inside the app bundle:

```
/Applications/Programa.app/Contents/Resources/bin/programa-mcp
```

For Claude Code, that is:

```json
{
  "mcpServers": {
    "programa": {
      "command": "/Applications/Programa.app/Contents/Resources/bin/programa-mcp"
    }
  }
}
```

The server finds the running app's socket on its own, using the same rules as the CLI.
No arguments or configuration are needed in the common case. To target a specific
instance (a tagged dev build, for example), set `PROGRAMA_SOCKET_PATH`:

```json
{
  "mcpServers": {
    "programa-dev": {
      "command": "/path/to/Programa DEV my-tag.app/Contents/Resources/bin/programa-mcp",
      "env": { "PROGRAMA_SOCKET_PATH": "/tmp/programa-debug-my-tag.sock" }
    }
  }
}
```

If Settings → Automation uses password-protected socket access, also provide
`PROGRAMA_SOCKET_PASSWORD` in the MCP server's environment. `programa-mcp` authenticates
with `auth.login` before sending each tool request and returns an explicit
`authentication_error` when the password is missing or rejected:

```json
{
  "mcpServers": {
    "programa": {
      "command": "/Applications/Programa.app/Contents/Resources/bin/programa-mcp",
      "env": { "PROGRAMA_SOCKET_PASSWORD": "your configured password" }
    }
  }
}
```

Note that inside a Programa terminal, `PROGRAMA_SOCKET_PATH` is already set and points at
the app you are running in. That is usually what you want, but it means a dev build's
server will talk to your production instance unless you override it explicitly.

On startup the server prints the socket it chose to stderr, and says whether that came from
an environment override or from discovery:

```
programa-mcp: control socket /tmp/programa-debug-my-tag.sock (via PROGRAMA_SOCKET_PATH override)
```

Most MCP clients keep that in a server log. Worth a look if a project you did not write ships
its own MCP config: anything that can set this process's environment can choose which socket
it talks to, and a substituted socket sees every tool argument and picks what the agent reads
back.

## Tools

187 tools, named after the socket method they call, with `.` replaced by `_`:
`surface.read_text` becomes `surface_read_text`, `review.comment.add` becomes
`review_comment_add`.

### The `focus_` prefix

Thirteen tools can pull macOS focus to Programa and raise its window. They are named with a
`focus_` prefix instead of their method name, so the name alone tells you the tool is
disruptive before you read its description:

| Tool | Socket method |
|---|---|
| `focus_window` | `window.focus` |
| `focus_workspace_select` | `workspace.select` |
| `focus_workspace_next` | `workspace.next` |
| `focus_workspace_previous` | `workspace.previous` |
| `focus_workspace_last` | `workspace.last` |
| `focus_surface` | `surface.focus` |
| `focus_pane` | `pane.focus` |
| `focus_pane_last` | `pane.last` |
| `focus_review_open` | `review.open` |
| `focus_worktree_open` | `worktree.open` |
| `focus_browser_webview` | `browser.focus_webview` |
| `focus_browser_element` | `browser.focus` |
| `focus_browser_tab_switch` | `browser.tab.switch` |

Every other tool leaves your focus alone. This is enforced by the app, not by the server:
the socket layer only permits focus changes for the methods in `focusIntentV2Methods`
(`Sources/TerminalController.swift`), so a tool cannot steal focus by accident regardless
of what the server asks for. The prefix is there to make the boundary visible to an agent
choosing which tool to call.

`worktree_create` is a deliberate exception. The underlying method accepts a `focus`
argument, but the tool does not expose it, so creating a worktree never moves your focus.
Use `focus_worktree_open` if you want to jump to it.

## Resources

| URI | Contents |
|---|---|
| `programa://tree` | The full window, workspace, pane and surface tree. Start here to find ids. |
| `programa://surface/{surface_id}/text` | Visible text plus scrollback for one terminal surface. |

Add `?lines=n` to bound the read: `programa://surface/<id>/text?lines=200`. Useful when a
pane has a large scrollback and you are polling it. Reads are capped at 10,000 lines
whatever you ask for, so one call cannot pull an unbounded buffer into an agent's context.

Reading a surface does not focus it, which is the point: an agent in one pane can watch
what another agent is doing in a different pane, in a different workspace, or in a
different window.

Resources are read on demand. There are no push notifications when a pane's output
changes, so poll if you need to follow along.

## Browser tools

Typical flow: `browser_open_split` (or `browser_tab_new`) to open a tab, `browser_navigate`
to load a URL, then `browser_snapshot`, `browser_get_text`, or `browser_screenshot` to read
the page, `browser_click`/`browser_fill`/`browser_press` and friends to interact with it, and
`browser_tab_close` when you are done.

Reads and interactions never move your focus -- opening or interacting with a browser tab
never raises the Programa window or steals keyboard focus, the same guarantee the rest of
the tool table gives you. Only the three `focus_browser_*` tools (see "The `focus_` prefix"
above) can do that.

## What is not exposed

Deliberate omissions, not oversights:

- **Debug methods** (`debug.*`). DEBUG builds only, and mostly UI-test hooks that can
  synthesize keystrokes and activate the app.
- **App chrome** (`auth.login`, `settings.open`, `feedback.*`, `markdown.open`) and
  app-wide test hooks (`app.*`).

The authoritative method list is `Sources/V2CommandCatalog.swift`. The tool table that
mirrors it is `CLI-MCP/ToolCatalog.swift`.

## Troubleshooting

**No response at all.** The server holds a session open on stdin. Piping a single request
with `echo ... | programa-mcp` will usually print nothing, because the process reaches
end-of-input and exits before the reply is flushed. Real MCP clients keep the pipe open,
so this only affects hand testing.

**`transport_error: Socket not found`.** Programa is not running, or the server resolved a
different instance's socket than you expected. Check `PROGRAMA_SOCKET_PATH`.

**`authentication_error`.** The running app requires socket authentication. Set
`PROGRAMA_SOCKET_PASSWORD` to the password configured in Settings → Automation, or verify
that the existing value matches.

**A tool is missing from `tools/list`.** Confirm the method exists in the running build via
the `system_capabilities` tool. The server and the app can be different versions if you
have more than one Programa installed.
