# `programa.json`

Custom command-palette entries, shareable via git. Programa looks for `programa.json`
by walking up from the focused workspace's current
directory, and always loads `~/.config/programa/programa.json` as a global fallback. Local entries take precedence over global ones
with the same `name`. Event routes are the exception: they load from the global file only (see
[`routes`](#routes)).

The Swift structs in `Sources/ProgramaConfig.swift` (`ProgramaConfigFile`,
`ProgramaCommandDefinition`, `ProgramaRecipeDefinition`, `ProgramaParameterDefinition`, ...) are
the authoritative schema; this file is a human-readable summary. Comments (`//`, `/* */`) and
trailing commas are accepted (JSONC).

```jsonc
{
  "commands": [ /* ... */ ],
  "recipes": [ /* ... */ ],
  "routes": [ /* ... */ ]
}
```

Every key is optional, so a file with only `routes` loads.

## Trust

`programa.json` can arrive by cloning someone else's repo, so it is treated as untrusted input
until the user explicitly trusts the directory it came from (the "Always trust commands from
this folder" checkbox on the confirmation dialog). Until then, every command and every recipe
is confirmed before it runs or sends anything, regardless of what the file itself says. See
`ProgramaConfigExecutor.requiresConfirmation` for the exact rule.

## `commands`

Each entry is either a `workspace` command (opens/recreates a named workspace with a saved
layout) or a `command` command (types a shell command into the focused terminal and submits it).

```jsonc
{
  "name": "Run tests",
  "description": "Shown as the palette subtitle",
  "keywords": ["test", "ci"],
  "command": "npm test",
  "confirm": false
}
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | required, non-blank |
| `description` | string? | palette subtitle; falls back to `"programa.json"` |
| `keywords` | string[]? | extra palette search terms |
| `command` | string? | shell text, submitted with a trailing newline. Mutually exclusive with `workspace` -- exactly one of the two is required |
| `workspace` | object? | `{name?, cwd?, color?, layout?}` -- opens a workspace, optionally with a saved pane/split layout |
| `restart` | `"recreate" \| "ignore" \| "confirm"`? | what to do if a workspace with the same name already exists (workspace commands only) |
| `confirm` | bool? | forces the confirmation dialog even in a trusted directory ("ask me anyway") |
| `parameters` | array? | see below; substituted into `command` before it runs |

## `recipes`

A recipe fills a text prompt template and delivers it into the focused terminal for the user to
review and send themselves -- it never runs anything and never auto-submits. This is the
mechanism for a shared, git-tracked library of prompts to hand a coding agent, without letting a
cloned repo fire attacker-chosen text straight at that agent.

```jsonc
{
  "name": "Fix a bug",
  "description": "Ask the agent to fix a specific bug",
  "keywords": ["bug", "fix"],
  "prompt": "Please fix the bug in {{file}}: {{description}}",
  "parameters": [
    { "name": "file", "prompt": "File path" },
    { "name": "description", "prompt": "What's wrong", "default": "it crashes" }
  ]
}
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | required, non-blank |
| `description` | string? | palette subtitle; falls back to `"programa.json"` |
| `keywords` | string[]? | extra palette search terms |
| `prompt` | string | required, non-blank. May contain `{{name}}` placeholders |
| `parameters` | array? | see below |

Selecting a recipe: collects any declared parameter values, substitutes them into `prompt`, goes
through the same confirmation gate as a command (showing the **fully substituted** prompt, never
the raw template), then types the result into the focused terminal **without** a trailing
newline. Nothing is sent until the user presses Return themselves.

## `parameters` (commands and recipes)

```jsonc
{ "name": "branch", "prompt": "Branch name", "default": "main" }
```

| Field | Type | Notes |
|---|---|---|
| `name` | string | referenced in the template as `{{name}}` |
| `prompt` | string? | label shown when asking for a value; defaults to `name` |
| `default` | string? | pre-filled value |

Selecting a command or recipe with `parameters` prompts once per declared parameter, in
declaration order, via a simple text-field dialog. Canceling any prompt aborts the whole thing --
nothing runs or is sent.

Substitution replaces every `{{name}}` occurrence with the collected value. A `{{...}}` that
matches no declared parameter is left **literal** (including its braces) -- it is never an error
and never stripped. Substituted values are **not** shell-quoted in `command` templates: the user
typed them, and quoting would break legitimate uses like passing flags. The confirmation dialog
showing the final substituted string is the control here, not escaping.

## `routes`

A route runs one action when an agent or workspace event happens: show a notification when an
agent asks a question, run the tests when an agent in a worktree goes idle, open the review panel
when it finishes a turn. The app evaluates routes itself; nothing has to stay subscribed to
`programa watch-events`.

```jsonc
// ~/.config/programa/programa.json
{
  "routes": [
    {
      "name": "blocked-question",
      "on": "agent/+/needs_input/question",
      "throttleMs": "5m",
      "notify": { "title": "Agent needs you", "body": "{{body}}" }
    },
    {
      "name": "tests-on-idle",
      "on": "agent/+/state/idle",
      "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
      "debounceMs": 2000,
      "run": { "command": "npm test" }
    },
    {
      "name": "review-on-idle",
      "on": "agent/+/state/idle",
      "when": { "previous_state": { "in": ["working", "blocked"] }, "worktree": "true" },
      "debounceMs": 2000,
      "review": {}
    }
  ]
}
```

`programa routes` lists the loaded routes with their counters and last error, and every route
that did not load. `programa --json routes` prints the raw `routes.list` result
([socket-api.md](socket-api.md#event-routes-routeslist)).

### Where routes load from

Routes load from `~/.config/programa/programa.json` only. A route runs with no person present,
and the trust dialog that guards a project's `programa.json` cannot be shown to nobody, so a
`routes` key in a project file is ignored.

The routes reload when the global file's settings change. Any such change, including a change to
a command, installs the routes again (an edit to comments or formatting alone does not): counters and last errors reset, throttle and debounce
windows start over, and a `send` or `prompt` waiting to be delivered is dropped. A `run` process
already started keeps running until it exits or reaches its timeout.

A route that fails to load does not cost the file anything else: every other route, command and
recipe still loads, and the failure is listed under `issues` in `programa routes`. When the
global file loads with at least one such issue, Programa posts one notification that names the
first failing route and how many more there are. It posts again only when the file's settings
change, and also when the app starts with a file that still has issues.

### Fields of a route

| Field | Type | Notes |
|---|---|---|
| `name` | string | Required, non-blank, unique in the file. |
| `on` | string | Required. The topic pattern, see below. |
| `when` | object? | Conditions on the event's fields, see below. |
| `debounceMs` | number or duration? | Handle only the last matching event of a burst, after this long without another match. |
| `throttleMs` | number or duration? | Fire at most once per window, on the first match. Required for `prompt`, at least 60000 (one minute). |
| `key` | string? | Template for what shares a debounce and throttle window. Default `{{topic}}`. |
| `notify`, `send`, `prompt`, `run`, `review` | object | The action. A route has exactly one. |

A duration is a whole number of milliseconds or a string with a unit: `"250ms"`, `"4s"`,
`"1.5m"`, `"5m"`, `"1h"`. It must not be negative; `0` means the same as leaving it out.

### Topics

A topic is a path of levels separated by `/`. The id level is a UUID, so a pattern names it
with `+`.

| Topic | Event | Last level |
|---|---|---|
| `agent/<surface_id>/state/<value>` | the agent's state changes | `working`, `blocked`, `idle`, or `none` when the state is cleared |
| `agent/<surface_id>/needs_input/<value>` | an `agent.needs_input` call | `permission`, `question`, or `unknown` when the call gave no kind |
| `workspace/<workspace_id>/<value>` | a workspace changes | `created`, `closed`, `renamed` |

Patterns follow MQTT: `+` matches exactly one level, and `#`, allowed only as the last level,
matches the rest, including nothing (`agent/#` also matches `agent`). A level cannot mix a
wildcard with text, and no level may be empty. Terminal output is not a route event, so a
pattern whose first level is `surface` does not load.

Only real transitions publish an `agent_state` event: an agent that reports the same state again
from the same source does not.

### Event fields

`when`, `key` and the action text read the event's fields by name. A field whose value is empty
or null is absent. Numbers are their decimal text.

| Field | Events | Trust | Value |
|---|---|---|---|
| `topic` | all | identifier | The event's topic. |
| `workspace_id` | all | identifier | |
| `surface_id` | `agent/…` | identifier | |
| `state` | `agent/+/state/+` | identifier | `working`, `blocked` or `idle`; absent on a clear. |
| `previous_state` | `agent/+/state/+` | identifier | The state before this transition; absent when there was none. A session that starts reports `idle` with no `previous_state`. |
| `source` | `agent/+/state/+` | identifier | `hooks`, `inferred` or `program`. |
| `program_status.<key>` | `agent/+/state/+` | free text | The `program_status` object, one field per key, when `source` is `program`. |
| `kind` | `needs_input`, `workspace/…` | identifier | `permission` or `question`; for a workspace, `created`, `closed` or `renamed`. |
| `provider`, `title`, `subtitle`, `body` | `needs_input` | free text | Taken from the `agent.needs_input` call. `title` carries the surface's custom title suffix. |
| `title` | `workspace/…` | free text | The workspace's title. |
| `ts` | all | identifier | Seconds since 1970, with a fraction. |
| `cwd` | `agent/…` | free text | The directory the surface's shell last reported (OSC 7 or `surface.report_pwd`), with symlinks and `..` resolved when it was reported. Absent when the surface has not reported one, or the report is not an existing absolute directory. |
| `git_branch` | `agent/…` | free text | The surface's branch. |
| `worktree` | `agent/…` | identifier | `"true"` when the surface's workspace was opened by `worktree.create` or `worktree.open`, else `"false"`. |

`cwd`, `git_branch` and `worktree` are absent once the surface's workspace is closed.

Because `cwd` is resolved, it is the real path: on macOS a shell in `/tmp/x` has the `cwd`
`/private/tmp/x`, and `/var/folders/…` is `/private/var/folders/…`. Anchor a `cwd` regex at the
start and end it at a separator, so it names exactly the tree you mean:
`{ "cwd": { "regex": "^/Users/me/work/app(/|$)" } }`. Without the anchor, `/Users/me/work/app`
also matches `/tmp/Users/me/work/app` and `/Users/me/work/app-old`.
`previous_state`, `cwd`, `git_branch` and `worktree` exist only for routes: the frames that
`programa watch-events` prints do not carry them.

The trust class decides where a field may go. Free text can be written by an agent, or carry text
an agent read from a web page or an issue, so it never goes into text a route sends to an agent.
`provider` is free text because the agent's hook chooses it.

### `when`

Every key of `when` names a field, and every key must hold.

| Value | Holds when |
|---|---|
| string, number or boolean | the field equals it (`true` equals `"true"`) |
| `{ "ne": v }` | the field is absent or not equal to `v` |
| `{ "in": [ ... ] }` | the field equals one of the values |
| `{ "exists": true }` | the field is present (`false`: absent) |
| `{ "regex": "...", "flags": "i" }` | the pattern matches somewhere in the field; flags are `i`, `m`, `s` and `x` |

One field can combine several operators, and all of them must hold. An absent field fails every
condition except `ne` and `exists: false`. A regex sees only the first 4096 UTF-16 units of the
field. An unknown operator, a regex that does not compile, `flags` without `regex`, an operator
object with no condition, or a regex that repeats a group which already repeats (such as `(a+)+`
or `(\w+\s?)*`, which can take exponential time) makes the route fail to load.

### The gate: `debounceMs`, `throttleMs` and `key`

Each match goes through, in order: the topic, `when`, `key`, the debounce, the throttle, and then
the action. Each (route, rendered `key`) pair has its own gate. The default key, `{{topic}}`,
gives every surface and every value its own window; `"key": "{{surface_id}}"` makes all states of
one surface share one. A placeholder for a field the event lacks stays as the literal
`{{name}}` text in the key.

- **Debounce** restarts its timer on every match and handles the newest event once the timer
  runs out. An event that does not match does not cancel it.
- **Throttle** lets the first match through and drops the matches that follow until the window
  ends. With both set, the debounced event is dropped when it lands inside the window.
- An action that takes time holds its route until it ends: a `run` until its process exits, a
  `send` or `prompt` until its text is delivered, and a submitted `prompt` until its turn ends.
  Matches meanwhile are dropped. A delivery still held after its timeout is cancelled.

`programa routes` counts each outcome per route:

| Counter | Counts |
|---|---|
| `matched` | events that passed the topic and `when` |
| `fired` | actions run |
| `throttled` | matches the throttle dropped |
| `busy` | matches dropped while the route's last action still held it, and `prompt` matches skipped while any route's prompt turn holds the surface |
| `expired` | deliveries cancelled at their timeout |

### Actions

Templates use `{{field}}`, and every placeholder must name a field from the table above, or the
route does not load.

**`notify: { title, subtitle?, body? }`** posts a notification for the event's workspace and
surface, with the same title suffix the built-in notifications use. All three fields may be
templated, and a placeholder for an absent field renders empty. When the workspace is already
closed, the notification is an app-level one instead. A `notify` route for a `needs_input` event
honours `notification.claim_banners`, as the built-in notification does.

A notify route also decides the built-in banner of the `agent.needs_input` call it matches:

- A **question** shows no built-in banner when a notify route matches it on topic and `when`,
  whether or not the route fires. With `"throttleMs": "5m"`, the person sees
  one banner per five minutes, and it is the route's.
- A **permission** prompt, or a call with no kind, shows no built-in banner only when a notify
  route fires for that very
  call, so the route's notification is the one shown. A route that is throttling or debouncing
  never hides a permission banner.

Either way, the built-in entry still goes to the notification list, the sidebar and the Dock
badge.

**`review: { mode?, baseBranch? }`** opens the review panel beside the event's surface, without
moving focus or bringing the app forward. `mode` is `uncommitted` (the default) or `branch`, and
`baseBranch` defaults to `origin/main`. Nothing happens when the workspace already shows a review
panel, or a route is opening one there. Outside a git repository the panel does not open and the
route's last error says why.

**`run: { command, timeoutMs? }`** runs `command` in the background as `<shell> -lc '<command>'`,
where `<shell>` is your account's login shell (`$SHELL` when the account names none), in the
event surface's `cwd`. Nothing is shown in a terminal.

- `command` is never templated. Event fields arrive as environment variables named
  `PROGRAMA_ROUTE_<FIELD>`: the field name upper-cased, with every character other than a letter
  or digit turned into `_` (`surface_id` is `PROGRAMA_ROUTE_SURFACE_ID`, `program_status.state`
  is `PROGRAMA_ROUTE_PROGRAM_STATUS_STATE`). A `{{field}}` in `command` makes the route fail to
  load; braces that name no field are left to the shell.
- The directory must exist when the command starts. A route whose event has no `cwd` (a
  `workspace/…` event, or a surface whose reported directory does not resolve) does not run:
  its last error reads `could not start: the surface's working directory is unknown or does not
  exist` and the failure notification below is posted. There is no fallback directory.
- `timeoutMs` defaults to 600000 (10 minutes). At most 4 route commands run at once across the
  app; the others wait in order. A command waiting for a turn uses up its own timeout while it
  waits, so one that never gets a turn times out. A waiting command whose routes change before it
  starts never runs, and a notification says so.
- A zero exit is silent. A non-zero exit, a timeout or a failure to start posts a notification
  titled "Route “name” failed" and sets the route's last error. After a non-zero exit, the
  notification's body is the last 600 characters of the command's output (standard output, then
  standard error). That output is visible to anyone who sees the notification, so keep secrets
  out of what a route command prints.

**`send: { text, whenBusy? }`** pastes `text` into the event's surface and never presses Return.
**`prompt: { text, whenBusy? }`** pastes `text` and presses Return, which submits it to the
agent.

Text goes only to an agent, and only to one whose state reports name their writer: a program that
reports its own status (OSC 7501, as Claude Code does), or hooks whose reports carry a session id
(the `session_id` of `surface.report_agent_state` and `agent.needs_input`, which Programa's own
hooks send whenever the agent gives them one). Screen detection and hooks reports without a session id are not enough. Each case
below refuses the delivery, sends nothing, and records the reason as the route's last error.

- The surface has no agent state, a plain shell for example.
- The surface shows a permission or sign-in prompt, or a person has typed unsent input into it.
  Routes keep to this even when the automation settings let socket writes through.
- The agent's state reports name no session.
- The agent stopped on a permission or sign-in prompt and has not reported `working` since, from
  the same writer as the prompt or from the program's own status. A report that only closes the
  prompt box does not count.
- The agent report that fired the route names no session.
- The report that fired the route is the first one from this agent, so nothing shows that an
  agent is really there.

`whenBusy` is `queue` (the default) or `steer`:

- With `queue`, if the agent is `working` when the route fires, the text waits for the end of that
  work: an `idle` report that follows a `working` report, both from the same writer. An idle from
  anyone else, or one that follows `blocked`, does not release it. If the agent's state is cleared
  first, or 600 seconds pass, nothing is sent. The checks above run again when the text goes out.
- With `steer`, the text goes out at once.

`prompt` presses Return only for an agent Programa knows about that is not blocked and not stale;
otherwise the text is pasted without Return and the last error reads `pasted without submitting:
no agent ready for a prompt`. A submitted prompt holds its route for its turn: until the surface
reports `idle` after a `working` report in that turn, or its state is cleared, for at most 600
seconds. While any route's prompt turn holds a surface, including the idle that ends it, no
`prompt` route fires on that surface's events (they count as `busy`). A prompt route therefore
cannot trigger itself, and two prompt routes cannot feed each other.

- `text` may use identifier fields only. A free-text placeholder (`{{body}}`, `{{provider}}`,
  `{{cwd}}` and the others marked free text above) makes the route fail to load. A placeholder
  for an absent identifier renders empty.
- A `prompt` route must set `throttleMs` to at least 60000 (one minute), which bounds how often it
  can submit.

## Layout schema

A `workspace` command's `layout` field describes the panes and splits of a workspace. Saved
layouts (`programa layout save`) use the same schema. A layout is a tree of two node kinds.

A **pane** holds one or more surfaces (tabs):

```jsonc
{
  "pane": {
    "surfaces": [
      { "type": "terminal", "name": "server", "command": "npm run dev", "cwd": "app", "env": { "PORT": "3000" } },
      { "type": "terminal", "name": "shell", "focus": true }
    ]
  }
}
```

A **split** divides space between exactly two children:

```jsonc
{
  "direction": "horizontal",
  "split": 0.4,
  "children": [ { "pane": { /* ... */ } }, { "pane": { /* ... */ } } ]
}
```

| Field | Where | Type | Notes |
|---|---|---|---|
| `pane` | node | object | Marks a pane node. A node has `pane` or `direction`, never both. |
| `pane.surfaces` | pane | array | Required, at least one surface. |
| `direction` | split | `"horizontal" \| "vertical"` | `horizontal` puts the two children side by side, `vertical` stacks them. |
| `split` | split | number? | Position of the divider between 0 and 1, clamped to 0.1 to 0.9. Default `0.5`. |
| `children` | split | array | Required, exactly two nodes (panes or splits). |
| `surfaces[].type` | surface | `"terminal"` | Required. Older files may name `"browser"`; those surfaces are skipped, and a pane left with none opens one terminal. |
| `surfaces[].name` | surface | string? | Custom tab title. |
| `surfaces[].command` | surface | string? | Typed into the terminal with a trailing newline once it is ready. |
| `surfaces[].cwd` | surface | string? | Absolute, `~`-relative, or relative to the workspace's directory. Empty or `.` means the workspace directory. |
| `surfaces[].env` | surface | object? | Extra environment variables, string to string. |
| `surfaces[].focus` | surface | bool? | `true` focuses this surface after the layout is applied. The last one wins. |

A workspace's `color` must be a 6-digit hex value (`#RRGGBB`); anything else fails to load.

## Saved layouts

`programa layout save <name>` captures the selected workspace's pane and split geometry into
`~/.config/programa/layouts/<name>.json`. `programa layout apply <name>` creates a new, unfocused
workspace from it, or fills an unused workspace given with `--workspace`. `programa layout list`
lists the saved names. `save` refuses to overwrite an existing layout unless you pass `--force`.
A name must be non-empty and cannot contain `/`.

The file wraps the layout in an envelope:

```jsonc
{
  "schemaVersion": 1,
  "name": "fullstack-dev",
  "savedAt": "2026-09-29T10:00:00Z",
  "layout": { /* a pane or split node, as above */ }
}
```

The file name is the layout's name; if you copy or rename a file, its `name` field is ignored.
A saved layout records geometry, each terminal's directory (relative to the workspace directory
where possible) and custom tab titles. It does not record running commands,
environment variables or focus, and markdown panels are skipped. You can add `command`, `env` and
`focus` by hand. The `layout.save`, `layout.apply` and `layout.list` socket methods work on the
same files; see [socket-api.md](socket-api.md).
