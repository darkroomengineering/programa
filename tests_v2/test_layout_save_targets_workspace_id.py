#!/usr/bin/env python3
"""layout.save honors workspace_id: saving a non-selected workspace saves THAT workspace (SOCK-30).

The target workspace has two panes and the selected one has one, so a save of the wrong
workspace produces a layout with the wrong pane count.
"""

import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _count_panes(node) -> int:
    if isinstance(node, dict):
        if "pane" in node and isinstance(node["pane"], dict):
            return 1
        if "surfaces" in node and "children" not in node and "split" not in node:
            return 1
        return sum(_count_panes(v) for v in node.values())
    if isinstance(node, list):
        return sum(_count_panes(v) for v in node)
    return 0


def main() -> int:
    name = f"test_save_target_{uuid.uuid4().hex[:8]}"
    created: list[str] = []
    saved_path = None
    with ProgramaClient(SOCKET_PATH) as c:
        try:
            target = c.new_workspace()
            created.append(target)
            c.select_workspace(target)
            time.sleep(0.3)
            c.new_split("right")
            time.sleep(0.3)
            selected = c.new_workspace()
            created.append(selected)
            c.select_workspace(selected)
            time.sleep(0.3)
            _must(c.current_workspace() == selected, "fixture: selected workspace not selected")

            res = c._call("layout.save", {"name": name, "workspace_id": target, "force": True}, timeout_s=15.0) or {}
            saved_path = res.get("path")
            _must(bool(saved_path) and os.path.exists(saved_path), f"layout.save returned no readable path: {res}")
            with open(saved_path) as fh:
                layout = json.load(fh)
            panes = _count_panes(layout)
            _must(panes == 2, f"saved layout should be the 2-pane target workspace, got {panes} panes: {layout}")
            _must(c.current_workspace() == selected, "layout.save changed the selected workspace")
        finally:
            for w in created:
                try:
                    c.close_workspace(w)
                except Exception:
                    pass
            if saved_path:
                try:
                    os.unlink(saved_path)
                except OSError:
                    pass

    print("PASS: layout.save saved the requested non-selected workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
