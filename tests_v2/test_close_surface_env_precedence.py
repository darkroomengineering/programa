#!/usr/bin/env python3
"""Regression: PROGRAMA_SURFACE_ID env fallback must not override a workspace
target that itself resolved from PROGRAMA_WORKSPACE_ID env (issue #162).

Issue #148 fixed this precedence bug for send/send-key/read-screen: the
PROGRAMA_SURFACE_ID env fallback is suppressed whenever a workspace target
resolved (explicit --workspace flag OR PROGRAMA_WORKSPACE_ID env). #162 found
that close-surface (and new-split, and notify) still only suppressed the
surface fallback when an *explicit --workspace flag* was passed
(`csWsFlag == nil`), not when the workspace came from env instead
(`workspaceArg == nil`) -- so a stale surface id inherited from another app
instance's shell could still be sent as surface_id even though
PROGRAMA_WORKSPACE_ID already resolved an explicit target.

This is observable end-to-end because the app enforces workspace membership
for the surface id: `guard ws.panels[surfaceId] != nil else { ... not_found }`
in v2SurfaceClose (Sources/TerminalController+Surface.swift). So:

  - Pre-fix: close-surface with only PROGRAMA_WORKSPACE_ID=<target> and
    PROGRAMA_SURFACE_ID=<surface belonging to a different workspace> set
    (no CLI flags) sends that foreign surface_id straight through, and the
    app rejects it with not_found -- even though a perfectly good surface
    exists in the target workspace and should have been used instead.
  - Post-fix: the stale env surface id is suppressed because a workspace
    target already resolved (via env), so close-surface falls back to the
    target workspace's own focused surface and succeeds.
"""

import glob
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/programa-*/Build/Products/Debug/programa")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: List[str], env_overrides: Optional[Dict[str, str]] = None) -> str:
    env = dict(os.environ)
    # Hermetic: strip caller-context env vars so this test's behavior does not
    # depend on whatever instance/workspace/surface the invoking shell happens
    # to be scoped to (see tests_v2/test_workspace_relative.py:52-57). Tests
    # opt back in via env_overrides.
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        env.pop(var, None)
    if env_overrides:
        env.update(env_overrides)
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        target_ws = c.new_workspace()
        stale_ws = c.new_workspace()
        try:
            stale_surfaces = c.list_surfaces(stale_ws)
            _must(len(stale_surfaces) == 1, f"expected exactly one surface in a fresh workspace, got {stale_surfaces!r}")
            stale_surface_id = stale_surfaces[0][1]

            # Give target_ws a second surface so close-surface has something
            # to close without tripping the "cannot close the last surface"
            # guard, regardless of which of the two ends up focused.
            c.select_workspace(target_ws)
            c.new_surface()
            before = c.list_surfaces(target_ws)
            _must(len(before) == 2, f"expected two surfaces in target workspace, got {before!r}")
            before_ids = {row[1] for row in before}

            # Repro: only PROGRAMA_WORKSPACE_ID + PROGRAMA_SURFACE_ID env vars
            # set, no --workspace/--surface flags -- this is the exact shape
            # that bypassed the old `csWsFlag == nil` check.
            _run_cli(
                cli,
                ["close-surface"],
                env_overrides={
                    "PROGRAMA_WORKSPACE_ID": target_ws,
                    "PROGRAMA_SURFACE_ID": stale_surface_id,
                },
            )

            after = c.list_surfaces(target_ws)
            after_ids = {row[1] for row in after}
            _must(len(after) == 1, f"expected one surface left in target workspace, got {after!r}")
            _must(after_ids.issubset(before_ids), "close-surface closed a surface that was never in target_ws")

            stale_after = c.list_surfaces(stale_ws)
            _must(
                len(stale_after) == 1 and stale_after[0][1] == stale_surface_id,
                f"stale workspace's surface must be untouched, got {stale_after!r}",
            )
        finally:
            c.close_workspace(target_ws)
            c.close_workspace(stale_ws)

    print("PASS: close-surface ignores stale PROGRAMA_SURFACE_ID once PROGRAMA_WORKSPACE_ID resolved a target")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
