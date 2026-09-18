# Notifications

Programa provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

## Sidebar agent indicator

Each workspace row in the sidebar shows one agent indicator: a glyph plus a short label, "Needs input", "Working", or "Idle". Earlier builds showed this same state in up to three places at once (a badge, a "Running"/"Waiting"/"Needs input" status row, and the notification text); it's now just the one indicator, so there's nothing to double-check or fall out of sync. Verbose per-tool status text still appears in its own row when the Claude Code verbose status setting is on, but it no longer duplicates the working/idle state itself.

"Needs input" appears only when a hook actually reports the agent is blocked on you (a permission prompt or a question), and it clears only when the agent resumes: a hook reports it's working or idle again, or the session ends. Opening or focusing the workspace does not clear it. It marks the notification read, but the agent still shows as needing input until the agent itself says otherwise. This is deliberate: closing the tab shouldn't silently answer a question that's still open.

If ten minutes pass with no hook update while an agent is marked "Working" or "Needs input", the indicator dims and its label grows a "(stale)" suffix ("Needs input (stale)", "Working (stale)"). Stale never clears itself; it's a signal that programa hasn't heard from the agent in a while, not a claim that the agent has actually stopped. A background watchdog also clears the indicator outright if the underlying agent process has died. Idle never goes stale, since it's already the resting state. Relaunching the app always starts with no agent indicators; the next hook event from a running agent restores it within one turn.

## Quick Start

```bash
# Send a notification (if programa is available)
command -v programa &>/dev/null && programa notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v programa &>/dev/null && programa notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `programa` CLI is available before using it:

```bash
# Shell
if command -v programa &>/dev/null; then
    programa notify --title "Hello"
fi

# One-liner with fallback
command -v programa &>/dev/null && programa notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("programa"):
        subprocess.run(["programa", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
programa notify --title "Build Complete"

# With subtitle and body
programa notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify specific tab/panel
programa notify --title "Done" --tab 0 --panel 1
```

## Integration Examples

### Claude Code

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for hook configuration.

### GitHub Copilot CLI

Copilot CLI supports [hooks](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks) that run shell commands at key lifecycle events. Add to `~/.copilot/config.json`:

```json
{
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "if command -v programa &>/dev/null; then programa set-status copilot_cli Running; fi",
        "timeoutSec": 3
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "if command -v programa &>/dev/null; then programa notify --title 'Copilot CLI' --body 'Done'; programa set-status copilot_cli Idle; else osascript -e 'display notification \"Done\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "errorOccurred": [
      {
        "type": "command",
        "bash": "if command -v programa &>/dev/null; then programa notify --title 'Copilot CLI' --subtitle 'Error' --body \"$(cat | jq -r '.errorMessage // \"An error occurred\"' 2>/dev/null | head -c 100)\"; programa set-status copilot_cli Error; else osascript -e 'display notification \"An error occurred\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "if command -v programa &>/dev/null; then programa clear-status copilot_cli; fi",
        "timeoutSec": 3
      }
    ]
  }
}
```

Or for repo-level hooks, create `.github/hooks/notify.json`:

```json
{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [ ... ],
    "agentStop": [ ... ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v programa &>/dev/null && programa notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v programa &>/dev/null && programa notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode Plugin

Create `.opencode/plugins/programa-notify.js`:

```javascript
export const ProgramaNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v programa && programa notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

## Environment Variables

Programa sets these in child shells:

| Variable | Description |
|----------|-------------|
| `PROGRAMA_SOCKET_PATH` | Path to control socket |
| `PROGRAMA_TAB_ID` | UUID of the current tab |
| `PROGRAMA_PANEL_ID` | UUID of the current panel |
| `PROGRAMA_DEFAULT_BROWSER` | Short key of the system default browser (e.g. `chrome`, `safari`, `arc`) -- see [v2-api-migration.md](v2-api-migration.md#browser-availability-appbrowsers-programa_default_browser) |
| `PROGRAMA_DEFAULT_BROWSER_BUNDLE_ID` | Bundle identifier of the system default browser |

## CLI Commands

```
programa notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
programa list-notifications
programa clear-notifications
programa set-status <key> <value>
programa clear-status <key>
programa ping
```

## Best Practices

1. **Always check availability first** - Use `command -v programa` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
