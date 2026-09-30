# Troubleshooting

## Log locations

| Log | Path | What it holds |
|---|---|---|
| Diagnostics (macOS) | `~/Library/Logs/Programa/diagnostics.log` | Always-on warning and error log, including control socket connections. Rotates at 2 MB to `diagnostics.log.1`. See [diagnostics.md](diagnostics.md). |
| Update (macOS) | `~/Library/Logs/programa-update.log` | Every step of an update check and install. Read it first for update bugs. |
| Launch (Windows) | `%LOCALAPPDATA%\Programa\launch.log` | Every launch attempt and its outcome. Read it when the app shows no window. |
| Debug event log (Debug builds) | `/tmp/programa-debug.log`, or `/tmp/programa-debug-<tag>.log` for a tagged build | Keys, mouse, focus, splits and tabs. The path of the latest one is in `/tmp/programa-last-debug-log-path`. |
| Debug background log (Debug builds) | The debug log path with `-bg` before `.log` | Background terminal events. |

The Debug logs exist only in Debug builds, and `PROGRAMA_DEBUG_LOG` overrides the path. Release
builds keep the diagnostics and update logs. `PROGRAMA_DIAGNOSTICS_LOG` overrides the diagnostics
path. The other variables are in [environment-variables.md](environment-variables.md).

```bash
tail -f ~/Library/Logs/Programa/diagnostics.log
```

## Find the control socket

The CLI and MCP server find the socket on their own. When they cannot, look for it yourself.

```bash
# Inside a Programa terminal
echo "$PROGRAMA_SOCKET_PATH"

# Anywhere: the release socket and the last socket the app wrote down
ls -l ~/Library/Application\ Support/programa/
cat ~/Library/Application\ Support/programa/last-socket-path

# Ask the app that answers
programa ping
programa identify
```

Debug and tagged builds use `/tmp/programa-debug.sock` and `/tmp/programa-debug-<tag>.sock`. To
talk to a specific instance, pass `--socket <path>` or set `PROGRAMA_SOCKET_PATH`. If the CLI
connects to the wrong app, or a script inside a Programa terminal reaches the app that hosts it
instead of the one you meant, the environment is overriding the choice; see
[socket-api.md](socket-api.md#how-clients-find-it).

Common symptoms:

- `Access denied — only processes started inside Programa can connect`: the socket is in the
  default `programaOnly` mode and the caller was not started from a Programa terminal. Change
  `automation.socketControlMode` or run the command from inside Programa.
- `auth_required` or `auth_failed`: the socket is in `password` mode. Pass `--password`, or set
  `PROGRAMA_SOCKET_PASSWORD`.
- Connection refused or no such file: Programa is not running, or the socket mode is `off`.

## Bug report checklist

Include:

1. What you did, what you expected, and what happened.
2. The output of `programa version`. On Windows, the version shown in the About box.
3. macOS or Windows version, CPU architecture, and display scaling for a rendering bug.
4. The end of the diagnostics log (macOS), the update log for an update problem, or `launch.log`
   (Windows) for a launch problem. Redact anything private first.
5. For a socket or CLI bug, the socket mode and the socket path from the steps above.
6. Whether it reproduces in a fresh workspace, and whether `PROGRAMA_DISABLE_SESSION_RESTORE=1`
   changes the behavior when the problem appears at launch.
7. For a crash, the crash report from Console under User Reports.

The logs stay on your machine. Nothing is sent anywhere unless you attach it.
