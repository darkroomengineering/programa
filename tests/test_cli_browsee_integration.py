#!/usr/bin/env python3
"""`programa browsee` registers browsee with Claude Code and Codex and serves as their MCP server.

`install-mcp` adds a `browsee` stdio server that runs `programa browsee mcp` (Codex with the
shared `programa` session); `uninstall-mcp` removes it, and nothing changes without consent.
`browsee mcp` becomes `browsee-mcp --session programa-<surface id>` inside a pane. When
browsee's socket does not answer it starts browsee with `open -g -b com.darkroom.browsee`,
waits for the socket, and fails with a clear error if it never answers. Nothing but the
helper ever writes to stdout, which is the agent's MCP channel.

When HOME is so long that browsee's socket path does not fit the 104-byte sun_path, browsee
keeps its socket under a hashed name in its fallback folder, and any socket answering there
counts as browsee running.

Runs a copy of the built Debug CLI under a temporary HOME with fake `claude`, `codex`,
`browsee-mcp` and `open` (PROGRAMA_BROWSEE_OPEN_FOR_TESTING), and a private fallback folder
(PROGRAMA_BROWSEE_SOCKET_FOLDER_FOR_TESTING). No app, no real browsee and no real agent are
involved.
"""

from __future__ import annotations

import os
import shutil
import socket
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
STRIPPED_ENV = (
    "PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID",
    "PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "CLAUDE_CONFIG_DIR", "CODEX_HOME",
)
SURFACE_ID = "0F6C7B52-3D4E-4A1B-9C2D-5E6F7A8B9C0D"

# Stands in for both `claude mcp` and `codex mcp`: a registered server is a file in the client's
# own state folder, so the two clients never see each other's registrations.
FAKE_CLIENT = r"""#!/bin/bash
state="$FAKE_STATE/$(basename "$0")"
mkdir -p "$state"
printf '%s\n' "$*" >> "$state/calls.log"
case "$1 $2" in
  "mcp get") [[ -f "$state/server-$3" ]] ;;
  "mcp add")
    name=""; for arg in "$@"; do [[ "$arg" == "--" ]] && break; name="$arg"; done
    touch "$state/server-$name" ;;
  "mcp remove") rm -f "$state/server-${@: -1}" ;;
  *) exit 2 ;;
esac
"""

FAKE_HELPER = """#!/bin/sh
printf '%s\\n' "$*" > "$FAKE_STATE/helper.log"
echo helper-stdout
"""

