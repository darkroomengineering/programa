# Diagnostics log

Programa keeps a small, always-on, local-only diagnostics log so real bug reports (e.g.
"sockets keep disconnecting") come with evidence, even from a Release build where the
Debug-only event log (`DebugEventLog` / `dlog`, see `CLAUDE.md` "Debug event log") isn't
compiled in.

**Nothing in this log ever leaves the machine.** It is a plain local file append — no
network calls, no telemetry service, no analytics SDK. There is no settings toggle for it;
it is always on at error/warning level by design (narrow surface area, nothing to configure).

## Log path

Default location:

```
~/Library/Logs/Programa/diagnostics.log
```

Override with the `PROGRAMA_DIAGNOSTICS_LOG` environment variable (useful for tagged dev
builds that want a per-tag path, same convention as `PROGRAMA_DEBUG_LOG`):

```bash
PROGRAMA_DIAGNOSTICS_LOG=/tmp/programa-diagnostics-my-tag.log ./scripts/reload.sh --tag my-tag --launch
```

## Rotation

The file is capped at 2 MB. When a write would push it over the cap, the current file is
rotated to `diagnostics.log.1` (overwriting any previous `.1`) and a fresh file is started.
At most 4 MB of diagnostics data is ever kept on disk.

## Tailing

```bash
tail -f ~/Library/Logs/Programa/diagnostics.log
```

## What gets logged

Currently: the Unix socket/control-protocol subsystem (`Sources/TerminalController.swift`,
`Sources/TerminalController+Subscriptions.swift`) — listener start/stop, accept-loop errors
and rearm/resume events, connections that close abnormally (`read_error`, `access_denied`,
`listener_stopped`, `policy_revoked`, `payload_too_large`, `invalid_utf8`,
`auth_failed_limit`), connections that lasted a second or more, and event-subscription
teardown. Short `eof` closes and the CLI's connect-and-hang-up liveness probe
(`access_denied_unverified`) come with almost every CLI call, so they are not logged;
otherwise they fill the 4 MB in a day or two and push out the session lines below. Session escrow,
agent exit and leftover-process reaper events are logged too (`escrow.*`, `agent`,
`reaper`, `surface`). Log lines look like:

```
2026-08-04T18:22:11.402Z socket.conn close pid=41213 reason=read_error errno=54 durationMs=1279
2026-11-04T16:01:46.862Z escrow.reattach session=F2B19125 outcome=revived newPanel=BE3B79C2
```

The facility itself (`DiagnosticsLog` / `dilog(_:_:)` in
`vendor/bonsplit/Sources/Bonsplit/Public/DiagnosticsLog.swift`) is generic — any subsystem
can call `dilog("category", "message")` from any thread without blocking. It intentionally
has no log-level enum or category registry; category is just a free-form string prefix.
