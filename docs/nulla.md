# Programa behavior and performance

Programa keeps terminal sessions usable while people type, switch workspaces, resize panes, and restore a previous layout. The journeys below describe the behavior to preserve on the platforms that support it. Use the [Nulla rules](https://github.com/darkroomengineering/nulla/blob/main/RULES.md) to decide where work runs and what evidence is needed. Adoption was checked against Nulla main at `529378a22c4e07ee443a98ea6360fa22aa67ca5b`.

| Journey | Expected behavior | Existing check and measurement |
| --- | --- | --- |
| Start a terminal | The window appears, the shell reaches its first prompt, and the focused pane accepts input. | Windows CI `programa.exe --smoke` verifies window creation and the first terminal snapshot. On each platform record process start to first painted prompt and then to first painted input echo. Socket readiness can help diagnose startup. |
| Type and read output | Input reaches the focused PTY. The terminal paints output in order and stays responsive after visiting other workspaces. | [macOS workspace churn check](../tests_v2/test_workspace_churn_up_arrow_lag.py) records socket-driven key latency before and after churn, with a 35 ms churn p95 cap in [CI](../.github/workflows/ci.yml). Use a display trace to measure input to paint separately. |
| Switch workspaces and resize splits | The selected workspace shows the correct content. Focus and input follow the selected pane. Hidden panes preserve their PTYs, output and scrollback. | [Tab and split UI tests](../programaUITests/BonsplitTabDragUITests.swift) and the [Windows desktop checklist](windows-testing.md). Record switch-to-paint latency and frame times during divider drags at a fixed display size and scale. |
| Restore after relaunch | On macOS, saved workspaces and layout come back with readable scrollback. A restored pane accepts input. | [Scrollback relaunch regression](../tests_v2/test_restored_scrollback_survives_relaunch.py) runs in socket CI. Use a saved ten-workspace fixture for launch latency and peak memory. |
| Leave a prompt idle | A quiet focused prompt remains ready for input. Hidden renderers can release their buffers while preserving terminal state. | [Nightly idle CPU check](../tests_v2/test_idle_cpu.py) uses a 30-second CPU-time delta and an informational 8% runner threshold. [Renderer planner tests](../programaTests/RendererRealizationPlannerTests.swift) cover selection policy. Verify actual buffer release with the memory procedure below. |

Run app tests in GitHub Actions or on the designated VM per [AGENTS.md](../AGENTS.md). Use the [Windows checklist](windows-testing.md) on a Windows desktop for interactive verification. Record unavailable checks, runner failures, and missing samples in the release evidence.

## First investigation on macOS

The November 4 audit of main at `45d4b8c2` measured ten surfaces on an Apple M1 Max with 32 GB RAM. Six spot samples put physical footprint at a median of 872 MB (671–1094 MB), with 138–553 MB in dirty IOSurface pages. A separate `vmmap` snapshot reported a 1.9 GB process-lifetime peak. Workspace activity and machine pressure varied during the capture. These observations prioritize renderer memory, and a controlled run is needed to establish the current baseline and attribute the launch peak. Windows CI has startup smoke coverage and still needs interactive performance samples on a Windows device.

On November 20, one read-only `footprint` sample of the installed macOS 27.2.1 app at `f137ad22e` reported 331 MB physical footprint, 445 MB process-lifetime peak, 68 MB dirty IOSurface, and 119 MB dirty Malloc Small. The session had seven workspaces and an uncontrolled activity history. The different fixture and workload prevent a comparison with the November 4 run.

### Automated baseline at `f137ad22e`

| Check | Result |
| --- | --- |
| Windows packaged startup and macOS socket integration, including restored scrollback | Both jobs passed in the [main CI run](https://github.com/darkroomengineering/programa/actions/runs/44825924033). |
| macOS sidebar resize | The targeted sidebar resize suite passed in the [hosted desktop run](https://github.com/darkroomengineering/programa/actions/runs/44826687970). |
| macOS focused idle CPU | 0.67% of one core over one 30-second window, within the existing informational 8% threshold. The probe verified window visibility and terminal focus. [Idle CPU log](https://github.com/darkroomengineering/programa/actions/runs/44826687970/job/136603051586) |
| macOS typing after workspace churn | Up-arrow socket round-trip p95 was 5.75 ms with one workspace and 3.26 ms after churn in one hosted run. The regression check passed. The in-process text-input refresh measured 0.018 ms p95 in a separate report-only probe. [Typing log](https://github.com/darkroomengineering/programa/actions/runs/44825924033/job/136604287384) |

General UI CI was skipped on the manual dispatch. The targeted resize run covered sidebar drag behavior. First-prompt paint, workspace-switch paint, split frame pacing, the ten-workspace restore peak, and Windows desktop interaction still need controlled captures.

The [native renderer lifecycle](../Sources/RendererRealization.swift) already releases hidden Metal swap chains. The window and pane visibility inputs are combined in [the terminal portal](../Sources/GhosttySurfaceScrollView.swift), which realizes a reclaimed renderer when its pane becomes visible. The controller keeps a warm renderer and periodically checks hidden renderers after their grace period. [Surface creation](../Sources/TerminalSurface.swift) starts with the renderer marked realized. Trace whether restored or background-started surfaces allocate Metal buffers before they can display a frame, then check whether those buffers disappear after reclamation. A Swift realization flag alone cannot establish that Metal allocated buffers. If buffers shrink as expected and footprint remains high, use the memory breakdown to find the surviving allocation owner.

### Reproduce and compare

The [ten-workspace Debug baseline](https://github.com/darkroomengineering/programa/actions/runs/44830672831/job/136616436343) reported the following on one hosted macOS run. Values below come from `footprint`. Its IOSurface row reports dirty bytes. The existing quiet-pane restore assertions passed in the same fixture.

| Phase | Physical footprint | Process peak | Dirty IOSurface | Dirty MALLOC_SMALL |
| --- | ---: | ---: | ---: | ---: |
| Restored, before workspace visits | 69 MB | 71 MB | 3344 KB | 42 MB |
| After visiting ten workspaces | 197 MB | 200 MB | 8704 KB | 133 MB |
| After 60 seconds without input | 184 MB | 200 MB | 4416 KB | 134 MB |

The hosted run points first to retained heap after churn. At the settled sample, `vmmap` reported 129.2 MB allocated in the default malloc zone and 0% reported fragmentation in that zone. Use a separate allocation trace with Instruments or `MallocStackLogging` to attribute the live allocations to call sites. Keep allocation tracing out of the footprint comparison because it changes the workload. The hosted display fixture still needs a higher-resolution counterpart to assess the renderer memory seen on the M1 Max.

The [occlusion candidate spot check](https://github.com/darkroomengineering/programa/actions/runs/44830957961/job/136617816779) passed the same lifecycle assertions. Its settled footprint was 185 MB, with 4416 KB of dirty IOSurface and 134 MB of dirty MALLOC_SMALL. The baseline and candidate each ran once on separate hosted runners. The samples establish no performance gain.

Dispatch `gh workflow run ci.yml --ref <branch> -f renderer_allocations=true` to collect live allocations grouped by stack and sorted by size at restore and after churn has settled. Download the `renderer-allocations` artifact from the socket integration job. Keep stack logging disabled for footprint comparisons.

For a hosted Debug spot check, dispatch the CI workflow with `gh workflow run ci.yml --ref <branch> -f renderer_memory=true`. In the socket integration job, **Profile renderer memory after restoring ten workspaces** logs native `footprint` and `vmmap` output before workspace visits, after visiting all ten and returning to the initially selected workspace, and after 60 seconds without input. The fixture also checks PTY identity and restored scrollback across relaunches. Use these samples to select the native trace to investigate. Use matched, alternating runs on one device for a performance comparison.

1. On a dedicated macOS desktop or VM, use the same display dimensions, scale, OS, shell configuration, and saved fixture for each build. Use one window with ten workspaces and one terminal per workspace. Seed identical scrollback and start from identical clean test profiles. Record the app commit, Ghostty pin, build configuration, device and OS. Prefer release-equivalent builds for performance and use the tagged Debug build for app behavior checks.
2. Capture one verified launch, visit all ten workspaces, and return to the first. Save `vmmap --summary "$APP_PID"` during launch and immediately after churn. Capture `footprint "$APP_PID"` after churn and again after 60 seconds with the app untouched. Record process peak, settled physical footprint, and dirty IOSurface bytes. Use `scripts/measure-idle.sh "$APP_PID" 30 5` for CPU time and wakeups. Preserve raw outputs by commit and run number.
3. Return to an early workspace after reclamation. Verify prompt echo, retained scrollback, focus, and the first correct frame. Check that background output is available on return and that visible splits still render during resize. Keep a display capture or frame trace along with the existing behavior checks.
4. Compare at least five alternating runs per build. Report medians and ranges and name the traced limiter. Review memory alongside startup and workspace-switch latency so that a lower buffer count earns its place in the app. Record inconclusive results when the distributions overlap.

## Build-time work and release evidence

The [v2 socket contract](../contracts/v2/methods.json) already supplies build-known method data to generated Swift. Run `scripts/check-v2-contract.sh` when it changes. Apply the same approach to static inputs when a journey trace shows repeated runtime work. Renderer visibility, PTY data, display geometry, and user configuration depend on runtime inputs. Prefer the existing AppKit and Ghostty visibility and draw paths on macOS and WinUI and ConPTY on Windows.

Programa currently ships native platform interfaces. Windows uses the Rust shared core and macOS uses Swift and GhosttyKit. Track the shared-core language and shared renderer-generation requirements as open adoption items against Nulla's platform rules.

Keep the fixture, commands, immutable build revisions, raw traces, behavior results, and budget verdict with the change. Existing CI thresholds retain their current scope. Device-floor references, native journey budgets, and release approval require human sign-off under Nulla. Record those approvals against the applicable reference, budget revision, and release artifact.
