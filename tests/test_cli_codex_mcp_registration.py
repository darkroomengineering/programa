#!/usr/bin/env python3
"""`programa codex install-integration` registers the bundled programa-mcp server with Codex.

Install runs `codex mcp add programa -- <dir of the CLI>/programa-mcp` after consent; uninstall
runs `codex mcp remove programa` only when the registered server is a programa-mcp binary. A
user's own server named `programa` is never replaced or removed, and nothing runs without
consent.

Runs a copy of the built CLI under a temporary HOME with a fake `codex` on PATH that records
its calls. No socket and no app are involved.
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
    "PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "CODEX_HOME",
)

FAKE_CODEX = r"""#!/bin/bash
state="$CODEX_HOME/fake-mcp-programa.json"
printf '%s\n' "$*" >> "$CODEX_HOME/fake-codex-calls.log"
case "$1 $2" in
  "mcp get")
    [[ -f "$state" ]] || { echo "Error: No MCP server named '$3' found." >&2; exit 1; }
    cat "$state" ;;
  "mcp add")
    printf '{"name":"%s","transport":{"type":"stdio","command":"%s"}}' "$3" "$5" > "$state" ;;
  "mcp remove")
    rm -f "$state" ;;
  *) exit 2 ;;
esac
"""


def make_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Sandbox:
    def __init__(self, root: str, with_mcp_binary: bool = True, with_codex: bool = True) -> None:
        self.root = Path(root)
        self.home = self.root / "home"
        self.codex_home = self.home / ".codex"
        self.codex_home.mkdir(parents=True)
        bin_dir = self.root / "bundle-bin"
        bin_dir.mkdir()
        self.cli = bin_dir / "programa"
        shutil.copy2(CLI_PATH, self.cli)
        self.mcp_binary = bin_dir / "programa-mcp"
        if with_mcp_binary:
            make_executable(self.mcp_binary, "#!/bin/sh\nexit 0\n")
        self.fake_bin = self.root / "fake-bin"
        self.fake_bin.mkdir()
        if with_codex:
            make_executable(self.fake_bin / "codex", FAKE_CODEX)

    @property
    def state_path(self) -> Path:
        return self.codex_home / "fake-mcp-programa.json"

    def registered_command(self) -> str | None:
        if not self.state_path.exists():
            return None
        return json.loads(self.state_path.read_text(encoding="utf-8"))["transport"]["command"]

    def register(self, command: str, **extra: object) -> None:
        transport = {"type": "stdio", "command": command, **extra}
        self.state_path.write_text(json.dumps({"name": "programa", "transport": transport}), encoding="utf-8")

    def calls(self) -> list[str]:
        log = self.codex_home / "fake-codex-calls.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def mutating_calls(self) -> list[str]:
        return [call for call in self.calls() if not call.startswith("mcp get ")]

    def run(self, action: str, consent: bool = True) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        for key in STRIPPED_ENV:
            env.pop(key, None)
        sock = str(self.root / "no-such.sock")
        env.update(
            HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), CODEX_HOME=str(self.codex_home),
            PATH=f"{self.fake_bin}:/usr/bin:/bin", PROGRAMA_SOCKET=sock, PROGRAMA_SOCKET_PATH=sock,
        )
        return subprocess.run(
            [str(self.cli), "codex", action, *(["--yes"] if consent else [])],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=60, env=env,
        )


class CodexMCPRegistrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self.tmp = tempfile.TemporaryDirectory(prefix="pcli-codex-mcp-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)

    def assertOK(self, proc: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")

    def test_install_registers_and_uninstall_removes(self) -> None:
        box = Sandbox(self.tmp.name)
        expected = str(box.mcp_binary)
        self.assertOK(box.run("install-integration"))
        self.assertEqual(box.registered_command(), expected)
        self.assertEqual(box.mutating_calls(), [f"mcp add programa -- {expected}"])

        self.assertOK(box.run("install-integration"))
        self.assertEqual(box.mutating_calls(), [f"mcp add programa -- {expected}"], "a reinstall must not re-register")

        self.assertOK(box.run("uninstall-integration"))
        self.assertIsNone(box.registered_command())
        self.assertEqual(box.mutating_calls()[-1], "mcp remove programa")

    def test_install_updates_a_programa_mcp_from_another_location(self) -> None:
        box = Sandbox(self.tmp.name)
        box.register("/Applications/Old Programa.app/Contents/Resources/bin/programa-mcp")
        self.assertOK(box.run("install-integration"))
        self.assertEqual(box.registered_command(), str(box.mcp_binary))

    def test_foreign_programa_server_is_left_alone(self) -> None:
        box = Sandbox(self.tmp.name)
        box.register("/usr/local/bin/my-own-server")
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("leaving it unchanged", proc.stdout)
        self.assertEqual(box.registered_command(), "/usr/local/bin/my-own-server")

        self.assertOK(box.run("uninstall-integration"))
        self.assertEqual(box.registered_command(), "/usr/local/bin/my-own-server")
        self.assertEqual(box.mutating_calls(), [])

    def test_customized_programa_mcp_is_left_alone(self) -> None:
        for extra in ({"args": ["--verbose"]}, {"env": {"PROGRAMA_SOCKET_PATH": "/tmp/x.sock"}}, {"env_vars": ["HOME"]}):
            with self.subTest(extra=extra):
                box = Sandbox(tempfile.mkdtemp(prefix="sub-", dir=self.tmp.name))
                box.register("/opt/programa/programa-mcp", **extra)
                proc = box.run("install-integration")
                self.assertOK(proc)
                self.assertIn("leaving it unchanged", proc.stdout)
                self.assertOK(box.run("uninstall-integration"))
                self.assertEqual(box.registered_command(), "/opt/programa/programa-mcp")
                self.assertEqual(box.mutating_calls(), [])

    def test_without_consent_codex_is_not_changed(self) -> None:
        box = Sandbox(self.tmp.name)
        proc = box.run("install-integration", consent=False)
        self.assertEqual(proc.returncode, 1, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
        self.assertIn("mcp add programa", proc.stdout, "the preview must list the Codex command")
        self.assertEqual(box.mutating_calls(), [])
        self.assertIsNone(box.registered_command())

    def test_missing_programa_mcp_skips_registration(self) -> None:
        box = Sandbox(self.tmp.name, with_mcp_binary=False)
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("programa-mcp not found", proc.stdout)
        self.assertEqual(box.mutating_calls(), [])

    def test_missing_codex_still_installs_hooks(self) -> None:
        box = Sandbox(self.tmp.name, with_codex=False)
        proc = box.run("install-integration")
        self.assertOK(proc)
        self.assertIn("Codex CLI not found", proc.stdout)
        self.assertTrue((box.codex_home / "hooks.json").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
