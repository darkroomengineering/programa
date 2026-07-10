#!/usr/bin/env python3
"""Behavioral contract for typed dispatch and lazy CLI socket acquisition."""

from __future__ import annotations

import json
import os
import socket
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import Any


CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
WINDOW_ID = "11111111-1111-1111-1111-111111111111"
WORKSPACE_ID = "22222222-2222-2222-2222-222222222222"
SURFACE_ID = "33333333-3333-3333-3333-333333333333"


class SocketRecorder:
    """Minimal v2 server that records whether and how the CLI used its socket."""

    def __init__(self, directory: str):
        self.path = os.path.join(directory, "programa.sock")
        self.accept_count = 0
        self.frames: list[dict[str, Any]] = []
        self.errors: list[str] = []
        self._stop = threading.Event()
        self._listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._listener.bind(self.path)
        self._listener.listen(4)
        self._listener.settimeout(0.05)
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> SocketRecorder:
        self._thread.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        self._stop.set()
        self._listener.close()
        self._thread.join(timeout=2.0)
        if self._thread.is_alive():
            self.errors.append("socket recorder thread did not stop")

    def _serve(self) -> None:
        while not self._stop.is_set():
            try:
                connection, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return

            self.accept_count += 1
            try:
                self._serve_connection(connection)
            except Exception as exc:  # noqa: BLE001 - recorder must report, not hide, fixture failures
                self.errors.append(f"socket recorder failed: {exc}")
            finally:
                connection.close()

    def _serve_connection(self, connection: socket.socket) -> None:
        connection.settimeout(0.1)
        pending = b""
        while not self._stop.is_set():
            try:
                chunk = connection.recv(8192)
            except socket.timeout:
                continue
            if not chunk:
                return
            pending += chunk
            while b"\n" in pending:
                raw, pending = pending.split(b"\n", 1)
                if not raw:
                    continue
                request = json.loads(raw)
                self.frames.append(request)
                response = {
                    "id": request.get("id"),
                    "ok": True,
                    "result": self._result_for(request.get("method", ""), request.get("params", {})),
                }
                connection.sendall(json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n")

    @staticmethod
    def _result_for(method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "system.ping":
            return {"pong": True}
        if method == "surface.move":
            return {
                "surface_id": params.get("surface_id", SURFACE_ID),
                "pane_id": "44444444-4444-4444-4444-444444444444",
                "workspace_id": params.get("workspace_id", WORKSPACE_ID),
                "window_id": params.get("window_id", WINDOW_ID),
            }
        return {}


def run_cli(
    socket_path: str,
    args: list[str],
    *,
    env_overrides: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env.pop("PROGRAMA_SOCKET", None)
    env.pop("PROGRAMA_SOCKET_PATH", None)
    env.pop("PROGRAMA_SOCKET_PASSWORD", None)
    env.pop("PROGRAMA_WORKSPACE_ID", None)
    env.pop("PROGRAMA_SURFACE_ID", None)
    if env_overrides:
        env.update(env_overrides)
    return subprocess.run(
        [CLI_PATH, "--socket", socket_path, *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=8.0,
        env=env,
    )


def merged_output(process: subprocess.CompletedProcess[str]) -> str:
    return f"{process.stdout}\n{process.stderr}".strip()


def main() -> int:
    if not CLI_PATH or not Path(CLI_PATH).is_file() or not os.access(CLI_PATH, os.X_OK):
        print("FAIL: PROGRAMA_CLI_BIN must point to an executable programa CLI")
        return 1

    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    def expect_without_connection(
        name: str,
        args: list[str],
        *,
        expected_status: int | None = None,
        expect_failure: bool = False,
        output_contains: str | None = None,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                try:
                    process = run_cli(recorder.path, args)
                except subprocess.TimeoutExpired:
                    failures.append(f"{name}: CLI timed out")
                    return
            output = merged_output(process)
            check(not recorder.errors, f"{name}: recorder errors: {recorder.errors}")
            check(
                recorder.accept_count == 0,
                f"{name}: expected no socket connection, observed {recorder.accept_count}; output={output!r}",
            )
            if expected_status is not None:
                check(
                    process.returncode == expected_status,
                    f"{name}: exit={process.returncode}, want {expected_status}; output={output!r}",
                )
            if expect_failure:
                check(
                    process.returncode != 0,
                    f"{name}: unexpectedly exited 0; output={output!r}",
                )
            if output_contains is not None:
                check(
                    output_contains.lower() in output.lower(),
                    f"{name}: output missing {output_contains!r}: {output!r}",
                )

    # Connection/dispatch regressions: lookup and help must happen before any socket work.
    expect_without_connection("help command", ["help"], expected_status=0, output_contains="Usage:")
    expect_without_connection("codex help", ["codex", "--help"], expected_status=0, output_contains="Usage: programa codex")
    expect_without_connection(
        "unknown command",
        ["definitely-not-a-command"],
        output_contains="Unknown command",
    )
    expect_without_connection(
        "unknown command help",
        ["definitely-not-a-command", "--help"],
        output_contains="Unknown command",
    )
    expect_without_connection(
        "unknown global option",
        ["--bogus", "ping"],
        output_contains="unknown",
    )

    # Unknown commands/options are usage failures, never successful no-ops.
    for name, args in [
        ("unknown command status", ["definitely-not-a-command"]),
        ("unknown command help status", ["definitely-not-a-command", "--help"]),
        ("unknown global option status", ["--bogus", "ping"]),
    ]:
        with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                try:
                    process = run_cli(recorder.path, args)
                except subprocess.TimeoutExpired:
                    failures.append(f"{name}: CLI timed out")
                    continue
            check(process.returncode != 0, f"{name}: unexpectedly exited 0; output={merged_output(process)!r}")

    # Typed parsing regressions: invalid CLI values must fail before acquiring a client.
    expect_without_connection(
        "ping unexpected positional",
        ["ping", "unexpected"],
        output_contains="unexpected",
    )
    expect_without_connection(
        "non-finite progress",
        ["set-progress", "nan"],
        output_contains="progress",
    )
    expect_without_connection(
        "negative log limit",
        ["list-log", "--limit", "-1"],
        output_contains="limit",
    )
    expect_without_connection(
        "non-positive read lines",
        ["read-screen", "--lines", "0"],
        output_contains="lines",
    )
    expect_without_connection(
        "missing panel value",
        ["focus-panel", "--panel"],
        output_contains="panel",
    )

    # Representative coverage for every shared grammar shape in the exhaustive
    # registry: no-arg, required options, enums, typed flags, JSON, metadata,
    # tree flags, and nested local syntax must all fail before socket focus.
    for name, args, needle in [
        ("no-argument command rejects extras", ["capabilities", "extra"], "unexpected"),
        ("required option", ["focus-window"], "window"),
        ("direction enum", ["new-split", "diagonal"], "direction"),
        ("typed integer option", ["move-surface", "--surface", SURFACE_ID, "--index", "two"], "index"),
        ("typed boolean option", ["move-surface", "--surface", SURFACE_ID, "--focus", "maybe"], "focus"),
        ("window target cannot focus before validation", ["--window", WINDOW_ID, "move-surface", "--surface", SURFACE_ID, "--index", "two"], "index"),
        ("malformed rpc params", ["rpc", "system.ping", "[]"], "params"),
        ("focus state enum", ["set-app-focus", "sometimes"], "state"),
        ("unknown tree flag", ["tree", "--bogus"], "unknown"),
        ("markdown subcommand", ["markdown", "render", "README.md"], "subcommand"),
        ("metadata cardinality", ["set-status", "build"], "missing"),
    ]:
        expect_without_connection(
            name,
            args,
            expect_failure=True,
            output_contains=needle,
        )

    # Every malformed command above must return a usage failure.
    for name, args in [
        ("ping positional status", ["ping", "unexpected"]),
        ("progress status", ["set-progress", "nan"]),
        ("limit status", ["list-log", "--limit", "-1"]),
        ("lines status", ["read-screen", "--lines", "0"]),
        ("panel status", ["focus-panel", "--panel"]),
    ]:
        with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                try:
                    process = run_cli(recorder.path, args)
                except subprocess.TimeoutExpired:
                    failures.append(f"{name}: CLI timed out")
                    continue
            check(process.returncode != 0, f"{name}: unexpectedly exited 0; output={merged_output(process)!r}")

    # Alias help remains available offline and points at the canonical grammar.
    for alias in ["rename-workspace", "rename-window"]:
        expect_without_connection(
            f"{alias} help",
            [alias, "--help"],
            expected_status=0,
            output_contains="Usage: programa rename-workspace",
        )

    # Outgoing values retain their CLI-side types after the registry refactor.
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(directory) as recorder:
            progress = run_cli(
                recorder.path,
                ["set-progress", "0.5", "--label", "Build", "--workspace", WORKSPACE_ID],
            )
        check(progress.returncode == 0, f"typed progress command failed: {merged_output(progress)!r}")
        check(recorder.accept_count == 1, f"typed progress accepted {recorder.accept_count} connections, want 1")
        progress_frames = [frame for frame in recorder.frames if frame.get("method") == "workspace.set_progress"]
        check(len(progress_frames) == 1, f"typed progress frames={recorder.frames!r}")
        if progress_frames:
            params = progress_frames[0].get("params", {})
            check(type(params.get("value")) is float and params["value"] == 0.5, f"progress value lost float type: {params!r}")
            check(params.get("label") == "Build", f"progress label mismatch: {params!r}")
            check(params.get("workspace_id") == WORKSPACE_ID, f"progress workspace mismatch: {params!r}")

    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(directory) as recorder:
            move = run_cli(
                recorder.path,
                ["move-surface", "--surface", SURFACE_ID, "--index", "2", "--focus", "false"],
            )
        check(move.returncode == 0, f"typed move command failed: {merged_output(move)!r}")
        check(recorder.accept_count == 1, f"typed move accepted {recorder.accept_count} connections, want 1")
        move_frames = [frame for frame in recorder.frames if frame.get("method") == "surface.move"]
        check(len(move_frames) == 1, f"typed move frames={recorder.frames!r}")
        if move_frames:
            params = move_frames[0].get("params", {})
            check(type(params.get("index")) is int and params["index"] == 2, f"move index lost integer type: {params!r}")
            check(type(params.get("focus")) is bool and params["focus"] is False, f"move focus lost boolean type: {params!r}")

    # Global window targeting stays ordered and shares one lazy connection.
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(directory) as recorder:
            ping = run_cli(recorder.path, ["--window", WINDOW_ID, "ping"])
        check(ping.returncode == 0, f"window-targeted ping failed: {merged_output(ping)!r}")
        check(recorder.accept_count == 1, f"window-targeted ping accepted {recorder.accept_count} connections, want 1")
        methods = [frame.get("method") for frame in recorder.frames]
        check(methods == ["window.focus", "system.ping"], f"window focus/ping order changed: {methods!r}")

    # The implicit password file is security-sensitive: only a regular,
    # user-owned, private file may contribute an auth frame.
    def password_file_frames(kind: str) -> tuple[subprocess.CompletedProcess[str], list[dict[str, Any]]]:
        with tempfile.TemporaryDirectory(prefix=f"programa-cli-password-{kind}-") as home:
            password_dir = Path(home) / "Library" / "Application Support" / "programa"
            password_dir.mkdir(parents=True, mode=0o700)
            password_path = password_dir / "socket-control-password"
            if kind == "symlink":
                target = Path(home) / "password-target"
                target.write_text("file-secret\n", encoding="utf-8")
                target.chmod(0o600)
                password_path.symlink_to(target)
            else:
                password_path.write_text("file-secret\n", encoding="utf-8")
                password_path.chmod(0o600 if kind == "secure" else 0o644)

            with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as socket_directory:
                with SocketRecorder(socket_directory) as recorder:
                    process = run_cli(
                        recorder.path,
                        ["ping"],
                        env_overrides={"HOME": home, "CFFIXED_USER_HOME": home},
                    )
            return process, recorder.frames

    secure_process, secure_frames = password_file_frames("secure")
    check(secure_process.returncode == 0, f"secure password file ping failed: {merged_output(secure_process)!r}")
    secure_auth = [frame for frame in secure_frames if frame.get("method") == "auth.login"]
    check(
        len(secure_auth) == 1 and secure_auth[0].get("params", {}).get("password") == "file-secret",
        f"secure password file was not used exactly once: {secure_frames!r}",
    )

    for kind in ["permissive", "symlink"]:
        process, frames = password_file_frames(kind)
        check(process.returncode == 0, f"{kind} password file ping failed: {merged_output(process)!r}")
        check(
            all(frame.get("method") != "auth.login" for frame in frames),
            f"{kind} password file was trusted: {frames!r}",
        )

    if failures:
        print(f"FAIL: {len(failures)} CLI registry behavior assertion(s) failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI registry validates and dispatches before lazily acquiring one typed client")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
