#!/usr/bin/env python3
"""Regression: workspace.create initial commands leave an interactive shell open."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def main() -> int:
    with ProgramaClient(SOCKET_PATH) as client:
        workspace_id = ""
        try:
            created = client._call("workspace.create", {
                "initial_command": "sleep 2; echo INC830_\"DONE\"",
            }) or {}
            workspace_id = str(created.get("workspace_id") or "")
            surface_id = str(created.get("surface_id") or "")
            _must(bool(workspace_id) and bool(surface_id), f"Missing workspace or surface: {created}")

            time.sleep(5)
            workspaces = client.list_workspaces()
            _must(any(row[1] == workspace_id for row in workspaces),
                  f"Initial command exit closed workspace {workspace_id}: {workspaces}")
            text = client.read_terminal_text(surface_id)
            _must("INC830_DONE" in text, f"Initial command did not finish: {text!r}")
        finally:
            if workspace_id:
                try:
                    client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: workspace.create initial command completes and keeps its shell open")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
