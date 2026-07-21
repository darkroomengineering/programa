#!/usr/bin/env python3
"""Regression tests for `surface.wait` (#166 task 1): server-owned pattern/exit waits.

Covers the two guarantees the issue calls out explicitly:
  1. A wait resolves once a marker is printed by a command that only finishes ~2s later
     (proves the wait is actually event-driven/polled server-side, not a no-op).
  2. A marker printed concurrently with the `surface.wait` call -- racing "check" against
     "act" -- is never missed (the atomic already-satisfied check + watcher install described
     in `Sources/TerminalController+SurfaceWait.swift`).

Also covers a timeout case (pattern that never appears) and a light `exit` condition check.
"""

from __future__ import annotations

import os
import secrets
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


def _new_marker(label: str) -> str:
    return f"PROGRAMA_WAIT_{label}_{secrets.token_hex(4)}"


def _surface_wait(
    client: cmux,
    workspace_id: str,
    surface_id: str,
    *,
    pattern: str = None,
    exit_condition: bool = False,
    timeout_ms: int = 8_000,
) -> dict:
    params = {"workspace_id": workspace_id, "surface_id": surface_id, "timeout_ms": timeout_ms}
    if exit_condition:
        params["exit"] = True
    else:
        params["pattern"] = pattern
    # Client-side socket read timeout must cover the server-side wait timeout, same reasoning
    # as the CLI's `minimumReceiveTimeout` (see CLI/programa.swift `SocketClient.sendV2`).
    return client._call("surface.wait", params, timeout_s=(timeout_ms / 1000.0) + 5.0) or {}


def _test_pattern_resolves_after_delay(client: cmux, workspace_id: str, surface_id: str) -> None:
    """A command that sleeps 2s before printing its marker should still resolve the wait --
    proves surface.wait is actually watching, not just checking once and giving up."""
    marker = _new_marker("DELAYED")
    client.send_surface(surface_id, f"sleep 2; echo {marker}\n")

    started = time.time()
    result = _surface_wait(client, workspace_id, surface_id, pattern=marker, timeout_ms=8_000)
    elapsed = time.time() - started

    _must(result.get("condition") == "pattern", f"expected condition=pattern, got {result}")
    _must(result.get("waited") is True, f"expected waited=True for a delayed marker, got {result}")
    _must(result.get("match") == marker, f"expected match={marker!r}, got {result.get('match')!r}")
    # Must have actually blocked roughly until the marker appeared (~2s), not returned
    # instantly (which would mean it wasn't really watching) and not hit the 8s timeout.
    _must(1.5 <= elapsed <= 7.5, f"expected ~2s wait, took {elapsed:.2f}s")


def _test_pattern_already_present_resolves_immediately(client: cmux, workspace_id: str, surface_id: str) -> None:
    """A marker already sitting in scrollback when the call arrives must be caught by the
    atomic 'already satisfied?' check -- not missed, and not force the caller to actually
    block for it (waited: false distinguishes this from a real wait)."""
    marker = _new_marker("ALREADY")
    client.send_surface(surface_id, f"echo {marker}\n")
    # Let the echo actually land in the terminal buffer before we ask -- this test targets the
    # "already true" branch specifically; the genuine concurrent race is covered separately
    # below.
    time.sleep(0.6)

    started = time.time()
    result = _surface_wait(client, workspace_id, surface_id, pattern=marker, timeout_ms=5_000)
    elapsed = time.time() - started

    _must(result.get("waited") is False, f"expected waited=False (already satisfied), got {result}")
    _must(result.get("match") == marker, f"expected match={marker!r}, got {result.get('match')!r}")
    _must(elapsed < 1.0, f"an already-satisfied wait should return promptly, took {elapsed:.2f}s")


def _test_concurrent_marker_is_not_missed(client: cmux, workspace_id: str, surface_id: str) -> None:
    """The literal 'a parallel state change can't be missed' case from #166: fire the marker
    from a background thread with only a small jitter while the main thread issues
    surface.wait essentially concurrently, so the two race in wall-clock time. Whichever
    happens to land first, the wait must still resolve (never time out)."""
    marker = _new_marker("RACE")
    errors: list[Exception] = []

    def _fire() -> None:
        try:
            time.sleep(0.05)
            client.send_surface(surface_id, f"echo {marker}\n")
        except Exception as exc:  # pragma: no cover - surfaced via errors list
            errors.append(exc)

    thread = threading.Thread(target=_fire)
    thread.start()
    try:
        result = _surface_wait(client, workspace_id, surface_id, pattern=marker, timeout_ms=6_000)
    finally:
        thread.join(timeout=5.0)

    _must(not errors, f"background echo failed: {errors}")
    _must(result.get("match") == marker, f"race case: expected match={marker!r}, got {result}")


def _test_pattern_timeout(client: cmux, workspace_id: str, surface_id: str) -> None:
    """A pattern that never appears must time out cleanly (not hang) within roughly the
    requested budget."""
    marker = _new_marker("NEVER")
    started = time.time()
    try:
        _surface_wait(client, workspace_id, surface_id, pattern=marker, timeout_ms=1_500)
        raise cmuxError("expected surface.wait to time out, but it returned success")
    except cmuxError as exc:
        _must("timeout" in str(exc).lower(), f"expected a timeout error, got: {exc}")
    elapsed = time.time() - started
    _must(elapsed < 4.0, f"timeout case took too long: {elapsed:.2f}s")


def _test_exit_condition(client: cmux, workspace_id: str) -> None:
    """Light coverage for the `exit` condition on a dedicated second surface, so it doesn't
    interfere with (or get torn down by) the pattern-focused surface used above."""
    surface_id = client.new_surface(panel_type="terminal")
    _wait_for_surface_command_roundtrip(client, workspace_id, surface_id)

    client.send_surface(surface_id, "exit\n")
    result = _surface_wait(client, workspace_id, surface_id, exit_condition=True, timeout_ms=6_000)
    _must(result.get("condition") == "exit", f"expected condition=exit, got {result}")
    _must(result.get("waited") is True, f"expected waited=True, got {result}")


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

            _test_pattern_resolves_after_delay(client, workspace_id, surface_id)
            _test_pattern_already_present_resolves_immediately(client, workspace_id, surface_id)
            _test_concurrent_marker_is_not_missed(client, workspace_id, surface_id)
            _test_pattern_timeout(client, workspace_id, surface_id)
            _test_exit_condition(client, workspace_id)

            client.close_workspace(workspace_id)
            workspace_id = ""

        print("PASS: surface.wait pattern/exit conditions behave as documented")
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
