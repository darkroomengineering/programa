"""Helpers shared by the tests_v2 socket tests.

Each test file imports what it needs under its historical private name, for example
`from v2_support import must as _must`. Only helpers whose per-file copies were
behaviorally identical live here; test-specific variants stay in their own files.
"""

import time
from typing import Callable

from cmux import cmux, cmuxError


def must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


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
    raise cmuxError(message)


def wait_for(pred: Callable[[], bool], timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def palette_visible(client: cmux, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))
