#!/usr/bin/env python3
"""Socket writes never land in a pane where a person has unsent typed input (INC-687).

A person types into a terminal (real keyDown through debug.shortcut.simulate, or an IME-style
commit through debug.type). Until they submit or clear that line, surface.send_text,
surface.send_key, surface.send_paste and surface.send_if_unchanged refuse with
`draft_in_progress` and send nothing; otherwise agent text would mix into, or submit, the
person's half-typed command. `force: true` sends anyway, and a forced write that submits ends
the draft.

agent.prompt waits instead (steps 11-14): it holds while the person drafts, lets the turn their
own submit started finish, then sends on its own line. If its timeout_ms runs out first it
returns `draft_in_progress` and nothing was sent; a surface closed while held resolves as
`outcome: "closed"`, and a client that disconnects mid-hold abandons the prompt. Terminal replies (DA1, DSR) reach the PTY without passing through the view, so they
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
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must
from v2_support import read_terminal_text_until as _read_terminal_text_until
from v2_support import report_agent_state as _report_agent_state
from v2_support import surface_agent_state as _surface_agent_state
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


class _AgentPromptCall(threading.Thread):
    """agent.prompt on its own connection, so the main client can keep driving the pane while the
    call is held (a shared connection interleaves responses: "Mismatched response id")."""

    def __init__(self, params: Dict[str, Any]):
        super().__init__(daemon=True)
        self.params = params
        self.response: Optional[Dict[str, Any]] = None
        self.error: Optional[BaseException] = None
        self.elapsed_s = 0.0

    def run(self) -> None:
        started = time.time()
        try:
            # Client read timeout must outlast the server-side budget.
            self.response = _call_full("agent.prompt", self.params, timeout_s=self.params["timeout_ms"] / 1000.0 + 10.0)
        except BaseException as exc:  # noqa: BLE001 - surfaced by finish()
            self.error = exc
        self.elapsed_s = time.time() - started

    def finish(self, timeout_s: float) -> Dict[str, Any]:
        self.join(timeout=timeout_s)
        _must(not self.is_alive(), f"agent.prompt still blocked after {timeout_s}s: {self.params!r}")
        if self.error is not None:
            raise self.error
        return dict(self.response or {})


def _fresh_terminal(c: ProgramaClient, workspace_id: str) -> str:
    surface_id = c.new_surface(panel_type="terminal")
    _wait_for_surface_command_roundtrip(c, workspace_id, surface_id)
    _focus(c, surface_id)
    return surface_id


def _prompt_marker(tag: str) -> tuple[str, str]:
    """(prompt text, output line). The empty quotes keep the output line distinct from the
    echoed command, and `tag` (the part after the quotes) appears on screen only once anything
    of the prompt was delivered."""
    return f'echo {tag[:3]}""{tag[3:]}', tag


def _screen_lines(c: ProgramaClient, surface_id: str) -> list[str]:
    return [line.strip() for line in c.read_terminal_text(surface_id).splitlines()]


def _assert_absent_while(c: ProgramaClient, surface_id: str, needle: str, call: _AgentPromptCall, window_s: float, why: str) -> None:
    """Nothing may land for `window_s` while `call` is held. An absence check has no event to
    wait on, so this is a bounded window; it also proves the call is still blocked."""
    end = time.time() + window_s
    while time.time() < end:
        screen = c.read_terminal_text(surface_id)
        _must(needle not in screen, f"agent.prompt delivered {why}: {screen!r}")
        _must(call.is_alive(), f"agent.prompt returned {why} instead of holding: {call.response!r} {call.error!r}")
        time.sleep(0.1)


def _check_prompt_holds_until_submit_and_turn(c: ProgramaClient, workspace_id: str) -> None:
    """T11-h: the prompt waits for the person's Return and the turn it started, then lands on
    its own line after the person's command."""
    sid = _fresh_terminal(c, workspace_id)
    person = f"HELD{STAMP}"
    prompt_text, prompt_out = _prompt_marker(f"PROMPT{STAMP}")

    c.simulate_type(f"echo {person}")
    c.settle()
    drafted_at = time.time()
    call = _AgentPromptCall(
        {"surface_id": sid, "text": prompt_text, "timeout_ms": 8000, "working_grace_ms": 3000}
    )
    call.start()
    _assert_absent_while(c, sid, prompt_out[3:], call, 1.0, "while the person was drafting")

    # The person submits; their own turn starts (the agent hook reports working) and is running.
    submit_at = time.time()
    _press(c, "enter")
    _report_agent_state(SOCKET_PATH, workspace_id, sid, "working")
    working_at = time.time()
    held_floor_ms = int((submit_at - drafted_at) * 1000) - 300
    # The draft line already shows `echo HELD...`; wait for the command's own output line.
    _wait_for(lambda: person in _screen_lines(c, sid), timeout_s=5.0)
    _assert_absent_while(c, sid, prompt_out[3:], call, 1.0, "while the person's own turn was running")
    _report_agent_state(SOCKET_PATH, workspace_id, sid, "idle")
    settle_floor_ms = int((time.time() - working_at) * 1000) - 300

    # Only now is the prompt sent; the agent's turn for it reports working, then idle.
    _wait_for(lambda: prompt_out in _screen_lines(c, sid), timeout_s=5.0)
    _report_agent_state(SOCKET_PATH, workspace_id, sid, "working")
    _report_agent_state(SOCKET_PATH, workspace_id, sid, "idle")
    resp = call.finish(timeout_s=10.0)

    _must(resp.get("ok") is True, f"held agent.prompt should succeed once the person is done: {resp!r}")
    res = dict(resp.get("result") or {})
    held = res.get("held_ms")
    settle = res.get("settle_ms")
    _must(isinstance(held, int) and held >= max(1, held_floor_ms), f"held_ms {held!r} < time drafted ({held_floor_ms} ms): {res!r}")
    _must(isinstance(settle, int) and settle >= max(0, settle_floor_ms), f"settle_ms {settle!r} < person's turn ({settle_floor_ms} ms): {res!r}")
    _must(res.get("working_observed") is True, f"the prompt's own turn should be observed: {res!r}")
    _must(res.get("final_state") == "idle", f"expected final_state=idle: {res!r}")

    lines = _screen_lines(c, sid)
    _must(person in lines and prompt_out in lines, f"both commands should have run on their own: {lines!r}")
    _must(lines.index(prompt_out) > lines.index(person), f"prompt ran before the person's command: {lines!r}")
    merged = [line for line in lines if person in line and prompt_out[3:] in line]
    _must(not merged, f"prompt text merged into the person's line: {merged!r}")


