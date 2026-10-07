#!/usr/bin/env python3
"""Socket error-code contract sweep (SOCK-30): typed errors, and no side effects on failure.

Callers branch on the error code, so each case pins the code:
  - workspace.close with an unknown ref        -> not_found
  - workspace.close on a window's last workspace -> invalid_state (workspace survives)
  - notification.create_for_surface, closed surface -> not_found
  - surface.focus, unknown id -> not_found, selection unchanged; malformed id -> invalid_params
  - markdown.open /dev/zero (device, would never finish reading) -> invalid_params
"""

import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _expect_code(c: ProgramaClient, code: str, method: str, params: dict) -> str:
    try:
        c._call(method, params)
    except ProgramaClientError as error:
        _must(code in str(error), f"{method} {params!r}: expected {code}, got {error}")
        return str(error)
    raise ProgramaClientError(f"{method} {params!r}: expected {code}, but the call succeeded")


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    created_window = None
    created_workspaces: list[str] = []
    with ProgramaClient(SOCKET_PATH) as c:
        try:
            # 2. unknown workspace ref
            _expect_code(c, "not_found", "workspace.close", {"workspace_id": "workspace:999"})

            # 3. last workspace of a window. A fresh window has exactly one workspace.
            created_window = c.new_window()
            time.sleep(0.5)
            rows = c.list_workspaces(window_id=created_window)
            _must(len(rows) == 1, f"expected a fresh window to hold 1 workspace, got {rows}")
            only_ws = rows[0][1]
            _expect_code(c, "invalid_state", "workspace.close", {"workspace_id": only_ws, "window_id": created_window})
            rows_after = c.list_workspaces(window_id=created_window)
            _must([r[1] for r in rows_after] == [only_ws], f"last workspace must survive: {rows_after}")
            c.close_window(created_window)
            created_window = None
            time.sleep(0.3)

            # Fixtures for the rest: a workspace with a second surface, then close that surface.
            ws = c.new_workspace()
            created_workspaces.append(ws)
            c.select_workspace(ws)
            time.sleep(0.3)
            extra = c.new_split("right")
            time.sleep(0.3)
            c.close_surface(extra)
            time.sleep(0.3)

            # 7. notify a closed surface
            _expect_code(c, "not_found", "notification.create_for_surface",
                         {"surface_id": extra, "title": "t", "workspace_id": ws})

            # 8. surface.focus: bad id is not_found with no selection change; malformed is invalid_params
            window_before = c.current_window()
            ws_before = c.current_workspace()
            _expect_code(c, "not_found", "surface.focus", {"surface_id": str(uuid.uuid4())})
            _must(c.current_window() == window_before, "surface.focus failure changed the selected window")
            _must(c.current_workspace() == ws_before, "surface.focus failure changed the selected workspace")
            _expect_code(c, "invalid_params", "surface.focus", {"surface_id": "not-a-uuid"})

            # 9. device file
            _expect_code(c, "invalid_params", "markdown.open", {"path": "/dev/zero"})

        finally:
            if created_window:
                try:
                    c.close_window(created_window)
                except Exception:
                    pass
            for w in created_workspaces:
                try:
                    c.close_workspace(w)
                except Exception:
                    pass

    print("PASS: socket error contract sweep")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
