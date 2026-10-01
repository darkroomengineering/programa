# Two browsers for agents: Programa's panel and Aside

Coding agents need a browser for two different jobs, and Programa treats them as two
different tools:

| Job | Use | Why |
| --- | --- | --- |
| Local previews, smoke tests, screenshots the agent reads back, DOM inspection, console and error logs | **Programa's embedded browser** | It lives next to the agent's pane, has its own per-workspace profile, never moves the user's focus, and every action is a socket method (`browser.*`) that the CLI and `programa-mcp` both expose. |
| Logged-in sites, private dashboards, CI logs, anything that depends on your real browsing profile and memory | **Aside** ([aside.com](https://aside.com)), a Chromium-based agent browser | Aside owns the sessions and cookies. Programa registers it with Claude Code and Codex so the agent can hand that work off instead of driving a Chrome extension. |

Neither replaces the other. Programa's panel is WKWebView, so it has no Chrome DevTools
Protocol and does not share cookies with Aside. Aside has the logins but is not a pane in
your workspace.

## Programa's browser from an agent

From a shell inside a Programa pane, the `programa browser` CLI covers the whole surface:

```bash
programa browser open-split https://localhost:3000          # new browser split beside this pane
programa browser --surface surface:7 snapshot --interactive # accessibility tree of interactive elements
programa browser --surface surface:7 click "button.submit" --snapshot-after
programa browser --surface surface:7 screenshot --out /tmp/after.png
programa browser --surface surface:7 tab close
```

Over MCP, the same methods are the `browser_*` tools in `programa-mcp` (`browser_open_split`,
`browser_navigate`, `browser_snapshot`, `browser_get_text`, `browser_screenshot`,
`browser_console_list`, and so on). Playwright-shaped tools for network routing, viewport
emulation and raw input injection do not exist: WKWebView has no DevTools Protocol to drive them. Only the three `focus_browser_*` tools move focus;
everything else leaves the user where they are. See [mcp-server.md](mcp-server.md) for the
full list and the setup.

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

Terminal links open in Programa's panel when the host is local or allowlisted, and in an
external browser otherwise. `Settings > Browser > Open External Links With` picks that
external browser; choose Aside there and every cmd-click that leaves Programa lands in the
browser that has your logins and agent memory. The same setting is `browser.externalBrowser`
in `~/.config/programa/settings.json` (a bundle identifier; empty means the macOS default).

## Aside driving Programa

The reverse direction, Aside dispatching work into a Claude Code or Codex pane, needs Aside
to act as an MCP client. Aside does not document that today. When it does, point it at
`Programa.app/Contents/Resources/bin/programa-mcp`: the `surface_send_text`,
`surface_read_text`, `surface_split`, and `surface_wait` tools already let a client start an
agent in a pane, send it a prompt, wait for it to go idle, and read the result, without
scraping a terminal screen. Nothing on Programa's side needs to change for that.
