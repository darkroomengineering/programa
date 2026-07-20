#!/usr/bin/env python3
"""
Regression test for #140: closing a terminal (including via the socket API, the same
path an agent uses) stages it for a 5s undo window instead of tearing it down
immediately. Cmd+Shift+T within that window brings the surface back with the *same*
surface id (the underlying process/panel is retained, not recreated). If nothing
restores it before the grace period elapses, the close finalizes for real and stays
closed.

What this asserts, and why:
  1. `surface.close` on a non-focused terminal drops the visible surface count by one
     (the socket API is used here specifically to prove an agent-initiated close is
     just as undoable as an interactive one).
  2. Cmd+Shift+T (`debug.shortcut.simulate`) within the grace period restores the
     surface count and the *same* surface id reappears -- proving the live panel was
     reattached rather than a fresh terminal being spawned.
  3. Closing again and waiting past the real 5s grace period leaves the surface
     permanently closed (count stays down), proving the undo window actually expires
     instead of undoing forever.

This test requires app focus (`debug.shortcut.simulate` synthesizes a real key event
routed through the app's key-equivalent handling), which is unreliable when run
against a developer's foregrounded machine. It is expected to run on the CI VM
runner where focus behaves deterministically. It fails loudly (raises) rather than
silently skipping, since CI is expected to always have a focusable, non-occluded
app window.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")

# Must exceed ClosedTerminalUndoStore.gracePeriodSeconds (5s) with margin for socket/IPC
# round trips and UI update latency.
GRACE_PERIOD_SECONDS = 5.0
POST_EXPIRY_MARGIN_SECONDS = 3.0


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_surface_count(c: cmux, workspace_id: str, expected: int, timeout_s: float = 8.0):
    deadline = time.time() + timeout_s
    last = []
    while time.time() < deadline:
        last = c.list_surfaces(workspace_id)
        if len(last) == expected:
            return last
        time.sleep(0.1)
    raise cmuxError(
        f"Timed out waiting for surface count == {expected}. Last surfaces: {last!r}"
    )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        workspace_id = c.new_workspace()
        created_workspace_id = workspace_id
        try:
            c.select_workspace(workspace_id)
            time.sleep(0.2)

            # A fresh workspace starts with exactly one terminal surface. Add a second
            # so closing one doesn't hit the "cannot close the last surface" guard.
            c.new_surface(panel_type="terminal")
            baseline = _wait_for_surface_count(c, workspace_id, 2, timeout_s=8.0)
            target_surface_id = baseline[-1][1]

            # --- Close via socket (the agent-close path) and verify it's undoable ---
            c.close_surface(target_surface_id)
            after_close = _wait_for_surface_count(c, workspace_id, 1, timeout_s=8.0)
            _must(
                all(row[1] != target_surface_id for row in after_close),
                f"expected surface {target_surface_id} to be gone after close: {after_close!r}",
            )

            # --- Restore within the grace period via the unified Cmd+Shift+T handler ---
            c.activate_app()
            time.sleep(0.2)
            c.simulate_shortcut("cmd+shift+t")

            restored = _wait_for_surface_count(c, workspace_id, 2, timeout_s=8.0)
            _must(
                any(row[1] == target_surface_id for row in restored),
                f"expected restored surfaces to include the original id {target_surface_id}: {restored!r}",
            )

            # --- Close again, let the real grace period fully elapse, confirm it stays closed ---
            c.close_surface(target_surface_id)
            after_second_close = _wait_for_surface_count(c, workspace_id, 1, timeout_s=8.0)
            _must(
                all(row[1] != target_surface_id for row in after_second_close),
                f"expected surface {target_surface_id} to be gone after second close: {after_second_close!r}",
            )

            time.sleep(GRACE_PERIOD_SECONDS + POST_EXPIRY_MARGIN_SECONDS)

            final = c.list_surfaces(workspace_id)
            _must(
                len(final) == 1,
                f"expected the close to have finalized (stayed closed) past the grace period, "
                f"got surfaces: {final!r}",
            )
            _must(
                all(row[1] != target_surface_id for row in final),
                f"expected surface {target_surface_id} to remain closed after expiry: {final!r}",
            )
        finally:
            try:
                c.close_workspace(created_workspace_id)
            except Exception:
                pass

    print("PASS: terminal close is undoable via Cmd+Shift+T within the grace period and finalizes after it expires")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
