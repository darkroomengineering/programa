#!/usr/bin/env python3
"""Regression: an unknown PROGRAMA_SURFACE_ID must resolve to not_found.

Issue #148: surface.send_text with a surface_id that does not exist in this
instance used to resolve to "Surface is not a terminal" (invalid_params)
instead of not_found, because the handler conflated "unknown id" with
"exists but is not a terminal panel". This covers both the no-workspace-context
case and the case where a valid workspace_id is supplied alongside the unknown
surface_id (membership check).
"""

import os
import sys
import uuid
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _expect_not_found(c: cmux, method: str, params: dict[str, Any]) -> None:
    try:
        c._call(method, params)
    except cmuxError as error:
        if "not_found" not in str(error):
            raise cmuxError(
                f"{method} returned the wrong error for params={params!r}: {error}"
            ) from error
        return
    raise cmuxError(f"{method} unexpectedly succeeded for params={params!r}")


def main() -> int:
    # Hermetic: strip caller-context env vars so this test's behavior does not
    # depend on whatever instance/workspace/surface the invoking shell happens
    # to be scoped to (see tests_v2/test_workspace_relative.py:52-57).
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    with cmux(SOCKET_PATH) as c:
        unknown_surface_id = str(uuid.uuid4())

        # (1) Unknown surface_id, no workspace context: must be not_found, not
        # "Surface is not a terminal" (invalid_params).
        _expect_not_found(
            c,
            "surface.send_text",
            {"surface_id": unknown_surface_id, "text": "echo hi"},
        )

        # (2) Unknown surface_id with an explicit, valid workspace_id: the
        # surface does not belong to (or exist in) that workspace, so this is
        # still not_found.
        workspace_id = c.current_workspace()
        _expect_not_found(
            c,
            "surface.send_text",
            {
                "workspace_id": workspace_id,
                "surface_id": unknown_surface_id,
                "text": "echo hi",
            },
        )

    print("PASS: unknown surface_id resolves to not_found in surface.send_text")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
