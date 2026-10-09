"""Helpers shared by the tests_v2 socket tests.

Each test file imports what it needs under its historical private name, for example
`from v2_support import must as _must`. Only helpers whose per-file copies were
behaviorally identical live here; test-specific variants stay in their own files.
"""

import glob
import os
import time
from typing import Callable

from programa_client import ProgramaClient, ProgramaClientError


def must(cond: bool, msg: str) -> None:
    if not cond:
        raise ProgramaClientError(msg)


def wait_until(
    predicate: Callable[[], bool],
    timeout_s: float = 4.0,
    interval_s: float = 0.05,
    message: str = "timeout",
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise ProgramaClientError(message)


def wait_for(pred: Callable[[], bool], timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise ProgramaClientError("Timed out waiting for condition")


def find_cli_binary() -> str:
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


def palette_visible(client: ProgramaClient, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))
