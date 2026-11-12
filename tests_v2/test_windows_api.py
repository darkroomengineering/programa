#!/usr/bin/env python3
"""
E2E tests for multi-window socket control (v2).

Goals:
- window handles are stable UUIDs
- workspace IDs can be moved across windows
- surface IDs remain stable when their workspace moves windows
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _focused_window_id(c: ProgramaClient) -> str:
    ident = c.identify()
    focused = ident.get("focused") or {}
    if isinstance(focused, dict):
        wid = focused.get("window_id")
        if wid:
            return str(wid)
    # Fallback in case identify.focused isn't populated yet.
    return c.current_window()


def main() -> int:
    with ProgramaClient(SOCKET_PATH) as c:
        windows0 = c.list_windows()
        if not windows0:
            raise ProgramaClientError("Expected at least one window from window.list")

        w1 = _focused_window_id(c)

        w2 = c.new_window()
        time.sleep(0.2)

        windows1 = c.list_windows()
        ids1 = {str(w.get("id")) for w in windows1 if w.get("id")}
        if w1 not in ids1:
            raise ProgramaClientError(f"Expected original window id in window.list (w1={w1}, ids={sorted(ids1)})")
        if w2 not in ids1:
            raise ProgramaClientError(f"Expected new window id in window.list (w2={w2}, ids={sorted(ids1)})")

        # window.current and system.tree answer for an explicit window_id that is not the
        # current window, and leave the current window as it was (read-only, focus-neutral).
        current = c.current_window()
        other = w1 if current != w1 else w2
        scoped = c._call("window.current", {"window_id": other}) or {}
        if str(scoped.get("window_id")) != other:
            raise ProgramaClientError(f"window.current ignored window_id (want {other}, got {scoped})")
        tree = c._call("system.tree", {"window_id": other}) or {}
        tree_ids = [str(w.get("id")) for w in tree.get("windows") or []]
        if tree_ids != [other]:
            raise ProgramaClientError(f"system.tree ignored window_id (want [{other}], got {tree_ids})")
        active = tree.get("active") or {}
        if str(active.get("window_id")) != other:
            raise ProgramaClientError(f"system.tree active is not the window_id window (want {other}, got {active})")
        if c.current_window() != current:
            raise ProgramaClientError("window-scoped window.current/system.tree changed the current window")
        for method in ("window.current", "system.tree"):
            try:
                c._call(method, {"window_id": "window:999"})
            except ProgramaClientError as e:
                if not str(e).startswith("not_found"):
                    raise ProgramaClientError(f"{method} unknown window_id: want not_found, got {e}")
            else:
                raise ProgramaClientError(f"{method} accepted an unknown window_id")

        # Create a workspace in w1, ensure it has at least 2 surfaces, then move it to w2.
        ws = c.new_workspace(window_id=w1)
        c.select_workspace(ws)
        time.sleep(0.2)

        _ = c.new_split("right")
        time.sleep(0.5)

        before = c.list_surfaces(ws)
        before_ids = [sid for _, sid, _focused in before]
        if len(before_ids) < 2:
            raise ProgramaClientError(f"Expected >=2 surfaces before move, got {len(before_ids)} ({before_ids})")

        c.move_workspace_to_window(ws, w2)
        # workspace.move_to_window is not a focus-intent method, so it never selects the moved
        # workspace (socket focus policy). Only a selected workspace has its terminals
        # mounted in the window, so select it explicitly before checking in_window.
        c.focus_window(w2)
        c.select_workspace(ws)
        time.sleep(0.5)

        # Wait for reattachment after cross-window move.
        start = time.time()
        while time.time() - start < 6.0:
            health = c.surface_health(ws)
            if health and all(h.get("in_window") is True for h in health):
                break
            time.sleep(0.2)
        else:
            raise ProgramaClientError(f"Expected all moved surfaces to be in_window=true (health={health})")

        # Ensure the moved workspace is now associated with destination window.
        w2_workspaces = c.list_workspaces(window_id=w2)
        w2_ids = {wid for _, wid, _title, _sel in w2_workspaces}
        if ws not in w2_ids:
            raise ProgramaClientError("Expected moved workspace to be present in destination window")

        # Focus behavior can lag under VM/SSH app-activation conditions.
        # Ensure the workspace is at least selectable post-move.
        c.select_workspace(ws)
        time.sleep(0.2)
        ident2 = c.identify()
        focused2 = ident2.get("focused") or {}
        if not isinstance(focused2, dict) or str(focused2.get("workspace_id")) != ws:
            raise ProgramaClientError(f"Expected moved workspace to be selectable after move (focused={focused2})")

        after = c.list_surfaces(ws)
        after_ids = [sid for _, sid, _focused in after]
        if set(after_ids) != set(before_ids):
            raise ProgramaClientError(f"Expected surface IDs to remain stable after move (before={before_ids}, after={after_ids})")

        # Source window should still have workspaces, but not this one.
        w1_workspaces = c.list_workspaces(window_id=w1)
        w1_ids = {wid for _, wid, _title, _sel in w1_workspaces}
        if ws in w1_ids:
            raise ProgramaClientError("Expected moved workspace to no longer be present in source window")

    print("PASS: window list/create + workspace move preserves surface IDs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
