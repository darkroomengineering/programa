#!/usr/bin/env python3
"""Regression tests for socket event subscriptions (#167): `subscribe` pushes agent_state,
workspace_lifecycle, and output events over a long-lived connection instead of the client
polling.

This is the #167 verify criterion verbatim: "tests_v2 client receives state-change events for a
scripted agent without polling" -- no real agent is involved, state is driven directly via
`surface.report_agent_state` on a *separate* connection while the subscribed connection just
reads pushed frames (see the HARD-WON LESSONS note below).

Pushed event frames are NOT wrapped in the usual {"id","ok","result"} v2 envelope (see
docs/socket-api.md "Socket Event Subscriptions (#167)") -- each is its own single-line
JSON object with an "event" key, so this test reads raw lines via `client._recv_line` (bypassing
`cmux._call`'s request/response id matching, which doesn't apply to pushed frames) rather than
`_call`.

HARD-WON LESSONS from this repo's CI (see test_surface_wait.py's header):
  - Any concurrent send while the subscribed connection is reading events MUST use its own cmux
    connection -- sharing one would mean the "driver" send and the subscriber's event read are
    racing for the same socket.
  - Client-side socket read timeouts must exceed how long we expect to wait for an event.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # noqa: E402
from v2_support import must as _must
from pane_resize_test_support import (  # noqa: E402
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


DEFAULT_SOCKET_PATHS = ["/tmp/programa-debug.sock", "/tmp/programa.sock"]


def _wait_for(pred, timeout_s: float = 10.0, step_s: float = 0.05) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _call_while_events_may_be_pending(client: cmux, method: str, params: dict | None = None) -> dict:
    """Send an ordinary RPC on a subscribed connection while ignoring interleaved events."""
    if client._socket is None:
        raise cmuxError("Not connected")
    request_id = client._next_id
    client._next_id += 1
    payload = {"id": request_id, "method": method, "params": params or {}}
    client._socket.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))

    deadline = time.time() + 5.0
    while time.time() < deadline:
        frame = json.loads(client._recv_line(timeout_s=max(0.5, deadline - time.time())))
        if not isinstance(frame, dict) or frame.get("id") != request_id:
            continue
        if frame.get("ok") is not True:
            raise cmuxError(f"{method} failed: {frame}")
        return dict(frame.get("result") or {})
    raise cmuxError(f"Timed out waiting for {method} response")


def _report_agent_state(socket_path: str, workspace_id: str, surface_id: str, state: str) -> None:
    with cmux(socket_path) as bg_client:
        bg_client._call(
            "surface.report_agent_state",
            {"workspace_id": workspace_id, "surface_id": surface_id, "state": state},
        )


def _read_event(client: cmux, timeout_s: float = 10.0) -> dict:
    line = client._recv_line(timeout_s=timeout_s)
    try:
        frame = json.loads(line)
    except json.JSONDecodeError as exc:
        raise cmuxError(f"Invalid JSON event frame: {exc}: {line[:200]}")
    _must(isinstance(frame, dict), f"expected a JSON object event frame, got: {line[:200]}")
    return frame


def _surface_has(client: cmux, workspace_id: str, surface_id: str, token: str) -> bool:
    payload = client._call(
        "surface.read_text",
        {"workspace_id": workspace_id, "surface_id": surface_id, "scrollback": True},
    ) or {}
    return token in str(payload.get("text") or "")


def _test_agent_state_events_without_polling(socket_path: str, workspace_id: str, surface_id: str) -> None:
    """The #167 verify criterion: a subscribed client receives agent_state change events for a
    scripted (socket-driven) agent without ever polling surface.list itself."""
    with cmux(socket_path) as sub_client:
        ack = sub_client._call("subscribe", {"classes": ["agent_state"]}, timeout_s=10.0) or {}
        _must(ack.get("classes") == ["agent_state"], f"expected classes echoed back, got {ack}")
        _must(isinstance(ack.get("subscription_id"), str) and ack["subscription_id"], f"expected a subscription_id, got {ack}")
        _must(ack.get("max_queued_events", 0) > 0, f"expected max_queued_events > 0, got {ack}")

        # Only start driving state changes *after* the ack is in hand -- see the file header on
        # why the ack-vs-first-event ordering isn't otherwise guaranteed to race-test cleanly.
        _report_agent_state(socket_path, workspace_id, surface_id, "working")
        working_event = _read_event(sub_client, timeout_s=10.0)
        _must(working_event.get("event") == "agent_state", f"expected an agent_state event, got {working_event}")
        _must(working_event.get("surface_id") == surface_id, f"expected surface_id={surface_id}, got {working_event}")
        _must(working_event.get("workspace_id") == workspace_id, f"expected workspace_id={workspace_id}, got {working_event}")
        _must(working_event.get("state") == "working", f"expected state=working, got {working_event}")
        _must(isinstance(working_event.get("ts"), (int, float)), f"expected a numeric ts, got {working_event}")

        _report_agent_state(socket_path, workspace_id, surface_id, "idle")
        idle_event = _read_event(sub_client, timeout_s=10.0)
        _must(idle_event.get("state") == "idle", f"expected state=idle, got {idle_event}")

        sub_client._call("unsubscribe", {}, timeout_s=5.0)


def _test_subscription_scoped_to_requested_surface(socket_path: str, workspace_id: str, watched_surface_id: str, other_surface_id: str) -> None:
    """Subscribing does not require --surface_ids for agent_state (unlike output) but events
    are still per-surface: a report on a different surface must not surface as an event here,
    and the one we care about must still arrive promptly."""
    with cmux(socket_path) as sub_client:
        sub_client._call("subscribe", {"classes": ["agent_state"]}, timeout_s=10.0)

        _report_agent_state(socket_path, workspace_id, other_surface_id, "blocked")
        _report_agent_state(socket_path, workspace_id, watched_surface_id, "working")

        seen_watched = False
        deadline = time.time() + 10.0
        while time.time() < deadline and not seen_watched:
            frame = _read_event(sub_client, timeout_s=max(0.5, deadline - time.time()))
            if frame.get("surface_id") == watched_surface_id and frame.get("state") == "working":
                seen_watched = True
        _must(seen_watched, "expected to see the watched surface's working event within 10s")


def _test_workspace_lifecycle_rename_event(socket_path: str, workspace_id: str) -> None:
    """workspace_lifecycle 'renamed' fires from the explicit rename entry point."""
    with cmux(socket_path) as sub_client:
        sub_client._call("subscribe", {"classes": ["workspace_lifecycle"]}, timeout_s=10.0)

        new_title = "PROGRAMA_TEST_RENAME_EVENT"
        with cmux(socket_path) as bg_client:
            bg_client._call("workspace.rename", {"workspace_id": workspace_id, "title": new_title})

        seen_rename = False
        deadline = time.time() + 10.0
        while time.time() < deadline and not seen_rename:
            frame = _read_event(sub_client, timeout_s=max(0.5, deadline - time.time()))
            if frame.get("event") == "workspace_lifecycle" and frame.get("workspace_id") == workspace_id and frame.get("kind") == "renamed":
                _must(frame.get("title") == new_title, f"expected title={new_title!r}, got {frame}")
                seen_rename = True
        _must(seen_rename, "expected a workspace_lifecycle 'renamed' event within 10s")


def _wait_for_output_event(client: cmux, surface_id: str, token: str) -> dict:
    deadline = time.time() + 10.0
    while time.time() < deadline:
        frame = _read_event(client, timeout_s=max(0.5, deadline - time.time()))
        if frame.get("event") != "output" or frame.get("surface_id") != surface_id:
            continue
        if token in str(frame.get("text") or ""):
            return frame
    raise cmuxError(f"expected output event containing {token!r} within 10s")


def _test_output_subscription_can_stop_and_restart(socket_path: str, workspace_id: str, surface_id: str) -> None:
    """An output consumer can unsubscribe while the surface keeps running, then resubscribe
    without receiving output produced while it was detached."""
    first_token = f"OUTPUT_SUB_FIRST_{time.time_ns()}"
    detached_token = f"OUTPUT_SUB_DETACHED_{time.time_ns()}"
    restarted_token = f"OUTPUT_SUB_RESTARTED_{time.time_ns()}"

    with cmux(socket_path) as sub_client:
        ack = sub_client._call(
            "subscribe",
            {"classes": ["output"], "surface_ids": [surface_id]},
            timeout_s=10.0,
        ) or {}
        _must(ack.get("classes") == ["output"], f"expected output subscription ack, got {ack}")
        time.sleep(0.25)  # Let the 100ms output poll establish its initial non-emitting baseline.

        with cmux(socket_path) as driver:
            driver.send_surface(surface_id, f"echo {first_token}\n")
        _wait_for_output_event(sub_client, surface_id, first_token)

        unsubscribed = _call_while_events_may_be_pending(sub_client, "unsubscribe")
        _must(unsubscribed.get("unsubscribed") is True, f"expected unsubscribe ack, got {unsubscribed}")

        with cmux(socket_path) as driver:
            driver.send_surface(surface_id, f"echo {detached_token}\n")
            _wait_for(
                lambda: _surface_has(driver, workspace_id, surface_id, detached_token),
                timeout_s=10.0,
            )

        try:
            unexpected = _read_event(sub_client, timeout_s=0.35)
        except cmuxError as exc:
            _must(
                "Timed out waiting for response" in str(exc),
                f"subscriber failed after unsubscribe ack: {exc}",
            )
        else:
            raise cmuxError(
                f"unsubscribe ack was not a delivery barrier; received stale frame: {unexpected}"
            )

        ack = sub_client._call(
            "subscribe",
            {"classes": ["output"], "surface_ids": [surface_id]},
            timeout_s=10.0,
        ) or {}
        _must(ack.get("classes") == ["output"], f"expected restarted output subscription ack, got {ack}")
        time.sleep(0.25)  # A restarted subscription establishes a fresh baseline.
        with cmux(socket_path) as driver:
            driver.send_surface(surface_id, f"echo {restarted_token}\n")
        restarted = _wait_for_output_event(sub_client, surface_id, restarted_token)
        _must(
            detached_token not in str(restarted.get("text") or ""),
            f"restarted subscription replayed output produced while detached: {restarted}",
        )

        _call_while_events_may_be_pending(sub_client, "unsubscribe")


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

            other_surface_id = client.new_surface(panel_type="terminal")
            _wait_for_surface_command_roundtrip(client, workspace_id, other_surface_id)

            _test_agent_state_events_without_polling(socket_path, workspace_id, surface_id)
            _test_subscription_scoped_to_requested_surface(socket_path, workspace_id, surface_id, other_surface_id)
            _test_workspace_lifecycle_rename_event(socket_path, workspace_id)
            _test_output_subscription_can_stop_and_restart(socket_path, workspace_id, surface_id)

            client.close_workspace(workspace_id)
            workspace_id = ""

        print("PASS: subscribe pushes events and output subscriptions stop and restart cleanly")
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
