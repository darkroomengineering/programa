#!/usr/bin/env python3
"""
Regression test for #137: Cmd+Shift+C must instantly create a new workspace in the
current workspace's working directory, boot Claude Code into it via
`initialTerminalCommand: "claude"`, and select it immediately (boot-in-place on
claim -- no pool, no hidden workspaces).

What this asserts, and why:
  1. Workspace count increases by exactly one after the shortcut fires. This is the
     most reliable, environment-independent signal that `createClaudeWorkspace()` ran
     and `TabManager.addWorkspace` created a new workspace (via `workspace.list`).
  2. The newly created workspace is the selected one (`select: true` in the plan).
  3. The literal string "claude" appears in the new workspace's focused terminal
     text within a timeout. `initialTerminalCommand: "claude"` resolves through the
     login shell's PATH exactly like user-typed input, so this assertion holds
     whichever way the CI runner is provisioned:
       - If the `claude` CLI is installed and on PATH, its own startup banner/TUI
         will contain "claude" (case-insensitive) once it boots.
       - If it is not installed, the login shell's own "command not found" error
         echoes the literal command name "claude" back into the terminal.
     Either outcome proves the initial command was actually threaded through to the
     terminal surface. There is no socket-readable way to introspect
     `initialTerminalCommand` directly (it is consumed once at surface-creation time
     and not re-exposed via `workspace.list` or `pane.surfaces`), so reading the
     rendered terminal text is the most direct assertable proxy available.

This test requires app focus (`debug.shortcut.simulate` synthesizes a real key event
routed through the app's key-equivalent handling), which is unreliable when run
against a developer's foregrounded machine. It is expected to run on the CI VM
runner where focus behaves deterministically. It fails loudly (raises) rather than
silently skipping, since CI is expected to always have a focusable, non-occluded
app window.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_new_workspace(c: cmux, baseline_ids: set, timeout_s: float = 8.0):
    deadline = time.time() + timeout_s
    last_rows = []
    while time.time() < deadline:
        rows = c.list_workspaces()
        last_rows = rows
        new_ids = [row for row in rows if row[1] not in baseline_ids]
        if new_ids:
            return rows, new_ids
        time.sleep(0.1)
    raise cmuxError(
        f"Timed out waiting for a new workspace after cmd+shift+c. "
        f"baseline_count={len(baseline_ids)} last_workspaces={last_rows!r}"
    )


def _wait_for_terminal_text_contains(c: cmux, needle_lower: str, timeout_s: float = 12.0) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        try:
            last_text = c.read_terminal_text()
        except Exception:
            last_text = last_text or ""
        if needle_lower in last_text.lower():
            return last_text
        time.sleep(0.2)
    raise cmuxError(
        f"Timed out waiting for {needle_lower!r} in new Claude workspace's terminal text. "
        f"Last text tail: {last_text[-600:]!r}"
    )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        baseline_rows = c.list_workspaces()
        baseline_ids = {row[1] for row in baseline_rows}
        baseline_count = len(baseline_rows)

        created_workspace_id = ""
        try:
            c.simulate_shortcut("cmd+shift+c")

            rows, new_rows = _wait_for_new_workspace(c, baseline_ids, timeout_s=8.0)
            _must(
                len(rows) == baseline_count + 1,
                f"expected workspace count to increase by exactly 1: "
                f"baseline={baseline_count} now={len(rows)}",
            )
            _must(
                len(new_rows) == 1,
                f"expected exactly one new workspace, found: {new_rows!r}",
            )

            _index, created_workspace_id, _title, selected = new_rows[0]
            _must(
                selected,
                f"expected the newly created Claude workspace to be selected immediately: {new_rows[0]!r}",
            )
            _must(
                c.current_workspace() == created_workspace_id,
                "expected current_workspace() to report the newly created Claude workspace",
            )

            _wait_for_terminal_text_contains(c, "claude", timeout_s=12.0)
        finally:
            if created_workspace_id:
                try:
                    c.close_workspace(created_workspace_id)
                except Exception:
                    pass

    print("PASS: cmd+shift+c instantly creates and selects a new Claude Code workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
