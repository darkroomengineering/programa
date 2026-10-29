#!/usr/bin/env python3
"""v2 regression: a tab dropped outside every window moves into a new window.

Drives the DEBUG seam `debug.tab.tear_off`, which runs the same code a tab
drag ends in. The real mouse drag is not exercised here.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
MARKER = "TEAROFF_MARKER_42"


def _wait_for_text(c: ProgramaClient, surface_id: str, needle: str, timeout_s: float = 10.0) -> str:
    deadline = time.time() + timeout_s
    text = ""
    while time.time() < deadline:
        text = c.read_terminal_text(surface_id)
        if needle in text:
            return text
        time.sleep(0.2)
    raise ProgramaClientError(f"Timed out waiting for {needle!r} in surface {surface_id}; last text tail={text[-300:]!r}")


def _surface_ids(c: ProgramaClient, workspace_id: str) -> list[str]:
    return [sid for _idx, sid, _focused in c.list_surfaces(workspace_id)]


def main() -> int:
    with ProgramaClient(SOCKET_PATH) as c:
        windows = c.list_windows()
        ws0 = c.current_workspace()

        # The last surface of the last window stays put.
        if len(windows) == 1 and windows[0].get("workspace_count") == 1:
            only = _surface_ids(c, ws0)
            if len(only) == 1:
                try:
                    c._call("debug.tab.tear_off", {"surface_id": only[0], "x": 10, "y": 10})
                except ProgramaClientError as exc:
                    if "not_found" not in str(exc):
                        raise
                else:
                    raise ProgramaClientError("Expected tear-off of the last surface to be refused")
                if len(c.list_windows()) != 1:
                    raise ProgramaClientError("Refused tear-off still changed the window count")

        moving = c.new_surface(panel_type="terminal")
        time.sleep(0.3)
        # The arithmetic keeps the marker out of the echoed command line.
        c.send_surface(moving, "echo TEAROFF_MARKER_$((6*7))\n")
        _wait_for_text(c, moving, MARKER)

        before = {str(w.get("id")) for w in c.list_windows()}
        res = c._call("debug.tab.tear_off", {"surface_id": moving, "x": 40, "y": 40}) or {}
        new_window_id = str(res.get("window_id") or "")
        try:
            if not new_window_id or new_window_id in before:
                raise ProgramaClientError(f"Expected a new window id, got {res}")
            after = {str(w.get("id")): w for w in c.list_windows()}
            if len(after) != len(before) + 1 or new_window_id not in after:
                raise ProgramaClientError(f"Expected exactly one new window (before={before}, after={list(after)})")

            new_ws = str(after[new_window_id].get("selected_workspace_id") or "")
            new_surfaces = _surface_ids(c, new_ws)
            if new_surfaces != [moving]:
                raise ProgramaClientError(f"Expected the new window to hold only the moved surface, got {new_surfaces}")
            if moving in _surface_ids(c, ws0):
                raise ProgramaClientError("Moved surface is still listed in its source workspace")

            # Moved, not recreated: the shell's earlier output is still there.
            _wait_for_text(c, moving, MARKER, timeout_s=5.0)
        finally:
            if new_window_id and new_window_id not in before:
                c.close_window(new_window_id)
                time.sleep(0.3)

    print("PASS: debug.tab.tear_off moves the surface into a new window with its scrollback intact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
