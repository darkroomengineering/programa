# browsee: the browser for agents

Programa does not embed a browser. When a coding agent in a Programa pane needs one, for local
previews, smoke tests, screenshots, logged-in sites, private dashboards or CI logs, it uses
**browsee**, Darkroom's agent browser. browsee keeps the sessions and cookies, and Programa
registers its MCP server with Claude Code and Codex so the agent drives browsee tabs instead
of a Chrome extension.

## Setup

```bash
programa browsee status          # where browsee is, whether it is running, what is registered where
programa browsee install-mcp     # registers `browsee` with Claude Code and Codex
programa browsee uninstall-mcp
```

`File > Install browsee MCP…` runs the same installer in a new workspace. The installer
lists the `claude mcp add` and `codex mcp add` commands it will run and asks first; `--yes`
skips the question. Agents pick up the server the next time they start.

Then turn on **Let other apps control my tabs** in browsee > Settings > Agents. browsee
serves no agent it did not start while that setting is off, and `browsee-mcp` says so.

## What the agent gets

Both clients run `programa browsee mcp`, which runs `browsee-mcp` from
`browsee.app/Contents/MacOS/` (looked up in `~/Applications`, then `/Applications`):

- **One session per pane.** Inside a Programa pane the session is `programa-<surface id>`,
  so each pane's agent sees and acts only on the tabs it opened. Codex hands MCP servers a
  filtered environment without the surface id, so every Codex agent shares the session
  `programa`. The tabs show in browsee as agent tabs.
- **browsee's rules stay on.** These sessions are ask-first, and no setting changes that.
  Purchases, deletes, sign-ins and closing one of your tabs always ask, on the Mac, in
  browsee. With "Let agents see my other tabs" on, the agent also sees your tabs, and closing
  one asks.
- **A closed browsee starts.** When browsee's socket does not answer, the server starts
  browsee in the background (`open -g -b com.darkroom.browsee`), waits up to 8 seconds for
  it, and then connects. If browsee never comes up, the server fails with an error that says
  so, and the agent reports the `browsee` server as failed.

While "Let other apps control my tabs" is on, any process running as you can connect to
browsee, not only Programa's agents.

## Sending links to browsee

Cmd-clicked terminal links and `open https://...` leave Programa for the macOS default
browser. Make browsee the default browser in System Settings > Desktop & Dock and those
links land in the browser that has your logins.
