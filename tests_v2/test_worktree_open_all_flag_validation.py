#!/usr/bin/env python3
"""`programa worktree open --all` CLI flag validation.

These are pure argument-parsing errors (mutual exclusion with a positional target and with
--focus) raised before `runWorktreeOpen` ever resolves a repo or calls the socket, so this does
not need a temp git repo fixture -- only a running app to connect to, same as every other
tests_v2 script. See docs/plans/snapshot-restore.md.
"""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClientError
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _find_cli_binary() -> str:
    env_cli = os.environ.get("PROGRAMA_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/programa-tests-v2/Build/Products/Debug/programa")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/programa"), recursive=True)
    candidates += glob.glob("/tmp/programa-*/Build/Products/Debug/programa")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise ProgramaClientError("Could not locate programa CLI binary; set PROGRAMA_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def _merged_output(proc: subprocess.CompletedProcess[str]) -> str:
    return f"{proc.stdout}\n{proc.stderr}".strip()


def main() -> int:
    cli = _find_cli_binary()
    base = [cli, "--socket", SOCKET_PATH]

    all_and_focus = _run(base + ["worktree", "open", "--all", "--focus"])
    all_and_focus_out = _merged_output(all_and_focus).lower()
    _must(
        all_and_focus.returncode != 0,
        f"worktree open --all --focus should fail non-zero: {all_and_focus_out!r}",
    )
    _must(
        "--all" in all_and_focus_out and "--focus" in all_and_focus_out,
        f"worktree open --all --focus should name both conflicting flags: {all_and_focus_out!r}",
    )

    all_and_target = _run(base + ["worktree", "open", "some-branch", "--all"])
    all_and_target_out = _merged_output(all_and_target).lower()
    _must(
        all_and_target.returncode != 0,
        f"worktree open <target> --all should fail non-zero: {all_and_target_out!r}",
    )

    neither = _run(base + ["worktree", "open"])
    neither_out = _merged_output(neither).lower()
    _must(neither.returncode != 0, f"worktree open with no target and no --all should fail non-zero: {neither_out!r}")
    _must(
        "path-or-branch" in neither_out or "--all" in neither_out,
        f"worktree open with no target and no --all should explain what is required: {neither_out!r}",
    )

    print("PASS: worktree open --all rejects a positional target, --focus, and being called with neither")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
