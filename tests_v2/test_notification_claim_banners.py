#!/usr/bin/env python3
"""`notification.claim_banners`: while a connection claims `needs_input`, an `agent.needs_input`
notification still lands in `notification.list` but is not handed to the macOS banner path, and
the banner comes back by itself once that connection closes.

Banner hand-offs are read through the Debug-only `debug.notification.banner_count` counter, which
counts every notification the store passes to its banner delivery handler (before the
notification-permission check, so a runner without permission still counts them). The app focus
override is set to inactive so the focused-panel suppression never hides a banner on its own.
"""

from __future__ import annotations

import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from v2_support import must as _must  # noqa: E402
from v2_support import wait_for as _wait_for  # noqa: E402


DEFAULT_SOCKET_PATHS = ["/tmp/programa-debug.sock", "/tmp/programa.sock"]


def _banner_count(client: ProgramaClient) -> int:
    return int((client._call("debug.notification.banner_count") or {}).get("count", -1))


def _post_needs_input(client: ProgramaClient, workspace_id: str, surface_id: str) -> dict:
    """Posts one agent.needs_input with a unique body and returns its notification.list entry.
    The notification is posted on a later main-thread hop, and the banner counter moves in that
    same hop, so once the entry is listed the counter is final for this call."""
    body = f"claim-banners-{uuid.uuid4().hex[:8]}"
    client._call(
        "agent.needs_input",
        {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "provider": "claude-code",
            "title": "Claude Code",
            "body": body,
            "kind": "question",
        },
    )
    found: list[dict] = []

    def listed() -> bool:
        found[:] = [n for n in client.list_notifications() if n.get("body") == body]
        return bool(found)

    _wait_for(listed, timeout_s=5.0)
    return found[0]


def _expect_invalid_params(client: ProgramaClient, params: dict) -> None:
    try:
        client._call("notification.claim_banners", params)
    except ProgramaClientError as exc:
        _must(str(exc).startswith("invalid_params"), f"expected invalid_params for {params}, got {exc}")
        return
    raise ProgramaClientError(f"notification.claim_banners accepted {params}")


def _run_once(socket_path: str) -> int:
    workspace_id = ""
    with ProgramaClient(socket_path) as client:
        try:
            workspace_id = client.new_workspace()
            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"workspace should have at least one surface: {workspace_id}")
            surface_id = surfaces[0][1]

            client.set_app_focus(False)
            client._call("debug.notification.banner_reset")

            first = _post_needs_input(client, workspace_id, surface_id)
            _must(_banner_count(client) == 1, "an unclaimed needs_input must be handed to the banner path")
            _must(first.get("is_read") is False, f"needs_input notification should be unread: {first}")

            with ProgramaClient(socket_path) as claimer:
                _expect_invalid_params(claimer, {"kinds": ["bogus"]})
                _expect_invalid_params(claimer, {})

                ack = claimer._call("notification.claim_banners", {"kinds": ["needs_input"]}) or {}
                _must(ack.get("claimed") == ["needs_input"], f"unexpected claim ack: {ack}")

                claimed = _post_needs_input(client, workspace_id, surface_id)
                _must(_banner_count(client) == 1, "a claimed needs_input must not be handed to the banner path")
                _must(claimed.get("is_read") is False, f"a claimed needs_input must still be listed unread: {claimed}")

                released = claimer._call("notification.claim_banners", {"kinds": []}) or {}
                _must(released.get("claimed") == [], f"unexpected release ack: {released}")
                _post_needs_input(client, workspace_id, surface_id)
                _must(_banner_count(client) == 2, "kinds [] must release the claim")

                claimer._call("notification.claim_banners", {"kinds": ["needs_input"]})
                _post_needs_input(client, workspace_id, surface_id)
                _must(_banner_count(client) == 2, "a renewed claim must hold the banner again")

            # The server releases the claim when its read loop sees the closed socket, which can
            # land just after the client-side close returns, so allow a few posts for it.
            deadline = time.time() + 5.0
            while True:
                _post_needs_input(client, workspace_id, surface_id)
                if _banner_count(client) == 3:
                    break
                _must(time.time() < deadline, "closing the claiming connection must restore banners")
                time.sleep(0.1)

            print("PASS: notification.claim_banners holds needs_input banners only while its connection lives")
            return 0
        finally:
            try:
                client.set_app_focus(None)
            except ProgramaClientError:
                pass
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                except ProgramaClientError:
                    pass


def main() -> int:
    env_socket = os.environ.get("PROGRAMA_SOCKET")
    if env_socket:
        return _run_once(env_socket)

    last_error: Exception | None = None
    for socket_path in DEFAULT_SOCKET_PATHS:
        try:
            return _run_once(socket_path)
        except ProgramaClientError as exc:
            text = str(exc)
            recoverable = ("Failed to connect", "Socket not found")
            if not any(token in text for token in recoverable):
                raise
            last_error = exc
            continue

    if last_error is not None:
        raise last_error
    raise ProgramaClientError("No socket candidates configured")


if __name__ == "__main__":
    raise SystemExit(main())
