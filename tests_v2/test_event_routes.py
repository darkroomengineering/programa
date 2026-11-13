#!/usr/bin/env python3
"""Event routes (docs/plans/event-routes.md) end to end over the socket.

Routes are installed with the Debug-only `debug.routes.load`, never by writing the user's global
programa.json, and every case reads the route counters back from `routes.list`. Agent states are
driven with `surface.report_agent_state`, so the "agent" is the workspace's plain shell: a
submitted prompt is an `echo` the shell runs, which `surface.read_text` then shows twice (the
command line and its output). Banner hand-offs are read through `debug.notification.banner_count`
with the app focus override set to inactive, so focused-panel suppression never hides one.

Reports name a hook session (`provider` and `session_id`), because text goes only to an agent
whose reports name their writer, and only the end of that writer's own work releases queued text.

Cases: load and clear; throttle and its banner; the permission banner rule; `queue` and the
prompt's own turn; a prompt on the idle edge that must not trigger itself; `steer`; a surface with
no agent; refusal during a permission prompt; a forged idle during a permission prompt; and a
`run` whose reported working directory must be an existing, absolute path without `..`.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError  # noqa: E402
from v2_support import must as _must  # noqa: E402

DEFAULT_SOCKET_PATHS = ["/tmp/programa-debug.sock", "/tmp/programa.sock"]
# Generous: CI runners are slow, and every wait polls for its condition instead of sleeping.
WAIT_S = 30.0


def _wait(what: str, pred: Callable[[], bool], timeout_s: float = WAIT_S) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.1)
    raise ProgramaClientError(f"Timed out waiting for {what}")


def _load(client: ProgramaClient, routes: list[dict[str, Any]] | None) -> dict:
    text = None if routes is None else json.dumps({"routes": routes})
    return client._call("debug.routes.load", {"json": text}) or {}


def _route(client: ProgramaClient, name: str) -> dict:
    for route in (client._call("routes.list") or {}).get("routes") or []:
        if route.get("name") == name:
            return route
    raise ProgramaClientError(f"routes.list has no route named {name}")


def _banners(client: ProgramaClient) -> int:
    return int((client._call("debug.notification.banner_count") or {}).get("count", -1))


def _screen(client: ProgramaClient, workspace_id: str, surface_id: str) -> str:
    payload = client._call("surface.read_text", {"workspace_id": workspace_id, "surface_id": surface_id}) or {}
    return str(payload.get("text") or "")


class _Session:
    """Workspaces opened by the test, each with its shell ready, closed again in `close`."""

    def __init__(self, client: ProgramaClient) -> None:
        self.client = client
        self.workspaces: list[str] = []

    def shell(self) -> tuple[str, str]:
        workspace_id = self.client.new_workspace()
        self.workspaces.append(workspace_id)
        surfaces = self.client.list_surfaces(workspace_id)
        _must(bool(surfaces), f"workspace should have a surface: {workspace_id}")
        surface_id = surfaces[0][1]
        # The prompt is drawn after shell integration reports its directory, so a directory the
        # test reports later is not overwritten by the shell's first report.
        _wait("the shell prompt", lambda: bool(_screen(self.client, workspace_id, surface_id).strip()))
        return workspace_id, surface_id

    def close(self) -> None:
        for workspace_id in self.workspaces:
            try:
                self.client.close_workspace(workspace_id)
            except ProgramaClientError:
                pass


AGENT_SESSION = "event-routes-test"


def _report(
    client: ProgramaClient,
    workspace_id: str,
    surface_id: str,
    state: str,
    *,
    session: bool = True,
    session_id: str = AGENT_SESSION,
) -> None:
    """A hook report of `state`; `session=False` sends one that names no session (a forged or
    mistaken report), and another `session_id` one from a made-up session."""
    params = {"workspace_id": workspace_id, "surface_id": surface_id, "state": state}
    if session:
        params.update({"provider": "claude-code", "session_id": session_id})
    client._call("surface.report_agent_state", params)


def _needs_input(client: ProgramaClient, workspace_id: str, surface_id: str, kind: str, *, session: bool = False) -> None:
    params = {
        "workspace_id": workspace_id,
        "surface_id": surface_id,
        "provider": "claude-code",
        "title": "Claude Code",
        "body": f"routes-{uuid.uuid4().hex[:8]}",
        "kind": kind,
    }
    if session:
        params["session_id"] = AGENT_SESSION
    client._call("agent.needs_input", params)


def _wait_counter(client: ProgramaClient, name: str, counter: str, value: int) -> dict:
    _wait(f"{name}.{counter} == {value}", lambda: _route(client, name).get(counter) == value)
    return _route(client, name)


def _case_load_and_clear(client: ProgramaClient) -> None:
    reply = _load(client, [
        {"name": "ask", "on": "agent/+/needs_input/question", "throttleMs": 3000, "notify": {"title": "t"}},
        {"name": "bad", "on": "agent/#/x", "notify": {"title": "t"}},
    ])
    _must(reply.get("source") == "debug_override", f"load should report the override: {reply}")
    _must(reply.get("routes") == ["ask"], f"only the valid route should load: {reply}")
    issues = reply.get("issues") or []
    _must(len(issues) == 1 and issues[0].get("index") == 1 and issues[0].get("name") == "bad",
          f"the bad route should be one issue: {reply}")
    listed = client._call("routes.list") or {}
    _must(listed.get("source") == "debug_override" and listed.get("issues") == issues,
          f"routes.list should show the override and its issues: {listed}")

    cleared = _load(client, None)
    _must(cleared.get("source") == "file", f"json: null should return to the file: {cleared}")
    _must((client._call("routes.list") or {}).get("source") == "file", "routes.list should report the file again")


def _case_throttle_and_banners(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    # A window far longer than the three calls take, even on a loaded runner.
    _load(client, [{"name": "ask", "on": "agent/+/needs_input/question", "throttleMs": "10m",
                    "notify": {"title": "Agent needs you", "body": "{{body}}"}}])
    client._call("debug.notification.banner_reset")

    for call in range(1, 4):
        _needs_input(client, workspace_id, surface_id, "question")
        _wait_counter(client, "ask", "matched", call)
    route = _route(client, "ask")
    _must((route.get("fired"), route.get("throttled")) == (1, 2), f"three questions inside one window fire once: {route}")
    _must(_banners(client) == 1, f"only the route's own notification shows a banner, got {_banners(client)}")

    # A permission call this route does not match keeps its built-in banner.
    _needs_input(client, workspace_id, surface_id, "permission")
    _wait("the unmatched permission banner", lambda: _banners(client) == 2)
    _must(_route(client, "ask").get("matched") == 3, "a question route must not match a permission call")

    # Permission rule (L2): a route that fires for the call shows the one banner; a throttled
    # route never hides a permission banner; a throttled question stays hidden.
    _load(client, [{"name": "any", "on": "agent/+/needs_input/#", "key": "{{surface_id}}", "throttleMs": "5m",
                    "notify": {"title": "Agent needs you"}}])
    client._call("debug.notification.banner_reset")
    _needs_input(client, workspace_id, surface_id, "permission")
    _wait_counter(client, "any", "matched", 1)
    _must(_banners(client) == 1, f"a firing route's banner replaces the built-in one, got {_banners(client)}")
    _needs_input(client, workspace_id, surface_id, "permission")
    _wait_counter(client, "any", "matched", 2)
    _must(_route(client, "any").get("throttled") == 1, "the second call should be throttled")
    _must(_banners(client) == 2, f"a throttled permission call keeps its banner, got {_banners(client)}")
    _needs_input(client, workspace_id, surface_id, "question")
    _wait_counter(client, "any", "matched", 3)
    _must(_banners(client) == 2, f"a throttled question shows no banner, got {_banners(client)}")


def _case_queue(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    marker = "QUEUED-working-DELIVERED"
    _load(client, [{"name": "queued", "on": "agent/+/state/working", "throttleMs": 60000,
                    "prompt": {"text": "echo QUEUED-{{state}}-DELIVERED"}}])

    _report(client, workspace_id, surface_id, "working")
    _wait_counter(client, "queued", "fired", 1)
    # The delivery would happen in the same main-thread hop as the fire, so give rendering a
    # moment and make sure nothing arrived while the agent works.
    held_until = time.time() + 1.0
    while time.time() < held_until:
        _must(marker not in _screen(client, workspace_id, surface_id), "queue must not deliver while working")
        time.sleep(0.1)

    _report(client, workspace_id, surface_id, "idle")
    _wait("the queued prompt to be submitted and run",
          lambda: _screen(client, workspace_id, surface_id).count(marker) >= 2)

    # The turn the prompt started holds the route: a working report during it is busy.
    _report(client, workspace_id, surface_id, "working")
    route = _wait_counter(client, "queued", "busy", 1)
    _must(route.get("fired") == 1, f"the route must not fire during its own turn: {route}")


def _case_no_self_trigger(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    _load(client, [{"name": "on-idle", "on": "agent/+/state/idle", "throttleMs": 60000,
                    "when": {"previous_state": {"in": ["working"]}},
                    "prompt": {"text": "echo SELF-{{state}}"}}])
    _report(client, workspace_id, surface_id, "working")
    _report(client, workspace_id, surface_id, "idle")
    _wait("the idle prompt to run", lambda: _screen(client, workspace_id, surface_id).count("SELF-idle") >= 2)

    _report(client, workspace_id, surface_id, "working")
    _report(client, workspace_id, surface_id, "idle")
    route = _wait_counter(client, "on-idle", "matched", 2)
    _must((route.get("fired"), route.get("busy")) == (1, 1),
          f"the idle that ends the prompt's own turn must not fire it again: {route}")


def _case_steer(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    _load(client, [{"name": "steer", "on": "agent/+/state/working",
                    "send": {"text": "STEERED-{{state}}", "whenBusy": "steer"}}])
    # The report that creates the agent's state cannot also release text, so start from idle.
    _report(client, workspace_id, surface_id, "idle")
    _report(client, workspace_id, surface_id, "working")
    _wait("steer to paste while the agent works",
          lambda: "STEERED-working" in _screen(client, workspace_id, surface_id))
    _must(_route(client, "steer").get("last_error") is None, f"steer should not fail: {_route(client, 'steer')}")


def _case_no_agent(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    _load(client, [{"name": "plain", "on": "agent/+/state/none", "throttleMs": 60000,
                    "prompt": {"text": "echo PLAIN-NOT-SENT", "whenBusy": "steer"}}])
    _report(client, workspace_id, surface_id, "working")
    client._call("surface.clear_agent_state", {"workspace_id": workspace_id, "surface_id": surface_id})
    _wait("the no-agent outcome", lambda: _route(client, "plain").get("last_error") is not None)
    route = _route(client, "plain")
    _must(route.get("last_error") == "refused: the surface has no agent; nothing was sent", f"unexpected last_error: {route}")
    _must("PLAIN-NOT-SENT" not in _screen(client, workspace_id, surface_id), "a surface with no agent gets nothing")


def _case_forged_idle_during_permission(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    marker = "FORGED-working-SAFE"
    _report(client, workspace_id, surface_id, "idle")
    _load(client, [{"name": "queued", "on": "agent/+/state/working", "throttleMs": 60000,
                    "prompt": {"text": "echo FORGED-{{state}}-SAFE"}}])
    _report(client, workspace_id, surface_id, "working")
    _wait_counter(client, "queued", "fired", 1)
    _needs_input(client, workspace_id, surface_id, "permission", session=True)

    # An idle that names no session closes the prompt box but must not release the queued
    # prompt into it, and neither does a working and idle from a made-up session (a hooks-only
    # agent, as in tmux, has no OSC 7501 status to fall back on).
    _report(client, workspace_id, surface_id, "idle", session=False)
    _report(client, workspace_id, surface_id, "working", session_id="made-up-session")
    _report(client, workspace_id, surface_id, "idle", session_id="made-up-session")
    held_until = time.time() + 1.5
    while time.time() < held_until:
        _must(marker not in _screen(client, workspace_id, surface_id), "forged reports must not release queued text")
        time.sleep(0.1)

    # The agent's own working and idle do.
    _report(client, workspace_id, surface_id, "working")
    _report(client, workspace_id, surface_id, "idle")
    _wait("the queued prompt after the agent's own idle",
          lambda: _screen(client, workspace_id, surface_id).count(marker) >= 2)


def _case_refused_during_prompt(client: ProgramaClient, session: _Session) -> None:
    workspace_id, surface_id = session.shell()
    _load(client, [{"name": "held", "on": "agent/+/needs_input/permission",
                    "send": {"text": "HELD-TEXT", "whenBusy": "steer"}}])
    _needs_input(client, workspace_id, surface_id, "permission")
    _wait("the refusal", lambda: _route(client, "held").get("last_error") is not None)
    route = _route(client, "held")
    _must(str(route.get("last_error")).startswith("refused: a permission prompt is showing"),
          f"unexpected last_error: {route}")
    _must("HELD-TEXT" not in _screen(client, workspace_id, surface_id), "nothing may be sent during a prompt")


def _surface_directory(client: ProgramaClient, surface_id: str) -> str | None:
    """The surface's directory as the app holds it, from `system.tree`."""
    def find(node: Any) -> str | None:
        if isinstance(node, dict):
            if node.get("id") == surface_id and "current_directory" in node:
                return node.get("current_directory")
            children = node.values()
        elif isinstance(node, list):
            children = node
        else:
            return None
        for child in children:
            found = find(child)
            if found is not None:
                return found
        return None
    return find(client._call("system.tree", {}) or {})


