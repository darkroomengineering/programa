# programa-cli

The `programa` command-line client for the Windows port. Each command sends one v2 request
(`{"id":1,"method":...,"params":{...}}` plus a newline) and reads one response line, the same
newline-delimited JSON protocol as the macOS socket (`contracts/v2/protocol.json`).

**Pipe path:** `--socket PATH`, else `PROGRAMA_SOCKET_PATH`, else `PROGRAMA_SOCKET`, else
`\\.\pipe\programa-%USERNAME%` (on Unix: `$HOME/Library/Application Support/programa/programa.sock`).
A busy pipe is retried for about a second; a missing one prints `Programa is not running` and exits 1.

A second binary, `programa-mcp` (`src/mcp.rs`), is the MCP server over stdio for agents (docs/mcp-server.md): tools named after the app's control methods, schemas from `contracts/v2/methods.json`.

**Commands:** `routes`, `usage [--workspace ID]` (tokens per recorded Claude Code or Codex session, from its transcript; `claude-hook` and `codex-hook` keep the session records in `~/.programa`), `codex install-integration|uninstall-integration [--yes]` (Programa's hooks in Codex's `hooks.json`, trusted in `config.toml`), `codex-hook <session-start|prompt-submit|stop|notification|session-end>` (run by those hooks; prints `{}`), `wait-surface (--pattern RE|--exit|--agent-state S|--program-state S) [--timeout SEC] [--lines N]`, `prompt-agent [--timeout SEC] [--working-grace SEC] [--force] [--answer-prompt] <text>`, `watch-events [--agent-state] [--workspace-lifecycle] [--needs-input] [--output IDS] [--no-reconnect]`, `move-surface [--surface ID] (--pane ID|--workspace ID|--window ID|new) [--before ID|--after ID|--index N] [--focus true|false]`, `storage scan`, `storage clean [--dry-run] [--include-external] [--now] [--path DIR]... [--packages|--caches] [--item ID]...`, `claude-hook <session-start|prompt-submit|stop|notification|pre-tool-use|post-tool-use|permission-request|subagent-start|subagent-stop|session-end>` (run by Claude Code hooks; reads the hook JSON on stdin, always exits 0), `list-windows`, `current-window`, `new-window`, `focus-window`, `close-window`, `move-workspace-to-window`, `race`, `resume`, `worktree create|open|remove|list`, `layout save|apply|list`, `markdown [open]`, `review open|refresh|comment|send`, `ping`, `identify`, `tree`, `list-workspaces`, `new-workspace`, `new-surface`,
`new-split [left|right|up|down]`, `select-workspace`, `close-workspace`, `rename-workspace`, `focus-surface`,
`close-surface`, `send` (escapes `\n \r \t \e \\`), `read-screen`, `notify --title`,
`list-notifications`, `clear-notifications`, `set-agent-state <working|blocked|idle|clear>`,
`set-status <key> <value> [--icon] [--color] [--url] [--priority] [--format] [--pid]`, `clear-status`, `list-status`,
`set-progress <0.0-1.0> [--label]`, `clear-progress`, `log [--level] [--source] <message>`, `clear-log`, `list-log [--limit N]`, `sidebar-state`,
`list-panes`, `list-pane-surfaces [--pane]`, `focus-pane <ID>`, `new-pane [--direction]`, `resize-pane -L|-R|-U|-D [--amount N]`,
`swap-pane --pane --target-pane`, `break-pane`, `join-pane --target-pane`, `last-pane`, `next-window`, `previous-window`, `last-window`,
`reorder-workspace <ID> (--index|--before|--after)`,
`list-ports`, `stop-port <PORT>|--pid PID` (a port resolves to its one listening pid).
Run `programa help` for every flag.

`--surface` and `--workspace` default to `PROGRAMA_SURFACE_ID` / `PROGRAMA_WORKSPACE_ID` (never for
`new-workspace`, `list-*` or `tree`); otherwise Programa uses the focused one. `--json` prints the raw
result. Exit codes: 0 success, 1 not running or an error response, 2 usage error.

Build: `cargo build -p programa-cli --release --target x86_64-pc-windows-msvc` from `core/`.