FAKE_OPEN = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_STATE/open.log"
"""


def make_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class Sandbox:
    def __init__(self, root: str, with_browsee: bool = True, long_home: bool = False) -> None:
        self.root = Path(root)
        self.home = self.root / ("home-" + "x" * 48 if long_home else "home")
        self.home.mkdir(parents=True)
        bin_dir = self.root / "bundle-bin"
        bin_dir.mkdir()
        self.cli = bin_dir / "programa"
        shutil.copy2(CLI_PATH, self.cli)
        if with_browsee:
            make_executable(self.home / "Applications/browsee.app/Contents/MacOS/browsee-mcp", FAKE_HELPER)
        self.fake_bin = self.root / "fake-bin"
        make_executable(self.fake_bin / "claude", FAKE_CLIENT)
        make_executable(self.fake_bin / "codex", FAKE_CLIENT)
        self.opener = self.root / "fake-open"
        make_executable(self.opener, FAKE_OPEN)
        self.state = self.root / "state"
        self.state.mkdir()
        self.fallback = self.root / "fallback"
        self.fallback.mkdir(mode=0o700)
        natural = self.home / "Library/Application Support/browsee/mcp.sock"
        natural.parent.mkdir(parents=True)
        fits = len(str(natural).encode()) < 104
        self.socket_fits = fits
        self.socket_path = natural if fits else self.fallback / "5f1d3c2b9a8e7d6c.sock"
        self.listener: socket.socket | None = None

    def calls(self, client: str) -> list[str]:
        log = self.state / client / "calls.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def registered(self, client: str) -> bool:
        return (self.state / client / "server-browsee").exists()

    def log(self, name: str) -> list[str]:
        path = self.state / name
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def start_browsee(self) -> None:
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(self.socket_path))
        listener.listen(16)
        self.listener = listener

    def close(self) -> None:
        if self.listener is not None:
            self.listener.close()

    def run(self, *args: str, surface: str | None = None, timeout: int = 60) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        for key in STRIPPED_ENV:
            env.pop(key, None)
        sock = str(self.root / "no-such.sock")
        env.update(
            HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), FAKE_STATE=str(self.state),
            PATH=f"{self.fake_bin}:/usr/bin:/bin", PROGRAMA_SOCKET=sock, PROGRAMA_SOCKET_PATH=sock,
            PROGRAMA_BROWSEE_OPEN_FOR_TESTING=str(self.opener),
            PROGRAMA_BROWSEE_SOCKET_FOLDER_FOR_TESTING=str(self.fallback),
        )
        if surface is not None:
            env["PROGRAMA_SURFACE_ID"] = surface
        return subprocess.run(
            [str(self.cli), "browsee", *args],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False, timeout=timeout, env=env,
        )


class BrowseeIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        # Under /tmp: browsee's socket path must fit the 104-byte sun_path.
        self.tmp = tempfile.TemporaryDirectory(prefix="pcli-browsee-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)

    def sandbox(self, **kwargs: bool) -> Sandbox:
        box = Sandbox(self.tmp.name, **kwargs)
        self.addCleanup(box.close)
        return box

    def assertOK(self, proc: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")

    def test_install_registers_browsee_with_both_clients_and_uninstall_removes_it(self) -> None:
        box = self.sandbox()
        proc = box.run("install-mcp", "--yes")
        self.assertOK(proc)
        server = f"{box.cli} browsee mcp"
        self.assertIn(f"mcp add --scope user --transport stdio browsee -- {server}", box.calls("claude"))
        self.assertIn(f"mcp add browsee -- {server} --session programa", box.calls("codex"))
        self.assertTrue(box.registered("claude") and box.registered("codex"))
        self.assertIn("Let other apps control my tabs", proc.stdout)

        again = box.run("install-mcp", "--yes")
        self.assertOK(again)
        self.assertIn("already registered, skipping", again.stdout)
        self.assertEqual(sum(call.startswith("mcp add") for call in box.calls("claude")), 1)

        removed = box.run("uninstall-mcp", "-y")
        self.assertOK(removed)
        self.assertIn("mcp remove --scope user browsee", box.calls("claude"))
        self.assertIn("mcp remove browsee", box.calls("codex"))
        self.assertFalse(box.registered("claude") or box.registered("codex"))
        self.assertEqual(box.log("open.log"), [], "registering must never start browsee")

    def test_without_consent_nothing_is_registered(self) -> None:
        box = self.sandbox()
        proc = box.run("install-mcp")
        self.assertOK(proc)
        self.assertIn("Aborted", proc.stdout)
        self.assertFalse(any(call.startswith("mcp add") for call in box.calls("claude") + box.calls("codex")))

    @unittest.skipIf(Path("/Applications/browsee.app").exists(), "a real browsee is installed on this machine")
    def test_install_without_browsee_fails_and_registers_nothing(self) -> None:
        box = self.sandbox(with_browsee=False)
        proc = box.run("install-mcp", "--yes")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("browsee not found", proc.stderr)
        self.assertEqual(box.calls("claude") + box.calls("codex"), [])

    def test_mcp_in_a_pane_runs_the_helper_with_the_pane_session(self) -> None:
        box = self.sandbox()
        box.start_browsee()
        proc = box.run("mcp", surface=SURFACE_ID)
        self.assertOK(proc)
        self.assertEqual(proc.stdout, "helper-stdout\n", "only the helper may write to stdout")
        self.assertEqual(box.log("helper.log"), [f"--session programa-{SURFACE_ID}"])
        self.assertEqual(box.log("open.log"), [], "a running browsee is not launched again")

    def test_mcp_outside_a_pane_or_with_a_session_uses_that_session(self) -> None:
        box = self.sandbox()
        box.start_browsee()
        for args, surface, expected in [
            ((), None, "programa"),
            (("--session", "programa"), SURFACE_ID, "programa"),
            ((), "bad id/with slash", "programa"),
        ]:
            with self.subTest(args=args, surface=surface):
                proc = box.run("mcp", *args, surface=surface)
                self.assertOK(proc)
                self.assertEqual(box.log("helper.log"), [f"--session {expected}"])

    def test_mcp_starts_a_closed_browsee_in_the_background_and_waits_for_it(self) -> None:
        for long_home in (False, True):
            with self.subTest(long_home=long_home):
                self.check_launch_then_handoff(long_home)

    def check_launch_then_handoff(self, long_home: bool) -> None:
        tmp = tempfile.TemporaryDirectory(prefix="pcli-browsee-", dir="/tmp")
        self.addCleanup(tmp.cleanup)
        box = Sandbox(tmp.name, long_home=long_home)
        self.addCleanup(box.close)
        self.assertEqual(box.socket_fits, not long_home, "the long HOME must push the socket past sun_path")
        open_log = box.state / "open.log"

        def browsee_starts_when_opened() -> None:
            deadline = time.monotonic() + 30
            while not open_log.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            time.sleep(0.5)
            box.start_browsee()

        starter = threading.Thread(target=browsee_starts_when_opened, daemon=True)
        starter.start()
        proc = box.run("mcp", surface=SURFACE_ID)
        starter.join()
        self.assertOK(proc)
        self.assertEqual(box.log("open.log"), ["-g -b com.darkroom.browsee"])
        self.assertEqual(proc.stdout, "helper-stdout\n")
        self.assertEqual(box.log("helper.log"), [f"--session programa-{SURFACE_ID}"])

    def test_mcp_with_a_long_home_finds_a_running_browsee_in_the_fallback_folder(self) -> None:
        box = self.sandbox(long_home=True)
        self.assertFalse(box.socket_fits)
        (box.fallback / "stale.sock").touch()
        box.start_browsee()
        proc = box.run("mcp", surface=SURFACE_ID)
        self.assertOK(proc)
        self.assertEqual(box.log("open.log"), [], "a running browsee is not launched again")
        self.assertEqual(box.log("helper.log"), [f"--session programa-{SURFACE_ID}"])

    def test_mcp_fails_clearly_when_browsee_never_starts(self) -> None:
        box = self.sandbox()
        started = time.monotonic()
        proc = box.run("mcp")
        self.assertNotEqual(proc.returncode, 0)
        self.assertLess(time.monotonic() - started, 30)
        self.assertEqual(box.log("open.log"), ["-g -b com.darkroom.browsee"])
        self.assertIn("browsee did not start", proc.stderr)
        self.assertEqual(proc.stdout, "")
        self.assertEqual(box.log("helper.log"), [], "the helper must not run without browsee")

    def test_status_reports_the_app_whether_it_runs_and_each_registration(self) -> None:
        box = self.sandbox()
        proc = box.run("status")
        self.assertOK(proc)
        self.assertIn(f"browsee: {box.home}/Applications/browsee.app", proc.stdout)
        self.assertIn("Running: no", proc.stdout)
        self.assertIn("Claude Code:", proc.stdout)
        self.assertIn("browsee not registered", proc.stdout)

        box.start_browsee()
        self.assertOK(box.run("install-mcp", "--yes"))
        proc = box.run("status")
        self.assertIn("Running: yes", proc.stdout)
        self.assertNotIn("browsee not registered", proc.stdout)
        self.assertEqual(box.log("open.log"), [], "status must never start browsee")


if __name__ == "__main__":
    unittest.main(verbosity=2)
