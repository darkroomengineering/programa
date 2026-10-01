#!/usr/bin/env python3
"""surface.resolve_tty and agent.spawn pane identity (SOCK-30).

resolve_tty: a known tty (as /dev/ttysNNN or bare ttysNNN) resolves to exactly that surface and
returns only its ids (no `terminals` list); an unknown tty is not_found; a missing tty is
invalid_params. The tty is attached with surface.report_tty and read back through
debug.terminals (Debug builds only, which is what CI runs).

agent.spawn: pane_id equals the pane pane/surface listing reports for the returned surface_id.
"""

import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must, wait_until

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _expect_code(c: ProgramaClient, code: str, method: str, params: dict) -> None:
    try:
        c._call(method, params)
    except ProgramaClientError as error:
        _must(code in str(error), f"{method} {params!r}: expected {code}, got {error}")
        return
    raise ProgramaClientError(f"{method} {params!r}: expected {code}, but it succeeded")


def _tty_of(c: ProgramaClient, surface_id: str) -> str | None:
    rows = (c._call("debug.terminals", {}) or {}).get("terminals") or []
    for row in rows:
        if row.get("surface_id") == surface_id:
            return row.get("tty")
    return None


def _test_resolve_tty(c: ProgramaClient, ws: str, surface: str) -> None:
    tty = "ttys" + str(int(uuid.uuid4().int % 900000) + 100000)
    c._call("surface.report_tty", {"workspace_id": ws, "surface_id": surface, "tty_name": tty})
    wait_until(lambda: _tty_of(c, surface) == tty, timeout_s=5.0, message="tty never appeared in debug.terminals")

    for form in (f"/dev/{tty}", tty):
        res = c._call("surface.resolve_tty", {"tty": form}) or {}
        _must(res.get("workspace_id") == ws, f"tty {form!r}: wrong workspace in {res}")
        _must(res.get("surface_id") == surface, f"tty {form!r}: wrong surface in {res}")
        _must("terminals" not in res, f"resolve_tty must not leak the terminal list: {res}")

    _expect_code(c, "not_found", "surface.resolve_tty", {"tty": "ttys" + "9" * 9})
    _expect_code(c, "invalid_params", "surface.resolve_tty", {})


def _test_agent_spawn_pane(c: ProgramaClient, parent_ws: str) -> None:
    spawned_ws = ""
    agent_id = ""
    try:
        res = c._call("agent.spawn", {"parent_workspace_id": parent_ws, "task": "sock30 pane check"}, timeout_s=20.0) or {}
        spawned_ws = str(res.get("workspace_id") or "")
        agent_id = str(res.get("agent_id") or "")
        surface_id = res.get("surface_id")
        pane_id = res.get("pane_id")
        _must(bool(pane_id) and bool(res.get("pane_ref")), f"agent.spawn result lacks pane_id/pane_ref: {res}")
        _must(bool(surface_id), f"agent.spawn result lacks surface_id: {res}")
        rows = (c._call("surface.list", {"workspace_id": spawned_ws}) or {}).get("surfaces") or []
        row = next((r for r in rows if r.get("id") == surface_id), None)
        _must(row is not None, f"spawned surface missing from surface.list: {rows}")
        _must(row.get("pane_id") == pane_id, f"pane_id {pane_id} != listed pane {row.get('pane_id')}")
    finally:
        if agent_id:
            try:
                c._call("agent.task.finish", {"agent_id": agent_id, "state": "cancelled"})
            except Exception:
                pass
        if spawned_ws:
            try:
                c.close_workspace(spawned_ws)
            except Exception:
                pass


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    ws = ""
    with ProgramaClient(SOCKET_PATH) as c:
        try:
            ws = c.new_workspace()
            c.select_workspace(ws)
            time.sleep(0.4)
            surface = c.list_surfaces()[0][1]
            _test_resolve_tty(c, ws, surface)
            _test_agent_spawn_pane(c, ws)
        finally:
            if ws:
                try:
                    c.close_workspace(ws)
                except Exception:
                    pass

    print("PASS: surface.resolve_tty and agent.spawn pane identity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
