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
CHILD_WORKSPACE_ID = "55555555-5555-5555-5555-555555555555"
DESCENDANT_WORKSPACE_ID = "66666666-6666-6666-6666-666666666666"
HELPER_AGENT_ID = "77777777-7777-7777-7777-777777777777"
DESCENDANT_AGENT_ID = "88888888-8888-8888-8888-888888888888"
OTHER_HELPER_WORKSPACE_ID = "99999999-9999-9999-9999-999999999999"


class SocketRecorder:
    """Minimal v2 server that records whether and how the CLI used its socket."""

    def __init__(
        self,
        directory: str,
        *,
        workspace_items: list[dict[str, Any]] | None = None,
        agents_by_workspace: dict[str, list[dict[str, Any]]] | None = None,
    ):
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
        self.workspace_items = workspace_items or [
            {"id": WORKSPACE_ID, "ref": "workspace:1", "selected": True}
        ]
        self.agents_by_workspace = agents_by_workspace or {}

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

    def _result_for(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "system.ping":
            return {"pong": True}
        if method == "workspace.list":
            return {"workspaces": self.workspace_items}
        if method == "agent.spawn":
            return {
                "agent_id": HELPER_AGENT_ID,
                "workspace_id": CHILD_WORKSPACE_ID,
                "surface_id": SURFACE_ID,
            }
        if method == "agent.task.list":
            agents = self.agents_by_workspace.get(str(params.get("workspace_id")), [])
            return {"agents": agents, "count": len(agents)}
        if method == "surface.list":
            return {
                "surfaces": [{
                    "id": SURFACE_ID,
                    "ref": "surface:1",
                    "workspace_id": params.get("workspace_id", WORKSPACE_ID),
                    "selected": True,
                }]
            }
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
    input_text: str | None = None,
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
        input=input_text,
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
        "claude provider rejects unknown action",
        ["claude", "bogus"],
        expect_failure=True,
        output_contains="Unknown claude subcommand",
    )
    expect_without_connection(
        "opencode provider rejects unknown action",
        ["opencode", "bogus"],
        expect_failure=True,
        output_contains="Unknown opencode subcommand",
    )
    expect_without_connection(
        "codex provider rejects unknown action",
        ["codex", "bogus"],
        expect_failure=True,
        output_contains="Unsupported codex subcommand",
    )
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

    # Claude Teams helpers use the native agent lifecycle instead of a second
    # workspace hierarchy maintained by the tmux shim.
    tmux_env = {
        "PROGRAMA_WORKSPACE_ID": WORKSPACE_ID,
        "PROGRAMA_SURFACE_ID": SURFACE_ID,
        "TMUX_PANE": "%1",
    }
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(directory) as recorder:
            helper = run_cli(
                recorder.path,
                ["__tmux-compat", "new-window", "-n", "Reviewer", "-c", "/tmp", "printf", "ready"],
                env_overrides=tmux_env,
            )
    check(helper.returncode == 0, f"Claude Teams new-window failed: {merged_output(helper)!r}")
    spawn_frames = [frame for frame in recorder.frames if frame.get("method") == "agent.spawn"]
    check(len(spawn_frames) == 1, f"Claude Teams new-window frames={recorder.frames!r}")
    if spawn_frames:
        params = spawn_frames[0].get("params", {})
        check(params.get("parent_workspace_id") == WORKSPACE_ID, f"helper parent mismatch: {params!r}")
        check(params.get("host") == "claude-teams", f"helper host mismatch: {params!r}")
        check(params.get("task") == "Reviewer", f"helper task mismatch: {params!r}")
        check(params.get("initial_command") == "cd -- '/tmp' && printf ready\r", f"helper command mismatch: {params!r}")
        check("needs_isolation" not in params, f"helper unexpectedly requested isolation: {params!r}")
    check(
        not any(frame.get("method") in {"workspace.create", "surface.send_text"} for frame in recorder.frames),
        f"Claude Teams helper used legacy creation calls: {recorder.frames!r}",
    )

    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(directory) as recorder:
            split_helper = run_cli(
                recorder.path,
                ["__tmux-compat", "split-window", "-c", "/tmp", "echo", "split"],
                env_overrides=tmux_env,
            )
    check(split_helper.returncode == 0, f"Claude Teams split-window failed: {merged_output(split_helper)!r}")
    split_spawn_frames = [frame for frame in recorder.frames if frame.get("method") == "agent.spawn"]
    check(len(split_spawn_frames) == 1, f"Claude Teams split-window frames={recorder.frames!r}")
    if split_spawn_frames:
        params = split_spawn_frames[0].get("params", {})
        check(params.get("parent_workspace_id") == WORKSPACE_ID, f"split helper parent mismatch: {params!r}")
        check(params.get("host") == "claude-teams", f"split helper host mismatch: {params!r}")
        check(params.get("task") == "Helper", f"split helper task mismatch: {params!r}")
        check(params.get("initial_command") == "cd -- '/tmp' && echo split\r", f"split helper command mismatch: {params!r}")
    check(
        not any(frame.get("method") in {"workspace.create", "surface.send_text"} for frame in recorder.frames),
        f"Claude Teams split helper used legacy creation calls: {recorder.frames!r}",
    )

    workspace_items = [
        {"id": WORKSPACE_ID, "ref": "workspace:1", "selected": True},
        {
            "id": CHILD_WORKSPACE_ID,
            "ref": "workspace:2",
            "agent_parent_workspace_id": WORKSPACE_ID,
            "helpers": [{
                "id": HELPER_AGENT_ID,
                "host": "claude-teams",
                "workspace_id": CHILD_WORKSPACE_ID,
            }],
        },
        {
            "id": DESCENDANT_WORKSPACE_ID,
            "ref": "workspace:3",
            "agent_parent_workspace_id": CHILD_WORKSPACE_ID,
            "helpers": [{
                "id": DESCENDANT_AGENT_ID,
                "host": "claude-teams",
                "workspace_id": DESCENDANT_WORKSPACE_ID,
            }],
        },
        {
            "id": OTHER_HELPER_WORKSPACE_ID,
            "ref": "workspace:4",
            "agent_parent_workspace_id": WORKSPACE_ID,
            "helpers": [{
                "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                "host": "codex",
                "workspace_id": OTHER_HELPER_WORKSPACE_ID,
            }],
        },
    ]
    agents_by_workspace = {
        CHILD_WORKSPACE_ID: [{"id": HELPER_AGENT_ID}],
        DESCENDANT_WORKSPACE_ID: [{"id": DESCENDANT_AGENT_ID}],
    }
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(
            directory,
            workspace_items=workspace_items,
            agents_by_workspace=agents_by_workspace,
        ) as recorder:
            killed = run_cli(
                recorder.path,
                ["__tmux-compat", "kill-window", "-t", WORKSPACE_ID],
                env_overrides=tmux_env,
            )
    check(killed.returncode == 0, f"Claude Teams root close failed: {merged_output(killed)!r}")
    close_frames = [frame for frame in recorder.frames if frame.get("method") == "workspace.close"]
    closed_ids = [frame.get("params", {}).get("workspace_id") for frame in close_frames]
    check(
        closed_ids == [DESCENDANT_WORKSPACE_ID, CHILD_WORKSPACE_ID, WORKSPACE_ID],
        f"Claude Teams close order changed: {recorder.frames!r}",
    )
    list_frames = [frame for frame in recorder.frames if frame.get("method") == "agent.task.list"]
    listed_workspace_ids = [frame.get("params", {}).get("workspace_id") for frame in list_frames]
    check(
        listed_workspace_ids == [DESCENDANT_WORKSPACE_ID, CHILD_WORKSPACE_ID],
        f"Claude Teams live-helper queries changed: {list_frames!r}",
    )
    check(
        all(frame.get("params", {}).get("include_finished") is False for frame in list_frames),
        f"Claude Teams queried finished helpers while closing: {list_frames!r}",
    )
    finished_ids = [
        frame.get("params", {}).get("agent_id")
        for frame in recorder.frames
        if frame.get("method") == "agent.task.finish"
    ]
    check(
        finished_ids == [DESCENDANT_AGENT_ID, HELPER_AGENT_ID],
        f"Claude Teams did not finish live helpers deepest-first: {recorder.frames!r}",
    )
    lifecycle_events = [
        (frame.get("method"), frame.get("params", {}).get("agent_id") or frame.get("params", {}).get("workspace_id"))
        for frame in recorder.frames
        if frame.get("method") in {"agent.task.finish", "workspace.close"}
    ]
    check(
        lifecycle_events == [
            ("agent.task.finish", DESCENDANT_AGENT_ID),
            ("workspace.close", DESCENDANT_WORKSPACE_ID),
            ("agent.task.finish", HELPER_AGENT_ID),
            ("workspace.close", CHILD_WORKSPACE_ID),
            ("workspace.close", WORKSPACE_ID),
        ],
        f"Claude Teams helper lifecycle order changed: {recorder.frames!r}",
    )

    # Global window targeting stays ordered and shares one lazy connection.
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        with SocketRecorder(directory) as recorder:
            ping = run_cli(recorder.path, ["--window", WINDOW_ID, "ping"])
        check(ping.returncode == 0, f"window-targeted ping failed: {merged_output(ping)!r}")
        check(recorder.accept_count == 1, f"window-targeted ping accepted {recorder.accept_count} connections, want 1")
        methods = [frame.get("method") for frame in recorder.frames]
        check(methods == ["window.focus", "system.ping"], f"window focus/ping order changed: {methods!r}")

    # Claude's native subagent hooks automatically create and finish one stable
    # virtual helper record in Agent Overview.
    subagent_payload = json.dumps({
        "session_id": "session-agent-overview",
        "agent_id": "agent-reviewer",
        "agent_type": "reviewer",
    })
    hook_env = {
        "PROGRAMA_WORKSPACE_ID": WORKSPACE_ID,
        "PROGRAMA_SURFACE_ID": SURFACE_ID,
        "PROGRAMA_CLAUDE_HOOK_STATE_PATH": "/tmp/programa-cli-registry-claude-hooks.json",
    }
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        hook_env["PROGRAMA_CLAUDE_HOOK_STATE_PATH"] = str(Path(directory) / "sessions.json")
        with SocketRecorder(directory) as recorder:
            started = run_cli(
                recorder.path,
                ["claude-hook", "subagent-start"],
                env_overrides=hook_env,
                input_text=subagent_payload,
            )
            stopped = run_cli(
                recorder.path,
                ["claude-hook", "subagent-stop"],
                env_overrides=hook_env,
                input_text=subagent_payload,
            )
            session_ended = run_cli(
                recorder.path,
                ["claude-hook", "session-end"],
                env_overrides=hook_env,
                input_text=subagent_payload,
            )
    check(started.returncode == 0, f"Claude subagent start hook failed: {merged_output(started)!r}")
    check(stopped.returncode == 0, f"Claude subagent stop hook failed: {merged_output(stopped)!r}")
    check(session_ended.returncode == 0, f"Claude session-end hook failed: {merged_output(session_ended)!r}")
    start_frames = [frame for frame in recorder.frames if frame.get("method") == "agent.task.start"]
    finish_frames = [frame for frame in recorder.frames if frame.get("method") == "agent.task.finish"]
    finish_session_frames = [frame for frame in recorder.frames if frame.get("method") == "agent.task.finish_session"]
    check(len(start_frames) == 1, f"Claude subagent start frames={recorder.frames!r}")
    check(len(finish_frames) == 1, f"Claude subagent finish frames={recorder.frames!r}")
    check(len(finish_session_frames) == 1, f"Claude session cleanup frames={recorder.frames!r}")
    if start_frames and finish_frames:
        start_params = start_frames[0].get("params", {})
        finish_params = finish_frames[0].get("params", {})
        check(start_params.get("agent_id") == finish_params.get("agent_id"), "Claude helper ID changed between hooks")
        check(start_params.get("placement") == "runs_with_parent", f"Claude helper placement={start_params!r}")
        check(start_params.get("task") == "reviewer", f"Claude helper title={start_params!r}")

    # A first hook invocation must persist its identity even before its state
    # directory exists, so session-end can clean up that same session.
    with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory:
        state_path = Path(directory) / "missing" / "nested" / "sessions.json"
        lifecycle_env = dict(hook_env, PROGRAMA_CLAUDE_HOOK_STATE_PATH=str(state_path))
        payload = json.dumps({"session_id": "first-run-session"})
        with SocketRecorder(directory) as recorder:
            started = run_cli(recorder.path, ["claude-hook", "session-start"],
                              env_overrides=lifecycle_env, input_text=payload)
            check(started.returncode == 0, f"first hook failed: {merged_output(started)!r}")
            persisted = json.loads(state_path.read_text()) if state_path.exists() else {}
            session = persisted.get("sessions", {}).get("first-run-session", {})
            check(session.get("workspaceId") == WORKSPACE_ID and session.get("surfaceId") == SURFACE_ID,
                  f"first hook did not persist origin identity: {persisted!r}")
            ended = run_cli(recorder.path, ["claude-hook", "session-end"],
                            env_overrides=lifecycle_env, input_text=payload)
            check(ended.returncode == 0, f"session cleanup failed: {merged_output(ended)!r}")
            remaining = json.loads(state_path.read_text()) if state_path.exists() else None
            check(remaining is not None and "first-run-session" not in remaining.get("sessions", {}),
                  f"session cleanup did not persist removal: {remaining!r}")

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
