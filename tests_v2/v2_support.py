"""Helpers shared by the tests_v2 socket tests.

Each test file imports what it needs under a private alias, for example
`from v2_support import must as _must`. Only helpers whose per-file copies were
behaviorally identical live here; test-specific variants stay in their own files.
"""

import glob
import json
import os
import select
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from programa_client import ProgramaClient, ProgramaClientError


def must(cond: bool, msg: str) -> None:
    if not cond:
        raise ProgramaClientError(msg)


def wait_until(
    predicate: Callable[[], bool],
    timeout_s: float = 4.0,
    interval_s: float = 0.05,
    message: str = "timeout",
) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if predicate():
            return
        time.sleep(interval_s)
    raise ProgramaClientError(message)


def wait_for(pred: Callable[[], bool], timeout_s: float = 5.0, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise ProgramaClientError("Timed out waiting for condition")


def find_cli_binary() -> str:
    env_cli = os.environ.get("PROGRAMA_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/programa-tests-v2/Build/Products/Debug/programa")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/programa"), recursive=True)
    candidates += glob.glob("/tmp/programa-*/Build/Products/Debug/programa")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise ProgramaClientError("Could not locate programa CLI binary; set PROGRAMA_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def palette_visible(client: ProgramaClient, window_id: str) -> bool:
    payload = client._call("debug.command_palette.visible", {"window_id": window_id}) or {}
    return bool(payload.get("visible"))


def run_git(args: list[str], cwd: Path) -> None:
    subprocess.run(
        ["git"] + args,
        cwd=cwd,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def hooks_commands(hooks: Dict[str, Any], event: str) -> List[str]:
    commands = []
    for group in hooks.get(event, []):
        for hook in group.get("hooks", []):
            command = hook.get("command", "")
            commands.append(command)
    return commands


def read_terminal_text_until(c: ProgramaClient, surface_id: str, needle: str, timeout_s: float = 10.0) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        last_text = c.read_terminal_text(surface_id)
        if needle in last_text:
            return last_text
        time.sleep(0.2)
    raise ProgramaClientError(f"Timed out waiting for marker {needle!r} in terminal output: {last_text!r}")


def surface_agent_state(client: ProgramaClient, workspace_id: str, surface_id: str) -> object:
    listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    for surface in listed.get("surfaces") or []:
        if str(surface.get("id")) == surface_id:
            return surface.get("agent_state")
    raise ProgramaClientError(f"surface {surface_id} not found in surface.list: {listed}")


def surface_agent_state_source(client: ProgramaClient, workspace_id: str, surface_id: str) -> object:
    """Additive sibling field (screen-manifest detection, docs/plans/screen-manifest-detection.md)
    -- must never affect the exact-string `agent_state` assertions in the agent-state tests."""
    listed = client._call("surface.list", {"workspace_id": workspace_id}) or {}
    for surface in listed.get("surfaces") or []:
        if str(surface.get("id")) == surface_id:
            return surface.get("agent_state_source")
    raise ProgramaClientError(f"surface {surface_id} not found in surface.list: {listed}")


def report_agent_state(socket_path: str, workspace_id: str, surface_id: str, state: str) -> None:
    """Reports a state change from its own connection: a send that shares a client blocked in
    another call interleaves request/response pairs on one socket ("Mismatched response id")."""
    with ProgramaClient(socket_path) as bg_client:
        bg_client._call(
            "surface.report_agent_state",
            {"workspace_id": workspace_id, "surface_id": surface_id, "state": state},
        )


def largest_split_frame(layout_payload: dict) -> dict:
    selected = layout_payload.get("selectedPanels") or []
    best = None
    best_area = -1.0
    for row in selected:
        for split in row.get("splitViews") or []:
            frame = split.get("frame")
            if not frame:
                continue
            try:
                x = float(frame.get("x", 0.0))
                y = float(frame.get("y", 0.0))
                width = float(frame.get("width", 0.0))
                height = float(frame.get("height", 0.0))
            except (TypeError, ValueError):
                continue
            if width <= 0.0 or height <= 0.0:
                continue
            area = width * height
            if area > best_area:
                best_area = area
                best = {"x": x, "y": y, "width": width, "height": height}
    if best is None:
        raise ProgramaClientError(f"layout_debug contains no usable split-view frame: {layout_payload}")
    return best


def container_frame(layout_payload: dict) -> dict:
    container = (layout_payload.get("layout") or {}).get("containerFrame")
    if container:
        try:
            return {
                "x": float(container.get("x", 0.0)),
                "y": float(container.get("y", 0.0)),
                "width": float(container.get("width", 0.0)),
                "height": float(container.get("height", 0.0)),
            }
        except (TypeError, ValueError):
            pass
    # Payloads without a usable containerFrame fall back to the largest split view.
    return largest_split_frame(layout_payload)


class RawSocketClient:
    """Minimal v2 JSON-RPC client for latency-critical simulate-keystroke loops.

    Speaks the same one-JSON-object-per-line framing as tests_v2/programa_client.py
    (``{"id": N, "method": ..., "params": {...}}`` in, ``{"id": N, "ok": ...}``
    out), but skips the full client's id-resolution helpers so the measured
    round trip is just: write one line, read one line. Keep timing loops on this
    client rather than the full one so per-call overhead stays constant.
    """

    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.sock: Optional[socket.socket] = None
        self.recv_buffer = ""
        self._next_id = 1

    def connect(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(self.socket_path)
        self.sock = sock

    def close(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            finally:
                self.sock = None

    def __enter__(self) -> "RawSocketClient":
        self.connect()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def call(self, method: str, params: Optional[dict] = None, timeout_s: float = 2.0) -> dict:
        if self.sock is None:
            raise ProgramaClientError("Raw socket client not connected")

        req_id = self._next_id
        self._next_id += 1
        payload = {"id": req_id, "method": method, "params": params or {}}
        self.sock.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8"))
        deadline = time.time() + timeout_s

        while True:
            if "\n" in self.recv_buffer:
                line, self.recv_buffer = self.recv_buffer.split("\n", 1)
                break

            remaining = deadline - time.time()
            if remaining <= 0:
                raise ProgramaClientError(f"Timed out waiting for response to: {method}")

            ready, _, _ = select.select([self.sock], [], [], remaining)
            if not ready:
                raise ProgramaClientError(f"Timed out waiting for response to: {method}")

            chunk = self.sock.recv(8192)
            if not chunk:
                raise ProgramaClientError("Socket closed while waiting for response")
            self.recv_buffer += chunk.decode("utf-8", errors="replace")

        try:
            resp = json.loads(line)
        except json.JSONDecodeError as e:
            raise ProgramaClientError(f"Invalid JSON response: {e}: {line[:200]}")

        if not isinstance(resp, dict) or resp.get("id") != req_id:
            raise ProgramaClientError(f"Mismatched or invalid response to {method}: {line[:200]}")

        if resp.get("ok") is True:
            return resp.get("result") or {}

        err = resp.get("error") or {}
        code = err.get("code") or "error"
        msg = err.get("message") or "Unknown error"
        raise ProgramaClientError(f"{code}: {msg}")


def resolve_target_socket(allow_main_socket: bool) -> str:
    """Never target the main/untagged socket from an automated harness unless the caller opts in."""
    socket_path = os.environ.get("PROGRAMA_SOCKET_PATH")
    if not socket_path:
        raise ProgramaClientError(
            "PROGRAMA_SOCKET_PATH is required. Point it to a tagged dev socket (for example /tmp/programa-debug-<tag>.sock)."
        )
    base = os.path.basename(socket_path)
    if not allow_main_socket and base in {"programa.sock", "programa-debug.sock"}:
        raise ProgramaClientError(
            f"Refusing to run against main socket '{socket_path}'. Set PROGRAMA_SOCKET_PATH to a tagged dev instance."
        )
    return socket_path
