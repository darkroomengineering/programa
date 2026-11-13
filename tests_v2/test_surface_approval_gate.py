#!/usr/bin/env python3
"""Socket writes never answer an agent's permission prompt for the person (INC-695).

While the agent in a surface waits on a permission or sign-in prompt, surface.send_text,
surface.send_key, surface.send_paste, surface.send_if_unchanged and agent.prompt fail with
`agent_awaiting_approval` and send nothing: one key (a digit, `y`, Enter, Escape) answers such a
prompt, so any write could approve something the person never saw. `force` (the draft override)
does not get past it; only `answer_prompt: true` does. agent.prompt refuses at once instead of
holding.

An unsigned OSC 7501 report (printed bytes without the terminal's token) can move the badge off
`blocked` but never lifts the refusal.

Only an explicit permission/auth prompt refuses. Claude's idle prompt arrives as a `question`,
and `prompt-agent` to an idle helper must keep working, so `kind=question`,
`agent.event user-input.requested`, and a kindless `blocked` (needs_input without kind,
surface.report_agent_state) do not refuse.

Proof that nothing was sent: before arming, the shell line is preloaded with an unsubmitted
`touch <k>`. Every refused write carries a different file name and would either extend that line
or submit it. The one allowed write finally submits the line, so the screen must show the
command exactly as preloaded plus the allowed suffix, and only the preloaded and the allowed
files may exist.

The person-side paths (a key at the prompt lifts the refusal, Escape, the 60 s draft expiry
under a prompt) and the automation.protectApprovalPrompts kill switch have no socket seam that
reproduces them faithfully; they are covered in programaTests/PersonDraftGateTests.swift and in
test_surface_draft_gate.py step 10.

Must run against a tagged build's socket (root CLAUDE.md "Testing policy"). CI-only.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, Optional

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from v2_support import must as _must  # noqa: E402
from v2_support import read_terminal_text_until as _read_terminal_text_until  # noqa: E402
from v2_support import report_agent_state as _report_agent_state  # noqa: E402
from v2_support import wait_for as _wait_for  # noqa: E402
from pane_resize_test_support import (  # noqa: E402
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
LINES = 20
STAMP = int(time.time() * 1000) % 100000000
APPROVAL_DATA_KEYS = {"surface_id", "surface_ref", "prompt_kind", "prompt_age_ms", "agent_state_source", "stale"}


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


def _expect_ok(method: str, params: Dict[str, Any], timeout_s: float = 10.0) -> Dict[str, Any]:
    resp = _call_full(method, params, timeout_s=timeout_s)
    _must(resp.get("ok") is True, f"{method} should have been delivered: {resp!r}")
    return dict(resp.get("result") or {})


def _expect_approval_refusal(
    method: str, params: Dict[str, Any], surface_id: str, timeout_s: float = 10.0, source: str = "hooks"
) -> Dict[str, Any]:
    return _check_approval_refusal(method, _call_full(method, params, timeout_s=timeout_s), surface_id, source)


def _check_approval_refusal(method: str, resp: Dict[str, Any], surface_id: str, source: str = "hooks") -> Dict[str, Any]:
    err = resp.get("error") or {}
    _must(resp.get("ok") is not True, f"{method} was delivered into a pane waiting on a permission prompt: {resp!r}")
    _must(err.get("code") == "agent_awaiting_approval", f"{method} expected agent_awaiting_approval: {resp!r}")
    data = err.get("data") or {}
    _must(APPROVAL_DATA_KEYS <= set(data), f"{method} error data lacks {APPROVAL_DATA_KEYS - set(data)}: {data!r}")
    ref = str(data.get("surface_ref") or "")
    _must(ref.startswith("surface:"), f"{method} error lacks surface_ref: {data!r}")
    _must(
        err.get("message") == f"{ref} is waiting on an approval prompt; nothing was sent",
        f"{method} error message changed: {err.get('message')!r}",
    )
    _must(data.get("surface_id") == surface_id, f"{method} error names the wrong surface: {data!r}")
    _must(data.get("prompt_kind") == "permission", f"{method} prompt_kind should be permission: {data!r}")
    age = data.get("prompt_age_ms")
    _must(isinstance(age, int) and age >= 0, f"{method} prompt_age_ms is not a non-negative int: {data!r}")
    _must(data.get("agent_state_source") == source, f"{method} agent_state_source should be {source}: {data!r}")
    _must(data.get("stale") is False, f"{method} a fresh report must not read as stale: {data!r}")
    return data


def _agent_state(c: ProgramaClient, workspace_id: str, surface_id: str) -> Optional[str]:
    rows = (c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
    for row in rows:
        if str(row.get("id")) == surface_id:
            return row.get("agent_state")
    raise ProgramaClientError(f"surface {surface_id} not in surface.list: {rows}")


def _wait_agent_state(c: ProgramaClient, workspace_id: str, surface_id: str, state: str) -> None:
    """Agent-state reports apply on a later main-queue hop; the gate moves in that same hop, so
    once surface.list shows the state the gate has seen it too."""
    _wait_for(lambda: _agent_state(c, workspace_id, surface_id) == state, timeout_s=5.0)


def _needs_input(kind: Optional[str]) -> Callable[[str, str], None]:
    def arm(workspace_id: str, surface_id: str) -> None:
        params: Dict[str, Any] = {
            "workspace_id": workspace_id,
            "surface_id": surface_id,
            "provider": "claude-code",
            "title": "Claude Code",
            "body": f"approval-gate-{STAMP}",
        }
        if kind is not None:
            params["kind"] = kind
        _expect_ok("agent.needs_input", params)
    return arm


def _agent_event(event_type: str) -> Callable[[str, str], None]:
    def arm(workspace_id: str, surface_id: str) -> None:
        _expect_ok(
            "agent.event",
            {"workspace_id": workspace_id, "surface_id": surface_id, "event_type": event_type, "provider": "claude-code"},
        )
    return arm


def _report_blocked(workspace_id: str, surface_id: str) -> None:
    _report_agent_state(SOCKET_PATH, workspace_id, surface_id, "blocked")


def _reopen(c: ProgramaClient, workspace_id: str, surface_id: str) -> None:
    _report_agent_state(SOCKET_PATH, workspace_id, surface_id, "working")
    _wait_agent_state(c, workspace_id, surface_id, "working")


def _send_text_ok_and_visible(c: ProgramaClient, surface_id: str, tag: str) -> None:
    """The empty quotes keep the output line distinct from the echoed command."""
    _expect_ok("surface.send_text", {"surface_id": surface_id, "text": f'echo {tag[:3]}""{tag[3:]}\n'})
    _wait_for(lambda: tag in _screen_lines(c, surface_id), timeout_s=10.0)


def _screen_lines(c: ProgramaClient, surface_id: str) -> list[str]:
    return [line.strip() for line in c.read_terminal_text(surface_id).splitlines()]


def _fresh_fingerprint(surface_id: str) -> str:
    return str(_expect_ok("surface.read_text", {"surface_id": surface_id, "lines": LINES}).get("fingerprint") or "")


def _check_refused_then_answered(
    c: ProgramaClient,
    workspace_id: str,
    surface_id: str,
    work_dir: Path,
    tag: str,
    arm: Callable[[str, str], None],
    deliver_with: str,
) -> None:
    names = {k: f"{tag}{k}{STAMP}" for k in ("k", "t", "f", "e", "p", "i", "q", "z")}
    files = {k: work_dir / n for k, n in names.items()}

    _reopen(c, workspace_id, surface_id)
    _expect_ok("surface.send_text", {"surface_id": surface_id, "text": f"touch {names['k']}"})
    _read_terminal_text_until(c, surface_id, f"touch {names['k']}")

    arm(workspace_id, surface_id)
    _wait_agent_state(c, workspace_id, surface_id, "blocked")
    armed_at = time.time()

    # All five writes refuse, each with a payload that would leave a trace if delivered.
    _expect_approval_refusal("surface.send_text", {"surface_id": surface_id, "text": f" {names['t']}\n"}, surface_id)
    _expect_approval_refusal(
        "surface.send_text", {"surface_id": surface_id, "text": f" {names['f']}\n", "force": True}, surface_id
    )
    _expect_approval_refusal("surface.send_key", {"surface_id": surface_id, "key": "enter"}, surface_id)
    _expect_approval_refusal(
        "surface.send_key", {"surface_id": surface_id, "key": "enter", "force": True}, surface_id
    )
    _expect_approval_refusal("surface.send_paste", {"surface_id": surface_id, "text": f" {names['p']}"}, surface_id)

    # send_if_unchanged checks the fingerprint first: a stale one is `mismatch`, a fresh one
    # reaches the approval refusal.
    outdated = _call_full(
        "surface.send_if_unchanged",
        {"surface_id": surface_id, "lines": LINES, "expected_fingerprint": f"stale-{STAMP}", "text": " x", "keys": ["enter"]},
    )
    _must((outdated.get("error") or {}).get("code") == "mismatch", f"a stale fingerprint must stay mismatch: {outdated!r}")
    last: Optional[Dict[str, Any]] = None
    for _ in range(5):
        params = {
            "surface_id": surface_id,
            "lines": LINES,
            "expected_fingerprint": _fresh_fingerprint(surface_id),
            "text": f" {names['i']}",
            "keys": ["enter"],
        }
        last = _call_full("surface.send_if_unchanged", params)
        if (last.get("error") or {}).get("code") != "mismatch":
            break
    _check_approval_refusal("surface.send_if_unchanged", last or {}, surface_id)

    # agent.prompt refuses at once; it does not hold for a prompt the way it holds for a draft.
    started = time.time()
    _expect_approval_refusal(
        "agent.prompt",
        {"surface_id": surface_id, "text": f"; touch {names['q']}", "timeout_ms": 8000},
        surface_id,
        timeout_s=15.0,
    )
    elapsed = time.time() - started
    _must(elapsed < 3.0, f"agent.prompt should refuse at once, not hold: took {elapsed:.2f}s")

    # A repeated report of the same prompt (every hook sample re-reports it) keeps its age.
    # This waits on the clock on purpose: the age is what is being measured.
    time.sleep(max(0.0, armed_at + 0.8 - time.time()))
    arm(workspace_id, surface_id)
    data = _expect_approval_refusal("surface.send_key", {"surface_id": surface_id, "key": "enter"}, surface_id)
    _must(data["prompt_age_ms"] >= 600, f"a repeated report reset the prompt's age: {data!r}")

    # answer_prompt delivers, and the line holds only the preload plus this write.
    if deliver_with == "send_text":
        c.send_surface(surface_id, f" {names['z']}\n", answer_prompt=True)
        expected_line = f"touch {names['k']} {names['z']}"
    else:
        res = _expect_ok(
            "agent.prompt",
            {
                "surface_id": surface_id,
                "text": f"; touch {names['z']}",
                "timeout_ms": 5000,
                "working_grace_ms": 300,
                "answer_prompt": True,
            },
            timeout_s=15.0,
        )
        _must("held_ms" not in res, f"an answer_prompt agent.prompt with no draft was held: {res!r}")
        expected_line = f"touch {names['k']}; touch {names['z']}"
    _wait_for(lambda: files["k"].exists() and files["z"].exists(), timeout_s=10.0)
    screen = c.read_terminal_text(surface_id)
    _must(expected_line in screen, f"refused text reached the shell line (expected {expected_line!r}): {screen!r}")
    leaked = [str(files[k]) for k in ("t", "f", "p", "i", "q") if files[k].exists()]
    _must(not leaked, f"refused writes still ran: {leaked}")

    # The delivered answer closes the prompt; a plain write goes through until it is reported again.
    _send_text_ok_and_visible(c, surface_id, f"LIF{tag.upper()}{STAMP}")
    arm(workspace_id, surface_id)
    _expect_approval_refusal("surface.send_text", {"surface_id": surface_id, "text": f" {names['e']}\n"}, surface_id)

    # The agent leaving blocked reopens the pane.
    _reopen(c, workspace_id, surface_id)
    _send_text_ok_and_visible(c, surface_id, f"OPE{tag.upper()}{STAMP}")
    _must(not files["e"].exists(), f"a refused write ran after the prompt closed (found {files['e']})")


def _check_not_refused(c: ProgramaClient, workspace_id: str, surface_id: str, tag: str, arm: Callable[[str, str], None]) -> None:
    _reopen(c, workspace_id, surface_id)
    arm(workspace_id, surface_id)
    _wait_agent_state(c, workspace_id, surface_id, "blocked")
    _send_text_ok_and_visible(c, surface_id, f"SEN{tag.upper()}{STAMP}")

    # prompt-agent to an idle helper (Claude's idle prompt reads as blocked/question) must send.
    out = f"PRM{tag.upper()}{STAMP}"
    res = _expect_ok(
        "agent.prompt",
        {"surface_id": surface_id, "text": f'echo {out[:3]}""{out[3:]}', "timeout_ms": 5000, "working_grace_ms": 300},
        timeout_s=15.0,
    )
    _must(res.get("working_observed") is False, f"no agent reported working, so none was observed: {res!r}")
    _wait_for(lambda: out in _screen_lines(c, surface_id), timeout_s=10.0)


def _agent_row(c: ProgramaClient, workspace_id: str, surface_id: str) -> Dict[str, Any]:
    rows = (c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
    for row in rows:
        if str(row.get("id")) == surface_id:
            return dict(row)
    raise ProgramaClientError(f"surface {surface_id} not in surface.list: {rows}")


def _check_unsigned_working_keeps_refusal(
    c: ProgramaClient, workspace_id: str, surface_id: str, work_dir: Path
) -> None:
    """Text printed in the pane (a file preview in the dialog, say) can carry an unsigned OSC 7501
    `working`. It moves the badge but must not lift the refusal (INC-1124). The release file is
    created from this process, never through the socket: any delivered write answers the prompt."""
    release = f"go{STAMP}"
    _reopen(c, workspace_id, surface_id)
    _expect_ok(
        "surface.send_text",
        {
            "surface_id": surface_id,
            "text": f"while [ ! -e {release} ]; do sleep 0.1; done; printf '\\033]7501;state=working\\033\\\\'; sleep 60\n",
        },
    )

    _needs_input("permission")(workspace_id, surface_id)
    _wait_agent_state(c, workspace_id, surface_id, "blocked")
    (work_dir / release).touch()

    def unsigned_working_shows() -> bool:
        row = _agent_row(c, workspace_id, surface_id)
        return row.get("agent_state") == "working" and row.get("agent_state_source") == "program"

    _wait_for(unsigned_working_shows, timeout_s=10.0)

    _expect_approval_refusal(
        "surface.send_text", {"surface_id": surface_id, "text": " forged\n"}, surface_id, source="program"
    )
    _expect_approval_refusal("surface.send_key", {"surface_id": surface_id, "key": "enter"}, surface_id, source="program")
    _expect_approval_refusal(
        "agent.prompt",
        {"surface_id": surface_id, "text": "forged", "timeout_ms": 5000},
        surface_id,
        timeout_s=15.0,
        source="program",
    )

    _expect_ok("surface.send_key", {"surface_id": surface_id, "key": "ctrl+c", "answer_prompt": True})
    _send_text_ok_and_visible(c, surface_id, f"UNS{STAMP}")


def _check_agent_exit_lifts_refusal(c: ProgramaClient, workspace_id: str, surface_id: str, work_dir: Path) -> None:
    """Claude Code under native status, killed at a permission prompt without its SessionEnd: the
    hooks' route view stays `blocked`, the program's unsigned status owns the badge. The shell
    reports its prompt over the socket before it prints the prompt mark, and that pair must lift
    the refusal. The agent stand-in is killed from this process, never through the socket."""
    release = f"gx{STAMP}"
    agent = f"sleep 7{STAMP}"
    _reopen(c, workspace_id, surface_id)
    _expect_ok(
        "surface.send_text",
        {
            "surface_id": surface_id,
            "text": f"while [ ! -e {release} ]; do sleep 0.1; done; printf '\\033]7501;state=working\\033\\\\'; {agent}\n",
        },
    )
    _needs_input("permission")(workspace_id, surface_id)
    _wait_agent_state(c, workspace_id, surface_id, "blocked")
    (work_dir / release).touch()

    def unsigned_working_shows() -> bool:
        row = _agent_row(c, workspace_id, surface_id)
        return row.get("agent_state") == "working" and row.get("agent_state_source") == "program"

    _wait_for(unsigned_working_shows, timeout_s=10.0)
    _expect_approval_refusal("surface.send_key", {"surface_id": surface_id, "key": "enter"}, surface_id, source="program")

    subprocess.run(["pkill", "-f", agent], check=False)
    tag = f"EXI{STAMP}"
    last: Dict[str, Any] = {}

    def delivered() -> bool:
        nonlocal last
        last = _call_full("surface.send_text", {"surface_id": surface_id, "text": f'echo {tag[:3]}""{tag[3:]}\n'})
        return last.get("ok") is True

    try:
        _wait_for(delivered, timeout_s=10.0, step_s=0.2)
    except Exception as exc:
        raise ProgramaClientError(f"the refusal outlived the agent's exit: {last!r}") from exc
    _wait_for(lambda: tag in _screen_lines(c, surface_id), timeout_s=10.0)


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    work_dir = Path(tempfile.mkdtemp(prefix="programa_approval_gate_"))
    workspace_id = ""

    try:
        with ProgramaClient(SOCKET_PATH) as c:
            created = c._call("workspace.create", {"cwd": str(work_dir)}, timeout_s=15.0) or {}
            workspace_id = str(created.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
            c.select_workspace(workspace_id)
            rows = list((c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or [])
            _must(len(rows) >= 1, f"Expected an initial terminal surface: {rows}")
            sid = str(rows[0].get("id") or "")
            _wait_for_surface_command_roundtrip(c, workspace_id, sid)
            # File names below are relative and short so no command line wraps on screen.
            _expect_ok("surface.send_text", {"surface_id": sid, "text": f"cd '{work_dir}' && echo IN\"\"DIR{STAMP}\n"})
            _wait_for(lambda: f"INDIR{STAMP}" in _screen_lines(c, sid), timeout_s=10.0)

            # 1. agent.needs_input kind=permission (Claude Code's and Codex's permission hook).
            _check_refused_then_answered(c, workspace_id, sid, work_dir, "a", _needs_input("permission"), "send_text")
            print("  PASS: needs_input permission refuses all five writes; answer_prompt delivers")

            # 2. agent.event request.opened maps to a permission prompt.
            _check_refused_then_answered(c, workspace_id, sid, work_dir, "b", _agent_event("request.opened"), "agent.prompt")
            print("  PASS: agent.event request.opened refuses all five writes; agent.prompt answer_prompt delivers")

            # 3. Questions and kindless blocked reports leave writes alone.
            _check_not_refused(c, workspace_id, sid, "q", _needs_input("question"))
            _check_not_refused(c, workspace_id, sid, "n", _needs_input(None))
            _check_not_refused(c, workspace_id, sid, "u", _agent_event("user-input.requested"))
            _check_not_refused(c, workspace_id, sid, "r", _report_blocked)
            print("  PASS: question, kindless and report_agent_state blocked prompts do not refuse writes")

            # 4. A printed, unsigned OSC 7501 `working` does not lift a permission refusal.
            _check_unsigned_working_keeps_refusal(c, workspace_id, sid, work_dir)
            print("  PASS: an unsigned working report keeps the refusal; answer_prompt delivers")

            # 5. The agent exiting at the prompt, as the shell reports it, lifts the refusal.
            _check_agent_exit_lifts_refusal(c, workspace_id, sid, work_dir)
            print("  PASS: the shell returning to its prompt lifts the refusal")
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
        for path in work_dir.glob("*"):
            path.unlink(missing_ok=True)
        try:
            work_dir.rmdir()
        except OSError:
            pass

    print("PASS: socket writes never answer an agent's permission prompt")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
