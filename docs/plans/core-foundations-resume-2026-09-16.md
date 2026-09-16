## Functional DAG

```text
Prior session + five workstreams ── recover exact scope and artifacts ──┐
Contract + Swift seam + provider events ── integrate and finish ────────┤
Rust daemon + GPUI client ── finish bounded foundation work ────────────┴── tagged build + CI verification
```

# Core foundations recovery

Base: `01cd644e275e87ddaa0804664f88604c3311a704`.
User resumed the last task on September 16. The actual unfinished request was
“do them all lfg work autonomously” in the September 15 session, after discussion
of the contract schema, Swift core interface, structured provider events, Rust
daemon, and cross-platform client. The reliability release is already complete.

## Recovered artifacts

- Architecture PR #337 remains open: `docs/rust-core-spike`, commit `c36b5683ad`.
- Contract: `.claude/worktrees/agent-a970de6bff8370bfa`, HEAD `86dc95d2f8`,
  with additional staged tests and documentation.
- Swift seam: `.claude/worktrees/agent-adaea1175de7c7903`, HEAD `deb9710fb7`,
  with an uncommitted supervision test.
- Events: `.claude/worktrees/agent-a4f0af67182471add`, HEAD `227388183d`,
  with staged hook adapter changes.
- Daemon: sibling `programa-core`, HEAD `c550894`, dirty fd-passing/server code
  and untracked integration tests. Prior session stopped while fixing framing.
- Client: sibling `programa-spike`, HEAD `2ff61c2`, dirty engine abstraction and
  untracked Ghostty FFI code. Prior session stopped during a Ghostty build.
- Integration checkout: `/private/tmp/programa-core-foundations`, branch
  `feat/core-foundations-resume`. Preserve the original worktrees and unrelated
  dirty main checkout. Dirty Swift patches backed up under
  `/private/tmp/programa-resume-backup`.

## Completion boundary

Finish and verify the five bounded briefs from the prior session. This is a
foundation pass, not a claim that the entire months-long core migration ships:
the Swift seam stays in-process; the daemon initially owns sessions and WAL;
remote transport is a design; organization mode still needs a product decision.
Do not create remotes for the Rust repositories without the user's decision.

1. Recover each brief and compare code against its promised deliverables.
2. Integrate contract, seam, and event changes; reconcile overlapping catalog,
   project, CLI, documentation, and CI entries.
3. Complete daemon framing/lifecycle/ownership, tests and operating documentation.
4. Complete client build workflows, selectable VT engine and component integration;
   report any unverified Windows build and UI measurements accurately.
5. Run tagged reload builds and appropriate static checks. Tests run in CI or on
   a VM under the current project policy. Do not weaken assertions or claim old
   agent-reported results as fresh verification.

## Current status

The three Swift workstreams are integrated in the isolated checkout. Tagged app
builds pass. The generated MCP catalog preserves all 187 original tool definitions,
verified by comparing the built helper's `tools/list` response. The contract covers
238 methods with source-derived result envelopes, typed Python arguments, CLI
method constants, and MCP schemas. The audit remains marked in progress for
dynamic JavaScript/DEBUG values, several broad nested list items, and errors
hidden in non-v2 helpers. The Swift test bundle also builds successfully; its
runtime tests have not run, and no Programa app was launched. Independent review
approved the provider installer, event ordering, metadata, and core routing.

The verified daemon changes are saved in sibling `programa-core`; its original
sources were archived first, and every original file passed a recovery hash check
before copying. The client changes are likewise saved in sibling `programa-spike`
after a hash guard. Both client engine selections compile and build. Review fixes
for rendering, resize ownership/retries, session cleanup, and Windows AltGr have
passed rereview. Final measurements are in `programa-spike/docs/measurements.md`;
all benchmark processes were terminated. Windows CI and interactive visual cases
remain unverified. The macOS Windows cross-check lacks `llvm-rc`.

The daemon's final pass passed 16 tests (none skipped) plus its Python smoke flow
in the isolated Linux VM `programa-core-tests-20260916`, created without host mounts.
Security review fixes cover descriptors, child reaping, and quiet WAL flushing.
Seven scratch generated-client behavioral checks also passed in that VM. A full
suite failure caused by non-CLOEXEC test fixtures was fixed without relaxing its
leak assertion. Multi-client per-axis minimum sizing and retention after detach
also pass. Daemon-restart session preservation is not implemented. Attachments
receive a write-only input pipe, keeping the daemon as the sole output reader;
this is not a zero-hop master-FD handoff.

No resumed changes have been committed, pushed, or merged. Original worktrees and
the unrelated dirty main checkout are preserved. Test logs and source backups are
under `/private/tmp`, with durable source archives and logs in
`.claude/resume-20260916`. `programa-swift-integration.tar.gz` records the base SHA,
the full patch, and untracked files for restoring the integration checkout.
The temporary Linux VM was removed after validation; its logs are preserved.
The final tagged reload and generated-client checks passed after the contract
audit. The tagged app is at the `App path:` recorded in the archived build log.

## Remaining gates and limits

- Run Swift runtime/provider tests in macOS CI or a VM; run the new client workflow
  on Windows and macOS. Both Rust repositories currently have no remote.
- Exercise client tab/split/scroll interactions, wide/combining/inverse visual
  cases, forced resize failures, and session teardown. Benchmarks do not prove
  those behaviors.
- Finish the contract's documented deep-schema caveats and the separate daemon
  keeper/restart-recovery deliverable before calling the original briefs complete.
- Automatic approval review rejected removal of an unreachable daemon shutdown
  branch because it interpreted the deletion as broadening child termination.
  The branch remains; no rejection was bypassed.
