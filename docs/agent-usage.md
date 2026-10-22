# Agent token usage

## What the agents record

Programa does not meter agents itself. Claude Code and Codex each write a JSONL transcript per
session, and both put token counts in it. Their hooks pass the transcript's location to
Programa as `transcript_path`, next to `session_id` and `cwd`.

### Claude Code

- **Location:** `~/.claude/projects/<encoded cwd>/<session_id>.jsonl`. The file name is the
  session id. Subagent transcripts live next to it in
  `<session_id>/subagents/**/agent-*.jsonl`, with the same line format and
  `isSidechain: true`. They are a large share of a session's tokens.
- **Token lines:** assistant lines (`type: "assistant"`) carry `message.usage` with integer
  `input_tokens`, `output_tokens`, `cache_creation_input_tokens` and `cache_read_input_tokens`.
  `input_tokens` excludes both cache counts. `message.id` and `message.model` sit beside it.
- **Dedupe:** one API response is written as several lines, one per content block, all with the
  same `message.id` (and the same top-level `requestId`). Lines that repeat a `message.id` carry
  either the same usage values or all zeros, so the rule is: count each `message.id` once, using
  its line with the largest token total. A subagent transcript can repeat a `message.id` from
  the main transcript, so the dedupe spans the main file and its subagent files.
- **Skipped lines:** `message.model == "<synthetic>"` marks locally generated messages with zero
  usage.
- **Advisor tokens:** `message.usage.iterations[]` lists each model call inside one response.
  Entries of `type: "advisor_message"` carry their own `model` and token counts, and those are
  not part of the top-level `usage` fields.
- **Cost:** no per-message cost exists. Some transcripts contain a `type: "cost-state"` line with
  `totalCostUSD` and `modelUsage.<model>.costUSD`, but it is a point-in-time snapshot of the
  whole Claude Code process: it appears zero to two times per file, mid-file, and its token
  totals are several times the transcript's own totals, so it cannot be attributed to the
  session.

### Codex

- **Location:** `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<thread id>.jsonl`. The
  thread id is `session_meta.payload.id` on the first line.
- **Token lines:**
  - `type: "token_usage_record"` lines, one per model response, with `payload.response_id` and
    `payload.usage`. `payload.turn_token_usage` and `payload.thread_token_usage` hold running
    totals.
  - `type: "event_msg"` lines with `payload.type: "token_count"` carry
    `payload.info.total_token_usage` (running total for the thread) and
    `payload.info.last_token_usage`. `payload.info` can be null.
  - Each usage object has `input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`,
    `output_tokens`, `reasoning_output_tokens` and `total_tokens`.
- **Field meaning:** `input_tokens` includes `cached_input_tokens`, and `total_tokens` equals
  `input_tokens + output_tokens`. `output_tokens` includes `reasoning_output_tokens`.
  `cache_write_input_tokens` is 0 in every record observed, so whether `input_tokens` also
  includes it is not visible in the data.
- **Dedupe:** count each `token_usage_record` `response_id` once. `token_count` events repeat
  (the same running total is often emitted twice) and the running total can drop after a
  resume, so summing `last_token_usage` double-counts and the last `total_token_usage` can
  undercount. The record sum matches the largest `total_token_usage` in most files; when a file
  has no records, the largest `total_token_usage` is the fallback.
- **Cost:** none. `token_count` also carries `payload.rate_limits` (plan usage percentages and a
  credit balance), which is account-wide, not per session.
- **Hook payload:** every Codex hook input (`SessionStart`, `UserPromptSubmit`, `Stop`,
  `SessionEnd` and the tool hooks) declares `session_id`, `cwd`, `hook_event_name` and a
  nullable `transcript_path`.

### How Programa maps a session to a workspace

The `claude-hook` and `codex-hook` commands keep one record per live session in
`~/.programa/claude-hook-sessions.json` and `~/.programa/codex-hook-sessions.json`, keyed by
`session_id`, with `workspaceId`, `surfaceId`, `cwd` and `transcriptPath`. Records expire 7 days
after their last update. `session-end` removes the live record and adds the session to
`~/.programa/agent-last-sessions.json`, which keeps at most one ended session per pane and per
directory, 50 entries, for 7 days. Ended sessions that a newer one replaced are no longer known.
OpenCode hooks pass no transcript, so OpenCode sessions have no token counts.

## `programa usage`

```sh
programa usage                          # every workspace
programa usage --workspace workspace:2  # one workspace
programa usage --json
```

`usage` lists the Claude Code and Codex sessions in the hook stores above, grouped by workspace,
with four token counts per session and a total per workspace:

| Column | Claude Code | Codex |
|---|---|---|
| input | `input_tokens` | `input_tokens - cached_input_tokens` |
| output | `output_tokens` | `output_tokens` (includes reasoning) |
| cache read | `cache_read_input_tokens` | `cached_input_tokens` |
| cache write | `cache_creation_input_tokens` | `cache_write_input_tokens` |

- Counts are read from the transcripts each time the command runs, one line at a time. Nothing
  runs in the background, and the sidebar does not show them.
- Claude Code counts include the session's subagent transcripts and exclude advisor-model
  iterations.
- A session recorded without a transcript path is looked up by id under `$CLAUDE_CONFIG_DIR`
  (default `~/.claude`) or `$CODEX_HOME` (default `~/.codex`).
- Sessions whose transcript is missing or unreadable are skipped. The text output ends with how
  many; `--json` lists them under `skipped`.
- A workspace that is no longer open is shown by its id, marked closed.
- There is no cost column: neither agent records a cost per session, and Programa does not keep
  a price table.
- Each session's state is `live` (still in a live hook store) or `ended`.
- In `--json`, each workspace has `id`, `ref`, `title`, `open`, `sessions[]` (`provider`,
  `session_id`, `state`, `tokens`) and `tokens`; the top level has `tokens` for all workspaces
  and `skipped`.
