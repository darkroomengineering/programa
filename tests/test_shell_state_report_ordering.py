#!/usr/bin/env python3
"""Contract (CLIX-P1): shell-state reports never block the prompt and never reorder.

The zsh and bash integrations report `running` before a command and `prompt` after it. A
slow CLI must not delay the shell, a late `running` must not land after the next `prompt`,
and bash must not print job-control noise ("[1] 1234") into the user's terminal. Each report
is the full shell state, so a fallback report may be skipped once a newer one was issued; the
CLI must still see the reports in order and finish on the newest state.

The real integration scripts are sourced into a real shell. The CLI is a stub that sleeps
longer for `running` than for `prompt`, so any lost ordering shows up in its log. The fake
socket answers auth_required to force the CLI fallback, or ok to exercise the zsh direct path.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

INTEGRATION_DIR = Path(__file__).resolve().parent.parent / "Resources" / "shell-integration"
ZSH_INTEGRATION = INTEGRATION_DIR / "programa-zsh-integration.zsh"
BASH_INTEGRATION = INTEGRATION_DIR / "programa-bash-integration.bash"
STATES = ["running", "prompt", "running", "prompt"]

STUB = """#!/bin/sh
# usage: stub rpc <method> <params-json>; logs the reported state after a state-dependent delay
state=$(printf '%s' "$3" | sed -n 's/.*"state":"\\([a-z]*\\)".*/\\1/p')
[ "$state" = running ] && sleep 0.4
printf '%s\\n' "$state" >> "$STUB_LOG"
"""


class FakeSocket:
    def __init__(self, path: str, reply: bytes):
        self.path = path
        self.reply = reply
        self.states: list[str] = []
        self._stop = threading.Event()
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(path)
        self._sock.listen(8)
        self._sock.settimeout(0.05)
        self._threads = [threading.Thread(target=self._accept, daemon=True)]

    def _accept(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            worker = threading.Thread(target=self._handle, args=(conn,), daemon=True)
            self._threads.append(worker)
            worker.start()

    def _handle(self, conn: socket.socket) -> None:
        conn.settimeout(0.2)
        pending = b""
        try:
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    return
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    try:
                        self.states.append(json.loads(line)["params"]["state"])
                    except (ValueError, KeyError):
                        self.states.append(f"<unparsed {line!r}>")
                    conn.sendall(self.reply + b"\n")
        except OSError:
            pass
        finally:
            conn.close()

    def __enter__(self) -> "FakeSocket":
        self._threads[0].start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._stop.set()
        self._sock.close()
        for t in self._threads:
            t.join(timeout=2.0)


AUTH_REQUIRED = b'{"id":1,"ok":false,"error":{"code":"auth_required","message":"auth required"}}'
OK = b'{"id":1,"ok":true,"result":{}}'


class ShellStateReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="pshell-", dir="/tmp")
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.stub = self.dir / "programa-stub"
        self.stub.write_text(STUB)
        self.stub.chmod(0o755)
        self.log = self.dir / "stub.log"
        self.sock_path = str(self.dir / "s.sock")

    def env(self) -> dict[str, str]:
        env = {k: v for k, v in os.environ.items() if not k.startswith(("PROGRAMA_", "GHOSTTY_"))}
        env.update(
            HOME=str(self.dir), CFFIXED_USER_HOME=str(self.dir), TMPDIR=str(self.dir),
            PROGRAMA_SOCKET=self.sock_path, PROGRAMA_SOCKET_PATH=self.sock_path,
            PROGRAMA_BUNDLED_CLI_PATH=str(self.stub), PROGRAMA_TAB_ID="tab-1",
            PROGRAMA_WORKSPACE_ID="ws-1", PROGRAMA_PANEL_ID="panel-1", STUB_LOG=str(self.log),
        )
        return env

    def logged(self) -> list[str]:
        return self.log.read_text().split() if self.log.exists() else []

    def run_shell(self, argv: list[str], script: str, settle: float) -> subprocess.CompletedProcess[str]:
        started = time.monotonic()
        proc = subprocess.run(argv + ["-c", script], stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, check=False, timeout=30, env=self.env())
        self.assertGreaterEqual(time.monotonic() - started, settle)
        return proc

    def report_script(self, integration: Path, settle: float) -> str:
        calls = "\n".join(f"_programa_report_shell_activity_state {s}" for s in STATES)
        return f'source "{integration}"\n{calls}\nsleep {settle}\n'

    def assert_delivered_in_order(self, stderr: str) -> None:
        logged = self.logged()
        self.assertTrue(logged, stderr)
        self.assertEqual(logged[-1], STATES[-1], f"the newest state must land last: {logged}")
        remaining = iter(enumerate(STATES))
        self.assertTrue(all(any(state == want for _, want in remaining) for state in logged),
                        f"reports arrived out of order: {logged}")

    def test_zsh_fallback_keeps_order_without_blocking(self) -> None:
        with FakeSocket(self.sock_path, AUTH_REQUIRED):
            # The reports themselves must return long before the 0.4 s stub finishes.
            script = self.report_script(ZSH_INTEGRATION, 3)
            script = script.replace("sleep 3", 'echo "REPORTS_DONE $EPOCHREALTIME"; sleep 3')
            start = time.time()
            proc = self.run_shell(["zsh", "-f"], 'zmodload zsh/datetime; ' + script, 3)
        self.assert_delivered_in_order(proc.stderr)
        done = re.search(r"REPORTS_DONE (\d+\.\d+)", proc.stdout)
        self.assertIsNotNone(done, proc.stdout + proc.stderr)
        self.assertLess(float(done.group(1)) - start, 1.0, "the four reports must not wait on the slow CLI")

    def test_zsh_direct_socket_sends_frames_in_order_without_cli(self) -> None:
        if subprocess.run(["zsh", "-f", "-c", "zmodload zsh/net/socket"], capture_output=True).returncode != 0:
            self.skipTest("zsh/net/socket is not available")
        with FakeSocket(self.sock_path, OK) as fake:
            self.run_shell(["zsh", "-f"], self.report_script(ZSH_INTEGRATION, 0.5), 0.5)
            states = list(fake.states)
        self.assertEqual(states, STATES)
        self.assertEqual(self.logged(), [], "the CLI must not run when the direct socket answers ok")

    def test_bash_keeps_order_without_job_noise(self) -> None:
        bashes = [b for b in dict.fromkeys(["/bin/bash", shutil.which("bash") or ""]) if b and os.access(b, os.X_OK)]
        self.assertTrue(bashes)
        for index, bash in enumerate(bashes):
            with self.subTest(bash=bash):
                self.log.unlink(missing_ok=True)
                self.sock_path = str(self.dir / f"b{index}.sock")
                with FakeSocket(self.sock_path, AUTH_REQUIRED):
                    proc = self.run_shell([bash, "--norc", "--noprofile", "-i", "-m"],
                                          self.report_script(BASH_INTEGRATION, 3), 3)
                self.assert_delivered_in_order(proc.stderr)
                self.assertIsNone(re.search(r"\[\d+\]\s+\d+", proc.stderr + proc.stdout),
                                  f"job-control noise leaked: {proc.stderr!r}")


if __name__ == "__main__":
    unittest.main()
