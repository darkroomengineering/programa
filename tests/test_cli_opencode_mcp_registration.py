#!/usr/bin/env python3
"""`programa opencode install-integration` registers the bundled programa-mcp server with OpenCode.

Install adds `mcp.programa = {"type": "local", "command": ["<dir of the CLI>/programa-mcp"],
"enabled": true}` to `$OPENCODE_CONFIG_DIR/opencode.json` after consent and keeps every other
key; uninstall removes the entry only while it is still that bare form. A user's own `programa`
server, an `opencode.jsonc` file and an `opencode.json` with comments are never rewritten, and
nothing changes without consent.

Runs a copy of the built CLI under a temporary HOME and OPENCODE_CONFIG_DIR. OpenCode itself,
the socket and the app are not involved.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
STRIPPED_ENV = (
    "PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID",
    "PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "OPENCODE_CONFIG_DIR", "XDG_CONFIG_HOME",
)


class Sandbox:
    def __init__(self, root: str, with_mcp_binary: bool = True) -> None:
        self.root = Path(root)
        self.home = self.root / "home"
        self.home.mkdir(parents=True)
        self.config_dir = self.root / "opencode-config"
        self.config_dir.mkdir()
        bin_dir = self.root / "bundle-bin"
        bin_dir.mkdir()
        self.cli = bin_dir / "programa"
        shutil.copy2(CLI_PATH, self.cli)
        self.mcp_binary = bin_dir / "programa-mcp"
        if with_mcp_binary:
            self.mcp_binary.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            self.mcp_binary.chmod(self.mcp_binary.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    @property
    def config_path(self) -> Path:
        return self.config_dir / "opencode.json"

    def entry(self) -> dict[str, object]:
        return {"type": "local", "command": [str(self.mcp_binary)], "enabled": True}

    def config(self) -> dict[str, object] | None:
        if not self.config_path.exists():
            return None
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def write_config(self, config: dict[str, object]) -> None:
        self.config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")

    def run(self, action: str, consent: bool = True) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        for key in STRIPPED_ENV:
            env.pop(key, None)
        sock = str(self.root / "no-such.sock")
        env.update(
            HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), OPENCODE_CONFIG_DIR=str(self.config_dir),
            PATH="/usr/bin:/bin", PROGRAMA_SOCKET=sock, PROGRAMA_SOCKET_PATH=sock,
        )
        return subprocess.run(
            [str(self.cli), "opencode", action, *(["--yes"] if consent else [])],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=60, env=env,
        )


class OpenCodeMCPRegistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self.tmp = tempfile.TemporaryDirectory(prefix="pcli-opencode-mcp-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)

    def assertOK(self, proc: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")

    def test_install_registers_and_uninstall_removes(self) -> None:
        box = Sandbox(self.tmp.name)
        self.assertOK(box.run("install-integration"))
        self.assertEqual(box.config(), {"mcp": {"programa": box.entry()}})

        written = box.config_path.read_text(encoding="utf-8")
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("Nothing to change", proc.stdout, "a reinstall must not change anything")
        self.assertEqual(box.config_path.read_text(encoding="utf-8"), written)

        self.assertOK(box.run("uninstall-integration"))
        self.assertEqual(box.config(), {})

    def test_other_keys_are_preserved(self) -> None:
        box = Sandbox(self.tmp.name)
        user_config = {
            "$schema": "https://opencode.ai/config.json",
            "model": "anthropic/claude-sonnet-4-5",
            "mcp": {"other": {"type": "remote", "url": "https://example.com/mcp", "enabled": True}},
        }
        box.write_config(user_config)
        self.assertOK(box.run("install-integration"))
        expected = json.loads(json.dumps(user_config))
        expected["mcp"]["programa"] = box.entry()
        self.assertEqual(box.config(), expected)

        self.assertOK(box.run("uninstall-integration"))
        self.assertEqual(box.config(), user_config)

    def test_install_updates_a_programa_mcp_from_another_location(self) -> None:
        box = Sandbox(self.tmp.name)
        box.write_config({"mcp": {"programa": {
            "type": "local", "command": ["/Applications/Old Programa.app/Contents/Resources/bin/programa-mcp"], "enabled": True,
        }}})
        self.assertOK(box.run("install-integration"))
        self.assertEqual(box.config(), {"mcp": {"programa": box.entry()}})

    def test_customized_programa_server_is_left_alone(self) -> None:
        customized = (
            {"type": "local", "command": ["/usr/local/bin/my-own-server"], "enabled": True},
            {"type": "local", "command": ["/opt/programa/programa-mcp", "--verbose"], "enabled": True},
            {"type": "local", "command": ["/opt/programa/programa-mcp"], "enabled": True, "environment": {"K": "V"}},
            {"type": "local", "command": ["/opt/programa/programa-mcp"], "enabled": False},
            {"type": "remote", "url": "https://example.com/mcp"},
        )
        for entry in customized:
            with self.subTest(entry=entry):
                box = Sandbox(tempfile.mkdtemp(prefix="sub-", dir=self.tmp.name))
                config = {"mcp": {"programa": entry}}
                box.write_config(config)
                before = box.config_path.read_text(encoding="utf-8")
                proc = box.run("install-integration")
                self.assertOK(proc)
                self.assertIn("leaving it unchanged", proc.stdout)
                self.assertOK(box.run("uninstall-integration"))
                self.assertEqual(box.config_path.read_text(encoding="utf-8"), before)

    def test_jsonc_config_is_left_alone_with_a_note(self) -> None:
        box = Sandbox(self.tmp.name)
        jsonc = box.config_dir / "opencode.jsonc"
        text = '{\n  // my settings\n  "model": "anthropic/claude-sonnet-4-5"\n}\n'
        jsonc.write_text(text, encoding="utf-8")
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("opencode.jsonc is JSONC", proc.stdout)
        self.assertIn(str(box.mcp_binary), proc.stdout, "the note must show the entry to add")
        self.assertEqual(jsonc.read_text(encoding="utf-8"), text)
        self.assertFalse(box.config_path.exists())

    def test_json_with_comments_is_left_alone_with_a_note(self) -> None:
        box = Sandbox(self.tmp.name)
        text = '{\n  // my settings\n  "model": "anthropic/claude-sonnet-4-5"\n}\n'
        box.config_path.write_text(text, encoding="utf-8")
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("is not plain JSON", proc.stdout)
        self.assertEqual(box.config_path.read_text(encoding="utf-8"), text)

    def test_without_consent_config_is_not_changed(self) -> None:
        box = Sandbox(self.tmp.name)
        proc = box.run("install-integration", consent=False)
        self.assertEqual(proc.returncode, 1, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
        self.assertIn("OpenCode MCP server", proc.stdout, "the preview must show the config change")
        self.assertFalse(box.config_path.exists())

    def test_missing_programa_mcp_skips_registration(self) -> None:
        box = Sandbox(self.tmp.name, with_mcp_binary=False)
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("programa-mcp not found", proc.stdout)
        self.assertFalse(box.config_path.exists())
        self.assertTrue((box.config_dir / "plugins" / "programa.js").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
