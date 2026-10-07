# Aside: the browser for agents

Programa does not embed a browser. When a coding agent in a Programa pane needs one, for
local previews, smoke tests, screenshots, logged-in sites, private dashboards or CI logs, use
**Aside** ([aside.com](https://aside.com)), a Chromium-based agent browser. Aside owns the
sessions and cookies, and Programa registers it with Claude Code and Codex so the agent can
hand browser work to it instead of driving a Chrome extension.

## Aside from an agent

Aside ships a CLI (`aside`) and an MCP server (`aside mcp`, stdio). Programa can register
that server with Claude Code and Codex for you:

```bash
programa aside status            # where the aside binary is, whether Aside is running, what is registered
programa aside install-mcp       # registers `aside` (aside mcp) with Claude Code and Codex
programa aside install-mcp --with-devtools
programa aside uninstall-mcp
```

`File > Install Aside Browser MCP…` runs the same installer in a new workspace.

The `--with-devtools` flag adds a second server named `aside-devtools`. While Aside is
running it exposes the Chrome DevTools Protocol on `127.0.0.1:9223`, and
`chrome-devtools-mcp` pointed at that URL gives an agent full DevTools control of Aside's
tabs (navigation, clicks, console, network, performance traces) with no extension involved.
`programa aside status` reports the endpoint when it is reachable.

Once registered, an agent can also delegate a whole task from a pane without MCP:

```bash
aside "Open the staging dashboard and check whether the last deploy is green"
aside --session <session-id> "Continue and report any failures"
```

Install the Aside CLI from Settings > Developer inside Aside, or with the command on
[docs.aside.com/help/developers](https://docs.aside.com/help/developers). Programa looks for
it at `~/.local/bin/aside`, then `~/.aside/cli/Aside CLI.app/Contents/MacOS/aside`, then on
`PATH`.

## Sending links to Aside

Cmd-clicked terminal links and `open https://...` leave Programa for the macOS default
browser. Make Aside the default browser in System Settings > Desktop & Dock and those links
land in the browser that has your logins and agent memory.

## Aside driving Programa

The reverse direction, Aside dispatching work into a Claude Code or Codex pane, needs Aside
to act as an MCP client. Aside does not document that today. When it does, point it at
`Programa.app/Contents/Resources/bin/programa-mcp`: the `surface_send_text`,
`surface_read_text`, `surface_split`, and `surface_wait` tools already let a client start an
agent in a pane, send it a prompt, wait for it to go idle, and read the result, without
scraping a terminal screen. Nothing on Programa's side needs to change for that.
