#!/usr/bin/env python3
"""OSC 7501 Program Status Protocol end-to-end test (docs/plans/osc7501-program-status.md, T-14).

Drives real terminal output: each case runs `printf '\\033]7501;...\\033\\\\'` in the surface's shell,
then asserts through `surface.wait` (`agent_state` / `program_state`) and `surface.list`
(`program_status`, `agent_state`, `agent_state_source`).

Wire shape asserted (plan D8): `program_status` is null or
{state, kind, progress, app, has_message, updated_at}; it never carries `msg`/`title`.
For a program-owned surface, done and error read as legacy `idle`.

Shell prompts and `working`/`blocked`: a prompt (OSC 133;A) drops working and blocked records, so
every case that needs `working`/`blocked` to stay visible keeps the command running with `sleep`
until the assertions finish. Case 4 does not depend on the test shell's own integration: it prints
the 133;A sequence itself, so it passes whether or not the shell emits one.

Must run against a tagged build's socket (root CLAUDE.md "Testing policy"). CI-only.
"""

from __future__ import annotations

import base64
import os
import re
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from v2_support import must as _must, wait_for as _wait_for  # noqa: E402
from pane_resize_test_support import (  # noqa: E402
    scrollback_has_exact_line as _scrollback_has_exact_line,
    surface_scrollback_text as _surface_scrollback_text,
    wait_for_surface_command_roundtrip as _wait_for_surface_command_roundtrip,
)


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")

WAIT_TIMEOUT_MS = 10_000
# Long enough that a held `sleep` outlives one case's assertions; _reset sends ctrl+c before
# the next case so the shell is free again.
HOLD_S = 12

OSC = "\\033]7501;"
ST = "\\033\\\\"
PROMPT_MARK = "printf '\\033]133;A\\033\\\\'"
RIS = "printf '\\033c'"


def _send_raw(client: ProgramaClient, surface_id: str, text: str) -> None:
    """Send text without ProgramaClient.send_surface's backslash unescaping, which would
    collapse the double backslash of the string terminator before the shell sees it."""
    client._call("surface.send_text", {"surface_id": surface_id, "text": text})


def _osc(body: str) -> str:
    return f"printf '{OSC}{body}{ST}'"


def _run(client: ProgramaClient, surface_id: str, command: str) -> None:
    _send_raw(client, surface_id, command + "\n")


def _emit_held(client: ProgramaClient, surface_id: str, body: str, hold_s: int = HOLD_S) -> None:
    """Emit one OSC 7501 and keep the command running so no prompt (133;A) drops the record."""
    _run(client, surface_id, f"{_osc(body)}; sleep {hold_s}")


def _emit_marked(client: ProgramaClient, workspace_id: str, surface_id: str, commands: list[str]) -> None:
    """Run commands then echo a unique marker and wait for the marker line. Proves the shell
    executed every printf before the caller asserts a negative (no change)."""
    marker = f"PROGRAMA_7501_{secrets.token_hex(4)}"
    _run(client, surface_id, "; ".join(commands + [f"echo {marker}"]))
    _wait_for(
        lambda: _scrollback_has_exact_line(client, workspace_id, surface_id, marker),
        timeout_s=10.0,
    )


def _wait(
    client: ProgramaClient, workspace_id: str, surface_id: str, *, timeout_ms: int = WAIT_TIMEOUT_MS, **cond: str
) -> dict:
    params = {"workspace_id": workspace_id, "surface_id": surface_id, "timeout_ms": timeout_ms, **cond}
    # Client-side read timeout must exceed the server-side wait timeout.
    return client._call("surface.wait", params, timeout_s=(timeout_ms / 1000.0) + 5.0) or {}


def _surface(client: ProgramaClient, workspace_id: str, surface_id: str) -> dict:
    listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    for row in listed.get("surfaces") or []:
        if str(row.get("id")) == surface_id:
            return row
    raise ProgramaClientError(f"surface {surface_id} not in surface.list: {listed}")


def _poll_surface(client, workspace_id, surface_id, pred, what: str, timeout_s: float = 10.0) -> dict:
    """Poll surface.list with a deadline, for conditions surface.wait cannot express."""
    deadline = time.time() + timeout_s
    last: dict = {}
    while time.time() < deadline:
        last = _surface(client, workspace_id, surface_id)
        if pred(last):
            return last
        time.sleep(0.1)
    raise ProgramaClientError(f"timed out waiting for {what}; last surface entry: {last}")


def _reset(client: ProgramaClient, workspace_id: str, surface_id: str) -> None:
    """Interrupt any held command, then RIS clears every record (case 10 asserts RIS itself)."""
    client._call("surface.send_key", {"surface_id": surface_id, "key": "ctrl+c"})
    _emit_marked(client, workspace_id, surface_id, [RIS])
    _poll_surface(
        client, workspace_id, surface_id,
        lambda s: s.get("program_status") is None, "program_status null after RIS",
    )


