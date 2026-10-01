#!/usr/bin/env python3
"""Regression (CLIX-10): integration installers never apply or abort silently without consent.

`programa <claude|codex|opencode> install-integration` used to exit 0 after "Aborted." when
stdin was not a terminal and no --yes was given, so a script or agent mistook a skipped install
for a successful one. The contract: without --yes/-y and without a TTY the command exits 1,
says "pass --yes" on stderr and leaves the filesystem untouched; --yes and -y both apply.

Runs the built CLI under a temporary HOME. No socket and no app are involved.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
PROVIDERS = ("claude", "codex", "opencode")
STRIPPED_ENV = (
    "PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID",
    "PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
    "OPENCODE_CONFIG_DIR", "XDG_CONFIG_HOME",
)


def run_install(home: str, provider: str, extra: list[str]) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    for key in STRIPPED_ENV:
        env.pop(key, None)
    sock = os.path.join(home, "no-such.sock")
    env.update(HOME=home, CFFIXED_USER_HOME=home, PROGRAMA_SOCKET=sock, PROGRAMA_SOCKET_PATH=sock)
    return subprocess.run(
        [CLI_PATH, provider, "install-integration", *extra],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=30, env=env,
    )


def files_under(home: str) -> list[str]:
    return sorted(str(p.relative_to(home)) for p in Path(home).rglob("*") if p.is_file())


class NonInteractiveInstallTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")

    def test_without_consent_exits_one_and_writes_nothing(self) -> None:
        for provider in PROVIDERS:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory(prefix="pcli-home-", dir="/tmp") as home:
                proc = run_install(home, provider, [])
                self.assertEqual(proc.returncode, 1, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
                self.assertIn("pass --yes", proc.stderr)
                self.assertEqual(files_under(home), [], "an unconfirmed install must not create files")

    def test_yes_and_short_flag_both_apply(self) -> None:
        for provider in PROVIDERS:
            for flag in ("--yes", "-y"):
                with self.subTest(provider=provider, flag=flag), tempfile.TemporaryDirectory(prefix="pcli-home-", dir="/tmp") as home:
                    proc = run_install(home, provider, [flag])
                    self.assertEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
                    self.assertNotEqual(files_under(home), [], "--yes/-y must apply the install")


if __name__ == "__main__":
    unittest.main()
