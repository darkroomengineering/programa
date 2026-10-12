#!/usr/bin/env python3
"""Regression: global CLI flags still parse and v1 ERROR responses fail with non-zero exit."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClientError
from v2_support import must as _must
from v2_support import find_cli_binary as _find_cli_binary


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def _merged_output(proc: subprocess.CompletedProcess[str]) -> str:
    return f"{proc.stdout}\n{proc.stderr}".strip()


def main() -> int:
    cli = _find_cli_binary()

    # Global --version should be handled before socket command dispatch.
    version_proc = _run([cli, "--version"])
    version_out = _merged_output(version_proc).lower()
    _must(version_proc.returncode == 0, f"--version should succeed: {version_proc.returncode} {version_out!r}")
    _must("programa" in version_out, f"--version output should mention programa: {version_out!r}")

    # Global --password should parse as a flag (not a command name) and still allow non-password sockets.
    ping_proc = _run([cli, "--socket", SOCKET_PATH, "--password", "ignored-in-programaonly", "ping"])
    ping_out = _merged_output(ping_proc).lower()
    _must(ping_proc.returncode == 0, f"ping with --password should succeed: {ping_proc.returncode} {ping_out!r}")
    _must("pong" in ping_out, f"ping should still return pong: {ping_out!r}")

    # V1 errors must produce non-zero exit codes for automation correctness.
    bad_focus = _run([cli, "--socket", SOCKET_PATH, "focus-window", "--window", "window:999999"])
    bad_out = _merged_output(bad_focus).lower()
    _must(bad_focus.returncode != 0, f"focus-window with invalid target should fail non-zero: {bad_out!r}")
    _must("error" in bad_out, f"focus-window failure should surface an error: {bad_out!r}")

    print("PASS: global flags parse correctly and v1 ERROR responses fail the CLI process")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
