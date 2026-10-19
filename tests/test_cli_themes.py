#!/usr/bin/env python3
"""`programa themes` lists and sets themes in Swift, with no bundled ghostty helper.

Runs the built CLI under a temporary HOME with GHOSTTY_RESOURCES_DIR pointing at a scratch
theme directory. No socket and no app are involved; PROGRAMA_BUNDLE_ID targets a bundle id
nothing listens on, so the reload request reaches no running Programa.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
THEMES = ("Catppuccin Mocha", "Catppuccin Latte", "Nord")


def run_cli(home: str, resources: str, *args: str) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    for key in ("PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "XDG_CONFIG_HOME", "XDG_DATA_DIRS"):
        env.pop(key, None)
    env.update(
        HOME=home,
        CFFIXED_USER_HOME=home,
        GHOSTTY_RESOURCES_DIR=resources,
        PROGRAMA_BUNDLE_ID="invalid.programa.themes.test",
    )
    return subprocess.run(
        [CLI_PATH, *args],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=30, env=env,
    )


class ThemesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self._tmp = tempfile.TemporaryDirectory(prefix="pcli-themes-", dir="/tmp")
        self.addCleanup(self._tmp.cleanup)
        self.home = str(Path(self._tmp.name) / "home")
        self.resources = str(Path(self._tmp.name) / "resources")
        Path(self.home).mkdir()
        themes_dir = Path(self.resources) / "themes"
        themes_dir.mkdir(parents=True)
        for name in THEMES:
            (themes_dir / name).write_text("background = #000000\n")

    def managed_config(self) -> str:
        path = Path(self.home) / "Library/Application Support/com.darkroom.programa/config.ghostty"
        return path.read_text() if path.exists() else ""

    def test_bare_themes_and_list_print_the_theme_names(self) -> None:
        for args in ((), ("list",)):
            with self.subTest(args=args):
                proc = run_cli(self.home, self.resources, "themes", *args)
                self.assertEqual(proc.returncode, 0, f"stderr={proc.stderr!r}")
                lines = proc.stdout.splitlines()
                for name in THEMES:
                    self.assertIn(name, lines)

    def test_list_json_reports_every_theme(self) -> None:
        proc = run_cli(self.home, self.resources, "--json", "themes", "list")
        self.assertEqual(proc.returncode, 0, f"stderr={proc.stderr!r}")
        names = {entry["name"] for entry in json.loads(proc.stdout)["themes"]}
        self.assertTrue(set(THEMES) <= names)

    def test_set_writes_the_managed_block_and_clear_removes_it(self) -> None:
        proc = run_cli(self.home, self.resources, "themes", "set", "catppuccin mocha")
        self.assertEqual(proc.returncode, 0, f"stderr={proc.stderr!r}")
        self.assertIn("theme = light:Catppuccin Mocha,dark:Catppuccin Mocha", self.managed_config())

        proc = run_cli(self.home, self.resources, "themes", "clear")
        self.assertEqual(proc.returncode, 0, f"stderr={proc.stderr!r}")
        self.assertNotIn("Catppuccin", self.managed_config())

    def test_set_light_and_dark_pair(self) -> None:
        proc = run_cli(self.home, self.resources, "themes", "set", "--light", "Catppuccin Latte", "--dark", "Nord")
        self.assertEqual(proc.returncode, 0, f"stderr={proc.stderr!r}")
        self.assertIn("theme = light:Catppuccin Latte,dark:Nord", self.managed_config())

    def test_unknown_theme_fails_with_suggestions_and_writes_nothing(self) -> None:
        proc = run_cli(self.home, self.resources, "themes", "set", "Catppuccin")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("Unknown theme 'Catppuccin'", proc.stderr)
        self.assertIn("Catppuccin Mocha", proc.stderr)
        self.assertEqual(self.managed_config(), "")


if __name__ == "__main__":
    unittest.main()