def _case_run_directory(client: ProgramaClient, session: _Session, temp_dir: str) -> None:
    workspace_id, surface_id = session.shell()

    def report_pwd(path: str) -> None:
        client._call("surface.report_pwd", {"workspace_id": workspace_id, "surface_id": surface_id, "path": path})

    def directory_is(path: str) -> bool:
        current = _surface_directory(client, surface_id)
        return current is not None and os.path.realpath(current) == os.path.realpath(path)

    try:
        report_pwd(f"{temp_dir}/../{Path(temp_dir).name}")
    except ProgramaClientError as exc:
        _must(str(exc).startswith("invalid_params"), f"a .. path should be invalid_params: {exc}")
    else:
        raise ProgramaClientError("surface.report_pwd accepted a path with ..")

    # The shell's own directory reports (OSC 7 is validated off the main thread) can land after
    # one the test sends, so move the shell itself into the temp dir and wait until the app
    # agrees. Its later reports then name the same directory, and a run that went wrong would
    # write there rather than into the home directory.
    client._call("surface.send_text", {"workspace_id": workspace_id, "surface_id": surface_id,
                                       "text": f"cd '{temp_dir}'\n"})
    _wait("the shell to report the temp dir", lambda: directory_is(temp_dir))

    _load(client, [{"name": "marker", "on": "agent/+/state/idle",
                    "run": {"command": "printf '%s' \"$PROGRAMA_ROUTE_SURFACE_ID\" > route-marker"}}])
    missing = f"/nonexistent-{uuid.uuid4().hex}/project"
    report_pwd(missing)
    _wait("the app to hold the missing directory", lambda: _surface_directory(client, surface_id) == missing)
    _report(client, workspace_id, surface_id, "idle")
    _wait("the refused run", lambda: _route(client, "marker").get("last_error") is not None)
    route = _route(client, "marker")
    _must(route.get("last_error") == "could not start: the surface's working directory is unknown or does not exist",
          f"a missing directory must refuse the run: {route}")

    report_pwd(temp_dir)
    _wait("the app to hold the temp dir again", lambda: directory_is(temp_dir))
    _report(client, workspace_id, surface_id, "working")
    _report(client, workspace_id, surface_id, "idle")
    marker = Path(temp_dir) / "route-marker"
    _wait("the run's marker file", lambda: marker.exists() and marker.read_text() == surface_id, timeout_s=60.0)
    _wait_counter(client, "marker", "fired", 2)


