#!/usr/bin/env python3
"""
Idle CPU budget: one focused, visible terminal at a quiet prompt.

Why: a focused terminal with nothing to draw must not keep the app busy. The
ghostty fork parks the display link after 250 ms with nothing to draw (PR #430);
before that, a focused quiet terminal woke on every screen refresh. Runaway
animations, polling timers and unpaused TimelineViews show up here too.

What it measures: the app process's CPU time over a fixed window
(`ps -o time=` delta / wall delta, `sample_cpu` below),
not `ps -o %cpu`, which on macOS is a decayed average since launch.

Exit codes: 0 within budget, 1 over budget, 2 harness error (the scenario could
not be set up, so no number was measured). The CI job is informational
(continue-on-error) until the budget is calibrated on runner numbers.

Environment:
  PROGRAMA_SOCKET_PATH            tagged dev socket (required)
  PROGRAMA_IDLE_CPU_BUDGET_PCT    budget for app CPU %, default 8.0
  PROGRAMA_IDLE_CPU_DURATION_S    sample window, default 30
  PROGRAMA_IDLE_CPU_SETTLE_S      quiet time before sampling, default 5
  PROGRAMA_IDLE_CPU_RESULT_FILE   receives the result line for the CI job summary
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Optional

_TESTS_V2_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _TESTS_V2_DIR)
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402

BUDGET_PCT = float(os.environ.get("PROGRAMA_IDLE_CPU_BUDGET_PCT", "8.0"))
DURATION_S = float(os.environ.get("PROGRAMA_IDLE_CPU_DURATION_S", "30.0"))
SETTLE_S = float(os.environ.get("PROGRAMA_IDLE_CPU_SETTLE_S", "5.0"))
RESULT_FILE = os.environ.get("PROGRAMA_IDLE_CPU_RESULT_FILE", "")

FOCUS_KEYS = ("inWindow", "windowIsKey", "windowOcclusionVisible", "appIsActive", "isActive", "isFirstResponder")


@dataclass
class SampleResult:
    wall_s: float
    app_cpu_pct: float
    total_cpu_pct: float


def parse_ps_time(raw: str) -> float:
    """Seconds from `ps -o time=`: "M:SS.ss", "HH:MM:SS", or "DD-HH:MM:SS" past a day."""
    s = raw.strip()
    days = 0.0
    if "-" in s:
        day_part, s = s.split("-", 1)
        days = float(day_part)
    parts = [float(p) for p in s.split(":")]
    if len(parts) == 2:
        parts.insert(0, 0.0)
    if len(parts) != 3:
        raise ValueError(f"Unexpected ps time format: {raw!r}")
    hours, minutes, seconds = parts
    return days * 86400.0 + hours * 3600.0 + minutes * 60.0 + seconds


def get_cpu_time(pid: int) -> Optional[float]:
    result = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True)
    try:
        return parse_ps_time(result.stdout) if result.returncode == 0 and result.stdout.strip() else None
    except ValueError:
        return None


def descendant_pids(root_pid: int) -> list[int]:
    seen, frontier = {root_pid}, [root_pid]
    while frontier:
        children: list[int] = []
        for pid in frontier:
            result = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True)
            children += [int(p) for p in result.stdout.split() if p.isdigit() and int(p) not in seen]
        seen.update(children)
        frontier = children
    return sorted(seen - {root_pid})


def sample_cpu(app_pid: int, window_s: float) -> SampleResult:
    """CPU time delta over wall time for the app and the shells it had at the start of the window."""
    tracked = [app_pid] + descendant_pids(app_pid)
    start_times = {pid: get_cpu_time(pid) for pid in tracked}
    wall_start = time.time()
    time.sleep(window_s)
    wall_delta = time.time() - wall_start

    app_delta = total_delta = 0.0
    for pid in tracked:
        start, end = start_times.get(pid), get_cpu_time(pid)
        if start is None or end is None:
            continue
        delta = max(0.0, end - start)
        total_delta += delta
        if pid == app_pid:
            app_delta = delta
    scale = 100.0 / wall_delta if wall_delta > 0 else 0.0
    return SampleResult(wall_s=wall_delta, app_cpu_pct=app_delta * scale, total_cpu_pct=total_delta * scale)


def resolve_target_socket() -> str:
    socket_path = os.environ.get("PROGRAMA_SOCKET_PATH")
    if not socket_path:
        raise ProgramaClientError("PROGRAMA_SOCKET_PATH is required; point it at a tagged dev socket")
    if os.path.basename(socket_path) in {"programa.sock", "programa-debug.sock"}:
        raise ProgramaClientError(f"refusing to run against main socket {socket_path!r}; use a tagged dev instance")
    return socket_path


def resolve_app_pid(socket_path: str) -> int:
    result = subprocess.run(["lsof", "-t", socket_path], capture_output=True, text=True)
    for line in result.stdout.split():
        if line.isdigit() and int(line) != os.getpid():
            return int(line)
    result = subprocess.run(["pgrep", "-f", r"Programa DEV.*\.app/Contents/MacOS/Programa DEV"],
                            capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.split():
        return int(result.stdout.split()[0])
    raise ProgramaClientError(f"could not find the app pid listening on {socket_path}")


def write_result(line: str) -> None:
    print(line)
    if RESULT_FILE:
        with open(RESULT_FILE, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def focus_state(client: ProgramaClient, surface_id: str) -> dict:
    stats = client.render_stats(surface_id)
    return {key: bool(stats.get(key)) for key in FOCUS_KEYS}


def is_focused_and_visible(state: dict) -> bool:
    return state["inWindow"] and state["windowIsKey"] and state["windowOcclusionVisible"] and state["isActive"]


def prepare_focused_terminal(client: ProgramaClient) -> tuple[str, dict]:
    """Leave exactly one focused, visible terminal surface in the selected workspace."""
    surfaces = client.list_surfaces()
    if len(surfaces) != 1:
        raise ProgramaClientError(f"expected one surface in the selected workspace, found {len(surfaces)}")
    surface_id = surfaces[0][1]

    state: dict = {}
    deadline = time.time() + 10.0
    while time.time() < deadline:
        client.activate_app()
        client.focus_surface(surface_id)
        time.sleep(0.25)
        state = focus_state(client, surface_id)
        if is_focused_and_visible(state):
            break
    return surface_id, state


def main() -> int:
    print("=" * 64)
    print(f"Idle CPU: focused quiet terminal, budget {BUDGET_PCT:.1f}% app CPU")
    print("=" * 64)

    client: Optional[ProgramaClient] = None
    try:
        socket_path = resolve_target_socket()
        app_pid = resolve_app_pid(socket_path)
        client = ProgramaClient(socket_path=socket_path)
        client.connect()

        surface_id, state = prepare_focused_terminal(client)
        # An unfocused or occluded terminal never runs the display link, so its number
        # says nothing about the focused-terminal idle path; label it rather than pass it.
        scenario = "focused" if is_focused_and_visible(state) else "unfocused"
        print(f"app pid {app_pid}, surface {surface_id}, scenario {scenario}, state {state}")

        # Close the socket so this connection adds no wakeups to the window.
        client.close()
        client = None

        time.sleep(SETTLE_S)
        sample = sample_cpu(app_pid, DURATION_S)

        client = ProgramaClient(socket_path=socket_path)
        client.connect()
        if not client.ping():
            raise ProgramaClientError("app stopped answering the socket during the sample window")
        after = focus_state(client, surface_id)
        if scenario == "focused" and not is_focused_and_visible(after):
            scenario = "focus-lost"
    except ProgramaClientError as e:
        write_result(f"IDLE_CPU_ERROR {e}")
        return 2
    finally:
        if client is not None:
            client.close()

    within = sample.app_cpu_pct <= BUDGET_PCT
    write_result(
        f"IDLE_CPU_APP_PCT={sample.app_cpu_pct:.2f} budget={BUDGET_PCT:.1f} "
        f"result={'PASS' if within else 'OVER'} scenario={scenario} "
        f"window_s={sample.wall_s:.1f} total_cpu_pct={sample.total_cpu_pct:.2f} "
        + " ".join(f"{key}={int(value)}" for key, value in state.items())
    )
    if scenario != "focused":
        print("WARN: the terminal was not focused and visible for the whole window; the number does not cover the focused idle path")
    return 0 if within else 1


if __name__ == "__main__":
    raise SystemExit(main())
