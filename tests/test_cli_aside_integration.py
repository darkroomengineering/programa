#!/usr/bin/env python3
"""`programa aside` finds Aside's DevTools endpoint and registers Programa inside Aside.

`status` reads `~/Library/Application Support/Aside/DevToolsActivePort` and reports the
WebSocket endpoint only while its port accepts connections. `install-mcp` also sets
`mcp.servers.programa` in the signed-in account's `~/.aside/u/<id>/settings.json`, keeping
every other key; `uninstall-mcp` removes it and its tool inventory. A user's own `programa`
server is never replaced or removed, and nothing changes without consent.

Runs a copy of the built CLI under a temporary HOME with fake `aside` and `claude` binaries.
No socket, no app and no real Aside are involved.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
STRIPPED_ENV = (
    "PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID",
    "PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
)
ACCOUNT_ID = 7

FAKE_CLAUDE = r"""#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_MCP_STATE/calls.log"
case "$1 $2" in
  "mcp get") [[ -f "$FAKE_MCP_STATE/server-$3" ]] ;;
  "mcp add")
    name=""; for arg in "$@"; do [[ "$arg" == "--" ]] && break; name="$arg"; done
    touch "$FAKE_MCP_STATE/server-$name" ;;
  "mcp remove") rm -f "$FAKE_MCP_STATE/server-${@: -1}" ;;
  *) exit 2 ;;
