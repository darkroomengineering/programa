# Agent detection manifests

Screen-manifest agent detection (see `docs/plans/screen-manifest-detection.md` for the full
design) infers `working`/`blocked`/`idle` status for terminal agent CLIs that have no installed
lifecycle hooks, by pattern-matching the visible terminal screen against a small declarative
manifest per agent. This doc is the schema reference for anyone adding or tuning a manifest —
contributing a new agent (e.g. a CLI not yet covered) or fixing a pattern that's gone stale after
an upstream UI change.

Wire-level behavior (report source tagging, hooks-always-win precedence) is documented in
`docs/v2-api-migration.md`'s `agent_state` sections; this doc is only about the manifest file
format itself.

## Location and precedence

- **Bundled**: `Resources/AgentDetection/<agent>.json`, shipped inside the app bundle.
- **User override**: `~/.config/programa/agent-detection/<agent>.json`. If present, it **fully
  replaces** the bundled manifest for that `agent` id — no field-level merge. This keeps the
  mental model simple: either you're using Programa's manifest for an agent, or your own,
  never a partial mix of both.

## Schema (v1)

```json
{
  "version": 1,
  "agent": "claude-code",
  "display_name": "Claude Code",
  "recognize": {
    "process_names": ["claude"],
    "screen_patterns": ["Claude Code v\\d"]
  },
  "states": [
    {
      "bucket": "blocked",
      "priority": 100,
      "anchor_last_n_lines": 12,
      "patterns": ["Do you want to .*\\?", "❯\\s*1\\.\\s*Yes"],
      "confidence": "verified",
      "source_notes": "Permission/approval prompt box."
    }
  ]
}
```

| Field | Notes |
|---|---|
| `version` | Schema version. Always `1` today. |
| `agent` | Stable id, matches the bundled filename (without extension). This is the lookup key (`surface.list`'s `agent_state` isn't tagged by agent id, but the loader/engine key manifests by it internally). |
| `display_name` | Human-readable name, for any future UI that lists detected agents. |
| `recognize.process_names` | Ideal Phase A signal: an exact foreground-command match. Not currently wired to a live signal — see the plan doc's §4 risk 1 for why v1 uses the `screen_patterns` fallback exclusively. Still worth filling in for forward-compatibility. |
| `recognize.screen_patterns` | Phase A fallback signal actually used in v1: checked against a not-yet-candidate surface's screen tail on a slow (~3s) cadence. Prefer patterns that are likely to still be on screen days into a session (a startup banner can scroll out of the sampled tail), not just a first-line banner. |
| `states[].bucket` | One of `working` \| `blocked` \| `idle` \| `done`. `done` is manifest-internal only — the engine reports it to the shared 3-value wire enum as `idle` (see plan §1.2). |
| `states[].priority` | Higher checked first within one sample; first matching bucket wins. Keep `blocked` highest — a permission prompt should never be shadowed by a lower-priority pattern. |
| `states[].anchor_last_n_lines` | Only the last N lines of the sampled text are matched against this bucket's patterns — keeps matching cheap and avoids false positives from scrollback-adjacent text (e.g. a `Do you want to...?` string that scrolled past isn't still "blocked"). |
| `states[].patterns` | `NSRegularExpression` (ICU) syntax. |
| `states[].confidence` | Free-form, greppable: `verified` \| `needs_verification` \| `low`. Never read by code — purely so contributors can `grep -r confidence.*low` to find what needs a closer pass. |
| `states[].source_notes` | Free-form context: what the pattern is trying to catch, caveats, which release it was last checked against. |

## Authoring guidance

- **Prefer fragments over full-line anchors.** Box-drawing borders (`│`/`╭`/`╰`) and prompt text
  commonly wrap at narrow terminal widths — `"Do you want to .*\\?"` is far more robust than
  trying to match an entire boxed line including its borders.
- **Don't enumerate transient wording you don't have to.** Claude Code's spinner rotates through
  whimsical verbs (Thinking/Pondering/Crunching/...) before the ellipsis — the bundled manifest
  matches the fixed `"✻ "` + ellipsis shape instead of every verb, so a new verb next release
  doesn't require a manifest update.
- **Mark anything you didn't verify against a live session.** `"confidence": "low"` or
  `"needs_verification"` plus a `source_notes` sentence saying what's uncertain. A wrong pattern
  that's honestly labeled is much easier to fix later than a silent guess.
- **`recognize.screen_patterns` should favor persistent UI over one-time banners** given v1's
  screen-pattern-fallback Phase A (see the plan doc's §4 risk 1) — a startup banner can scroll out
  of the sampled tail on a long-running session, but an "esc to interrupt" style working-indicator
  or a recurring prompt shape tends to reappear.
- **Test new/changed manifests** with `programaTests/AgentManifestTests.swift`'s pattern:
  `AgentManifest.classify(text:)` is a pure function, so you can feed it a real captured screen
  sample and assert the expected bucket with no app launch required.
