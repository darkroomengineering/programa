#!/usr/bin/env python3
"""layout.save/apply roundtrip: build a 2-pane split workspace, save it, apply it into a new
workspace, and assert the pane count and each pane's cwd match.

Split ratio is not asserted numerically here -- there is no v2 method that returns a specific
workspace's divider position by id (`debug.layout` operates on the currently selected
workspace/window only), so this test verifies the structural shape (still a 2-pane split after
apply) instead of a precise ratio comparison.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
LAYOUTS_DIR = Path(os.path.expanduser("~/.config/programa/layouts"))


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _pwd_via_terminal(c: cmux, surface_id: str, timeout_s: float = 8.0) -> str:
    token = f"PWD_CHECK_{int(time.time() * 1000)}"
    c.send_surface(surface_id, f"printf '{token}:%s\\n' \"$(pwd)\"\\n")

    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        last_text = c.read_terminal_text(surface_id)
        for line in last_text.splitlines():
            if line.startswith(f"{token}:"):
                return line[len(token) + 1:].strip()
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for pwd marker {token!r} in surface output: {last_text!r}")


def _shell_ack(c: cmux, surface_id: str) -> int:
    nonce = "LIVE_" + uuid.uuid4().hex
    # Direct RPC preserves the printf escape and sends an actual Return once.
    c._call("surface.send_text", {"surface_id": surface_id, "text": f"printf '{nonce}:%s\\n' \"$$\"\n"})
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        for line in c.read_terminal_text(surface_id).splitlines():
            if line.startswith(nonce + ":"):
                pid = line.split(":", 1)[1].strip()
                if pid.isdigit():
                    return int(pid)
        time.sleep(0.1)
    raise cmuxError("Original terminal did not acknowledge fresh nonce")


def main() -> int:
    layout_name = f"test_roundtrip_{int(time.time() * 1000)}"
    source_dir = Path(tempfile.mkdtemp(prefix="programa_layout_roundtrip_source_"))
    target_dir = Path(tempfile.mkdtemp(prefix="programa_layout_roundtrip_target_"))
    source_workspace = ""
    applied_workspace = ""
    live_workspace = ""

    try:
        with cmux(SOCKET_PATH) as c:
            created = c._call("workspace.create", {"cwd": str(source_dir)}, timeout_s=15.0) or {}
            source_workspace = str(created.get("workspace_id") or "")
            _must(bool(source_workspace), f"workspace.create returned no workspace_id: {created}")
            c.select_workspace(source_workspace)

            c.new_split("right")
            # pane.list has no workspace scoping in this client; use surface.list instead, which
            # does, to count panes for *this* workspace via distinct pane_id values.
            surfaces = c._call("surface.list", {"workspace_id": source_workspace}, timeout_s=10.0) or {}
            source_pane_ids = {row.get("pane_id") for row in (surfaces.get("surfaces") or [])}
            _must(len(source_pane_ids) == 2, f"Expected 2 panes after new_split, got pane ids: {source_pane_ids}")

            save_result = c._call("layout.save", {"name": layout_name, "force": True}, timeout_s=15.0) or {}
            _must(save_result.get("name") == layout_name, f"layout.save returned unexpected payload: {save_result}")

            listed = c._call("layout.list", {}, timeout_s=10.0) or {}
            names = [row.get("name") for row in (listed.get("layouts") or [])]
            _must(layout_name in names, f"layout.list should include the saved layout: {names}")

            # A realized single terminal must not be mistaken for an unused placeholder.
            live = c._call("workspace.create", {"cwd": str(source_dir)}, timeout_s=15.0) or {}
            live_workspace = str(live.get("workspace_id") or "")
            _must(bool(live_workspace), "Expected live workspace")
            for target in (live_workspace, source_workspace):
                c.select_workspace(target)
                before_rows = (c._call("surface.list", {"workspace_id": target}) or {}).get("surfaces") or []
                _must(len(before_rows) == (1 if target == live_workspace else 2), "Expected distinct single-terminal and split-terminal fixtures")
                surface_id = str(before_rows[0].get("id") or "")
                before_pid = _shell_ack(c, surface_id)
                selected_before = c.current_workspace()
                try:
                    c._call("layout.apply", {"name": layout_name, "workspace_id": target}, timeout_s=15.0)
                except cmuxError as error:
                    _must("invalid_state" in str(error), f"Expected nonpristine target rejection: {error}")
                else:
                    raise cmuxError("layout.apply replaced an existing live terminal")
                after_rows = (c._call("surface.list", {"workspace_id": target}) or {}).get("surfaces") or []
                _must([(r.get("id"), r.get("pane_id")) for r in after_rows] == [(r.get("id"), r.get("pane_id")) for r in before_rows], "Rejected apply changed terminal identity/layout")
                _must(c.current_workspace() == selected_before, "Rejected apply changed workspace selection")
                _must(_shell_ack(c, surface_id) == before_pid, "Rejected apply replaced the original shell process")

            selected_before_apply = c.current_workspace()
            applied = c._call(
                "layout.apply",
                {"name": layout_name, "cwd": str(target_dir)},
                timeout_s=20.0,
            ) or {}
            applied_workspace = str(applied.get("workspace_id") or "")
            _must(bool(applied_workspace), f"layout.apply returned no workspace_id: {applied}")

            _must(
                c.current_workspace() == selected_before_apply,
                "layout.apply must not focus/select the new workspace",
            )

            applied_surfaces = c._call("surface.list", {"workspace_id": applied_workspace}, timeout_s=10.0) or {}
            applied_rows = list(applied_surfaces.get("surfaces") or [])
            applied_pane_ids = {row.get("pane_id") for row in applied_rows}
            _must(
                len(applied_pane_ids) == 2,
                f"Expected the applied layout to reproduce 2 panes, got pane ids: {applied_pane_ids}",
            )

            first_surface_id = str(applied_rows[0].get("id") or "")
            _must(bool(first_surface_id), f"Applied workspace surface has no id: {applied_rows}")
            observed_cwd = _pwd_via_terminal(c, first_surface_id)
            _must(
                observed_cwd == str(target_dir),
                f"Expected applied layout's terminal cwd to be {target_dir}, got {observed_cwd!r}",
            )
    finally:
        for workspace_id in (source_workspace, applied_workspace, live_workspace):
            if not workspace_id:
                continue
            try:
                with cmux(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
        try:
            (LAYOUTS_DIR / f"{layout_name}.json").unlink(missing_ok=True)
        except Exception:
            pass
        shutil.rmtree(source_dir, ignore_errors=True)
        shutil.rmtree(target_dir, ignore_errors=True)

    print("PASS: layout.save/apply roundtrip reproduces pane count and resolves cwd against the new workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
