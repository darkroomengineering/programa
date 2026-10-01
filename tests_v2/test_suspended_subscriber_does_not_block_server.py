#!/usr/bin/env python3
"""A subscriber that stops reading must not block other clients (SOCK-30).

The subscriber connects, subscribes, then never reads while a driver connection floods it
with agent_state events. Other clients must still get answers within 10s, and the subscriber's
own `unsubscribe` must be accepted once it reads again or be survivable by the server.
Each sender uses its own connection; client timeouts exceed the 10s bound under test.
"""

import json
import os
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
BOUND_S = 10.0
CLIENT_TIMEOUT_S = 25.0
FLOOD_EVENTS = 2000


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    ws = ""
    with ProgramaClient(SOCKET_PATH) as driver:
        try:
            ws = driver.new_workspace()
            driver.select_workspace(ws)
            time.sleep(0.4)
            surface = driver.list_surfaces()[0][1]

            with ProgramaClient(SOCKET_PATH) as sub:
                sub._call("subscribe", {"classes": ["agent_state"]}, timeout_s=10.0)
                # Tiny receive buffer so the kernel queue fills fast; the subscriber never reads.
                sub._socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)

                states = ("working", "idle")
                for i in range(FLOOD_EVENTS):
                    driver._call(
                        "surface.report_agent_state",
                        {"workspace_id": ws, "surface_id": surface, "state": states[i % 2]},
                        timeout_s=CLIENT_TIMEOUT_S,
                    )

                started = time.time()
                with ProgramaClient(SOCKET_PATH) as other:
                    other._call("system.ping", {}, timeout_s=CLIENT_TIMEOUT_S)
                    other._call("workspace.list", {}, timeout_s=CLIENT_TIMEOUT_S)
                elapsed = time.time() - started
                _must(elapsed < BOUND_S, f"other client waited {elapsed:.1f}s behind a suspended subscriber")

                started = time.time()
                driver._call(
                    "surface.report_agent_state",
                    {"workspace_id": ws, "surface_id": surface, "state": "working"},
                    timeout_s=CLIENT_TIMEOUT_S,
                )
                elapsed = time.time() - started
                _must(elapsed < BOUND_S, f"state report blocked {elapsed:.1f}s behind a suspended subscriber")

                # The subscriber's own unsubscribe: send it, then drain frames until its reply.
                sub._socket.sendall((json.dumps({"id": 99999, "method": "unsubscribe", "params": {}}) + "\n").encode())
                deadline = time.time() + BOUND_S
                answered = False
                while time.time() < deadline and not answered:
                    try:
                        frame = json.loads(sub._recv_line(timeout_s=max(0.5, deadline - time.time())))
                    except ProgramaClientError:
                        # Server dropped the slow consumer: acceptable, the point is it did not hang.
                        answered = True
                        break
                    answered = isinstance(frame, dict) and frame.get("id") == 99999
                _must(answered, "unsubscribe from the suspended subscriber never completed within 10s")
        finally:
            if ws:
                try:
                    driver.close_workspace(ws)
                except Exception:
                    pass

    print("PASS: suspended subscriber does not block other clients")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
