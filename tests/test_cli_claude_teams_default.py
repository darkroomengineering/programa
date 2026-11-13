#!/usr/bin/env python3
"""Contract (INC-258): plain `claude` in a Programa terminal starts with agent teams on.

Runs the bundled `claude` wrapper (Resources/bin/claude) next to the built CLI against a fake
socket and a fake real `claude` that records its argv and environment. No app is involved.

- By default the wrapper hands off to `programa claude-teams`: the real claude sees
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, the tmux shim on PATH and --teammate-mode auto,
  anchored on the launching pane rather than the focused one, and still gets the hooks.
- An explicit CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS (here 0) is passed through untouched.
- automation.claudeTeamsByDefault off (PROGRAMA_CLAUDE_TEAMS_DISABLED=1) leaves teams unset.
- A real tmux session and a Claude Code too old for teams keep the plain launch.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

from test_cli_registry_behavior import SURFACE_ID, WINDOW_ID, WORKSPACE_ID, SocketRecorder

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
WRAPPER_DIR = Path(__file__).resolve().parent.parent / "Resources" / "bin"
CALLER_PANE_ID = "aaaaaaaa-0000-0000-0000-000000000001"
FOCUSED_PANE_ID = "bbbbbbbb-0000-0000-0000-000000000002"
FOCUSED_WORKSPACE_ID = "cccccccc-0000-0000-0000-000000000003"
FOCUSED_SURFACE_ID = "dddddddd-0000-0000-0000-000000000004"
TEAMS_VAR = "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"

FAKE_CLAUDE = """#!{python}
import json, os, sys
if sys.argv[1:2] == ["--help"]:
    sys.exit(0)
if sys.argv[1:2] == ["--version"]:
    print(os.environ.get("FAKE_CLAUDE_VERSION", "2.1.300") + " (Claude Code)")
    sys.exit(0)
with open(os.environ["FAKE_CLAUDE_OUT"], "w") as out:
    json.dump({{"argv": sys.argv[1:], "env": dict(os.environ)}}, out)
