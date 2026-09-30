#!/usr/bin/env python3
"""
CPU measurement harness: cost of busy terminal panes the user cannot see.

Context: the renderer now throttles frame generation for OCCLUDED (hidden)
terminal surfaces to ~4Hz instead of redrawing on every PTY output burst
(ghostty fork commit 08bac45e9, PR #265). This harness answers exactly one
question: how much CPU does the app burn with N busy terminal panes that are
not visible, and how does that compare to the same N panes when they ARE
visible?

This is a measurement tool, not a regression gate -- it never fails on "CPU
was high". It only exits non-zero on a harness/socket error. Compare medians
of 3+ runs; a single run is noisy (see docs/cpu-harness.md).

Methodology (read before trusting a number):
- Does NOT use `ps -o %cpu`: on macOS that column is a decayed average since
  process start, so it dilutes any short measurement window and is not
  comparable across scenarios. Instead this samples cumulative CPU time via
  `ps -o time=` (wall-clock seconds of CPU actually consumed) once at the
  start and once at the end of the sample window, and computes:

      cpu_percent = (cpu_time_delta / wall_time_delta) * 100

  That is exact (not decayed, not smoothed) and comparable run to run.
- Samples the app process AND its PTY/shell descendant processes
  separately, then reports both the app-only figure and the total. The
  descendant set is captured once at the start of the sample window (the
  long-lived shell processes backing each pane); very short-lived
  processes spawned mid-window (e.g. each iteration's `sleep`) are not
  individually tracked, matching how `ps` cumulative time works -- their
  own CPU cost is real but tiny and does not land on a parent's TIME field.
  The renderer/PTY-processing cost this harness targets is charged to the
  app's own pid, which IS captured in full.

Scenarios (see run_scenario / main):
  hidden-busy  (default): N workspaces, each with one busy pane, all
               occluded behind a different selected workspace. This is the
               scenario the throttle targets.
  visible-busy: the same N busy panes, arranged as splits in ONE visible
               workspace (the control -- should read materially higher than
               hidden-busy if the throttle is working).
  idle:        N hidden, non-busy panes (baseline).

Socket commands used to build the scenarios (tests_v2/programa_client.py):
  workspace.create / workspace.select   -- create + occlude/reveal workspaces
  surface.list                          -- find each new workspace's default pane
  surface.split ("right")               -- add visible split panes in one workspace
  surface.send_text (client.send_surface) -- start the busy loop in each pane
  workspace.close                       -- tear down created workspaces afterward

Requires PROGRAMA_SOCKET_PATH (or --socket) pointed at a tagged dev instance.
Never targets the main/untagged socket. Never launches an app itself.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import Optional

_TESTS_V2_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests_v2"))
sys.path.insert(0, _TESTS_V2_DIR)
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402

DEFAULT_PANES = int(os.environ.get("PROGRAMA_CPU_HARNESS_PANES", "4"))
DEFAULT_DURATION_S = float(os.environ.get("PROGRAMA_CPU_HARNESS_DURATION_S", "30.0"))
DEFAULT_SETTLE_S = float(os.environ.get("PROGRAMA_CPU_HARNESS_SETTLE_S", "2.0"))
DEFAULT_BUSY_SLEEP_S = float(os.environ.get("PROGRAMA_CPU_HARNESS_BUSY_SLEEP_S", "0.015"))
ALLOW_MAIN_SOCKET = os.environ.get("PROGRAMA_CPU_HARNESS_ALLOW_MAIN_SOCKET", "0") == "1"

# A real window can't usefully show more than a handful of side-by-side split
# panes. Cap visible-busy so the control scenario stays a fair "same N panes,
# but visible" comparison rather than a degenerate sliver layout.
MAX_VISIBLE_PANES = 6

ALL_SCENARIOS = ("hidden-busy", "visible-busy", "idle")


def busy_command(sleep_s: float) -> str:
    # Approximates an agent's output rate (a line every ~10-20ms), not a
    # fork bomb. `sleep_s` is a flag so the rate can be swept later.
    return f'while true; do echo "harness output $RANDOM"; sleep {sleep_s}; done\n'


@dataclass
class SampleResult:
    wall_s: float
    app_cpu_pct: float
    total_cpu_pct: float
    tracked_pids: int


@dataclass
class ScenarioResult:
    scenario: str
    requested_panes: int
    effective_panes: int
    duration_s: float
    sample: SampleResult
    notes: list[str] = field(default_factory=list)


def parse_ps_time(raw: str) -> float:
    """Parse `ps -o time=`/`ps -o cputime=` output into seconds.

    Formats observed on macOS: "M:SS.ss", "MM:SS.ss", "HH:MM:SS", and, for
    processes older than a day, "DD-HH:MM:SS". Fractional seconds are only
    present at the small end; older processes may show whole seconds.
    """
    s = raw.strip()
    if not s:
        raise ValueError(f"Empty ps time value: {raw!r}")

    days = 0.0
    if "-" in s:
        day_part, s = s.split("-", 1)
        days = float(day_part)

    parts = s.split(":")
    if len(parts) == 2:
        minutes, seconds = (float(p) for p in parts)
        hours = 0.0
    elif len(parts) == 3:
        hours, minutes, seconds = (float(p) for p in parts)
    else:
        raise ValueError(f"Unexpected ps time format: {raw!r}")

    return days * 86400.0 + hours * 3600.0 + minutes * 60.0 + seconds


def get_cpu_time(pid: int) -> Optional[float]:
    result = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True)
    if result.returncode != 0:
        return None
    raw = result.stdout.strip()
    if not raw:
        return None
    try:
        return parse_ps_time(raw)
    except ValueError:
        return None


def child_pids(pid: int) -> list[int]:
    result = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
    if result.returncode != 0:
        return []
    out: list[int] = []
    for line in result.stdout.split():
        line = line.strip()
        if line.isdigit():
            out.append(int(line))
    return out


def descendant_pids(root_pid: int) -> list[int]:
    visited = {root_pid}
    ordered: list[int] = []
    frontier = [root_pid]
    while frontier:
        next_frontier: list[int] = []
        for pid in frontier:
            for child in child_pids(pid):
                if child not in visited:
                    visited.add(child)
                    ordered.append(child)
                    next_frontier.append(child)
        frontier = next_frontier
    return ordered


def sample_cpu(app_pid: int, window_s: float) -> SampleResult:
    tracked = [app_pid] + descendant_pids(app_pid)
    start_times = {pid: get_cpu_time(pid) for pid in tracked}

    wall_start = time.time()
    time.sleep(window_s)
    wall_delta = time.time() - wall_start

    app_delta = 0.0
    total_delta = 0.0
    tracked_count = 0
    for pid in tracked:
        start = start_times.get(pid)
        end = get_cpu_time(pid)
        if start is None or end is None:
            continue
        delta = max(0.0, end - start)
        tracked_count += 1
        total_delta += delta
        if pid == app_pid:
            app_delta = delta

    app_pct = (app_delta / wall_delta) * 100.0 if wall_delta > 0 else 0.0
    total_pct = (total_delta / wall_delta) * 100.0 if wall_delta > 0 else 0.0
    return SampleResult(wall_s=wall_delta, app_cpu_pct=app_pct, total_cpu_pct=total_pct, tracked_pids=tracked_count)


def resolve_target_socket(explicit: Optional[str]) -> str:
    socket_path = explicit or os.environ.get("PROGRAMA_SOCKET_PATH")
    if not socket_path:
        raise ProgramaClientError(
            "PROGRAMA_SOCKET_PATH is required (or pass --socket). Point it to a "
            "tagged dev socket (for example /tmp/programa-debug-<tag>.sock). "
            "Never run this harness against an untagged Programa DEV.app."
        )
    base = os.path.basename(socket_path)
    if not ALLOW_MAIN_SOCKET and base in {"programa.sock", "programa-debug.sock"}:
        raise ProgramaClientError(
            f"Refusing to run against main socket '{socket_path}'. Set "
            "PROGRAMA_SOCKET_PATH to a tagged dev instance."
        )
    return socket_path


def resolve_app_pid(socket_path: str, override_pid: Optional[int]) -> int:
    if override_pid is not None:
        return override_pid

    result = subprocess.run(["lsof", "-t", socket_path], capture_output=True, text=True)
    if result.returncode == 0:
        for line in result.stdout.strip().split("\n"):
            line = line.strip()
            if not line:
                continue
            try:
                pid = int(line)
            except ValueError:
                continue
            if pid != os.getpid():
                return pid

    result = subprocess.run(
        ["pgrep", "-f", r"Programa DEV.*\.app/Contents/MacOS/Programa DEV"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
        if lines:
            return int(lines[0])

    raise ProgramaClientError(
        f"Could not resolve app pid for socket {socket_path}. Pass --pid explicitly."
    )


def close_workspaces(client: ProgramaClient, workspace_ids: list[str]) -> None:
    for wid in reversed(workspace_ids):
        try:
            client.close_workspace(wid)
        except ProgramaClientError:
            pass


def default_surface_id(client: ProgramaClient, workspace_id: str) -> str:
    surfaces = client.list_surfaces(workspace_id)
    if not surfaces:
        raise ProgramaClientError(f"New workspace {workspace_id} has no default surface")
    return surfaces[0][1]


def run_hidden_scenario(
    client: ProgramaClient,
    app_pid: int,
    n: int,
    duration_s: float,
    settle_s: float,
    command: Optional[str],
) -> ScenarioResult:
    created: list[str] = []
    try:
        for _ in range(n):
            wid = client.new_workspace()
            created.append(wid)
            client.select_workspace(wid)
            sid = default_surface_id(client, wid)
            if command:
                client.send_surface(sid, command)
            time.sleep(0.05)

        # Select one more, distinct workspace so all N created above are occluded.
        viewer_id = client.new_workspace()
        created.append(viewer_id)
        client.select_workspace(viewer_id)

        time.sleep(settle_s)
        sample = sample_cpu(app_pid, duration_s)
        label = "hidden-busy" if command else "idle"
        return ScenarioResult(scenario=label, requested_panes=n, effective_panes=n, duration_s=duration_s, sample=sample)
    finally:
        close_workspaces(client, created)


def run_visible_busy_scenario(
    client: ProgramaClient,
    app_pid: int,
    n: int,
    duration_s: float,
    settle_s: float,
    command: str,
) -> ScenarioResult:
    effective_n = min(n, MAX_VISIBLE_PANES)
    created: list[str] = []
    notes: list[str] = []
    if effective_n < n:
        notes.append(f"capped from {n} to {effective_n} panes (MAX_VISIBLE_PANES)")

    try:
        wid = client.new_workspace()
        created.append(wid)
        client.select_workspace(wid)
        surface_ids = [default_surface_id(client, wid)]
        for _ in range(effective_n - 1):
            sid = client.new_split("right")
            surface_ids.append(sid)

        for sid in surface_ids:
            client.send_surface(sid, command)
            time.sleep(0.05)

        time.sleep(settle_s)
        sample = sample_cpu(app_pid, duration_s)
        return ScenarioResult(
            scenario="visible-busy",
            requested_panes=n,
            effective_panes=effective_n,
            duration_s=duration_s,
            sample=sample,
            notes=notes,
        )
    finally:
        close_workspaces(client, created)


def print_table(results: list[ScenarioResult]) -> None:
    header = f"{'scenario':<14} {'N':>3} {'duration_s':>10} {'app_cpu_%':>10} {'total_cpu_%':>12}"
    print(header)
    print("-" * len(header))
    for r in results:
        print(
            f"{r.scenario:<14} {r.effective_panes:>3} {r.duration_s:>10.1f} "
            f"{r.sample.app_cpu_pct:>10.2f} {r.sample.total_cpu_pct:>12.2f}"
        )
        for note in r.notes:
            print(f"  note: {note}")


def results_to_json(results: list[ScenarioResult], app_pid: int) -> str:
    payload = {
        "app_pid": app_pid,
        "scenarios": [
            {
                "scenario": r.scenario,
                "requested_panes": r.requested_panes,
                "effective_panes": r.effective_panes,
                "duration_s": r.duration_s,
                "wall_s": r.sample.wall_s,
                "app_cpu_pct": r.sample.app_cpu_pct,
                "total_cpu_pct": r.sample.total_cpu_pct,
                "tracked_pids": r.sample.tracked_pids,
                "notes": r.notes,
            }
            for r in results
        ],
    }
    return json.dumps(payload, separators=(",", ":"))


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=None, help="Socket path (defaults to PROGRAMA_SOCKET_PATH)")
    parser.add_argument("--pid", type=int, default=None, help="App pid override (skips pid discovery)")
    parser.add_argument(
        "--scenario",
        choices=("all",) + ALL_SCENARIOS,
        default="all",
        help="Which scenario(s) to run (default: all)",
    )
    parser.add_argument("-n", "--panes", type=int, default=DEFAULT_PANES, help="Number of busy panes (default: 4)")
    parser.add_argument(
        "--duration", type=float, default=DEFAULT_DURATION_S, help="Sample window in seconds (default: 30)"
    )
    parser.add_argument(
        "--settle", type=float, default=DEFAULT_SETTLE_S, help="Settle time before sampling starts (default: 2s)"
    )
    parser.add_argument(
        "--busy-sleep-s",
        type=float,
        default=DEFAULT_BUSY_SLEEP_S,
        help="Sleep between busy-loop output lines, i.e. the output rate (default: 0.015s)",
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])

    print("=" * 64)
    print("CPU Occlusion Throttle Harness")
    print("=" * 64)

    client: Optional[ProgramaClient] = None
    try:
        target_socket = resolve_target_socket(args.socket)
        app_pid = resolve_app_pid(target_socket, args.pid)
        print(f"Using socket: {target_socket}")
        print(f"App pid: {app_pid}")
        print(f"Panes requested: {args.panes}  duration: {args.duration}s  busy_sleep_s: {args.busy_sleep_s}")

        client = ProgramaClient(socket_path=target_socket)
        client.connect()

        command = busy_command(args.busy_sleep_s)
        scenarios = ALL_SCENARIOS if args.scenario == "all" else (args.scenario,)
        results: list[ScenarioResult] = []

        for scenario in scenarios:
            print(f"\nRunning scenario: {scenario} ...")
            if scenario == "hidden-busy":
                results.append(
                    run_hidden_scenario(client, app_pid, args.panes, args.duration, args.settle, command)
                )
            elif scenario == "visible-busy":
                results.append(
                    run_visible_busy_scenario(client, app_pid, args.panes, args.duration, args.settle, command)
                )
            elif scenario == "idle":
                results.append(
                    run_hidden_scenario(client, app_pid, args.panes, args.duration, args.settle, None)
                )

        print()
        print_table(results)
        print()
        print(results_to_json(results, app_pid))
        return 0

    except ProgramaClientError as e:
        print(f"FAIL: {e}")
        return 1
    finally:
        if client is not None:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main())
