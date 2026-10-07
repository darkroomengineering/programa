#!/usr/bin/env python3
"""CI-only end-to-end coverage for the `programa-mcp` sidecar (docs/mcp-server.md).

Spawns the real `programa-mcp` binary as a subprocess, speaks MCP over stdio against a
*live, running* tagged Programa build's control socket, and exercises the sidecar the way an
actual MCP client would -- not a mock. A separate, direct `programa` socket connection (the same
client every other tests_v2 file uses) drives setup/verification independently of the layer
under test.

Do NOT run this locally -- per CLAUDE.md's testing policy, this launches/talks to a real
Programa instance and is CI-only (`gh workflow run test-e2e.yml`). Syntax-check with
`python3 -m py_compile tests_v2/test_mcp_server_e2e.py` instead.

Known SDK race (see MCPSocketBridgeTests.swift's docstring and the Phase 6 briefing): the
Swift MCP SDK's `Server.start()` spawns its request-handling loop in an un-awaited `Task`, so a
one-shot `echo request | programa-mcp` can exit before that Task ever runs and produce no
output at all. `ProgramaMcpClient` below keeps stdin open for the whole subprocess lifetime
(closed only in `close()`) rather than writing-and-closing per call, exactly like the verified
reference driver this file was built from.
"""

from __future__ import annotations

import glob
import json
import os
import select
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET_PATH") or os.environ.get("PROGRAMA_SOCKET") or "/tmp/programa-debug.sock"

# Set BOTH -- programa-mcp resolves its socket the same way the CLI/programa.py do
# (PROGRAMA_SOCKET_PATH takes priority over PROGRAMA_SOCKET). Per project memory
# "tests-v2-socket-hijack": inside a Programa terminal, PROGRAMA_SOCKET_PATH already points at
# the user's PRODUCTION app, so both must be explicitly overridden to the tagged build's
# socket -- never rely on ambient inheritance.
MCP_ENV_OVERRIDE = {
    "PROGRAMA_SOCKET_PATH": SOCKET_PATH,
    "PROGRAMA_SOCKET": SOCKET_PATH,
}

MCP_PROTOCOL_VERSION = "2025-11-25"

# Ground truth extracted from CLI-MCP/Tools/*.swift's `name:` fields (Phase 3's ToolCatalog).
# Hardcoded and asserted for exact equality against the LIVE `tools/list` response below -- this
# is what makes a silently dropped/renamed tool fail the build instead of "some tools present".
EXPECTED_TOOL_NAMES = {
    "agent_spawn", "agent_task_start", "agent_task_update", "agent_task_finish", "agent_task_finish_session",
    "agent_task_list",
    "focus_pane", "focus_pane_last", "focus_review_open", "focus_surface", "focus_window",
    "focus_workspace_last", "focus_workspace_next", "focus_workspace_previous", "focus_workspace_select", "focus_worktree_open",
    "layout_apply", "layout_list", "layout_save", "notification_clear", "notification_create",
    "notification_create_for_surface", "notification_create_for_target", "notification_list", "pane_break", "pane_create",
    "pane_join", "pane_list", "pane_resize", "pane_surfaces", "pane_swap",
    "review_comment_add", "review_comment_list", "review_comment_remove", "review_refresh", "review_send_comments",
    "snapshot_list", "snapshot_restore", "surface_action", "surface_clear_agent_state", "surface_clear_git_branch",
    "surface_clear_history", "surface_clear_ports", "surface_clear_pr", "surface_close", "surface_create",
    "surface_current", "surface_health", "surface_list", "surface_move", "surface_ports_kick",
    "surface_read_text", "surface_refresh", "surface_reorder", "surface_report_agent_state", "surface_report_git_branch",
    "surface_report_ports", "surface_report_pr", "surface_report_pwd", "surface_report_shell_state", "surface_report_tty",
    "surface_send_key", "surface_send_text", "surface_split", "surface_trigger_flash", "surface_wait",
    "system_capabilities", "system_identify", "system_ping", "system_tree", "tab_action",
    "window_close", "window_create", "window_current", "window_list", "workspace_action",
    "workspace_clear_agent_pid", "workspace_clear_log", "workspace_clear_meta_block", "workspace_clear_progress", "workspace_clear_status",
    "workspace_close", "workspace_create", "workspace_current", "workspace_equalize_splits", "workspace_list",
    "workspace_list_log", "workspace_list_meta_blocks", "workspace_list_status", "workspace_log", "workspace_move_to_window",
    "workspace_rename", "workspace_reorder", "workspace_report_meta_block", "workspace_reset_sidebar", "workspace_set_agent_pid",
    "workspace_set_progress", "workspace_set_status", "workspace_sidebar_state", "worktree_create", "worktree_list",
    "worktree_remove",
}

