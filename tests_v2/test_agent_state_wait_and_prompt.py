#!/usr/bin/env python3
"""Regression tests for surface.wait's `agent_state` condition and `agent.prompt` (#166 tasks
2-3), both built directly on #164's agent activity state model.

No real agent is involved -- state transitions are driven directly via the socket
`surface.report_agent_state`/`surface.clear_agent_state` commands (the same plumbing the shipped
Claude Code/Codex/OpenCode hook wrappers call), matching test_agent_activity_state_socket.py's
approach for #164 itself.

HARD-WON LESSONS from this repo's CI (see test_surface_wait.py's header for the #166 task 1
version of the same lessons):
  - Any concurrent send while another call blocks MUST use its own cmux connection, never the
    blocked client's -- sharing one interleaves request/response pairs on the same socket
    ("Mismatched response id").
  - Client-side socket read timeouts must exceed server-side wait timeouts.
"""

from __future__ import annotations

import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # noqa: E402
from pane_resize_test_support import (  # noqa: E402
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


DEFAULT_SOCKET_PATHS = ["/tmp/programa-debug.sock", "/tmp/programa.sock"]


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _report_agent_state(socket_path: str, workspace_id: str, surface_id: str, state: str) -> None:
    """Reports a state change from its own connection -- see the HARD-WON LESSONS header."""
    with cmux(socket_path) as bg_client:
        bg_client._call(
            "surface.report_agent_state",
            {"workspace_id": workspace_id, "surface_id": surface_id, "state": state},
        )


def _clear_agent_state(socket_path: str, workspace_id: str, surface_id: str) -> None:
    with cmux(socket_path) as bg_client:
        bg_client._call("surface.clear_agent_state", {"workspace_id": workspace_id, "surface_id": surface_id})


def _surface_wait_agent_state(
    client: cmux, workspace_id: str, surface_id: str, *, agent_state: str, timeout_ms: int = 8_000
) -> dict:
    params = {
        "workspace_id": workspace_id,
        "surface_id": surface_id,
        "agent_state": agent_state,
        "timeout_ms": timeout_ms,
    }
    # Client-side socket read timeout must cover the server-side wait timeout.
    return client._call("surface.wait", params, timeout_s=(timeout_ms / 1000.0) + 5.0) or {}


def _test_agent_state_idle_already_satisfied_with_no_report(client: cmux, workspace_id: str, surface_id: str) -> None:
    """A surface that has never reported any agent_state counts as idle-equivalent (the
    documented no-state rule) -- an `idle` wait resolves immediately, not after a timeout."""
    started = time.time()
    result = _surface_wait_agent_state(client, workspace_id, surface_id, agent_state="idle", timeout_ms=5_000)
    elapsed = time.time() - started

    _must(result.get("condition") == "agent_state", f"expected condition=agent_state, got {result}")
    _must(result.get("waited") is False, f"expected waited=False (no-state == idle), got {result}")
    _must(result.get("state") is None, f"expected state=null for a surface that never reported, got {result}")
    _must(elapsed < 1.0, f"an already-satisfied wait should return promptly, took {elapsed:.2f}s")


def _test_agent_state_resolves_after_delayed_report(socket_path: str, client: cmux, workspace_id: str, surface_id: str) -> None:
    """A `blocked` wait must actually block until a report arrives ~1.5s later -- proves the
    wait is event-driven off AgentStateWaitRegistry, not a one-shot check."""
    thread = threading.Thread(
        target=lambda: (time.sleep(1.5), _report_agent_state(socket_path, workspace_id, surface_id, "blocked"))
    )
    thread.start()
    try:
        started = time.time()
        result = _surface_wait_agent_state(client, workspace_id, surface_id, agent_state="blocked", timeout_ms=8_000)
        elapsed = time.time() - started
    finally:
        thread.join(timeout=5.0)

    _must(result.get("waited") is True, f"expected waited=True for a delayed report, got {result}")
    _must(result.get("state") == "blocked", f"expected state=blocked, got {result}")
    _must(1.0 <= elapsed <= 7.0, f"expected ~1.5s wait, took {elapsed:.2f}s")


def _test_agent_state_concurrent_report_is_not_missed(socket_path: str, client: cmux, workspace_id: str, surface_id: str) -> None:
    """The #166 task 1 'a parallel state change can't be missed' guarantee, extended to
    agent_state: fire the report from a background thread with only a small jitter while the
    main thread issues surface.wait essentially concurrently."""
    errors: list[Exception] = []

    def _fire() -> None:
        try:
            time.sleep(0.05)
            _report_agent_state(socket_path, workspace_id, surface_id, "working")
        except Exception as exc:  # pragma: no cover
            errors.append(exc)

    thread = threading.Thread(target=_fire)
    thread.start()
    try:
        result = _surface_wait_agent_state(client, workspace_id, surface_id, agent_state="working", timeout_ms=6_000)
    finally:
        thread.join(timeout=5.0)

    _must(not errors, f"background report failed: {errors}")
    _must(result.get("state") == "working", f"race case: expected state=working, got {result}")


def _test_agent_state_any_change(socket_path: str, client: cmux, workspace_id: str, surface_id: str) -> None:
    """`any_change` never counts as already-satisfied -- it must resolve on the *next*
    transition after registration, even if the current state already differs from some
    caller-assumed baseline (there is nothing to compare against yet)."""
    thread = threading.Thread(
        target=lambda: (time.sleep(1.0), _report_agent_state(socket_path, workspace_id, surface_id, "idle"))
    )
    thread.start()
    try:
        started = time.time()
        result = _surface_wait_agent_state(client, workspace_id, surface_id, agent_state="any_change", timeout_ms=6_000)
        elapsed = time.time() - started
    finally:
        thread.join(timeout=5.0)

    _must(result.get("waited") is True, f"any_change should never be already-satisfied, got {result}")
    _must(0.6 <= elapsed <= 5.0, f"expected ~1s wait for any_change, took {elapsed:.2f}s")


def _test_agent_state_timeout(client: cmux, workspace_id: str, surface_id: str) -> None:
    """A `blocked` wait on a surface that stays working must time out cleanly."""
    started = time.time()
    try:
        _surface_wait_agent_state(client, workspace_id, surface_id, agent_state="blocked", timeout_ms=1_500)
        raise cmuxError("expected surface.wait to time out, but it returned success")
    except cmuxError as exc:
        _must("timeout" in str(exc).lower(), f"expected a timeout error, got: {exc}")
    elapsed = time.time() - started
    _must(elapsed < 4.0, f"timeout case took too long: {elapsed:.2f}s")


def _test_agent_prompt_round_trip(socket_path: str, client: cmux, workspace_id: str, surface_id: str) -> None:
    """agent.prompt's full happy path: report working shortly after the prompt is sent (as a
    real agent hook would), then idle -- resolves working_observed=True, final_state=idle."""

    def _simulate_agent() -> None:
        time.sleep(0.8)
        _report_agent_state(socket_path, workspace_id, surface_id, "working")
        time.sleep(1.2)
        _report_agent_state(socket_path, workspace_id, surface_id, "idle")

    thread = threading.Thread(target=_simulate_agent)
    thread.start()
    try:
        started = time.time()
        result = client._call(
            "agent.prompt",
            {
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "text": "PROGRAMA_TEST_PROMPT (scripted, no real agent)",
                "timeout_ms": 15_000,
                "working_grace_ms": 5_000,
            },
            timeout_s=25.0,
        ) or {}
        elapsed = time.time() - started
    finally:
        thread.join(timeout=5.0)

    _must(result.get("working_observed") is True, f"expected working_observed=True, got {result}")
    _must(result.get("final_state") == "idle", f"expected final_state=idle, got {result}")
    _must(result.get("warning") is None, f"happy path should not carry a warning, got {result}")
    _must(1.5 <= elapsed <= 10.0, f"expected roughly the scripted 2s round trip, took {elapsed:.2f}s")


def _test_agent_prompt_no_working_within_grace(client: cmux, workspace_id: str, surface_id: str) -> None:
    """If nothing ever reports 'working' within the grace window, agent.prompt resolves
    promptly (not a hang/timeout) with working_observed=False and a warning, since this surface
    has never reported any agent_state at all."""
    started = time.time()
    result = client._call(
        "agent.prompt",
        {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "text": "PROGRAMA_TEST_PROMPT_NO_AGENT (no hooks installed on this surface)",
            "timeout_ms": 15_000,
            "working_grace_ms": 1_500,
        },
        timeout_s=25.0,
    ) or {}
    elapsed = time.time() - started

    _must(result.get("working_observed") is False, f"expected working_observed=False, got {result}")
    _must(isinstance(result.get("warning"), str) and "hooks" in result["warning"].lower(), f"expected a hooks warning, got {result}")
    _must(1.0 <= elapsed <= 6.0, f"expected to resolve around the 1.5s grace window, took {elapsed:.2f}s")


def _run_once(socket_path: str) -> int:
    workspace_id = ""
    try:
        with cmux(socket_path) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)

            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]
            _wait_for_surface_command_roundtrip(client, workspace_id, surface_id)

            _test_agent_state_idle_already_satisfied_with_no_report(client, workspace_id, surface_id)
            _test_agent_state_resolves_after_delayed_report(socket_path, client, workspace_id, surface_id)
            _clear_agent_state(socket_path, workspace_id, surface_id)
            _test_agent_state_concurrent_report_is_not_missed(socket_path, client, workspace_id, surface_id)
            _test_agent_state_any_change(socket_path, client, workspace_id, surface_id)
            _test_agent_state_timeout(client, workspace_id, surface_id)

            # agent.prompt gets its own fresh surface so the reports above don't leave stale
            # state behind that would short-circuit its "already working" branch.
            prompt_surface_id = client.new_surface(panel_type="terminal")
            _wait_for_surface_command_roundtrip(client, workspace_id, prompt_surface_id)
            _test_agent_prompt_round_trip(socket_path, client, workspace_id, prompt_surface_id)

            no_agent_surface_id = client.new_surface(panel_type="terminal")
            _wait_for_surface_command_roundtrip(client, workspace_id, no_agent_surface_id)
            _test_agent_prompt_no_working_within_grace(client, workspace_id, no_agent_surface_id)

            client.close_workspace(workspace_id)
            workspace_id = ""

        print("PASS: surface.wait agent_state condition and agent.prompt behave as documented")
        return 0
    finally:
        if workspace_id:
            try:
                with cmux(socket_path) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass


def main() -> int:
    env_socket = os.environ.get("PROGRAMA_SOCKET")
    if env_socket:
        return _run_once(env_socket)

    last_error: Exception | None = None
    for socket_path in DEFAULT_SOCKET_PATHS:
        try:
            return _run_once(socket_path)
        except cmuxError as exc:
            text = str(exc)
            recoverable = ("Failed to connect", "Socket not found")
            if not any(token in text for token in recoverable):
                raise
            last_error = exc
            continue

    if last_error is not None:
        raise last_error
    raise cmuxError("No socket candidates configured")


if __name__ == "__main__":
    raise SystemExit(main())
