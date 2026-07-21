#!/usr/bin/env python3
"""Issue #164 (v1 hook tier) regression: surface.report_agent_state / clear_agent_state
land on surface.list, and reject an unrecognized state value.

This exercises the socket plumbing the shipped Claude Code / Codex / OpenCode hook
wrappers call (see CLI/CLI+Hooks.swift's reportAgentState/clearAgentState) — not any
heuristic/screen-rule classification, which does not exist in this tier.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _surface_agent_state(client: cmux, workspace_id: str, surface_id: str) -> object:
    listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    for surface in listed.get("surfaces") or []:
        if str(surface.get("id")) == surface_id:
            return surface.get("agent_state")
    raise cmuxError(f"surface {surface_id} not found in surface.list: {listed}")


def main() -> int:
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"new workspace should have at least one surface: {surfaces}")
            surface_id = surfaces[0][1]

            # A surface with no hook report has no agent_state at all (not "idle") —
            # distinct from an explicit hook-reported rest state.
            initial_state = _surface_agent_state(client, workspace_id, surface_id)
            _must(initial_state is None, f"agent_state should be absent before any report: {initial_state!r}")

            reported = client._call(
                "surface.report_agent_state",
                {"workspace_id": workspace_id, "surface_id": surface_id, "state": "working"},
            ) or {}
            _must(reported.get("state") == "working", f"report should echo state=working: {reported}")

            state_after_working = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_working == "working", f"surface.list should carry agent_state=working: {state_after_working!r}")

            client._call(
                "surface.report_agent_state",
                {"workspace_id": workspace_id, "surface_id": surface_id, "state": "blocked"},
            )
            state_after_blocked = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_blocked == "blocked", f"surface.list should carry agent_state=blocked: {state_after_blocked!r}")

            # Strict-blocked rule at the wire level: only the three known state values
            # are accepted — an unrecognized value must be rejected, not silently
            # coerced into a blocked/working badge.
            rejected = False
            try:
                client._call(
                    "surface.report_agent_state",
                    {"workspace_id": workspace_id, "surface_id": surface_id, "state": "not-a-real-state"},
                )
            except cmuxError:
                rejected = True
            _must(rejected, "surface.report_agent_state should reject an unrecognized state value")

            # The rejected call must not have clobbered the last-good state.
            state_after_rejected = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_rejected == "blocked", f"rejected report should not change agent_state: {state_after_rejected!r}")

            client._call(
                "surface.clear_agent_state",
                {"workspace_id": workspace_id, "surface_id": surface_id},
            )
            state_after_clear = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_clear is None, f"agent_state should be absent after clear: {state_after_clear!r}")

            client.close_workspace(workspace_id)
            workspace_id = ""
    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: surface.report_agent_state / clear_agent_state round-trip through surface.list")
    return 0


if __name__ == "__main__":
    sys.exit(main())
