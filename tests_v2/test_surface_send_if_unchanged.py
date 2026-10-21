#!/usr/bin/env python3
"""surface.send_if_unchanged sends only while the screen still matches a read_text fingerprint.

Chat bridges read a pane, decide the prompt is still waiting, then reply. The conditional send
closes the gap between those two calls: a fresh fingerprint delivers text and keys, a stale one
returns `mismatch` and sends nothing. Each case runs a `touch` so delivery is checked by a file
on disk, not by screen text alone.
"""

from __future__ import annotations

import hashlib
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must
from pane_resize_test_support import (
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
LINES = 20


def _read(c: ProgramaClient, surface_id: str) -> tuple[str, str]:
    res = c._call("surface.read_text", {"surface_id": surface_id, "lines": LINES}, timeout_s=10.0) or {}
    text = str(res.get("text") or "")
    fingerprint = str(res.get("fingerprint") or "")
    expected = hashlib.sha256(text.encode("utf-8")).hexdigest()
    _must(fingerprint == expected, f"read_text fingerprint {fingerprint!r} is not sha256(text) {expected!r}")
    return text, fingerprint


def _wait_for_file(path: Path, timeout_s: float = 10.0) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.2)
    raise ProgramaClientError(f"Timed out waiting for {path} to be created")


def _expect_error(c: ProgramaClient, params: dict, code: str) -> str:
    try:
        c._call("surface.send_if_unchanged", params, timeout_s=10.0)
    except ProgramaClientError as error:
        _must(str(error).startswith(f"{code}:"), f"Expected {code} for {params!r}: {error}")
        return str(error)
    raise ProgramaClientError(f"surface.send_if_unchanged unexpectedly succeeded for {params!r}")


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    stamp = int(time.time() * 1000)
    work_dir = Path(tempfile.mkdtemp(prefix="programa_send_if_unchanged_"))
    sent_canary = work_dir / f"sent-{stamp}"
    stale_canary = work_dir / f"stale-{stamp}"
    workspace_id = ""

    try:
        with ProgramaClient(SOCKET_PATH) as c:
            created = c._call("workspace.create", {"cwd": str(work_dir)}, timeout_s=15.0) or {}
            workspace_id = str(created.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
            surfaces = c._call("surface.list", {"workspace_id": workspace_id}, timeout_s=10.0) or {}
            rows = list(surfaces.get("surfaces") or [])
            _must(len(rows) >= 1, f"Expected an initial terminal surface: {surfaces}")
            surface_id = str(rows[0].get("id") or "")
            _must(bool(surface_id), f"Initial surface has no id: {rows}")
            _wait_for_surface_command_roundtrip(c, workspace_id, surface_id)

            _, fingerprint = _read(c, surface_id)
            _expect_error(c, {"surface_id": surface_id, "lines": LINES, "expected_fingerprint": fingerprint}, "invalid_params")
            _expect_error(
                c,
                {"surface_id": surface_id, "lines": LINES, "expected_fingerprint": fingerprint, "text": "", "keys": []},
                "invalid_params",
            )
            _expect_error(c, {"surface_id": surface_id, "lines": LINES, "text": "x"}, "invalid_params")

            # 1. A fresh fingerprint delivers the text, then the keys in order. The shell may still
            # be redrawing right after startup, so a mismatch here is retried with a new read.
            stale_fingerprint = ""
            sent = {}
            for _ in range(10):
                _, fingerprint = _read(c, surface_id)
                try:
                    sent = c._call(
                        "surface.send_if_unchanged",
                        {
                            "surface_id": surface_id,
                            "lines": LINES,
                            "expected_fingerprint": fingerprint,
                            "text": f"touch {sent_canary}",
                            "keys": ["enter"],
                        },
                        timeout_s=10.0,
                    ) or {}
                    stale_fingerprint = fingerprint
                    break
                except ProgramaClientError as error:
                    _must(str(error).startswith("mismatch:"), f"Unexpected send_if_unchanged error: {error}")
                    time.sleep(0.3)
            _must(bool(stale_fingerprint), "send_if_unchanged never matched a fresh fingerprint")
            _must(str(sent.get("surface_id") or "") == surface_id, f"send_if_unchanged targeted the wrong surface: {sent}")
            _must(str(sent.get("fingerprint") or "") == stale_fingerprint, f"Result fingerprint differs from the matched one: {sent}")
            _wait_for_file(sent_canary)

            # 2. The command above changed the screen, so its fingerprint is now stale.
            deadline = time.time() + 10.0
            while _read(c, surface_id)[1] == stale_fingerprint and time.time() < deadline:
                time.sleep(0.2)
            error = _expect_error(
                c,
                {
                    "surface_id": surface_id,
                    "lines": LINES,
                    "expected_fingerprint": stale_fingerprint,
                    "text": f"touch {stale_canary}",
                    "keys": ["enter"],
                },
                "mismatch",
            )
            _must("current_fingerprint" in error, f"mismatch error carries no current_fingerprint: {error}")
            time.sleep(1.5)
            _must(not stale_canary.exists(), f"A stale fingerprint still delivered input (found {stale_canary})")
            text, _ = _read(c, surface_id)
            _must(stale_canary.name not in text, f"A stale fingerprint still typed text: {text!r}")

            # 3. An unknown key is rejected before anything is sent, even with a fresh fingerprint.
            _, fingerprint = _read(c, surface_id)
            _expect_error(
                c,
                {
                    "surface_id": surface_id,
                    "lines": LINES,
                    "expected_fingerprint": fingerprint,
                    "text": f"touch {stale_canary}",
                    "keys": ["enter", "nonexistentkey"],
                },
                "invalid_params",
            )
            time.sleep(1.0)
            _must(not stale_canary.exists(), f"An unknown key still let the text through (found {stale_canary})")
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
        for canary in (sent_canary, stale_canary):
            canary.unlink(missing_ok=True)
        try:
            work_dir.rmdir()
        except OSError:
            pass

    print("PASS: surface.send_if_unchanged sends only while the fingerprint matches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
