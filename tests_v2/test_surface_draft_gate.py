#!/usr/bin/env python3
"""Socket writes never land in a pane where a person has unsent typed input (INC-687).

A person types into a terminal (real keyDown through debug.shortcut.simulate, or an IME-style
commit through debug.type). Until they submit or clear that line, surface.send_text,
surface.send_key, surface.send_paste, surface.send_if_unchanged and agent.prompt refuse with
`draft_in_progress` and send nothing; otherwise agent text would mix into, or submit, the
person's half-typed command. `force: true` sends anyway, and a forced write that submits ends
the draft. Terminal replies (DA1, DSR) reach the PTY without passing through the view, so they
must never count as typing.

Escape, Backspace, Tab and arrow keys are covered in programaTests/PersonDraftGateTests.swift:
debug.shortcut.simulate has no Escape/Backspace/Tab keys, and its arrows carry a printable
arrow character that a real arrow key does not. The 60 s expiry and the
automation.holdAgentTextWhileTyping kill switch are covered there too (no socket seam).
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must
from v2_support import read_terminal_text_until as _read_terminal_text_until
from v2_support import report_agent_state as _report_agent_state
from v2_support import wait_for as _wait_for
from pane_resize_test_support import (
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
LINES = 20
STAMP = int(time.time() * 1000) % 100000000


def _call_full(method: str, params: Dict[str, Any], timeout_s: float = 10.0) -> Dict[str, Any]:
    """One request on its own connection, returning the whole response so error data is visible
    (ProgramaClient flattens `error.data` into its exception message)."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout_s)
    try:
        sock.connect(SOCKET_PATH)
        sock.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                raise ProgramaClientError(f"Socket closed waiting for {method}")
            buf += chunk
    finally:
        sock.close()
    resp = json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    _must(isinstance(resp, dict), f"Invalid response to {method}: {resp!r}")
    return resp


def _expect_draft_rejection(method: str, params: Dict[str, Any], surface_id: str) -> Dict[str, Any]:
    resp = _call_full(method, params)
    err = resp.get("error") or {}
    _must(resp.get("ok") is not True, f"{method} was delivered into a pane with a draft: {resp!r}")
    _must(err.get("code") == "draft_in_progress", f"{method} expected draft_in_progress: {resp!r}")
    data = err.get("data") or {}
    _must(data.get("surface_id") == surface_id, f"{method} error names the wrong surface: {data!r}")
    _must(str(data.get("surface_ref") or "").startswith("surface:"), f"{method} error lacks surface_ref: {data!r}")
    age = data.get("draft_age_ms")
    expires = data.get("expires_in_ms")
    _must(isinstance(age, int) and age >= 0, f"{method} draft_age_ms is not a non-negative int: {data!r}")
    _must(isinstance(expires, int) and 0 < expires <= 60000, f"{method} expires_in_ms outside (0, 60000]: {data!r}")
    return data


def _expect_ok(method: str, params: Dict[str, Any]) -> Dict[str, Any]:
    resp = _call_full(method, params)
    _must(resp.get("ok") is True, f"{method} should have been delivered: {resp!r}")
    return dict(resp.get("result") or {})


def _focus(c: ProgramaClient, surface_id: str) -> None:
    c.activate_app()
    c.focus_surface_by_panel(surface_id)
    c.settle()
    _wait_for(lambda: c.is_terminal_focused(surface_id), timeout_s=5.0)


def _type_keys(c: ProgramaClient, keys: str) -> None:
    for key in keys:
        c.simulate_shortcut(key)
    c.settle()


def _press(c: ProgramaClient, combo: str) -> None:
    c.simulate_shortcut(combo)
    c.settle()


def _send_text_ok_and_visible(c: ProgramaClient, surface_id: str, marker: str) -> None:
    _expect_ok("surface.send_text", {"surface_id": surface_id, "text": f"echo {marker}\n"})
    _read_terminal_text_until(c, surface_id, marker)


def _fresh_fingerprint(surface_id: str) -> str:
    res = _expect_ok("surface.read_text", {"surface_id": surface_id, "lines": LINES})
    return str(res.get("fingerprint") or "")