def _check_prompt_hold_times_out(c: ProgramaClient, workspace_id: str, canary: Path) -> None:
    """T11-h timeout: a person who never submits keeps the prompt out; the budget ends it with
    draft_in_progress and nothing was sent."""
    sid = _fresh_terminal(c, workspace_id)
    _type_keys(c, "qzx")
    started = time.time()
    resp = _call_full("agent.prompt", {"surface_id": sid, "text": f"touch {canary}", "timeout_ms": 1500}, timeout_s=15.0)
    elapsed = time.time() - started

    err = resp.get("error") or {}
    _must(resp.get("ok") is not True, f"agent.prompt was delivered into a pane with a draft: {resp!r}")
    _must(err.get("code") == "draft_in_progress", f"expected draft_in_progress after the hold: {resp!r}")
    data = err.get("data") or {}
    _must(data.get("surface_id") == sid, f"error names the wrong surface: {data!r}")
    _must(data.get("timeout_ms") == 1500, f"error should echo timeout_ms: {data!r}")
    _must(isinstance(data.get("surface_ref"), str), f"error should carry surface_ref like the send_* refusals: {data!r}")
    held = data.get("held_ms")
    _must(isinstance(held, int) and 1300 <= held <= 4000, f"held_ms should cover the 1500 ms budget: {data!r}")
    _must("settle_ms" not in data, f"the draft never ended, so there was no settle: {data!r}")
    _must(1.3 <= elapsed <= 6.0, f"agent.prompt should hold for its budget, returned after {elapsed:.2f}s")

    c.settle()
    _must(not canary.exists(), f"a timed-out held prompt still ran (found {canary})")
    _must(str(canary) not in c.read_terminal_text(sid), "a timed-out held prompt reached the screen")
    _press(c, "ctrl+u")


def _check_prompt_force_skips_hold(c: ProgramaClient, workspace_id: str) -> None:
    """T11-h force: force sends at once, so the result carries no hold timings."""
    sid = _fresh_terminal(c, workspace_id)
    _type_keys(c, "qzx")
    prompt_text, prompt_out = _prompt_marker(f"FORCED{STAMP}")
    started = time.time()
    resp = _call_full(
        "agent.prompt",
        {"surface_id": sid, "text": prompt_text, "timeout_ms": 8000, "working_grace_ms": 500, "force": True},
        timeout_s=20.0,
    )
    elapsed = time.time() - started

    _must(resp.get("ok") is True, f"force should deliver despite the draft: {resp!r}")
    res = dict(resp.get("result") or {})
    _must("held_ms" not in res and "settle_ms" not in res, f"a forced prompt was held: {res!r}")
    _must(elapsed < 4.0, f"a forced prompt should return after its 500 ms grace, took {elapsed:.2f}s")
    # The forced text joins the person's `qzx` (the documented cost of force); it is on screen.
    _read_terminal_text_until(c, sid, prompt_out[3:])
    # The forced Enter submitted the line, so the pane takes plain writes again.
    _send_text_ok_and_visible(c, sid, f"AFTERFORCEPROMPT{STAMP}")


