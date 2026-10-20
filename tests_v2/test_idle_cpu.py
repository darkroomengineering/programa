#!/usr/bin/env python3
"""
Idle CPU budget: one focused, visible terminal at a quiet prompt.

Why: a focused terminal with nothing to draw must not keep the app busy. The
ghostty fork parks the display link after 250 ms with nothing to draw (PR #430);
before that, a focused quiet terminal woke on every screen refresh. Runaway
animations, polling timers and unpaused TimelineViews show up here too.

What it measures: the app process's CPU time over a fixed window
(`ps -o time=` delta / wall delta, via test_cpu_occlusion_throttle.sample_cpu),
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
import sys
import time
from typing import Optional

_TESTS_V2_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _TESTS_V2_DIR)
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from test_cpu_occlusion_throttle import (  # noqa: E402
    resolve_app_pid,
    resolve_target_socket,
    sample_cpu,
)

BUDGET_PCT = float(os.environ.get("PROGRAMA_IDLE_CPU_BUDGET_PCT", "8.0"))
DURATION_S = float(os.environ.get("PROGRAMA_IDLE_CPU_DURATION_S", "30.0"))
SETTLE_S = float(os.environ.get("PROGRAMA_IDLE_CPU_SETTLE_S", "5.0"))
RESULT_FILE = os.environ.get("PROGRAMA_IDLE_CPU_RESULT_FILE", "")

FOCUS_KEYS = ("inWindow", "windowIsKey", "windowOcclusionVisible", "appIsActive", "isActive", "isFirstResponder")


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
        socket_path = resolve_target_socket(None)
        app_pid = resolve_app_pid(socket_path, None)
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
