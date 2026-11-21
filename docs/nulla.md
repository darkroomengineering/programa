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

On `d0e69e73`, the [printable-key regression](https://github.com/darkroomengineering/programa/actions/runs/44902932422/job/136845023222) measured socket round-trip p95 of 8.84 ms before churn and 6.63 ms after churn, within the existing 35 ms cap. The separately instrumented refresh call measured 0.020 ms p95. This is one hosted run. The socket probe measures command completion and the refresh probe times an app call. Use an on-screen frame trace to measure when the typed character appears.

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

The [size-sorted allocation capture](https://github.com/darkroomengineering/programa/actions/runs/44835452535) classified 18.8 MB at restore and 98.2 MB after churn as live malloc allocations with AttributeGraph in their stacks. The grouping excludes anonymous mappings and pthread stack reservations. In the settled first-launch sample, 47.4 MB of live malloc allocations had `ThemeWindowThumbnail.body` in their stacks, including stacks from Setup Assistant presentation. These stack totals can overlap and cannot be added together. The trace includes onboarding and identifies fixed thumbnail artwork as a build-time candidate.

Pass `-f renderer_returning_user=true` with either profiling option to start the isolated profile with Setup Assistant already seen. Use the same onboarding state for both sides of a comparison.

For a same-runner comparison, dispatch `gh workflow run ci.yml --ref <candidate-branch> -f renderer_memory=true -f renderer_baseline_run=<successful-main-ci-run-id>`. Choose a baseline whose app artifact is still available. CI retains that artifact for one day. The socket integration job validates the baseline run, downloads its app artifact, and runs five alternating baseline and candidate pairs. Both builds use the same explicit onboarding preference and fresh profiles. Keep allocation tracing off for the paired footprint run.

The 3840×2160 virtual-display experiment stopped before memory sampling. The [first hosted attempt](https://github.com/darkroomengineering/programa/actions/runs/44900967519/job/136837798878) found the seed window on the runner's 1920×1080 screen. The [second attempt](https://github.com/darkroomengineering/programa/actions/runs/44902021796/job/136840515352) queried AppKit for the virtual screen directly. AppKit exposed no 3840×2160 screen at 1×. Use a dedicated macOS desktop or VM with a verified backing resolution for the larger-drawable comparison. Record both the window's point size and backing scale.

The [returning-user spot check](https://github.com/darkroomengineering/programa/actions/runs/44838209615/job/136643294686) measured 69 MB at restore, 102 MB after visiting ten workspaces, and 92 MB after 60 seconds without input. The settled sample reported 57 MB of dirty MALLOC_SMALL and 4416 KB of dirty IOSurface. The fixture exercised socket-driven workspace selection and terminal readiness. Painted frames and shortcut-driven cycling require a desktop capture. The first-launch and returning-user runs differ in onboarding state and build revision, so their footprint figures are descriptive.

The separate stack-logged returning-user run attributed 19.5 MB at restore and 19.0 MB after settling to live malloc allocations with AttributeGraph in their stacks. Neither report contained theme thumbnail or Setup Assistant malloc stacks. Ghostty surface creation appeared in 2.7 MB at restore and 13.6 MB after settling. Those stacks identify allocation sites. Determining which allocations can be released requires tracing their owners while the PTYs and scrollback remain live.

For a hosted Debug spot check, dispatch the CI workflow with `gh workflow run ci.yml --ref <branch> -f renderer_memory=true`. In the socket integration job, **Profile renderer memory after restoring ten workspaces** logs native `footprint` and `vmmap` output before workspace visits, after visiting all ten and returning to the initially selected workspace, and after 60 seconds without input. The fixture also checks PTY identity and restored scrollback across relaunches. Use these samples to select the native trace to investigate. Use matched, alternating runs on one device for a performance comparison.

1. On a dedicated macOS desktop or VM, use the same display dimensions, scale, OS, shell configuration, and saved fixture for each build. Use one window with ten workspaces and one terminal per workspace. Seed identical scrollback and start from identical clean test profiles. Record the app commit, Ghostty pin, build configuration, device and OS. Prefer release-equivalent builds for performance and use the tagged Debug build for app behavior checks.
2. Capture one verified launch, visit all ten workspaces, and return to the first. Save `vmmap --summary "$APP_PID"` during launch and immediately after churn. Capture `footprint "$APP_PID"` after churn and again after 60 seconds with the app untouched. Record process peak, settled physical footprint, and dirty IOSurface bytes. Use `scripts/measure-idle.sh "$APP_PID" 30 5` for CPU time and wakeups. Preserve raw outputs by commit and run number.
3. Return to an early workspace after reclamation. Verify prompt echo, retained scrollback, focus, and the first correct frame. Check that background output is available on return and that visible splits still render during resize. Keep a display capture or frame trace along with the existing behavior checks.
4. Compare at least five alternating runs per build. Report medians and ranges and name the traced limiter. Review memory alongside startup and workspace-switch latency so that a lower buffer count earns its place in the app. Record inconclusive results when the distributions overlap.

## Build-time work and release evidence

The [v2 socket contract](../contracts/v2/methods.json) already supplies build-known method data to generated Swift. Run `scripts/check-v2-contract.sh` when it changes. Apply the same approach to static inputs when a journey trace shows repeated runtime work. Renderer visibility, PTY data, display geometry, and user configuration depend on runtime inputs. Prefer the existing AppKit and Ghostty visibility and draw paths on macOS and WinUI and ConPTY on Windows.

Theme picker wallpaper and window artwork ship as generated layers in the Xcode asset catalog. Regenerate them from the repository root with `swift scripts/generate-theme-thumbnails.swift Assets.xcassets`. Verify the light, dark, and split system previews on a macOS desktop when changing the art or the thumbnail dimensions. The live system accent and material stay in the picker.

The [hosted Appearance test](https://github.com/darkroomengineering/programa/actions/runs/44843917443) exercised the native toolbar navigation and all three appearance controls. Its window screenshot showed the assembled preview layers and the selected System ring. The [first-launch footprint spot check](https://github.com/darkroomengineering/programa/actions/runs/44840787940/job/136653089883) reported 72 MB at restore, 191 MB after ten workspace visits, and 184 MB after settling. The prior first-launch sample also settled at 184 MB. These spot checks establish no process-footprint gain. The stack-logged run timed out during workspace selection.

The Copy Ghostty Resources phase indexes the bundled theme filenames after applying Programa's theme overlays. Settings loads that index for the bundled directory and preserves native discovery for external directories and bundles with a missing or invalid index. The loader still resolves precedence, case and diacritic deduplication, and locale-aware sorting at runtime. On a warm local filesystem with 465 bundled themes, ten alternating reads measured a median of 2.928 ms (2.602–3.476 ms) for enumeration and resource metadata, and 0.239 ms (0.198–0.292 ms) for reading and decoding the same names from an index. This isolates bundled catalog loading before runtime merge and sort.

Programa currently ships native platform interfaces. Windows uses the Rust shared core and macOS uses Swift and GhosttyKit. Track the shared-core language and shared renderer-generation requirements as open adoption items against Nulla's platform rules.

Setup Assistant populates its terminal theme menus when the native pop-up opens. In separate settled first-launch allocation captures, live malloc allocations with `SetupAssistantController` in their stacks totaled 29.3 MB with the eager menus and 2.6 MB with the native pop-ups. Stacks containing both `SetupAssistantController` and `ForEach` accounted for 15.2 MB and 0.3 MB, respectively. These totals overlap and describe allocation attribution under stack logging. Use the paired footprint fixture to measure process memory. The [hosted picker test](https://github.com/darkroomengineering/programa/actions/runs/44851945806) verifies that choosing and resetting a theme persists the expected configuration.

The [paired first-launch comparison](https://github.com/darkroomengineering/programa/actions/runs/44854170787/job/136693421229) used five alternating Debug runs per build on one hosted macOS 26 runner, with the same virtual display and allocation tracing disabled. All ten runs passed the PTY and scrollback assertions. The retained SwiftUI heap was the largest cost identified in the allocation captures. These samples measure memory footprint. The fixture's display resolution and Debug build limit the comparison to this workload.

| Physical footprint, median (range) | Baseline `a8ffc2df` | Native pop-ups `baca77a4` |
| --- | ---: | ---: |
| Restored | 69.5 MiB (68.3–71.1) | 69.1 MiB (68.5–70.0) |
| After visiting ten workspaces | 193.3 MiB (190.3–199.8) | 100.5 MiB (99.1–114.3) |
| After 60 seconds without input | 184.3 MiB (183.6–187.3) | 95.2 MiB (94.1–97.8) |
| Process peak | 208.5 MiB (202.3–214.6) | 117.4 MiB (111.7–122.1) |

Keep the fixture, commands, immutable build revisions, raw traces, behavior results, and budget verdict with the change. Existing CI thresholds retain their current scope. Device-floor references, native journey budgets, and release approval require human sign-off under Nulla. Record those approvals against the applicable reference, budget revision, and release artifact.
