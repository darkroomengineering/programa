#!/usr/bin/env python3
"""Regression: workspace handoff and non-focus split must converge on one focus owner."""

from __future__ import annotations

import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _focused_surface(client: cmux, workspace_id: str) -> str:
    rows = client.list_surfaces(workspace=workspace_id)
    focused = [surface_id for _index, surface_id, is_focused in rows if is_focused]
    if len(focused) != 1:
        raise cmuxError(
            f"expected exactly one model-focused surface in {workspace_id}: {rows!r}"
        )
    return focused[0]


def _wait_for_focus_convergence(
    client: cmux,
    *,
    workspace_id: str,
    surface_id: str,
    other_surface_id: str,
    timeout_s: float = 4.0,
) -> None:
    deadline = time.time() + timeout_s
    last_state = ""
    while time.time() < deadline:
        current_workspace = client.current_workspace()
        model_surface = _focused_surface(client, workspace_id)
        target_is_first_responder = client.is_terminal_focused(surface_id)
        other_is_first_responder = client.is_terminal_focused(other_surface_id)
        last_state = (
            f"current_workspace={current_workspace} model_surface={model_surface} "
            f"target_first_responder={target_is_first_responder} "
            f"other_first_responder={other_is_first_responder}"
        )
        if (
            current_workspace == workspace_id
            and model_surface == surface_id
            and target_is_first_responder
            and not other_is_first_responder
        ):
            return
        time.sleep(0.025)

    raise cmuxError(f"focus transition did not converge: {last_state}")


def _assert_input_routes_only_to_target(
    client: cmux,
    *,
    target_surface_id: str,
    excluded_surface_ids: list[str],
) -> None:
    marker = f"focus-transition-{uuid.uuid4().hex}"
    client.simulate_type(f"printf '{marker}\\n'")
    client.simulate_shortcut("enter")

    deadline = time.time() + 4.0
    while time.time() < deadline:
        if marker in client.read_terminal_text(target_surface_id):
            break
        time.sleep(0.05)
    else:
        raise cmuxError(f"typed input did not reach target surface {target_surface_id}")

    wrongly_routed = [
        surface_id
        for surface_id in excluded_surface_ids
        if marker in client.read_terminal_text(surface_id)
    ]
    if wrongly_routed:
        raise cmuxError(
            f"typed input reached non-target surfaces {wrongly_routed}; target={target_surface_id}"
        )


def main() -> int:
    created_workspaces: list[str] = []
    try:
        with cmux(SOCKET_PATH) as client:
            workspace_a = client.new_workspace()
            workspace_b = client.new_workspace()
            created_workspaces.extend([workspace_a, workspace_b])

            client.select_workspace(workspace_a)
            time.sleep(0.25)
            surface_a = _focused_surface(client, workspace_a)

            client.select_workspace(workspace_b)
            time.sleep(0.25)
            surface_b = _focused_surface(client, workspace_b)

            for iteration in range(6):
                # Mutate A's portal/layout while B owns the visible AppKit focus. The split
                # explicitly has no focus intent and must not steal either model or responder focus.
                split_result = client._call(
                    "surface.split",
                    {
                        "workspace_id": workspace_a,
                        "surface_id": surface_a,
                        "direction": "right" if iteration % 2 == 0 else "down",
                        "focus": False,
                    },
                ) or {}
                split_surface = str(split_result.get("surface_id") or "")
                if not split_surface:
                    raise cmuxError(f"surface.split returned no surface: {split_result!r}")

                if client.current_workspace() != workspace_b:
                    raise cmuxError("background non-focus split stole workspace selection")
                if _focused_surface(client, workspace_a) != surface_a:
                    raise cmuxError("background non-focus split stole model focus")

                # Do not sleep between selections: stale async work from B and the split must
                # be rejected when the final transition returns to A.
                client.select_workspace(workspace_a)
                client.select_workspace(workspace_b)
                client.select_workspace(workspace_a)

                _wait_for_focus_convergence(
                    client,
                    workspace_id=workspace_a,
                    surface_id=surface_a,
                    other_surface_id=surface_b,
                )
                _assert_input_routes_only_to_target(
                    client,
                    target_surface_id=surface_a,
                    excluded_surface_ids=[surface_b, split_surface],
                )

                client.close_surface(split_surface)
                _wait_for_focus_convergence(
                    client,
                    workspace_id=workspace_a,
                    surface_id=surface_a,
                    other_surface_id=surface_b,
                )

    finally:
        with cmux(SOCKET_PATH) as cleanup_client:
            for workspace_id in reversed(created_workspaces):
                try:
                    cleanup_client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: rapid workspace/split transitions preserve one observable focus owner")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
