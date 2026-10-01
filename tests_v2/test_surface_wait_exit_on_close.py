#!/usr/bin/env python3
"""surface.wait --exit ends promptly with outcome "closed" when the surface is closed (SOCK-30).

A waiter must not pin its connection until the timeout once its surface is gone. The close
comes from a second client (own connection), and the waiting client's read timeout has
headroom over the server-side timeout under test.
"""

import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
SERVER_TIMEOUT_MS = 20_000
MAX_AFTER_CLOSE_S = 2.0


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    ws = ""
    closed_at: list[float] = []
    errors: list[Exception] = []
    with ProgramaClient(SOCKET_PATH) as a:
        try:
            ws = a.new_workspace()
            a.select_workspace(ws)
            time.sleep(0.4)
            surface = a.new_split("right")
            time.sleep(0.4)

            def _close_later() -> None:
                try:
                    time.sleep(0.8)
                    with ProgramaClient(SOCKET_PATH) as b:
                        closed_at.append(time.time())
                        b._call("surface.close", {"workspace_id": ws, "surface_id": surface})
                except Exception as exc:  # surfaced below
                    errors.append(exc)

            t = threading.Thread(target=_close_later)
            t.start()
            result = a._call(
                "surface.wait",
                {"workspace_id": ws, "surface_id": surface, "exit": True, "timeout_ms": SERVER_TIMEOUT_MS},
                timeout_s=SERVER_TIMEOUT_MS / 1000.0 + 10.0,
            ) or {}
            returned_at = time.time()
            t.join()
            _must(not errors, f"closer failed: {errors}")
            _must(result.get("outcome") == "closed", f"expected outcome=closed, got {result}")
            _must(closed_at, "closer never ran")
            lag = returned_at - closed_at[0]
            _must(lag <= MAX_AFTER_CLOSE_S, f"wait returned {lag:.2f}s after the close (limit {MAX_AFTER_CLOSE_S}s)")
        finally:
            if ws:
                try:
                    a.close_workspace(ws)
                except Exception:
                    pass

    print("PASS: surface.wait exit returns outcome=closed promptly after the surface closes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
