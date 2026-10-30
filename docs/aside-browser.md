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
programa aside status            # where the aside binary is, the DevTools endpoint, what is registered where
programa aside install-mcp       # registers `aside` (aside mcp) with Claude Code and Codex, and Programa with Aside
programa aside install-mcp --with-devtools
programa aside uninstall-mcp
```

`File > Install Aside Browser MCP…` runs the same installer in a new workspace.

The `--with-devtools` flag adds a second server named `aside-devtools`:
`chrome-devtools-mcp --autoConnect --userDataDir ~/Library/Application Support/Aside`. It gives
an agent full DevTools control of Aside's tabs (navigation, clicks, console, network,
performance traces) with no extension involved. It needs remote debugging turned on in Aside:
open `chrome://inspect/#remote-debugging` in Aside and enable it. Aside then writes the live
port and browser path to `DevToolsActivePort` in its user data directory, and
`chrome-devtools-mcp` follows that file, so the port can change between launches without
re-registering anything. `programa aside status` reports the `ws://127.0.0.1:<port>/devtools/browser/<id>`
endpoint while that port accepts connections, and says remote debugging is off otherwise.

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

Aside is also an MCP client, so it can dispatch work into a Claude Code or Codex pane.
`programa aside install-mcp` registers Programa there: it adds a `programa` stdio server
pointing at the `programa-mcp` next to the CLI (`Programa.app/Contents/Resources/bin/programa-mcp`)
to `mcp.servers` in the signed-in account's `~/.aside/u/<account>/settings.json`. Every other
setting stays as it is, and the confirmation prompt lists the change before anything is
written. Aside reads its MCP servers when it starts, so quit and reopen Aside afterwards.
`programa-mcp` finds the running Programa's socket on its own and needs no arguments or
environment.

With it, the `surface_send_text`, `surface_read_text`, `surface_split`, and `surface_wait`
tools let Aside start an agent in a pane, send it a prompt, wait for it to go idle, and read
the result, without scraping a terminal screen.

The installer skips this step when Aside has no signed-in account on this Mac, and leaves a
`programa` server it did not create untouched. `programa aside uninstall-mcp` removes the
entry and the tool list Aside cached for it. `programa aside status` shows whether Aside has
Programa registered.
