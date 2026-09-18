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

Since docs/plans/agent-state-unification.md, a manifest classification writes the same
`AgentPresence` record (state, source, and a timestamp) that hook reports write, so an inferred
`blocked`/`working` state goes stale and dims in the sidebar on the same 10-minute rule described
in `docs/notifications.md`, instead of sitting fixed once written. It still loses outright to any
surface that has ever received a hook report — hooks-always-win precedence is unchanged.

## Location and precedence

- **Bundled**: `Resources/AgentDetection/<agent>.json`, shipped inside the app bundle. Programa
  deliberately ships only the agents the team can actually run and verify against — it does not
  add more bundled manifests for agents nobody here uses.
- **User override**: `~/.config/programa/agent-detection/<agent>.json`. If present, it **fully
  replaces** the bundled manifest for that `agent` id — no field-level merge. This keeps the
  mental model simple: either you're using Programa's manifest for an agent, or your own,
  never a partial mix of both.

## Authoring your own with `programa agent-detection`

For any agent programa doesn't ship a bundled manifest for, `programa agent-detection` scaffolds
and verifies a user override without hand-writing JSON from scratch:

1. Run the target agent in a pane, in whatever state you want to capture, then
   `programa agent-detection scaffold <agent-id>` — it captures that pane's current screen and
   writes a starter manifest to `~/.config/programa/agent-detection/<agent-id>.json`, with the
   captured screen embedded as reference text in each state's `source_notes` (JSON has no
   comments). All three `states[].patterns` arrays start empty — safe by construction (an empty
   list matches nothing, never everything — see `AgentManifest.classify(text:)`), but useless
   until you fill them in.
2. Edit the generated file: write real regex patterns for `blocked`/`working`/`idle` (and
   `recognize.screen_patterns`, left empty by the scaffold too) using the reference screen text
   in each state's `source_notes` and the authoring guidance below.
3. Re-run the agent into the state you just wrote a pattern for, then
   `programa agent-detection test <agent-id>` to classify the live screen through the real
   `classify(text:)` path and confirm it lands in the bucket you expect. Repeat per bucket.
4. `programa agent-detection test` (no agent id) runs the real Phase A recognition too — useful
   once `recognize.screen_patterns` is filled in, to confirm programa would actually promote this
   surface as a candidate for your manifest during live detection, not just when explicitly named.
5. `programa agent-detection list` shows every currently loaded manifest (bundled + overrides)
   with its source, to confirm your override is actually being picked up. If an override is
   shadowing a bundled manifest, `list` marks it as `[shadows bundled manifest]`.

**`scaffold` refuses to touch one of the seven bundled agent ids** (`claude-code`, `codex`,
`gemini-cli`, `opencode`, `copilot-cli`, `cursor-agent`, `aider`) unless you pass `--force`.
Since an override *fully replaces* the bundled manifest and a fresh scaffold starts with empty
`patterns`, scaffolding one of these without `--force` would silently kill working screen-based
detection for that agent — you'd get no error, detection would just stop. Passing `--force`
seeds the new file with the bundled manifest's own patterns (fetched live, not re-typed) instead
of starting blank, so you're editing a copy of what already worked.

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