def _check_every_method_refuses(c: ProgramaClient, surface_id: str, canary: Path) -> None:
    _type_keys(c, "qzx")
    _expect_draft_rejection("surface.send_text", {"surface_id": surface_id, "text": f"echo T{STAMP}\n"}, surface_id)
    _expect_draft_rejection("surface.send_key", {"surface_id": surface_id, "key": "enter"}, surface_id)
    _expect_draft_rejection("surface.send_paste", {"surface_id": surface_id, "text": f"touch {canary}"}, surface_id)
    _expect_draft_rejection(
        "agent.prompt", {"surface_id": surface_id, "text": f"touch {canary}", "timeout_ms": 2000}, surface_id
    )
    # Fingerprint first: a stale screen keeps reporting `mismatch`, a fresh one hits the draft.
    last: Optional[Dict[str, Any]] = None
    for _ in range(5):
        params = {
            "surface_id": surface_id,
            "lines": LINES,
            "expected_fingerprint": _fresh_fingerprint(surface_id),
            "text": f"touch {canary}",
            "keys": ["enter"],
        }
        last = _call_full("surface.send_if_unchanged", params)
        if (last.get("error") or {}).get("code") != "mismatch":
            break
    _must(
        (last or {}).get("error", {}).get("code") == "draft_in_progress",
        f"surface.send_if_unchanged expected draft_in_progress: {last!r}",
    )
    time.sleep(1.0)
    _must(not canary.exists(), f"A refused write still ran in the pane (found {canary})")
    screen = c.read_terminal_text(surface_id)
    _must(f"T{STAMP}" not in screen, f"Refused send_text text reached the screen: {screen!r}")


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    work_dir = Path(tempfile.mkdtemp(prefix="programa_draft_gate_"))
    canary = work_dir / f"canary-{STAMP}"
    workspace_id = ""

    try:
        with ProgramaClient(SOCKET_PATH) as c:
            created = c._call("workspace.create", {"cwd": str(work_dir)}, timeout_s=15.0) or {}
            workspace_id = str(created.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
            c.select_workspace(workspace_id)
            rows = list((c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or [])
            _must(len(rows) >= 1, f"Expected an initial terminal surface: {rows}")
            pane_a = str(rows[0].get("id") or "")
            _wait_for_surface_command_roundtrip(c, workspace_id, pane_a)
            pane_b = c.new_split("right")
            _wait_for_surface_command_roundtrip(c, workspace_id, pane_b)

            # 1. Typed letters block all five write methods, and nothing reaches the shell.
            _focus(c, pane_a)
            _check_every_method_refuses(c, pane_a, canary)
            print("  PASS: a keyDown draft refuses send_text, send_key, send_paste, send_if_unchanged, agent.prompt")

            # 2. The draft is per pane: pane B still takes writes.
            _send_text_ok_and_visible(c, pane_b, f"PANEB{STAMP}")
            print("  PASS: a draft in one pane does not block another")

            # 3. Return submits the person's line and releases the pane.
            _press(c, "enter")
            _send_text_ok_and_visible(c, pane_a, f"AFTERENTER{STAMP}")
            print("  PASS: Return releases the pane")

            # 4. Ctrl+C and Ctrl+U discard the line and release the pane.
            for combo in ("ctrl+c", "ctrl+u"):
                _type_keys(c, "qzx")
                _expect_draft_rejection("surface.send_text", {"surface_id": pane_a, "text": "x"}, pane_a)
                _press(c, combo)
                _send_text_ok_and_visible(c, pane_a, f"AFTER{combo.replace('+', '').upper()}{STAMP}")
                print(f"  PASS: {combo} releases the pane")

            # 5. Command bindings are not typing.
            _press(c, "cmd+k")
            _send_text_ok_and_visible(c, pane_a, f"AFTERCMD{STAMP}")
            print("  PASS: a Command binding does not start a draft")

            # 6. force bypasses the guard. A forced write without CR/LF leaves the draft; one with
            #    a newline submits it, so the next plain write goes through.
            _type_keys(c, "qzx")
            _expect_ok("surface.send_text", {"surface_id": pane_a, "text": "w", "force": True})
            _expect_draft_rejection("surface.send_text", {"surface_id": pane_a, "text": "x"}, pane_a)
            _expect_ok("surface.send_text", {"surface_id": pane_a, "text": "\n", "force": True})
            _send_text_ok_and_visible(c, pane_a, f"AFTERFORCECR{STAMP}")
            _type_keys(c, "qzx")
            _expect_ok("surface.send_key", {"surface_id": pane_a, "key": "enter", "force": True})
            _send_text_ok_and_visible(c, pane_a, f"AFTERFORCEENTER{STAMP}")
            print("  PASS: force bypasses the guard and a forced submit ends the draft")

            # 7. IME-style commits outside keyDown (debug.type -> insertText) count as typing,
            #    and a committed CR submits.
            c.simulate_type("qzx")
            c.settle()
            _expect_draft_rejection("surface.send_text", {"surface_id": pane_a, "text": "x"}, pane_a)
            c.simulate_type("\r")
            c.settle()
            _send_text_ok_and_visible(c, pane_a, f"AFTERIME{STAMP}")
            print("  PASS: committed text drafts and a committed CR submits")

            # 8. Socket text without a newline is not a person draft.
            _expect_ok("surface.send_text", {"surface_id": pane_a, "text": "echo PART"})
            _expect_ok("surface.send_text", {"surface_id": pane_a, "text": f"IAL{STAMP}\n"})
            _read_terminal_text_until(c, pane_a, f"PARTIAL{STAMP}")
            print("  PASS: socket text never counts as the person's draft")

            # 9. Terminal replies (DA1, DA2, DSR) are written back by the terminal, not typed.
            mark = f"REPLIES{STAMP}"
            _expect_ok(
                "surface.send_text",
                {"surface_id": pane_a, "text": f"printf '\\033[c\\033[>c\\033[6n'; echo {mark}\n"},
            )
            _read_terminal_text_until(c, pane_a, mark)
            c.settle()
            _expect_ok("surface.send_key", {"surface_id": pane_a, "key": "ctrl-c"})
            _send_text_ok_and_visible(c, pane_a, f"AFTERREPLIES{STAMP}")
            print("  PASS: terminal replies do not start a draft")

            # 10. Keys typed while the agent waits on an approval answer it and leave no draft.
            _focus(c, pane_b)
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "blocked")
            c.settle()
            _type_keys(c, "y")
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "working")
            c.settle()
            _expect_ok("surface.send_key", {"surface_id": pane_b, "key": "ctrl-c"})
            _send_text_ok_and_visible(c, pane_b, f"AFTERAPPROVAL{STAMP}")

            # A draft typed before the approval prompt is still the person's text afterwards.
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "idle")
            c.settle()
            _type_keys(c, "qzx")
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "blocked")
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "working")
            c.settle()
            _expect_draft_rejection("surface.send_text", {"surface_id": pane_b, "text": "x"}, pane_b)
            print("  PASS: approval answers leave no draft, and an earlier draft survives the prompt")
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
        canary.unlink(missing_ok=True)
        try:
            work_dir.rmdir()
        except OSError:
            pass

    print("PASS: socket writes wait for the person's unsent typing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
