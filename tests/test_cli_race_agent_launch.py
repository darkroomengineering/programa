#!/usr/bin/env python3
"""Behavioral contract for the command `programa race` types to start each agent.

Runs the built CLI against a fake unix-socket server (the harness from
`test_cli_registry_behavior.py`) inside a scratch git repo and checks the text
sent with `surface.send_text`:

  - claude and codex get the prompt as one shell-quoted positional argument
  - opencode gets it through `--prompt`, since OpenCode reads a bare argument
    as the project path
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from typing import Any

from test_cli_registry_behavior import CLI_PATH, SocketRecorder, merged_output, run_cli


PROMPT = "fix the bug in Bob's parser"
QUOTED_PROMPT = "'fix the bug in Bob'\\''s parser'"


class RaceRecorder(SocketRecorder):
    def _result_for(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "worktree.create":
            return {
                "workspace_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                "workspace_ref": "workspace:5",
                "worktree": {"path": "/tmp/fake-race-worktree", "branch": params.get("branch")},
            }
        return super()._result_for(method, params)


def main() -> int:
    if not CLI_PATH or not os.path.isfile(CLI_PATH) or not os.access(CLI_PATH, os.X_OK):
        print("FAIL: PROGRAMA_CLI_BIN must point to an executable programa CLI")
        return 1
    git = shutil.which("git")
    if not git:
        print("FAIL: git must be on PATH")
        return 1

    failures: list[str] = []
    expected = {
        "claude": f"claude {QUOTED_PROMPT}\n",
        "codex": f"codex {QUOTED_PROMPT}\n",
        "opencode": f"opencode --prompt {QUOTED_PROMPT}\n",
    }

    with tempfile.TemporaryDirectory(prefix="pwtr-", dir="/tmp") as root:
        repo = os.path.join(root, "repo")
        os.makedirs(repo)
        subprocess.run([git, "init", "-q", repo], check=True)
        os.chdir(repo)

        for agent, command in expected.items():
            socket_dir = tempfile.mkdtemp(prefix="s", dir=root)
            with RaceRecorder(socket_dir) as recorder:
                try:
                    process = run_cli(recorder.path, ["race", "--n", "1", "--agent", agent, PROMPT])
                except subprocess.TimeoutExpired:
                    failures.append(f"{agent}: CLI timed out")
                    continue
            failures.extend(f"{agent}: {error}" for error in recorder.errors)
            if process.returncode != 0:
                failures.append(f"{agent}: exit {process.returncode}: {merged_output(process)}")
                continue
            sends = [frame for frame in recorder.frames if frame.get("method") == "surface.send_text"]
            if len(sends) != 1:
                failures.append(f"{agent}: expected one surface.send_text, got {len(sends)}")
                continue
            text = sends[0].get("params", {}).get("text")
            if text != command:
                failures.append(f"{agent}: typed {text!r}, expected {command!r}")

    if failures:
        print("FAIL: race agent launch command")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: race agent launch command")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
