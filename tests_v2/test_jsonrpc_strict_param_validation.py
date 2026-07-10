#!/usr/bin/env python3
"""Regression: JSON-RPC integer parameters reject booleans and fractions."""

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _expect_invalid_params(c: cmux, method: str, params: dict[str, Any]) -> None:
    try:
        c._call(method, params)
    except cmuxError as error:
        if "invalid_params" not in str(error):
            raise cmuxError(
                f"{method} returned the wrong error for params={params!r}: {error}"
            ) from error
        return
    raise cmuxError(f"{method} accepted invalid params={params!r}")


def _expect_invalid_request_for_non_object_params(c: cmux, method: str) -> None:
    if c._socket is None:
        raise cmuxError("Socket is not connected")

    request_id = c._next_id
    c._next_id += 1
    payload = {
        "id": request_id,
        "method": method,
        "params": [],
    }
    line = json.dumps(payload, separators=(",", ":")) + "\n"
    c._socket.sendall(line.encode("utf-8"))
    response = json.loads(c._recv_line())

    if response.get("id") != request_id:
        raise cmuxError(f"Mismatched response id: {response!r}")
    if response.get("ok") is not False:
        raise cmuxError(f"{method} accepted non-object params: {response!r}")
    error_code = (response.get("error") or {}).get("code")
    if error_code != "invalid_request":
        raise cmuxError(
            f"{method} returned {error_code!r}, expected 'invalid_request': {response!r}"
        )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        original_workspace = c.current_workspace()
        reordered_workspace = c.new_workspace()

        # Build a pane with two surfaces so an incorrectly coerced index would mutate state.
        split_surface = c.new_split("right")
        time.sleep(0.2)
        second_surface = c.new_surface(panel_type="terminal")
        time.sleep(0.2)
        pane_rows = c.list_panes()
        focused_pane = next(
            (pane_id for _idx, pane_id, _count, focused in pane_rows if focused),
            None,
        )
        if focused_pane is None:
            raise cmuxError(f"Expected a focused pane, got {pane_rows!r}")

        common_workspace_params = {"workspace_id": reordered_workspace}
        common_surface_params = {"surface_id": second_surface}
        common_pane_params = {
            "workspace_id": original_workspace,
            "pane_id": focused_pane,
            "direction": "left",
        }

        for invalid_integer in (True, 1.5):
            _expect_invalid_params(
                c,
                "workspace.reorder",
                {**common_workspace_params, "index": invalid_integer},
            )
            _expect_invalid_params(
                c,
                "surface.reorder",
                {**common_surface_params, "index": invalid_integer},
            )
            _expect_invalid_params(
                c,
                "pane.resize",
                {**common_pane_params, "amount": invalid_integer},
            )

        # Keep a live reference so setup failures cannot silently leave an unused split.
        if not split_surface:
            raise cmuxError("Expected split surface ID")

        for method in ("workspace.reorder", "surface.reorder", "pane.resize"):
            _expect_invalid_request_for_non_object_params(c, method)

    print("PASS: JSON-RPC rejects boolean/fraction integers and non-object params")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
