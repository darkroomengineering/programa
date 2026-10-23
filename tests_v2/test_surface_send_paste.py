#!/usr/bin/env python3
"""surface.send_paste delivers multi-line text as one paste and never presses Return.

`programa handoff` uses it to put another pane's output into an agent prompt without
submitting. Covers a plain shell without bracketed paste (bash 3.2 on CI: the text is flattened
onto one prompt line) and zsh, which turns bracketed paste on (the lines stay separate rows).
In both, a `touch` on the first line proves the shell never received Return.
"""

from __future__ import annotations

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must
from v2_support import read_terminal_text_until as _read_terminal_text_until
from pane_resize_test_support import (
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _expect_invalid_params(c: ProgramaClient, params: dict) -> None:
    try:
        c._call("surface.send_paste", params, timeout_s=10.0)
    except ProgramaClientError as error:
        _must("invalid_params" in str(error), f"Expected invalid_params for {params!r}: {error}")
        return
    raise ProgramaClientError(f"surface.send_paste unexpectedly succeeded for {params!r}")


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    stamp = int(time.time() * 1000)
    work_dir = Path(tempfile.mkdtemp(prefix="programa_send_paste_"))
    canaries = [work_dir / f"bash-canary-{stamp}", work_dir / f"zsh-canary-{stamp}"]
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

            _expect_invalid_params(c, {"surface_id": surface_id, "text": ""})
            _expect_invalid_params(c, {"surface_id": surface_id})

            # 1. Plain shell, no bracketed paste: one line at the prompt, nothing runs.
            first, second = f"PASTEA{stamp % 100000000}", f"PASTEB{stamp % 100000000}"
            sent = c._call(
                "surface.send_paste",
                {"surface_id": surface_id, "text": f"echo {first}; touch {canaries[0]}\necho {second}\n"},
                timeout_s=10.0,
            ) or {}
            _must(str(sent.get("surface_id") or "") == surface_id, f"send_paste targeted the wrong surface: {sent}")
            text = _read_terminal_text_until(c, surface_id, second)
            _must(
                any(first in row and second in row for row in text.splitlines()),
                f"Expected both pasted lines on one prompt line in the plain shell: {text!r}",
            )
            time.sleep(1.5)
            _must(not canaries[0].exists(), f"Pasted text was executed by the plain shell (found {canaries[0]})")

            # 2. zsh turns bracketed paste on: the lines stay separate and still nothing runs.
            c.send_key_surface(surface_id, "ctrl-c")
            c.send_surface(surface_id, "exec /bin/zsh -f\n")
            _wait_for_surface_command_roundtrip(c, workspace_id, surface_id)
            zfirst, zsecond = f"ZPASTEA{stamp % 100000000}", f"ZPASTEB{stamp % 100000000}"
            c._call(
                "surface.send_paste",
                {"surface_id": surface_id, "text": f"echo {zfirst}; touch {canaries[1]}\necho {zsecond}"},
                timeout_s=10.0,
            )
            ztext = _read_terminal_text_until(c, surface_id, zsecond)
            _must(
                not any(zfirst in row and zsecond in row for row in ztext.splitlines()),
                f"Expected zsh (bracketed paste) to keep the pasted lines on separate rows: {ztext!r}",
            )
            time.sleep(1.5)
            _must(not canaries[1].exists(), f"Pasted text was executed by zsh (found {canaries[1]})")
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
        for canary in canaries:
            canary.unlink(missing_ok=True)
        try:
            work_dir.rmdir()
        except OSError:
            pass

    print("PASS: surface.send_paste delivers one paste with no Return")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
