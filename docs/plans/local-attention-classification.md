## Functional DAG

```text
docs/plans/agent-state-unification.md ──┐
https://github.com/mizorewww/laya-mlx ──┴── P1 define baseline and evaluation ── P2 evaluate local backend ── P3 implement optional integration ── P4 verify both platforms
```

# Local workspace attention classification

Status: queued; implementation and measurements pending.

## Intent and continuity

Make it easier to identify which workspace needs attention. This is a repository-owned backlog for Codex, Claude Code, and other contributors; no conversation history or private agent memory is required. Pick up the first incomplete task, read the referenced implementation before editing, and record evidence beside completed items. Do not mark research claims as locally verified.

Reuse the evaluation principles from the [cc-settings skill-routing evaluation](../../../cc-settings/docs/audits/skill-routing-2026-09-21.md) in a sibling checkout; that experiment ended in no-go. The projects share evaluation principles, not a runtime dependency. Session recovery reliability takes priority over shipping this feature.

## Research basis

Candidate: [Laya MLX](https://github.com/mizorewww/laya-mlx), reviewed 2026-09-21. It supplies constrained classifications, scores, and probabilities, not generated explanations. The documented runtime uses Python and targets Apple Silicon. Upstream latency measurements exclude loading and do not establish accuracy on terminal activity. Verify upstream revisions, supported platforms, packaging, and weight licenses during evaluation. No dependency or model has been selected for production.

## Tasks

- [ ] **P1 — Define observable behavior and a baseline.** Trace existing agent events, shell/process signals, and workspace state. Reuse authoritative events before inference. Define working, waiting for input, finished, possibly stuck, and unknown; elapsed time alone must not prove stuck. Build consented, sanitized labeled fixtures including noisy output, ambiguous prompts, multilingual sessions, and missing signals. Establish a deterministic baseline and numeric acceptance thresholds before model evaluation.
- [ ] **P2 — Evaluate a local backend against that baseline.** Start with Laya MLX and record pinned code/weight revisions. Measure per-class precision/recall, false alerts, abstention, cold start, warm p50/p95 latency, process memory, model download size, and resource use with multiple active sessions. Measure representative Apple hardware. Assess a Windows-capable backend separately; do not imply MLX supplies Windows support. Retain a no-model fallback. Record a proceed/change-backend decision supported by measurements.
- [ ] **P3 — Implement the validated optional integration.** Keep questions, state semantics, and result policy in the shared core; keep inference behind a replaceable platform backend. Use explicit opt-in and bounded, sanitized context. Do not send terminal data to a cloud service implicitly. Handle unavailable models, malformed results, timeout, cancellation, stale results, and low confidence as unknown/fallback. Coalesce background work; never run inference on typing/rendering paths. Show advisory attention indicators through native macOS and Windows UI, with localized accessible labels and an off switch. Predictions must never execute commands, close sessions, change permissions, or override explicit agent events.
- [ ] **P4 — Verify before release.** Run behavioral tests for state precedence, abstention, stale results, backend failure, and disabled mode in CI/VM under repository policy. Exercise the native attention UI end-to-end on macOS and Windows. Compare measured typing latency and resource use with the baseline. Verify installation/offline operation/model removal and document platform capability differences honestly. Record build/test run links, measured results, and any unexercised behavior here.

## Follow-up scope

After attention classification meets its acceptance criteria, evaluate notification relevance and workspace category suggestions as separate tasks. Do not expand this implementation into autonomous command execution or generated coding assistance.
