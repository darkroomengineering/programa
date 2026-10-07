#!/usr/bin/env python3
"""Socket commands must not steal focus and must report the pane cap as a typed error (SOCK-30).

  1. pane.list's focused pane is unchanged after surface.split
     (socket commands never move focus unless they are focus commands).
  4. A split past the cap returns limit_reached with data.max_panes == 4 (surface.split, pane.create).
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
MAX_PANES = 4


def _focused_pane(c: ProgramaClient) -> str:
    rows = [r for r in c.list_panes() if r[3]]
    _must(len(rows) == 1, f"expected exactly one focused pane, got {c.list_panes()}")
    return rows[0][1]


def _expect_limit(c: ProgramaClient, method: str, params: dict) -> None:
    try:
        c._call(method, params)
    except ProgramaClientError as error:
        text = str(error)
        _must("limit_reached" in text, f"{method}: expected limit_reached, got {text}")
        _must("max_panes" in text and f"{MAX_PANES}" in text, f"{method}: expected data.max_panes == {MAX_PANES}, got {text}")
        return
    raise ProgramaClientError(f"{method} past the pane cap unexpectedly succeeded")


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    ws = ""
    with ProgramaClient(SOCKET_PATH) as c:
        try:
            ws = c.new_workspace()
            c.select_workspace(ws)
            time.sleep(0.4)
            focused = _focused_pane(c)
            focused_surface = c.current_workspace()  # selection sanity anchor
            _must(focused_surface == ws, "fixture workspace is not selected")

            # 1. focus preservation across non-focus commands
            c.new_split("right")
            time.sleep(0.3)
            _must(_focused_pane(c) == focused, "surface.split moved the focused pane")

            # 4. pane cap, on a fresh workspace so the count is exact
            ws2 = c.new_workspace()
            c.select_workspace(ws2)
            time.sleep(0.4)
            for i in range(MAX_PANES - 1):
                c.new_split("right" if i % 2 == 0 else "down")
                time.sleep(0.3)
            _must(len(c.list_panes()) == MAX_PANES, f"expected {MAX_PANES} panes, got {c.list_panes()}")
            _expect_limit(c, "surface.split", {"direction": "right"})
            _expect_limit(c, "pane.create", {"direction": "right", "type": "terminal"})
            _must(len(c.list_panes()) == MAX_PANES, "refused split changed the pane count")
            c.close_workspace(ws2)
        finally:
            if ws:
                try:
                    c.close_workspace(ws)
                except Exception:
                    pass

    print("PASS: focus preserved, pane cap typed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