esac
"""

UNRELATED_SETTINGS = {
    "defaultModel": "some-model",
    "experimental": {"flag": True, "ratio": 0.5},
    "customModels": [],
    "mcp": {
        "toolInventoryMigrationVersion": 2,
        "servers": {
            "other": {"enabled": True, "transport": "streamable-http", "url": "https://example.test/mcp", "auth": {"type": "none"}},
        },
        "inventories": {"other": {"tools": [], "refreshedAt": "2026-10-01T00:00:00Z"}},
    },
}


def make_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Sandbox:
    def __init__(self, root: str, with_aside_home: bool = True) -> None:
        self.root = Path(root)
        self.home = self.root / "home"
        self.home.mkdir(parents=True)
        bin_dir = self.root / "bundle-bin"
        bin_dir.mkdir()
        self.cli = bin_dir / "programa"
        shutil.copy2(CLI_PATH, self.cli)
        self.mcp_binary = bin_dir / "programa-mcp"
        make_executable(self.mcp_binary, "#!/bin/sh\nexit 0\n")
        make_executable(self.home / ".local/bin/aside", "#!/bin/sh\nexit 0\n")
        self.fake_bin = self.root / "fake-bin"
        make_executable(self.fake_bin / "claude", FAKE_CLAUDE)
        self.state = self.root / "mcp-state"
        self.state.mkdir()
        self.user_data_dir = self.home / "Library/Application Support/Aside"
        self.user_data_dir.mkdir(parents=True)
        self.settings_path = self.home / f".aside/u/{ACCOUNT_ID}/settings.json"
        if with_aside_home:
            self.settings_path.parent.mkdir(parents=True)
            (self.home / ".aside/accounts.json").write_text(
                json.dumps({"currentAccountId": ACCOUNT_ID, "accounts": [{"token": "secret"}]}), encoding="utf-8"
            )
            self.write_settings(UNRELATED_SETTINGS)

    def write_settings(self, settings: dict) -> None:
        self.settings_path.write_text(json.dumps(settings, indent=2), encoding="utf-8")
        self.settings_path.chmod(0o600)

    def settings(self) -> dict:
        return json.loads(self.settings_path.read_text(encoding="utf-8"))

    def calls(self) -> list[str]:
        log = self.state / "calls.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def run(self, *args: str, consent: bool = True) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        for key in STRIPPED_ENV:
            env.pop(key, None)
        sock = str(self.root / "no-such.sock")
        env.update(
            HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), FAKE_MCP_STATE=str(self.state),
            PATH=f"{self.fake_bin}:/usr/bin:/bin", PROGRAMA_SOCKET=sock, PROGRAMA_SOCKET_PATH=sock,
        )
        return subprocess.run(
            [str(self.cli), "aside", *args, *(["--yes"] if consent else [])],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=60, env=env,
        )


def unused_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class AsideIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self.tmp = tempfile.TemporaryDirectory(prefix="pcli-aside-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)

    def assertOK(self, proc: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")

    def expected_entry(self, box: Sandbox) -> dict:
        return {"enabled": True, "transport": "stdio", "command": str(box.mcp_binary), "args": [], "env": {}}

    def test_status_reports_the_endpoint_from_devtools_active_port(self) -> None:
        box = Sandbox(self.tmp.name)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            port = listener.getsockname()[1]
            (box.user_data_dir / "DevToolsActivePort").write_text(f"{port}\n/devtools/browser/abc-123\n", encoding="utf-8")
            proc = box.run("status", consent=False)
        self.assertOK(proc)
        self.assertIn(f"DevTools: ws://127.0.0.1:{port}/devtools/browser/abc-123", proc.stdout)

    def test_status_says_remote_debugging_is_off_without_a_live_port(self) -> None:
        box = Sandbox(self.tmp.name)
        cases = {
            "missing file": None,
            "stale port": f"{unused_port()}\n/devtools/browser/stale\n",
            "garbage": "not-a-port\n",
        }
        for label, content in cases.items():
            with self.subTest(label):
                port_file = box.user_data_dir / "DevToolsActivePort"
                port_file.unlink(missing_ok=True)
                if content is not None:
                    port_file.write_text(content, encoding="utf-8")
                proc = box.run("status", consent=False)
                self.assertOK(proc)
                self.assertIn("remote debugging is off", proc.stdout)
                self.assertIn("chrome://inspect/#remote-debugging", proc.stdout)
                self.assertNotIn("ws://", proc.stdout)

    def test_install_registers_programa_in_aside_and_uninstall_removes_it(self) -> None:
        box = Sandbox(self.tmp.name)
        proc = box.run("install-mcp")
        self.assertOK(proc)
        self.assertIn("set mcp.servers.programa", proc.stdout, "the preview must list the Aside change")
        settings = box.settings()
        entry = settings["mcp"]["servers"]["programa"]
        self.assertEqual(entry, self.expected_entry(box))
        self.assertIsInstance(entry["env"], dict, "Aside rejects a non-object env")
        without_programa = json.loads(json.dumps(settings))
        del without_programa["mcp"]["servers"]["programa"]
        self.assertEqual(without_programa, UNRELATED_SETTINGS, "unrelated keys must survive")
        self.assertEqual(stat.S_IMODE(box.settings_path.stat().st_mode), 0o600)
        self.assertFalse(Path(f"{box.settings_path}.lock").exists(), "Aside's lock must be released")
        self.assertIn("programa registered: " + str(box.mcp_binary), box.run("status", consent=False).stdout)

        written = box.settings_path.read_bytes()
        proc = box.run("install-mcp")
        self.assertOK(proc)
        self.assertNotIn("mcp.servers.programa", proc.stdout, "a reinstall must not plan an Aside change")
        self.assertEqual(box.settings_path.read_bytes(), written)

        settings = box.settings()
        settings["mcp"]["inventories"]["programa"] = {"tools": [], "refreshedAt": "2026-10-02T00:00:00Z"}
        box.write_settings(settings)
        proc = box.run("uninstall-mcp")
        self.assertOK(proc)
        self.assertIn("remove mcp.servers.programa", proc.stdout)
        self.assertEqual(box.settings(), UNRELATED_SETTINGS)
        self.assertIn("programa not registered", box.run("status", consent=False).stdout)

    def test_install_repairs_a_programa_entry_aside_cannot_validate(self) -> None:
        box = Sandbox(self.tmp.name)
        settings = json.loads(json.dumps(UNRELATED_SETTINGS))
        settings["mcp"]["servers"]["programa"] = {
            "enabled": True, "transport": "stdio",
            "command": "/Applications/Programa.app/Contents/Resources/bin/programa-mcp", "args": [], "env": [],
        }
        box.write_settings(settings)
        self.assertOK(box.run("install-mcp"))
        self.assertEqual(box.settings()["mcp"]["servers"]["programa"], self.expected_entry(box))

    def test_foreign_programa_server_is_left_alone(self) -> None:
        box = Sandbox(self.tmp.name)
        foreign = {"enabled": True, "transport": "stdio", "command": "/usr/local/bin/my-own-server", "args": [], "env": {}}
        settings = json.loads(json.dumps(UNRELATED_SETTINGS))
        settings["mcp"]["servers"]["programa"] = foreign
        box.write_settings(settings)
        before = box.settings_path.read_bytes()
        proc = box.run("install-mcp")
        self.assertOK(proc)
        self.assertIn("leaving it unchanged", proc.stdout)
        self.assertOK(box.run("uninstall-mcp"))
        self.assertEqual(box.settings_path.read_bytes(), before)

    def test_without_consent_aside_settings_are_not_changed(self) -> None:
        box = Sandbox(self.tmp.name)
        before = box.settings_path.read_bytes()
        proc = box.run("install-mcp", consent=False)
        self.assertIn("set mcp.servers.programa", proc.stdout)
        self.assertIn("Aborted", proc.stdout)
        self.assertEqual(box.settings_path.read_bytes(), before)
        self.assertEqual([call for call in box.calls() if not call.startswith("mcp get")], [])

    def test_held_aside_lock_blocks_the_write(self) -> None:
        box = Sandbox(self.tmp.name)
        lock = Path(f"{box.settings_path}.lock")
        lock.mkdir()
        before = box.settings_path.read_bytes()
        proc = box.run("install-mcp")
        self.assertEqual(proc.returncode, 1, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
        self.assertIn("Aside is writing", proc.stdout + proc.stderr)
        self.assertEqual(box.settings_path.read_bytes(), before)
        self.assertTrue(lock.is_dir(), "a lock Programa did not take must be left in place")

    def test_missing_aside_home_still_registers_aside_with_claude(self) -> None:
        box = Sandbox(self.tmp.name, with_aside_home=False)
        proc = box.run("install-mcp")
        self.assertOK(proc)
        self.assertIn(".aside not found, skipping", proc.stdout)
        self.assertTrue(any(call.startswith("mcp add --scope user --transport stdio aside ") for call in box.calls()))
        self.assertFalse((box.home / ".aside").exists())

    def test_with_devtools_attaches_through_the_aside_user_data_dir(self) -> None:
        box = Sandbox(self.tmp.name)
        self.assertOK(box.run("install-mcp", "--with-devtools"))
        devtools = [call for call in box.calls() if " aside-devtools " in call]
        self.assertEqual(devtools, [
            "mcp add --scope user --transport stdio aside-devtools -- npx -y chrome-devtools-mcp@latest "
            f"--autoConnect --userDataDir {box.user_data_dir}"
        ])


if __name__ == "__main__":
    unittest.main(verbosity=2)
