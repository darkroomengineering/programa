#!/usr/bin/env python3
"""Screen-manifest agent detection (docs/plans/screen-manifest-detection.md) regression test.

Drives a small fake "agent" shell script that prints Claude Code manifest-matching screen text
(Resources/AgentDetection/claude-code.json) on a timer -- banner (Phase A recognition) -> idle
prompt -> working spinner -> blocked approval prompt -> idle again -- with no real Claude Code
process and no lifecycle hooks installed. Asserts via `surface.wait`'s `agent_state` condition
(the same wire path #164/#166 already prove event-driven) that the surface's agent_state
transitions idle-equivalent -> working -> blocked, with `agent_state_source`/`source` reporting
"inferred" throughout (never "hooks", since no hook ever reports here).

Must run against a tagged build's socket per the repo's testing policy -- never an untagged
instance (see root CLAUDE.md "Testing policy").

Timing budget: Phase A recognition runs on a ~3s cadence (fallback path -- see
AgentScreenDetectionEngine.swift's header for why there's no foreground-command signal to hook
into instead) and Phase B classification requires 2 consecutive ~0.75s samples before flipping
`working`/`idle` (blocked applies on the first match, no dwell). The script's own sleeps are sized
generously above that worst case so CI runner jitter doesn't produce flakes (see this repo's
stress-profile-perf-budget-flaky lesson: prefer generous timeouts over tight ones for
background-thread-driven behavior).
"""

from __future__ import annotations

import os
import stat
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # noqa: E402
from pane_resize_test_support import (  # noqa: E402
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")

FAKE_AGENT_SCRIPT = """#!/bin/bash
# Fake Claude Code session for screen-manifest detection testing -- prints screen text matching
# Resources/AgentDetection/claude-code.json's recognize/state patterns, nothing else.
sleep 0.3
echo 'Claude Code v1.0.0 (fake test agent)'
sleep 0.3
printf '\\n❯ '
sleep 10
printf '\\n✻ Thinking… (esc to interrupt)\\n'
sleep 8
printf '\\nDo you want to proceed?\\n❯ 1. Yes\\n'
sleep 8
printf '\\n❯ '
sleep 30
"""


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _surface_wait_agent_state(
    client: cmux, workspace_id: str, surface_id: str, *, agent_state: str, timeout_ms: int
) -> dict:
    params = {
        "workspace_id": workspace_id,
        "surface_id": surface_id,
        "agent_state": agent_state,
        "timeout_ms": timeout_ms,
    }
    # Client-side socket read timeout must exceed the server-side wait timeout.
    return client._call("surface.wait", params, timeout_s=(timeout_ms / 1000.0) + 5.0) or {}


def main() -> int:
    workspace_id = ""
    script_path = ""

    try:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".sh", prefix="programa_fake_agent_", delete=False
        ) as script_file:
            script_file.write(FAKE_AGENT_SCRIPT)
            script_path = script_file.name
        os.chmod(script_path, os.stat(script_path).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"new workspace should have at least one surface: {surfaces}")
            surface_id = surfaces[0][1]
            _wait_for_surface_command_roundtrip(client, workspace_id, surface_id)

            # No hooks are installed on this surface and nothing has reported yet -- confirm the
            # baseline before launching the fake agent.
            baseline = _surface_wait_agent_state(
                client, workspace_id, surface_id, agent_state="idle", timeout_ms=2_000
            )
            _must(baseline.get("waited") is False, f"expected no-report-yet to count as idle already, got {baseline}")
            _must(baseline.get("state") is None, f"expected state=null before the fake agent starts, got {baseline}")

            client.send_surface(surface_id, f"bash {script_path}\n")

            # 1. idle -> working: requires Phase A recognition (banner) to promote the surface
            #    into the candidate set, then Phase B to see the working spinner text for 2
            #    consecutive samples.
            working_result = _surface_wait_agent_state(
                client, workspace_id, surface_id, agent_state="working", timeout_ms=30_000
            )
            _must(working_result.get("waited") is True, f"expected an event-driven wait for working, got {working_result}")
            _must(working_result.get("state") == "working", f"expected state=working, got {working_result}")
            _must(
                working_result.get("source") == "inferred",
                f"expected source=inferred (no hooks installed on this surface), got {working_result}",
            )

            # 2. working -> blocked: the approval prompt applies immediately (no hysteresis dwell).
            blocked_result = _surface_wait_agent_state(
                client, workspace_id, surface_id, agent_state="blocked", timeout_ms=20_000
            )
            _must(blocked_result.get("waited") is True, f"expected an event-driven wait for blocked, got {blocked_result}")
            _must(blocked_result.get("state") == "blocked", f"expected state=blocked, got {blocked_result}")
            _must(
                blocked_result.get("source") == "inferred",
                f"expected source=inferred, got {blocked_result}",
            )

            # 3. blocked -> idle: the manifest's idle prompt reappears once the fake approval
            #    prompt clears; requires 2 consecutive idle-classified samples.
            idle_result = _surface_wait_agent_state(
                client, workspace_id, surface_id, agent_state="idle", timeout_ms=20_000
            )
            _must(idle_result.get("waited") is True, f"expected an event-driven wait back to idle, got {idle_result}")
            _must(idle_result.get("state") == "idle", f"expected state=idle, got {idle_result}")
            _must(
                idle_result.get("source") == "inferred",
                f"expected source=inferred, got {idle_result}",
            )

            client.close_workspace(workspace_id)
            workspace_id = ""
    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass
        if script_path:
            try:
                os.remove(script_path)
            except OSError:
                pass

    print("PASS: screen-manifest detection infers idle -> working -> blocked -> idle with source=inferred")
    return 0


if __name__ == "__main__":
    sys.exit(main())