def _check_prompt_hold_ends_on_close(c: ProgramaClient, workspace_id: str) -> None:
    """T11-l: closing the surface while the prompt is held resolves it as closed, not an error
    and not a hang until timeout_ms."""
    sid = _fresh_terminal(c, workspace_id)
    _type_keys(c, "qzx")
    call = _AgentPromptCall({"surface_id": sid, "text": f"echo CLOSED{STAMP}", "timeout_ms": 20000})
    call.start()
    _assert_absent_while(c, sid, f"CLOSED{STAMP}", call, 0.5, "while the person was drafting")
    c.close_surface(sid)
    # Far below the 20 s budget: only the close can end the call this early.
    resp = call.finish(timeout_s=5.0)

    _must(resp.get("ok") is True, f"a surface closed during the hold should resolve, not fail: {resp!r}")
    res = dict(resp.get("result") or {})
    _must(res.get("outcome") == "closed", f"expected outcome=closed: {res!r}")
    _must(res.get("surface_id") == sid, f"result names the wrong surface: {res!r}")
    _must(isinstance(res.get("held_ms"), int), f"a closed hold should report held_ms: {res!r}")


def _check_prompt_hold_abandoned_on_disconnect(c: ProgramaClient, workspace_id: str, canary: Path) -> None:
    """T11-l: a client that disconnects mid-hold leaves the app running and its prompt unsent,
    even after the draft ends."""
    sid = _fresh_terminal(c, workspace_id)
    _type_keys(c, "qzx")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5.0)
    try:
        sock.connect(SOCKET_PATH)
        params = {"surface_id": sid, "text": f"touch {canary}", "timeout_ms": 20000}
        sock.sendall((json.dumps({"id": 1, "method": "agent.prompt", "params": params}) + "\n").encode("utf-8"))
        # The request is held, so no response may arrive before the disconnect.
        sock.settimeout(0.5)
        try:
            early = sock.recv(65536)
            _must(False, f"agent.prompt answered instead of holding: {early!r}")
        except socket.timeout:
            pass
    finally:
        sock.close()

    _must(c.ping(), "app stopped answering after a client disconnected mid-hold")
    c.settle()
    # End the draft. A call still alive would now deliver within one 100 ms poll plus the
    # 1500 ms settle cap, so this window is long enough to see it.
    _press(c, "ctrl+u")
    end = time.time() + 2.5
    while time.time() < end:
        _must(not canary.exists(), f"an abandoned prompt was delivered after its client left (found {canary})")
        time.sleep(0.1)
    _must(str(canary) not in c.read_terminal_text(sid), "an abandoned prompt reached the screen")
    _must(c.ping(), "app stopped answering after the abandoned hold")
    _send_text_ok_and_visible(c, sid, f"AFTERDISCONNECT{STAMP}")


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
            print("  PASS: a keyDown draft refuses send_text, send_key, send_paste, send_if_unchanged")

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

            # 10b. A permission prompt refuses writes until the person's first key answers it;
            #      keys after that are a draft again (INC-695).
            _press(c, "ctrl+u")
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "working")
            c._call(
                "agent.needs_input",
                {"workspace_id": workspace_id, "surface_id": pane_b, "provider": "claude-code", "body": f"allow? {STAMP}", "kind": "permission"},
            )
            _wait_for(lambda: _surface_agent_state(c, workspace_id, pane_b) == "blocked", timeout_s=5.0)
            refused = _call_full("surface.send_text", {"surface_id": pane_b, "text": "x"})
            _must(
                (refused.get("error") or {}).get("code") == "agent_awaiting_approval",
                f"a permission prompt should refuse socket writes: {refused!r}",
            )
            _type_keys(c, "y")
            _type_keys(c, "qzx")
            _expect_draft_rejection("surface.send_text", {"surface_id": pane_b, "text": "x"}, pane_b)
            _press(c, "ctrl+u")
            _send_text_ok_and_visible(c, pane_b, f"AFTERPERMISSIONKEY{STAMP}")
            _report_agent_state(SOCKET_PATH, workspace_id, pane_b, "working")
            print("  PASS: a person's key at a permission prompt lifts the refusal and later keys draft")

            # 11. agent.prompt holds for the draft and the person's turn, then sends on its own line.
            _check_prompt_holds_until_submit_and_turn(c, workspace_id)
            print("  PASS: agent.prompt waits for the person's submit and turn, then sends after it")

            # 12. A draft that outlasts timeout_ms ends the call with draft_in_progress, unsent.
            _check_prompt_hold_times_out(c, workspace_id, canary)
            print("  PASS: agent.prompt's budget running out mid-draft sends nothing")

            # 13. force skips the hold.
            _check_prompt_force_skips_hold(c, workspace_id)
            print("  PASS: agent.prompt force sends without holding")

            # 14. A held prompt ends cleanly when its surface closes or its client disconnects.
            _check_prompt_hold_ends_on_close(c, workspace_id)
            _check_prompt_hold_abandoned_on_disconnect(c, workspace_id, canary)
            print("  PASS: a held agent.prompt resolves on close and is abandoned on disconnect")
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

    print("PASS: socket writes and agent.prompt wait for the person's unsent typing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
