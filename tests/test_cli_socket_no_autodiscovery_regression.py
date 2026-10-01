#!/usr/bin/env python3
"""Regression (CLIX-18): the CLI never auto-selects another live Programa instance.

With no PROGRAMA_SOCKET / PROGRAMA_SOCKET_PATH and nothing listening at the stable
default, `programa ping` used to fall through to any live tagged, debug or staging socket,
so a command meant for the user's app silently landed in a different build. It must not
send them a request and must name them on stderr so the caller can opt in explicitly.

Stand-ins: a uniquely named /tmp/programa-clix18-*.sock (found by tagged-socket discovery)
always, and /tmp/programa-staging.sock only when that path is free (a real staging socket
is never touched). The test skips if a legacy /tmp/programa.sock exists, because that is a
legitimate implicit default and would answer instead.
"""

from __future__ import annotations

import os
import socket
import subprocess
import tempfile
import threading
import unittest
import uuid

CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
STAGING = "/tmp/programa-staging.sock"
LEGACY_DEFAULT = "/tmp/programa.sock"


class StandInListener:
    """Answers every request with pong and records what it was sent."""

    def __init__(self, path: str):
        self.path = path
        self.requests: list[bytes] = []
        self._stop = threading.Event()
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.bind(path)
        self._sock.listen(8)
        self._sock.settimeout(0.05)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._workers: list[threading.Thread] = []

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                conn, _ = self._sock.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            worker = threading.Thread(target=self._handle, args=(conn,), daemon=True)
            self._workers.append(worker)
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
                    self.requests.append(line)
                    conn.sendall(b'{"id":"1","ok":true,"result":{"pong":true}}\n')
        except OSError:
            pass
        finally:
            conn.close()

    def __enter__(self) -> "StandInListener":
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self._stop.set()
        self._sock.close()
        self._thread.join(timeout=2.0)
        for worker in self._workers:
            worker.join(timeout=2.0)
        try:
            os.unlink(self.path)
        except FileNotFoundError:
            pass


class NoAutodiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        if os.path.exists(LEGACY_DEFAULT):
            self.skipTest(f"{LEGACY_DEFAULT} exists and would legitimately answer as the implicit default")

    def ping_without_socket_env(self) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="pcli-home-", dir="/tmp") as home:
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith("PROGRAMA_") and k not in ("CMUX_SOCKET_PATH",)}
            env.update(HOME=home, CFFIXED_USER_HOME=home)
            return subprocess.run([CLI_PATH, "ping"], stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, check=False, timeout=20, env=env)

    def test_tagged_socket_is_named_not_used(self) -> None:
        path = f"/tmp/programa-clix18-{uuid.uuid4().hex[:8]}.sock"
        with StandInListener(path) as listener:
            proc = self.ping_without_socket_env()
            self.assertNotEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
            self.assertNotIn("pong", proc.stdout.lower())
            self.assertIn(path, proc.stderr, "stderr must name the live socket the CLI refused to use")
            self.assertEqual(listener.requests, [], "no request may be sent to another instance")

    def test_staging_socket_is_named_not_used(self) -> None:
        if os.path.exists(STAGING):
            self.skipTest(f"{STAGING} exists; never clobber a real staging socket")
        with StandInListener(STAGING) as listener:
            proc = self.ping_without_socket_env()
            self.assertNotEqual(proc.returncode, 0, f"stdout={proc.stdout!r} stderr={proc.stderr!r}")
            self.assertNotIn("pong", proc.stdout.lower())
            self.assertIn(STAGING, proc.stderr)
            self.assertEqual(listener.requests, [], "no request may be sent to another instance")


if __name__ == "__main__":
    unittest.main()
