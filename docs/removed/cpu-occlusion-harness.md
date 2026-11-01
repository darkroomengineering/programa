# CPU occlusion harness

Removed 2026-11-01. Last present at commit c7e49738b8. Restore with `git checkout c7e49738b8 -- tests_v2/test_cpu_occlusion_throttle.py docs/cpu-harness.md`. Then point `tests_v2/test_idle_cpu.py` back at its helpers, or leave it on its own copies, and re-add the doc links in `docs/README.md`, `docs/testing-layout.md` and `docs/environment-variables.md`.

## What it did

`tests_v2/test_cpu_occlusion_throttle.py` measured how much CPU the app used with N busy terminal panes the user could not see, against the same panes when they were visible. It established a baseline for the occluded-render throttle, which caps hidden surfaces at about 4 Hz (ghostty fork commit `08bac45e9`, PR #265). It had three scenarios: `hidden-busy` (N workspaces with one busy pane each, all behind another selected workspace), `visible-busy` (the same panes as splits in one visible workspace, capped at 6) and `idle` (N hidden quiet panes). It printed a table and one JSON line.

## How it was wired

- It ran by hand against a tagged dev socket and refused the production sockets unless `PROGRAMA_CPU_HARNESS_ALLOW_MAIN_SOCKET=1` was set. Other settings came from `PROGRAMA_CPU_HARNESS_PANES`, `_DURATION_S`, `_SETTLE_S` and `_BUSY_SLEEP_S`, plus the `--scenario`, `--panes`, `--duration`, `--busy-sleep-s` and `--pid` flags.
- It was in no CI subset. It ran only in a full VM sweep.
- `tests_v2/test_idle_cpu.py` imported its `sample_cpu`, `resolve_target_socket` and `resolve_app_pid`. Those now live in `test_idle_cpu.py` itself.

## Files removed and files edited

Deleted `tests_v2/test_cpu_occlusion_throttle.py` (454 lines) and `docs/cpu-harness.md` (80 lines). Moved the sampling helpers into `tests_v2/test_idle_cpu.py`. Removed the references from `docs/README.md`, `docs/testing-layout.md`, `docs/environment-variables.md` and a comment in `programaTests/CommandPaletteSearchEngineTests.swift`.

## What we learned

- Measure CPU as the change in `ps -o time=` over wall time. `ps -o %cpu` on macOS is a decayed average since launch and misleads over a short window.
- Most of the cost lands on the app's own pid. Short-lived children spawned mid-window are not tracked, and their cost is small.
- A single run is noisy. Compare medians of 3 or more runs.
- A measurement with no pass/fail line protects nothing. `test_idle_cpu.py` has a budget and runs in the nightly job, so it is the CPU check that stays.

## Why removed

It could never fail, so it guarded nothing, and it still needed upkeep (2026-10-28 audit, INC-363). The occluded-render throttle it measured has shipped. Restore the harness if that throttle needs measuring again.