"""


class IdentifyRecorder(SocketRecorder):
    """Reports a focused pane that differs from the caller pane named in the request."""

    def _result_for(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method != "system.identify":
            return super()._result_for(method, params)
        caller = params.get("caller") or {}
        result: dict[str, Any] = {
            "focused": {
                "window_id": WINDOW_ID,
                "workspace_id": FOCUSED_WORKSPACE_ID,
                "pane_id": FOCUSED_PANE_ID,
                "surface_id": FOCUSED_SURFACE_ID,
            },
            "caller": None,
        }
        if caller.get("surface_id") == SURFACE_ID and caller.get("workspace_id") == WORKSPACE_ID:
            result["caller"] = {
                "window_id": WINDOW_ID,
                "workspace_id": WORKSPACE_ID,
                "pane_id": CALLER_PANE_ID,
                "surface_id": SURFACE_ID,
            }
        return result


class ClaudeTeamsDefaultTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self._tmp = tempfile.TemporaryDirectory(prefix="pcli-teams-", dir="/tmp")
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.home = root / "home"
        self.home.mkdir()
        self.app_bin = root / "app-bin"
        self.app_bin.mkdir()
        for name in ("claude", "restore-node-options.cjs"):
            shutil.copy2(WRAPPER_DIR / name, self.app_bin / name)
        (self.app_bin / "programa").symlink_to(CLI_PATH)
        real_bin = root / "real-bin"
        real_bin.mkdir()
        fake = real_bin / "claude"
        fake.write_text(FAKE_CLAUDE.format(python=sys.executable), encoding="utf-8")
        fake.chmod(0o755)
        self.path = f"{self.app_bin}:{real_bin}:/usr/bin:/bin"
        self.out = root / "claude-run.json"

    def launch(self, extra_env: dict[str, str] | None = None) -> dict[str, Any]:
        with IdentifyRecorder(self._tmp.name) as recorder:
            env = {
                key: value for key, value in os.environ.items()
                if not key.startswith(("PROGRAMA_", "_PROGRAMA_", "CLAUDE_CODE_", "TMUX"))
                and key not in {"STY", "NODE_OPTIONS", "CLAUDECODE"}
            }
            env.update(
                HOME=str(self.home),
                CFFIXED_USER_HOME=str(self.home),
                PATH=self.path,
                PROGRAMA_SURFACE_ID=SURFACE_ID,
                PROGRAMA_WORKSPACE_ID=WORKSPACE_ID,
                PROGRAMA_SOCKET_PATH=recorder.path,
                PROGRAMA_SOCKET=recorder.path,
                FAKE_CLAUDE_OUT=str(self.out),
            )
            env.update(extra_env or {})
            proc = subprocess.run(
                [str(self.app_bin / "claude"), "--model", "sonnet"],
                stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=30, env=env,
            )
        self.assertEqual(recorder.errors, [])
        self.assertEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
        self.assertTrue(self.out.exists(), f"real claude never ran: stderr={proc.stderr!r}")
        run = json.loads(self.out.read_text(encoding="utf-8"))
        run["identify_frames"] = [f for f in recorder.frames if f.get("method") == "system.identify"]
        return run

    def assert_plain_launch(self, run: dict[str, Any]) -> None:
        self.assertNotIn("--teammate-mode", run["argv"])
        self.assertNotIn("claude-teams-bin", run["env"]["PATH"])
        self.assertIn("--settings", run["argv"], "the plain launch still injects hooks")
        self.assertEqual(run["argv"][-2:], ["--model", "sonnet"])

    def test_plain_claude_turns_teams_on_with_pane_plumbing(self) -> None:
        run = self.launch()
        env, argv = run["env"], run["argv"]
        self.assertEqual(env.get(TEAMS_VAR), "1")
        self.assertEqual(argv[:2], ["--teammate-mode", "auto"])
        self.assertIn("--settings", argv, "hooks must survive the claude-teams hand-off")
        self.assertEqual(argv[-2:], ["--model", "sonnet"])
        shim_dir = str(self.home / ".programa" / "claude-teams-bin")
        self.assertEqual(env["PATH"].split(":")[0], shim_dir)
        self.assertTrue(os.access(os.path.join(shim_dir, "tmux"), os.X_OK))
        # Anchored on the pane claude was launched in, not the focused pane.
        self.assertTrue(env.get("TMUX", "").startswith(f"/tmp/programa-claude-teams/{WORKSPACE_ID},"), env.get("TMUX"))
        self.assertEqual(env.get("TMUX_PANE"), f"%{CALLER_PANE_ID}")
        self.assertEqual(env.get("PROGRAMA_SURFACE_ID"), SURFACE_ID)
        self.assertEqual(env.get("PROGRAMA_WORKSPACE_ID"), WORKSPACE_ID)
        self.assertTrue(run["identify_frames"], "claude-teams never identified its pane")
        # Claude skips its own status under the fake TMUX, so the hooks must keep reporting it.
        self.assertNotIn("PROGRAMA_CLAUDE_NATIVE_STATUS", env)
        # One restore module, from the wrapper; claude-teams must not wrap NODE_OPTIONS again.
        self.assertEqual(env.get("NODE_OPTIONS", "").count("--require="), 1, env.get("NODE_OPTIONS"))
        self.assertEqual(env.get("PROGRAMA_ORIGINAL_NODE_OPTIONS_PRESENT"), "0")

    def test_explicit_zero_is_preserved(self) -> None:
        run = self.launch({TEAMS_VAR: "0"})
        self.assertEqual(run["env"].get(TEAMS_VAR), "0")
        self.assert_plain_launch(run)

    def test_setting_off_leaves_teams_unset(self) -> None:
        run = self.launch({"PROGRAMA_CLAUDE_TEAMS_DISABLED": "1"})
        self.assertNotIn(TEAMS_VAR, run["env"])
        self.assert_plain_launch(run)

    def test_real_tmux_keeps_plain_launch(self) -> None:
        run = self.launch({"TMUX": "/private/tmp/tmux-501/default,1,0", "TMUX_PANE": "%3"})
        self.assertNotIn(TEAMS_VAR, run["env"])
        self.assertEqual(run["env"].get("TMUX"), "/private/tmp/tmux-501/default,1,0")
        self.assert_plain_launch(run)

    def test_claude_without_teams_support_keeps_plain_launch(self) -> None:
        run = self.launch({"FAKE_CLAUDE_VERSION": "2.1.31"})
        self.assertNotIn(TEAMS_VAR, run["env"])
        self.assert_plain_launch(run)


if __name__ == "__main__":
    unittest.main()
