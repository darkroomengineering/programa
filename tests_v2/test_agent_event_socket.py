#!/usr/bin/env python3
"""docs/plans/agent-events.md: the normalized `agent.event` v2 method lands on
surface.list exactly like the existing tri-state `surface.report_agent_state`
(tests_v2/test_agent_activity_state_socket.py) does, since both funnel through
the same hooks-always-win `updatePanelAgentState(source: .hooks)` write path.

This does not re-test the tri-state wire method itself -- it exercises the new
normalized event_type -> AgentActivityState mapping end to end over the socket.
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


def _surface_agent_state_source(client: cmux, workspace_id: str, surface_id: str) -> object:
    listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    for surface in listed.get("surfaces") or []:
        if str(surface.get("id")) == surface_id:
            return surface.get("agent_state_source")
    raise cmuxError(f"surface {surface_id} not found in surface.list: {listed}")


def main() -> int:
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"new workspace should have at least one surface: {surfaces}")
            surface_id = surfaces[0][1]

            _must(
                _surface_agent_state(client, workspace_id, surface_id) is None,
                "agent_state should be absent before any event",
            )

            # turn.started -> working
            reported = client._call(
                "agent.event",
                {
                    "workspace_id": workspace_id,
                    "surface_id": surface_id,
                    "event_type": "turn.started",
                    "provider": "claude-code",
                    "session_id": "test-session-1",
                },
            ) or {}
            _must(reported.get("event_type") == "turn.started", f"should echo event_type: {reported}")
            _must(reported.get("state") == "working", f"turn.started should apply state=working: {reported}")
            _must(reported.get("source") == "hooks", f"agent.event report should echo source=hooks: {reported}")

            state_after_turn_started = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_turn_started == "working", f"surface.list should carry agent_state=working: {state_after_turn_started!r}")
            source_after_turn_started = _surface_agent_state_source(client, workspace_id, surface_id)
            _must(source_after_turn_started == "hooks", f"surface.list should carry agent_state_source=hooks: {source_after_turn_started!r}")

            # request.opened -> blocked (permission/approval prompt)
            client._call(
                "agent.event",
                {
                    "workspace_id": workspace_id,
                    "surface_id": surface_id,
                    "event_type": "request.opened",
                    "provider": "claude-code",
                    "session_id": "test-session-1",
                    "label": "Bash(rm -rf /tmp/x)",
                },
            )
            state_after_request_opened = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_request_opened == "blocked", f"request.opened should apply state=blocked: {state_after_request_opened!r}")

            # request.resolved -> working again
            client._call(
                "agent.event",
                {
                    "workspace_id": workspace_id,
                    "surface_id": surface_id,
                    "event_type": "request.resolved",
                    "provider": "claude-code",
                    "session_id": "test-session-1",
                    "resolution": "approved",
                },
            )
            state_after_request_resolved = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_request_resolved == "working", f"request.resolved should apply state=working: {state_after_request_resolved!r}")

            # An unrecognized event_type must be rejected, not silently applied.
            rejected = False
            try:
                client._call(
                    "agent.event",
                    {
                        "workspace_id": workspace_id,
                        "surface_id": surface_id,
                        "event_type": "not-a-real-event",
                    },
                )
            except cmuxError:
                rejected = True
            _must(rejected, "agent.event should reject an unrecognized event_type")

            state_after_rejected = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_rejected == "working", f"rejected event should not change agent_state: {state_after_rejected!r}")

            # session.exited -> clears the state entirely, same as surface.clear_agent_state.
            client._call(
                "agent.event",
                {
                    "workspace_id": workspace_id,
                    "surface_id": surface_id,
                    "event_type": "session.exited",
                    "provider": "claude-code",
                    "session_id": "test-session-1",
                },
            )
            state_after_session_exited = _surface_agent_state(client, workspace_id, surface_id)
            _must(state_after_session_exited is None, f"session.exited should clear agent_state: {state_after_session_exited!r}")

            client.close_workspace(workspace_id)
            workspace_id = ""
    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: agent.event normalized events round-trip through surface.list")
    return 0


if __name__ == "__main__":
    sys.exit(main())