def _run_once(socket_path: str) -> int:
    temp_dir = tempfile.mkdtemp(prefix="programa-routes-")
    with ProgramaClient(socket_path) as client:
        session = _Session(client)
        try:
            client.set_app_focus(False)
            _case_load_and_clear(client)
            _case_throttle_and_banners(client, session)
            _case_queue(client, session)
            _case_no_self_trigger(client, session)
            _case_steer(client, session)
            _case_no_agent(client, session)
            _case_refused_during_prompt(client, session)
            _case_forged_idle_during_permission(client, session)
            _case_run_directory(client, session, temp_dir)
            print("PASS: event routes load, throttle, own banners, deliver text and guard runs")
            return 0
        finally:
            for cleanup in (
                lambda: _load(client, None),
                lambda: client.set_app_focus(None),
                session.close,
            ):
                try:
                    cleanup()
                except ProgramaClientError:
                    pass
            shutil.rmtree(temp_dir, ignore_errors=True)


def main() -> int:
    env_socket = os.environ.get("PROGRAMA_SOCKET")
    if env_socket:
        return _run_once(env_socket)

    last_error: Exception | None = None
    for socket_path in DEFAULT_SOCKET_PATHS:
        try:
            return _run_once(socket_path)
        except ProgramaClientError as exc:
            text = str(exc)
            recoverable = ("Failed to connect", "Socket not found")
            if not any(token in text for token in recoverable):
                raise
            last_error = exc
            continue

    if last_error is not None:
        raise last_error
    raise ProgramaClientError("No socket candidates configured")


if __name__ == "__main__":
    raise SystemExit(main())
