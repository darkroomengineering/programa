#!/usr/bin/env python3
"""tmux send-keys explains a refused write in tmux terms (INC-729).

While the agent in a pane waits on a permission prompt, the server refuses every write with
`agent_awaiting_approval` (INC-695). An agent driving Programa through the tmux shim must get a
plain hint that names the `programa` command able to override it, since tmux's own grammar has
no such flag, and never the bare error code. Both a text segment and a key segment are checked,
and neither may reach the pane.

Must run against a tagged build's socket (root CLAUDE.md "Testing policy"). CI-only.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from v2_support import find_cli_binary as _find_cli_binary  # noqa: E402
from v2_support import must as _must  # noqa: E402
from v2_support import wait_for as _wait_for  # noqa: E402


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
STAMP = int(time.time() * 1000) % 100000000


def _run_shim(cli: str, args: List[str]) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        env.pop(var, None)
    cmd = [cli, "--socket", SOCKET_PATH, "__tmux-compat"] + args
    try:
        return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env, timeout=15)
    except subprocess.TimeoutExpired as exc:
        raise ProgramaClientError(f"CLI timed out ({' '.join(cmd)})") from exc


def _expect_tmux_hint(proc: subprocess.CompletedProcess[str], label: str) -> None:
    out = f"{proc.stdout}\n{proc.stderr}"
    _must(proc.returncode != 0, f"{label}: send-keys succeeded into a pane awaiting approval: {out!r}")
    _must("agent_awaiting_approval:" not in out, f"{label}: raw error code leaked: {out!r}")
    _must("waiting on an approval prompt" in out, f"{label}: refusal reason missing: {out!r}")
    _must("Ask the person to answer it in that pane" in out, f"{label}: tmux hint missing: {out!r}")
    _must("programa send --answer-prompt" in out, f"{label}: override command missing: {out!r}")


def main() -> int:
    cli = _find_cli_binary()
    workspace_id = ""
    try:
        with ProgramaClient(SOCKET_PATH) as c:
            workspace_id = c.new_workspace()
            c.select_workspace(workspace_id)
            c.settle()
            panes = [pid for _idx, pid, _count, _focused in c.list_panes()]
            _must(len(panes) >= 1, f"Expected a pane: {panes}")
            rows = list((c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or [])
            _must(len(rows) >= 1, f"Expected a terminal surface: {rows}")
            sid = str(rows[0].get("id") or "")
            target = f"%{panes[0]}"

            c._call("agent.needs_input", {
                "workspace_id": workspace_id,
                "surface_id": sid,
                "provider": "claude-code",
                "title": "Claude Code",
                "body": f"tmux-hint-{STAMP}",
                "kind": "permission",
            })
            _wait_for(
                lambda: any(
                    str(r.get("id")) == sid and r.get("agent_state") == "blocked"
                    for r in (c._call("surface.list", {"workspace_id": workspace_id}) or {}).get("surfaces") or []
                ),
                timeout_s=5.0,
            )

            token = f"TMUXHINT{STAMP}"
            _expect_tmux_hint(_run_shim(cli, ["send-keys", "-t", target, "-l", token]), "text segment")
            _expect_tmux_hint(_run_shim(cli, ["send-keys", "-t", target, "Enter"]), "key segment")
            _must(token not in c.read_terminal_text(sid), "refused send-keys text reached the pane")
            print("  PASS: tmux send-keys shows the tmux hint for agent_awaiting_approval and sends nothing")
    finally:
        if workspace_id:
            try:
                with ProgramaClient(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
