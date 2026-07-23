#!/usr/bin/env python3
"""Regression: `worktree` and `layout` CLI subcommands must have a registered
argument contract.

Both commands' descriptors previously had no `case` in the CLI's
`validateRegisteredArguments` switch, so every invocation -- even harmless
ones like `worktree list` / `layout list` -- failed before socket dispatch
with:

    Internal CLI registry error: no argument contract for worktree

This shipped to main and made the entire documented `worktree`/`layout` CLI
surface dead on arrival, even though the underlying `worktree.*`/`layout.*`
socket methods worked fine via `programa rpc`.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
REPO_ROOT = str(Path(__file__).resolve().parent.parent)
REGISTRY_ERROR = "no argument contract for"


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


def _run(cli: str, args: List[str]) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(
        [cli, "--socket", SOCKET_PATH] + args,
        capture_output=True,
        text=True,
        check=False,
    )


def _merged(proc: "subprocess.CompletedProcess[str]") -> str:
    return f"{proc.stdout}\n{proc.stderr}".strip()


def main() -> int:
    cli = _find_cli_binary()

    # `worktree list` previously died before ever reaching the socket.
    worktree_list = _run(cli, ["worktree", "list", "--repo", REPO_ROOT])
    worktree_out = _merged(worktree_list)
    _must(REGISTRY_ERROR not in worktree_out, f"worktree list hit registry error: {worktree_out!r}")
    _must(worktree_list.returncode == 0, f"worktree list should succeed: {worktree_list.returncode} {worktree_out!r}")

    # `layout list` previously died the same way.
    layout_list = _run(cli, ["layout", "list"])
    layout_out = _merged(layout_list)
    _must(REGISTRY_ERROR not in layout_out, f"layout list hit registry error: {layout_out!r}")
    _must(layout_list.returncode == 0, f"layout list should succeed: {layout_list.returncode} {layout_out!r}")

    # Subcommand validation must reject garbage with a real per-command
    # error, never falling through to the "no argument contract" catch-all --
    # this proves the new cases run actual grammar checks, not a bare pass-through.
    bad_worktree = _run(cli, ["worktree", "bogus-subcommand"])
    bad_worktree_out = _merged(bad_worktree)
    _must(bad_worktree.returncode != 0, f"worktree bogus-subcommand should fail: {bad_worktree_out!r}")
    _must(REGISTRY_ERROR not in bad_worktree_out, f"worktree bogus-subcommand hit registry error: {bad_worktree_out!r}")
    _must("unknown subcommand" in bad_worktree_out.lower(), f"worktree bogus-subcommand should report unknown subcommand: {bad_worktree_out!r}")

    bad_layout = _run(cli, ["layout", "bogus-subcommand"])
    bad_layout_out = _merged(bad_layout)
    _must(bad_layout.returncode != 0, f"layout bogus-subcommand should fail: {bad_layout_out!r}")
    _must(REGISTRY_ERROR not in bad_layout_out, f"layout bogus-subcommand hit registry error: {bad_layout_out!r}")
    _must("unknown subcommand" in bad_layout_out.lower(), f"layout bogus-subcommand should report unknown subcommand: {bad_layout_out!r}")

    print("PASS: worktree and layout CLI subcommands have registered argument contracts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
