#!/usr/bin/env python3
"""ports.list / ports.stop: a dev server started in a surface shows up under its workspace with
its pid and command, ports.stop terminates it, and ports.stop refuses pids Programa does not own.
"""

from __future__ import annotations

import os
import socket
import sys
import time
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


def _find_row(listing: Dict[str, Any], workspace_id: str, port: int) -> Optional[Dict[str, Any]]:
    for workspace in listing.get("workspaces") or []:
        if workspace.get("id") != workspace_id:
            continue
        for row in workspace.get("ports") or []:
            if row.get("port") == port:
                return row
    return None


def _wait_for_row(
    c: ProgramaClient, workspace_id: str, surface_id: str, port: int, present: bool, timeout_s: float
) -> Optional[Dict[str, Any]]:
    deadline = time.monotonic() + timeout_s
    last: Dict[str, Any] = {}
    while time.monotonic() < deadline:
        # Ask for a fresh scan; the periodic path alone can take several seconds.
        c._call(
            "surface.ports_kick",
            {"workspace_id": workspace_id, "surface_id": surface_id, "reason": "refresh"},
            timeout_s=10.0,
        )
        last = c._call("ports.list", {}, timeout_s=10.0) or {}
        row = _find_row(last, workspace_id, port)
        if (row is not None) == present:
            return row
        time.sleep(0.5)
    raise ProgramaClientError(
        f"Timed out waiting for port {port} to be {'listed' if present else 'gone'}; last ports.list: {last}"
    )


def main() -> int:
    port = _free_port()
    workspace_id = ""
    try:
        with ProgramaClient(SOCKET_PATH) as c:
            created = c._call("workspace.create", {}, timeout_s=15.0) or {}
            workspace_id = str(created.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
            c.select_workspace(workspace_id)

            surfaces = c._call("surface.list", {"workspace_id": workspace_id}, timeout_s=10.0) or {}
            rows = surfaces.get("surfaces") or []
            _must(len(rows) >= 1, f"Expected a terminal surface, got: {surfaces}")
            surface_id = str(rows[0].get("id") or "")

            # The listing must refuse pids that no Programa workspace owns.
            try:
                c._call("ports.stop", {"pid": 1}, timeout_s=10.0)
                raise AssertionError("ports.stop accepted pid 1")
            except ProgramaClientError as e:
                _must("invalid_params" in str(e), f"pid 1 should be invalid_params, got: {e}")
            try:
                c._call("ports.stop", {"pid": os.getpid()}, timeout_s=10.0)
                raise AssertionError("ports.stop accepted a pid Programa does not own")
            except ProgramaClientError as e:
                _must("not_found" in str(e), f"unowned pid should be not_found, got: {e}")

            c._call(
                "surface.send_text",
                {"surface_id": surface_id, "text": f"python3 -m http.server {port} --bind 127.0.0.1\n"},
                timeout_s=10.0,
            )
            row = _wait_for_row(c, workspace_id, surface_id, port, present=True, timeout_s=30.0)
            _must(row is not None, "listed row missing")
            pid = row.get("pid")
            _must(isinstance(pid, int) and pid > 1, f"row has no usable pid: {row}")
            _must("python" in str(row.get("command") or "").lower(), f"unexpected command: {row}")
            _must(row.get("surface_id") == surface_id, f"row not attributed to the surface: {row}")

            stopped = c._call("ports.stop", {"pid": pid}, timeout_s=10.0) or {}
            _must(stopped.get("signaled") is True, f"ports.stop did not signal: {stopped}")
            _wait_for_row(c, workspace_id, surface_id, port, present=False, timeout_s=30.0)

            c.close_workspace(workspace_id)
            workspace_id = ""
        print("PASS: ports.list shows the dev server, ports.stop ends it, unowned pids are refused")
        return 0
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as cleanup:
                    cleanup.close_workspace(workspace_id)
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
