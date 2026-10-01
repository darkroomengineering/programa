#!/usr/bin/env python3
"""Contract (CLIX-12/13): Claude settings.json keeps user hooks and file permissions.

A user may add their own hook to the group Programa created (same matcher group), and may
tighten settings.json to 0600 because it can hold API keys in `env`. Reinstalling must split
the user's hook out of the Programa group instead of dropping or duplicating it, and neither
install nor uninstall may widen the file mode.

Runs the built CLI under a temporary HOME; no socket and no app are involved.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
MARKER = "programa claude-hook"
USER_COMMAND = "echo user-notify"
STRIPPED_ENV = (
    "PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID",
    "CLAUDE_CONFIG_DIR", "XDG_CONFIG_HOME",
)


class ClaudeSettingsPreservationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self._tmp = tempfile.TemporaryDirectory(prefix="pcli-home-", dir="/tmp")
        self.addCleanup(self._tmp.cleanup)
        self.home = self._tmp.name
        self.settings = Path(self.home) / ".claude" / "settings.json"

    def cli(self, action: str) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        for key in STRIPPED_ENV:
            env.pop(key, None)
        sock = os.path.join(self.home, "no-such.sock")
        env.update(HOME=self.home, CFFIXED_USER_HOME=self.home, PROGRAMA_SOCKET=sock, PROGRAMA_SOCKET_PATH=sock)
        proc = subprocess.run(
            [CLI_PATH, "claude", action, "--yes"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=30, env=env,
        )
        self.assertEqual(proc.returncode, 0, f"{action}: stdout={proc.stdout!r} stderr={proc.stderr!r}")
        return proc

    def load(self) -> dict[str, Any]:
        return json.loads(self.settings.read_text(encoding="utf-8"))

    def mode(self) -> int:
        return stat.S_IMODE(self.settings.stat().st_mode)

    @staticmethod
    def commands(group: dict[str, Any]) -> list[str]:
        return [h.get("command", "") for h in group.get("hooks", [])]

    def test_user_hook_in_programa_group_survives_reinstall_and_uninstall_with_mode_0600(self) -> None:
        self.cli("install-integration")

        data = self.load()
        groups = data["hooks"]["Notification"]
        programa_group = next(g for g in groups if any(MARKER in c for c in self.commands(g)))
        programa_group["hooks"].append({"type": "command", "command": USER_COMMAND})
        self.settings.write_text(json.dumps(data, indent=2), encoding="utf-8")
        os.chmod(self.settings, 0o600)

        self.cli("install-integration")
        self.cli("install-integration")

        groups = self.load()["hooks"]["Notification"]
        self.assertEqual(len(groups), 2, f"expected a user group and one Programa group: {groups}")
        user_groups = [g for g in groups if USER_COMMAND in self.commands(g)]
        programa_groups = [g for g in groups if any(MARKER in c for c in self.commands(g))]
        self.assertEqual(len(user_groups), 1, groups)
        self.assertEqual(len(programa_groups), 1, groups)
        self.assertEqual(self.commands(user_groups[0]), [USER_COMMAND], "the user hook must not share a group with Programa's")
        self.assertEqual(groups.index(user_groups[0]), 0, "the user's group keeps its position ahead of Programa's")
        self.assertEqual(self.mode(), 0o600, "reinstall must not widen settings.json permissions")

        self.cli("uninstall-integration")

        remaining = self.load().get("hooks", {}).get("Notification", [])
        self.assertEqual([self.commands(g) for g in remaining], [[USER_COMMAND]])
        self.assertEqual(self.mode(), 0o600, "uninstall must not widen settings.json permissions")


if __name__ == "__main__":
    unittest.main()