def _must_have_no_text_fields(status: dict, where: str) -> None:
    for banned in ("msg", "title", "message", "children"):
        _must(banned not in status, f"{where}: program_status must not expose {banned!r}: {status}")


def main() -> int:
    workspace_id = ""

    try:
        with ProgramaClient(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            client.select_workspace(workspace_id)
            surfaces = client.list_surfaces(workspace_id)
            _must(bool(surfaces), f"new workspace should have at least one surface: {surfaces}")
            surface_id = surfaces[0][1]
            _wait_for_surface_command_roundtrip(client, workspace_id, surface_id)

            baseline = _surface(client, workspace_id, surface_id)
            _must(baseline.get("program_status") is None, f"program_status should start null: {baseline}")

            # 1. working -> agent_state working, source program, program_status.state working.
            _emit_held(client, surface_id, "state=working:app=fake")
            res = _wait(client, workspace_id, surface_id, program_state="working")
            _must(res.get("program_state") == "working", f"case 1 wait: {res}")
            row = _surface(client, workspace_id, surface_id)
            ps = row.get("program_status") or {}
            _must(row.get("agent_state") == "working", f"case 1 agent_state: {row}")
            _must(row.get("agent_state_source") == "program", f"case 1 agent_state_source: {row}")
            _must(ps.get("state") == "working" and ps.get("app") == "fake", f"case 1 program_status: {ps}")
            _must(isinstance(ps.get("updated_at"), (int, float)), f"case 1 updated_at: {ps}")
            _must_have_no_text_fields(ps, "case 1")
            agent_wait = _wait(client, workspace_id, surface_id, agent_state="working")
            _must(agent_wait.get("state") == "working", f"case 1 agent_state wait: {agent_wait}")

            # 2. blocked with kind=permission.
            _reset(client, workspace_id, surface_id)
            _emit_held(client, surface_id, "state=blocked:kind=permission")
            res = _wait(client, workspace_id, surface_id, program_state="blocked")
            _must(res.get("program_state") == "blocked", f"case 2 wait: {res}")
            row = _surface(client, workspace_id, surface_id)
            ps = row.get("program_status") or {}
            _must(row.get("agent_state") == "blocked", f"case 2 agent_state: {row}")
            _must(ps.get("state") == "blocked" and ps.get("kind") == "permission", f"case 2 program_status: {ps}")

            # 3. done with a base64 msg: reads as idle, has_message true, message text never on the wire.
            _reset(client, workspace_id, surface_id)
            secret_text = f"secret-body-{secrets.token_hex(6)}"
            b64 = base64.b64encode(secret_text.encode()).decode()
            _emit_marked(client, workspace_id, surface_id, [_osc(f"state=done:msg={b64}")])
            res = _wait(client, workspace_id, surface_id, program_state="done")
            _must(res.get("program_state") == "done", f"case 3 wait: {res}")
            row = _surface(client, workspace_id, surface_id)
            ps = row.get("program_status") or {}
            _must(row.get("agent_state") == "idle", f"case 3 done must read as agent_state idle: {row}")
            _must(row.get("agent_state_source") == "program", f"case 3 source: {row}")
            _must(ps.get("state") == "done" and ps.get("has_message") is True, f"case 3 program_status: {ps}")
            _must_have_no_text_fields(ps, "case 3")
            for payload in (res, row):
                blob = repr(payload)
                _must(secret_text not in blob and b64 not in blob, f"case 3 message leaked onto the wire: {payload}")

            # 4. A prompt (133;A) drops working but keeps done and error. 133;A is printed
            #    explicitly so the case does not depend on the test shell's own integration.
            _reset(client, workspace_id, surface_id)
            _emit_marked(client, workspace_id, surface_id, [_osc("state=working"), PROMPT_MARK])
            _poll_surface(
                client, workspace_id, surface_id,
                lambda s: s.get("program_status") is None, "case 4 working dropped by prompt",
            )
            _emit_marked(client, workspace_id, surface_id, [_osc("state=done"), PROMPT_MARK])
            row = _surface(client, workspace_id, surface_id)
            _must((row.get("program_status") or {}).get("state") == "done", f"case 4 done must survive a prompt: {row}")
            _emit_marked(client, workspace_id, surface_id, [_osc("state=error"), PROMPT_MARK])
            row = _surface(client, workspace_id, surface_id)
            _must((row.get("program_status") or {}).get("state") == "error", f"case 4 error must survive a prompt: {row}")
            _must(row.get("agent_state") == "idle", f"case 4 error must read as idle: {row}")

            # 5. Authority. Hooks idle cannot end a program working claim; while the program
            #    says done, a hooks working is accepted.
            _reset(client, workspace_id, surface_id)
            _emit_held(client, surface_id, "state=working")
            _wait(client, workspace_id, surface_id, program_state="working")
            client._call(
                "surface.report_agent_state",
                {"workspace_id": workspace_id, "surface_id": surface_id, "state": "idle"},
            )
            row = _surface(client, workspace_id, surface_id)
            _must(row.get("agent_state") == "working", f"case 5 hooks idle must not override program working: {row}")
            _must(row.get("agent_state_source") == "program", f"case 5 source after hooks idle: {row}")
            _reset(client, workspace_id, surface_id)
            _emit_marked(client, workspace_id, surface_id, [_osc("state=done")])
            _wait(client, workspace_id, surface_id, program_state="done")
            client._call(
                "surface.report_agent_state",
                {"workspace_id": workspace_id, "surface_id": surface_id, "state": "working"},
            )
            row = _surface(client, workspace_id, surface_id)
            _must(row.get("agent_state") == "working", f"case 5 hooks working must win over program done: {row}")
            _must(row.get("agent_state_source") == "hooks", f"case 5 source after hooks working: {row}")

            # 6. A socket client cannot impersonate the terminal tier.
            error_text = ""
            try:
                client._call(
                    "surface.report_agent_state",
                    {"workspace_id": workspace_id, "surface_id": surface_id, "state": "working", "source": "program"},
                )
            except ProgramaClientError as exc:
                error_text = str(exc)
            _must("invalid_params" in error_text, f"case 6 source=program must be invalid_params, got: {error_text!r}")

            # 7. Child records. Children are not on the wire, so assert the root is unaffected and
            #    a later root update still applies, including after 257 children (cap is 256).
            _reset(client, workspace_id, surface_id)
            _emit_held(client, surface_id, "state=working:app=root")
            _wait(client, workspace_id, surface_id, program_state="working")
            # Held command owns the shell; children go through a second surface-less path: wait
            # for the hold to finish by interrupting it, then re-assert the root via a done record
            # that survives prompts.
            client._call("surface.send_key", {"surface_id": surface_id, "key": "ctrl+c"})
            _emit_marked(client, workspace_id, surface_id, [
                _osc("state=done:app=root"),
                _osc("state=working:id=a"),
                _osc("state=working:id=a/b"),
                _osc("state=clear:id=a"),
            ])
            ps = _surface(client, workspace_id, surface_id).get("program_status") or {}
            _must(ps.get("state") == "done" and ps.get("app") == "root", f"case 7 root must be unaffected by child ops: {ps}")
            flood = f"for i in $(seq 1 257); do printf '{OSC}state=working:id=c%s{ST}' \"$i\"; done"
            _emit_marked(client, workspace_id, surface_id, [flood])
            _emit_marked(client, workspace_id, surface_id, [_osc("state=error:app=root")])
            ps = _surface(client, workspace_id, surface_id).get("program_status") or {}
            _must(ps.get("state") == "error", f"case 7 root update must still apply after 257 child records: {ps}")

            # 8. Malformed input changes nothing: control char in decoded msg, unknown state.
            _reset(client, workspace_id, surface_id)
            _emit_marked(client, workspace_id, surface_id, [_osc("state=done:app=keep")])
            before = _surface(client, workspace_id, surface_id).get("program_status") or {}
            _must(before.get("state") == "done", f"case 8 precondition: {before}")
            bad_b64 = base64.b64encode(b"bad\x07body").decode()  # decodes to a BEL control char
            _emit_marked(client, workspace_id, surface_id, [
                _osc(f"state=done:app=keep:msg={bad_b64}"),
                _osc("state=bogus"),
            ])
            after = _surface(client, workspace_id, surface_id).get("program_status") or {}
            _must(
                after.get("state") == "done" and after.get("app") == "keep"
                and after.get("has_message") is False
                and after.get("updated_at") == before.get("updated_at"),
                f"case 8 malformed sequences must not change program_status: before={before} after={after}",
            )

            # 9. Query smoke check; the byte-exact reply is covered by the T-3 Zig test.
            _reset(client, workspace_id, surface_id)
            _run(
                client, surface_id,
                "stty -echo; printf '\\033]7501;?\\033\\\\'; IFS= read -r -t 2 -d $'\\\\' reply; stty echo; "
                "printf 'REPLY=%q\\n' \"$reply\"",
            )
            reply_re = re.compile(r"^REPLY=.*7501")
            _wait_for(
                lambda: any(
                    reply_re.match(line.strip()) and "%q" not in line
                    for line in _surface_scrollback_text(client, workspace_id, surface_id).splitlines()
                ),
                timeout_s=10.0,
            )

            # 10. RIS clears everything.
            _emit_held(client, surface_id, "state=working:app=ris")
            _wait(client, workspace_id, surface_id, program_state="working")
            client._call("surface.send_key", {"surface_id": surface_id, "key": "ctrl+c"})
            _emit_marked(client, workspace_id, surface_id, [RIS])
            row = _poll_surface(
                client, workspace_id, surface_id,
                lambda s: s.get("program_status") is None, "case 10 program_status null after RIS",
            )
            _must(row.get("agent_state_source") != "program", f"case 10 source after RIS: {row}")

            client.close_workspace(workspace_id)
            workspace_id = ""
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: OSC 7501 program status drives agent_state and program_status per spec")
    return 0


if __name__ == "__main__":
    sys.exit(main())