EXPECTED_FOCUS_TOOL_NAMES = {name for name in EXPECTED_TOOL_NAMES if name.startswith("focus_")}

FOCUS_TOOL_DESCRIPTION_MARKER = "may raise/activate the Programa window"


class McpError(Exception):
    """Raised for any programa-mcp protocol/transport failure."""


def _find_mcp_binary() -> str:
    env_bin = os.environ.get("PROGRAMA_MCP_BIN")
    if env_bin and os.path.isfile(env_bin) and os.access(env_bin, os.X_OK):
        return env_bin

    # Matches the CLI's Copy-CLI destination (GhosttyTabs.xcodeproj's "Copy CLI" build phase):
    # Contents/Resources/bin/programa-mcp inside whichever built .app.
    patterns = [
        os.path.expanduser(
            "~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/*.app/Contents/Resources/bin/programa-mcp"
        ),
        "/tmp/programa-*/Build/Products/Debug/*.app/Contents/Resources/bin/programa-mcp",
    ]
    candidates: List[str] = []
    for pattern in patterns:
        candidates.extend(glob.glob(pattern, recursive=True))
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise ProgramaClientError("Could not locate programa-mcp binary; set PROGRAMA_MCP_BIN")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


class ProgramaMcpClient:
    """Speaks MCP-over-stdio with `programa-mcp`, holding stdin open for the whole session.

    Framing: one JSON object per line on both stdin and stdout (newline-delimited, matching the
    verified reference probe this class is built from) -- NOT LSP-style Content-Length framing.
    """

    def __init__(self, binary_path: str, env: Dict[str, str], timeout_s: float = 20.0):
        self._binary_path = binary_path
        self._env = env
        self._timeout_s = timeout_s
        self._proc: Optional[subprocess.Popen] = None
        self._next_id = 1
        self._stderr_lines: List[str] = []
        self._stderr_lock = threading.Lock()
        self._stderr_thread: Optional[threading.Thread] = None

    def __enter__(self) -> "ProgramaMcpClient":
        self._proc = subprocess.Popen(
            [self._binary_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=self._env,
        )
        self._stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self._stderr_thread.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.close()
        return False

    def _drain_stderr(self) -> None:
        # Must be continuously drained in the background: stderr is a real OS pipe with a
        # bounded buffer, and programa-mcp can log to it. If nothing reads it, a chatty
        # subprocess blocks on its own stderr write and the whole session hangs.
        assert self._proc is not None and self._proc.stderr is not None
        for line in self._proc.stderr:
            with self._stderr_lock:
                self._stderr_lines.append(line.rstrip("\n"))
                del self._stderr_lines[:-200]

    def _stderr_tail(self) -> str:
        with self._stderr_lock:
            return "\n".join(self._stderr_lines[-40:])

    def close(self) -> None:
        if self._proc is None:
            return
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
        except Exception:
            pass
        try:
            self._proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            try:
                self._proc.wait(timeout=5.0)
            except Exception:
                pass
        self._proc = None

    def _write(self, payload: Dict[str, Any]) -> None:
        if self._proc is None or self._proc.stdin is None:
            raise McpError("programa-mcp process is not running")
        line = json.dumps(payload) + "\n"
        try:
            self._proc.stdin.write(line)
            self._proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise McpError(f"Failed to write to programa-mcp stdin: {exc}. stderr: {self._stderr_tail()}")

    def _read_response(self, expected_id: int, timeout_s: Optional[float] = None) -> Dict[str, Any]:
        assert self._proc is not None and self._proc.stdout is not None
        deadline = time.time() + (timeout_s if timeout_s is not None else self._timeout_s)

        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                raise McpError(
                    f"Timed out waiting for programa-mcp response to id={expected_id}. "
                    f"stderr tail: {self._stderr_tail()}"
                )
            if self._proc.poll() is not None:
                raise McpError(
                    f"programa-mcp exited (code={self._proc.returncode}) while waiting for id={expected_id}. "
                    f"stderr tail: {self._stderr_tail()}"
                )
            ready, _, _ = select.select([self._proc.stdout], [], [], min(0.2, remaining))
            if not ready:
                continue

            line = self._proc.stdout.readline()
            if not line:
                raise McpError(
                    f"programa-mcp stdout closed while waiting for id={expected_id}. "
                    f"stderr tail: {self._stderr_tail()}"
                )
            line = line.strip()
            if not line:
                continue
            try:
                frame = json.loads(line)
            except json.JSONDecodeError as exc:
                raise McpError(f"Invalid JSON from programa-mcp: {exc}: {line[:300]}")
            if not isinstance(frame, dict):
                raise McpError(f"Expected a JSON object frame, got: {line[:300]}")
            if frame.get("id") == expected_id:
                return frame
            # Not our response (e.g. a stray notification) -- keep reading.

    def request(self, method: str, params: Optional[Dict[str, Any]] = None, timeout_s: Optional[float] = None) -> Any:
        request_id = self._next_id
        self._next_id += 1
        self._write({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        frame = self._read_response(request_id, timeout_s=timeout_s)
        if "error" in frame and frame["error"] is not None:
            err = frame["error"]
            raise McpError(f"{method} failed: {err.get('code')}: {err.get('message')}")
        return frame.get("result")

    def notify(self, method: str, params: Optional[Dict[str, Any]] = None) -> None:
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    # -- MCP-level convenience wrappers -------------------------------------------------

    def initialize(self) -> Dict[str, Any]:
        result = self.request(
            "initialize",
            {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "test_mcp_server_e2e", "version": "1"},
            },
        )
        self.notify("notifications/initialized")
        return result

    def list_tools(self) -> List[Dict[str, Any]]:
        result = self.request("tools/list") or {}
        return list(result.get("tools") or [])

    def call_tool(self, name: str, arguments: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}}) or {}
        if result.get("isError"):
            content = result.get("content") or []
            text = content[0].get("text") if content and isinstance(content[0], dict) else result
            raise McpError(f"Tool {name} returned isError=true: {text}")
        return result

    def call_tool_structured(self, name: str, arguments: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return dict(self.call_tool(name, arguments).get("structuredContent") or {})

    def read_resource(self, uri: str) -> List[Dict[str, Any]]:
        result = self.request("resources/read", {"uri": uri}) or {}
        return list(result.get("contents") or [])


# ---------------------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------------------


def _assert_initialize_advertises_tools_and_resources(mcp: ProgramaMcpClient) -> None:
    result = mcp.initialize()
    capabilities = result.get("capabilities") or {}
    _must("tools" in capabilities, f"initialize must advertise 'tools' capability, got {capabilities}")
    _must("resources" in capabilities, f"initialize must advertise 'resources' capability, got {capabilities}")


def _assert_tools_list_matches_exact_catalog(mcp: ProgramaMcpClient) -> None:
    tools = mcp.list_tools()
    names = [tool["name"] for tool in tools]

    _must(len(names) == len(set(names)), f"tools/list returned duplicate tool names: {names}")
    actual_names = set(names)

    missing = EXPECTED_TOOL_NAMES - actual_names
    extra = actual_names - EXPECTED_TOOL_NAMES
    _must(
        not missing and not extra,
        f"tools/list catalog drifted from the expected tool set -- missing={sorted(missing)}, "
        f"unexpected={sorted(extra)}",
    )
    _must(len(actual_names) == len(EXPECTED_TOOL_NAMES), f"expected exactly {len(EXPECTED_TOOL_NAMES)} tools, got {len(actual_names)}")

    focus_names = {name for name in actual_names if name.startswith("focus_")}
    _must(
        focus_names == EXPECTED_FOCUS_TOOL_NAMES,
        f"focus_-prefixed tool set drifted -- expected {sorted(EXPECTED_FOCUS_TOOL_NAMES)}, got {sorted(focus_names)}",
    )
    _must(len(focus_names) == 13, f"expected exactly 13 focus_-prefixed tools, got {len(focus_names)}")

    _must(all("." not in name for name in actual_names), f"tool names must never contain '.': {[n for n in actual_names if '.' in n]}")

    by_name = {tool["name"]: tool for tool in tools}
    for focus_name in focus_names:
        description = by_name[focus_name].get("description") or ""
        _must(
            FOCUS_TOOL_DESCRIPTION_MARKER in description,
            f"{focus_name}'s description must contain {FOCUS_TOOL_DESCRIPTION_MARKER!r}, got: {description!r}",
        )

    worktree_create_schema = by_name.get("worktree_create", {}).get("inputSchema") or {}
    worktree_create_properties = worktree_create_schema.get("properties") or {}
    _must(
        "focus" not in worktree_create_properties,
        f"worktree_create's input schema must never expose a 'focus' property, got properties: {sorted(worktree_create_properties)}",
    )


def _assert_system_ping_reaches_real_app(mcp: ProgramaMcpClient) -> None:
    structured = mcp.call_tool_structured("system_ping")
    _must(structured.get("pong") is True, f"system_ping should return pong:true from the real app, got {structured}")


def _assert_workspace_list_matches_known_count(mcp: ProgramaMcpClient, expected_count: int) -> None:
    structured = mcp.call_tool_structured("workspace_list")
    workspaces = structured.get("workspaces") or []
    _must(
        len(workspaces) == expected_count,
        f"workspace_list via MCP should return exactly {expected_count} pre-created workspaces, got {len(workspaces)}: {workspaces}",
    )


def _current_workspace_id(mcp: ProgramaMcpClient) -> str:
    structured = mcp.call_tool_structured("workspace_current")
    workspace_id = structured.get("workspace_id")
    _must(bool(workspace_id), f"workspace_current returned no workspace_id: {structured}")
    return str(workspace_id)


def _assert_focus_tool_changes_selected_workspace(mcp: ProgramaMcpClient, target_workspace_id: str) -> None:
    mcp.call_tool("focus_workspace_select", {"workspace_id": target_workspace_id})
    _must(
        _current_workspace_id(mcp) == target_workspace_id,
        "focus_workspace_select should have made workspace_current report the selected workspace",
    )


def _assert_non_focus_tool_preserves_selected_workspace(
    mcp: ProgramaMcpClient, selected_workspace_id: str, other_workspace_id: str
) -> None:
    """The negative-space form of the socket focus policy (CLAUDE.md "Socket focus policy"):
    a non-focus_ tool must be able to act on a DIFFERENT workspace's data without moving the
    app's current selection there."""
    before = _current_workspace_id(mcp)
    _must(before == selected_workspace_id, f"test setup invariant broken: expected {selected_workspace_id} selected, got {before}")

    # workspace_rename is a plain data-mutating tool (not focus_-prefixed) targeting a
    # workspace that is NOT the currently selected one.
    mcp.call_tool("workspace_rename", {"workspace_id": other_workspace_id, "title": "mcp-e2e-non-focus-rename"})

    after = _current_workspace_id(mcp)
    _must(
        after == selected_workspace_id,
        f"workspace_rename (non-focus) on a different workspace must not change workspace_current "
        f"-- expected it to stay {selected_workspace_id}, got {after}",
    )


def _assert_resource_read_exposes_sibling_pane_text(mcp: ProgramaMcpClient, surface_id: str, marker: str) -> None:
    uri = f"programa://surface/{surface_id}/text"

    deadline = time.time() + 10.0
    contents: List[Dict[str, Any]] = []
    while time.time() < deadline:
        contents = mcp.read_resource(uri)
        text = "".join(str(item.get("text") or "") for item in contents)
        if marker in text:
            return
        time.sleep(0.3)

    text = "".join(str(item.get("text") or "") for item in contents)
    raise ProgramaClientError(f"resources/read on {uri} never surfaced marker {marker!r}; last text tail: {text[-500:]!r}")


# ---------------------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------------------


def main() -> int:
    mcp_binary = _find_mcp_binary()

    created_workspace_ids: List[str] = []
    try:
        with ProgramaClient(SOCKET_PATH) as setup_client:
            baseline_workspaces = setup_client.list_workspaces()
            baseline_count = len(baseline_workspaces)

            # Three known, freshly created workspaces: one to select as the "current" workspace
            # for the focus-policy checks, one as the "other" (non-focus) target, one as a
            # spare so workspace_list's exact-count assertion isn't fragile against exactly-2.
            ws_selected = setup_client.new_workspace()
            created_workspace_ids.append(ws_selected)
            ws_other = setup_client.new_workspace()
            created_workspace_ids.append(ws_other)
            ws_spare = setup_client.new_workspace()
            created_workspace_ids.append(ws_spare)

            setup_client.select_workspace(ws_selected)

            surfaces = setup_client.list_surfaces(ws_other)
            _must(bool(surfaces), f"newly created workspace should have at least one surface: {ws_other}")
            other_surface_id = surfaces[0][1]

            expected_workspace_count = baseline_count + len(created_workspace_ids)

            mcp_env = dict(os.environ)
            mcp_env.update(MCP_ENV_OVERRIDE)

            with ProgramaMcpClient(mcp_binary, env=mcp_env) as mcp:
                _assert_initialize_advertises_tools_and_resources(mcp)
                _assert_tools_list_matches_exact_catalog(mcp)
                _assert_system_ping_reaches_real_app(mcp)
                _assert_workspace_list_matches_known_count(mcp, expected_workspace_count)

                _must(
                    _current_workspace_id(mcp) == ws_selected,
                    "test setup invariant broken: expected the directly-selected workspace to be current",
                )
                _assert_non_focus_tool_preserves_selected_workspace(mcp, ws_selected, ws_other)

                _assert_focus_tool_changes_selected_workspace(mcp, ws_other)
                # Restore selection via the same focus tool so subsequent assertions (and any
                # later test in the same CI run) start from a known state.
                _assert_focus_tool_changes_selected_workspace(mcp, ws_selected)

                marker = f"PROGRAMA_MCP_E2E_{os.getpid()}_{int(time.time())}"
                mcp.call_tool("surface_send_text", {"surface_id": other_surface_id, "text": f"echo {marker}\n"})
                _assert_resource_read_exposes_sibling_pane_text(mcp, other_surface_id, marker)


        print("PASS: programa-mcp end-to-end (initialize, tools/list catalog, system_ping, "
              "workspace_list count, focus policy positive+negative space, sibling-pane resource read)")
        return 0
    finally:
        if created_workspace_ids:
            try:
                with ProgramaClient(SOCKET_PATH) as cleanup_client:
                    for workspace_id in created_workspace_ids:
                        try:
                            cleanup_client.close_workspace(workspace_id)
                        except Exception:
                            pass
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
