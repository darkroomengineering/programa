#!/usr/bin/env python3
"""CI-only lifecycle contract: a restored pane that stays quiet keeps its
scrollback across the next relaunch. No XCTest launch gates (XCTest launches
disable the WAL and escrow).

Flow: a child prints a marker once and then stays silent. The app is killed,
relaunched (the pane is reattached and shows the marker from the old session's
WAL), left untouched so the new session records no PTY output, killed again and
relaunched. The marker must still be in the reattached pane's scrollback.
"""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def eventually(description, operation, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = operation()
            if result:
                return result
        except (OSError, ValueError, KeyError):
            pass
        time.sleep(0.2)
    raise RuntimeError(f"Timed out: {description}")


def rpc(path, method, params=None):
    request_id = str(uuid.uuid4())
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        connection.sendall(json.dumps({"id": request_id, "method": method, "params": params or {}}).encode() + b"\n")
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(65536)
            require(bool(chunk), f"EOF from {method}")
            data += chunk
            require(len(data) < 4 * 1024 * 1024, "Unexpectedly large socket response")
        response = json.loads(data.split(b"\n", 1)[0])
        require(response.get("id") == request_id and response.get("ok"),
                f"RPC failed: {method}: {json.dumps(response.get('error'))[:500]}")
        return response.get("result", {})


def processes():
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,lstart="], text=True)
    return {int(parts[0]): (int(parts[1]), " ".join(parts[2:]))
            for line in output.splitlines() if len(parts := line.split()) >= 7}


# Prints the marker exactly once, then only writes its heartbeat file. The
# marker is assembled at run time so the echoed command line, which carries the
# nonce, never contains it.
CHILD = r'''
import json, os, pathlib, select, sys, time
root = pathlib.Path(sys.argv[1])
nonce = sys.argv[2]
print('MARK-' + nonce, flush=True)
while True:
    temporary = root / 'heartbeat.next'
    temporary.write_text(json.dumps({'pid': os.getpid(), 'nonce': nonce, 'time': time.time()}))
    temporary.replace(root / 'heartbeat.json')
    ready, _, _ = select.select([sys.stdin], [], [], 0.25)
    if ready and not sys.stdin.readline():
        break
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    profiling = parser.add_mutually_exclusive_group()
    profiling.add_argument("--renderer-memory", action="store_true")
    profiling.add_argument("--allocations", type=Path)
    parser.add_argument("--returning-user", action="store_true")
    args = parser.parse_args()
    profile_memory = args.renderer_memory or args.allocations is not None
    app = args.app.resolve()
    require(os.environ.get("CI") == "true", "This lifecycle test runs only in CI")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    bundle = info["CFBundleIdentifier"]
    nonce = uuid.uuid4().hex
    marker = "MARK-" + nonce
    tag = "ci-seed-" + nonce[:10]
    control = Path("/tmp") / f"programa-debug-{tag}.sock"
    holder_socket = Path(tempfile.gettempdir()) / f"{control.stem}-escrow-v2.sock"
    require(not control.exists() and not holder_socket.exists(), "Unique fixture socket already exists")
    owned = {}
    current = None
    surface_ids = []
    escrow_pid = None
    with tempfile.TemporaryDirectory(prefix="programa-seed-lifecycle-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        support = home / "Library/Application Support/programa"
        sessions = support / "sessions"
        primary = support / f"session-{bundle}.json"
        policy = support / f"session-{bundle}.scrollback-policy.json"
        child_script = root / "child.py"
        child_script.write_text(CHILD)
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("PROGRAMA_UI_TEST", "XCTest", "XCInject"))
                       and key not in ("PROGRAMA_SOCKET", "PROGRAMA_SOCKET_PATH", "PROGRAMA_SOCKET_PASSWORD",
                                       "PROGRAMA_DISABLE_SESSION_RESTORE", "PROGRAMA_SESSION_ESCROW_HOLDER_SOCKET",
                                       "DYLD_INSERT_LIBRARIES",
                                       "PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID")}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), PROGRAMA_TAG=tag)

        def remember_descendants():
            table = processes()
            roots = {pid for pid, started in owned.items() if table.get(pid, (None, None))[1] == started}
            if current is not None and current.poll() is None:
                roots.add(current.pid)
            changed = True
            while changed:
                changed = False
                for pid, (parent, started) in table.items():
                    if parent in roots and pid not in roots:
                        roots.add(pid)
                        owned[pid] = started
                        changed = True

        def launch(*, record_allocations=False):
            nonlocal current
            # Preferences ride the NSUserDefaults argument domain; see
            # test_scrollback_privacy_recovery.py for why a plist in the isolated
            # home would not be read.
            launch_arguments = ["-socketControlMode", "full", "-sessionPersistScrollback", "YES"]
            if args.returning_user:
                launch_arguments += ["-programaWelcomeShown", "YES"]
            elif profile_memory:
                launch_arguments += ["-programaWelcomeShown", "NO"]
            log = (root / f"app-{time.time_ns()}.log").open("wb")
            try:
                app_environment = environment | {"MallocStackLogging": "1"} if record_allocations else environment
                current = subprocess.Popen([str(executable), *launch_arguments],
                                           env=app_environment, stdout=log, stderr=subprocess.STDOUT)
                table = processes()
                require(current.pid in table, "Launched app exited before identity capture")
                owned[current.pid] = table[current.pid][1]
            finally:
                log.close()
            eventually("ordinary app control socket", lambda: control.exists() and rpc(control, "system.ping").get("pong"))
            table = processes()
            require(current.poll() is None and current.pid in table, "Launched app exited or delegated to another instance")
            owned[current.pid] = table[current.pid][1]
            eventually("startup preference reaching durable policy",
                       lambda: json.loads(policy.read_text()).get("enabled") is True)
            remember_descendants()

        def kill_app():
            remember_descendants()
            require(current is not None and current.poll() is None, "App already exited before crash step")
            current.kill()
            current.wait(timeout=10)

        def heartbeat():
            return json.loads((root / "heartbeat.json").read_text())

        def alive_after(previous):
            value = heartbeat()
            return value if value["time"] > previous and value["pid"] == child_pid and value["nonce"] == nonce else None

        def scrollback(surface):
            return rpc(control, "surface.read_text", {"surface_id": surface, "scrollback": True}).get("text", "")

        def restored_scrollback(surface):
            # A restored pane in a tab that is not shown has no runtime surface
            # yet, and read_text fails until it starts.
            try:
                return scrollback(surface)
            except RuntimeError:
                return ""

        def surface_for_original_child():
            # Finds the reattached pane without sending it input: any PTY output
            # would let the periodic frame capture record the marker on its own.
            workspaces = []
            for window in rpc(control, "window.list").get("windows", []) or [{}]:
                params = {"window_id": window["id"]} if window.get("id") else {}
                workspaces.extend(rpc(control, "workspace.list", params).get("workspaces", []))
            matches = []
            for workspace in workspaces:
                for row in rpc(control, "surface.list", {"workspace_id": workspace["id"]}).get("surfaces", []):
                    candidate = row["id"]
                    try:
                        meta = json.loads((sessions / candidate / "meta.json").read_text())
                    except (OSError, ValueError):
                        continue
                    if (meta.get("childPID") == escrow_pid and meta.get("escrowed")
                            and meta.get("escrowSocketPath") == str(holder_socket)):
                        matches.append(candidate)
            require(len(matches) <= 1, "Multiple surfaces claim the original child")
            return matches[0] if matches else None

        def reattached_surface():
            surface = eventually("surface bound to original child", surface_for_original_child)
            require(surface.lower() not in (known.lower() for known in surface_ids),
                    "Relaunch did not create a new session for the reattached child")
            surface_ids.append(surface)
            require(heartbeat()["pid"] == child_pid, "Recovery respawned the child")
            # Show the pane so its runtime surface starts and replays the restored
            # text. Focus sends no input to the PTY.
            rpc(control, "surface.focus", {"surface_id": surface})
            return surface

        def wal_bytes(surface):
            return sum(path.stat().st_size for path in (sessions / surface).glob("wal.log*") if path.is_file())

        def workspaces():
            return rpc(control, "workspace.list")["workspaces"]

        def capture_memory(phase):
            require(current.poll() is None, f"App exited before {phase} sample")
            print(f"--- renderer memory: {phase} ---", flush=True)
            subprocess.run(["footprint", str(current.pid)], check=True, timeout=30)
            subprocess.run(["vmmap", "--summary", str(current.pid)], check=True, timeout=30)

        def capture_allocations(phase):
            require(current.poll() is None, f"App exited before {phase} allocation capture")
            print(f"--- allocation history: {phase} ---", flush=True)
            args.allocations.mkdir(parents=True, exist_ok=True)
            output = args.allocations / f"{phase}.txt"
            with output.open("w") as report:
                subprocess.run(
                    ["malloc_history", str(current.pid), "-allBySize"],
                    stdout=report, check=True, timeout=180,
                )
            with output.open() as report:
                require(any(" bytes:" in line for line in report), f"No allocation stacks for {phase}")

        def visit_workspace(workspace):
            workspace_id = workspace["id"]
            rpc(control, "workspace.select", {"workspace_id": workspace_id})

            def attached_terminal():
                surfaces = rpc(control, "surface.health", {"workspace_id": workspace_id})["surfaces"]
                require(len(surfaces) == 1 and surfaces[0]["type"] == "terminal",
                        f"Expected one terminal in workspace {workspace_id}")
                terminal = surfaces[0]
                return terminal["id"] if terminal["in_window"] is True else None

            surface_id = eventually(f"terminal attached in {workspace_id}", attached_terminal)
            eventually(f"prompt or retained output in {workspace_id}", lambda: restored_scrollback(surface_id))

        try:
            launch()
            created = rpc(control, "workspace.create", {
                # The login shell stays the PTY child; the Python process runs under it.
                "initial_command": shlex.join([sys.executable, "-u", str(child_script), str(root), nonce]),
                "working_directory": str(root), "title": "Seed lifecycle " + nonce,
            })
            surface = created["surface_id"]
            require(isinstance(surface, str), "No terminal surface created")
            surface_ids.append(surface)
            value = eventually("real child heartbeat", heartbeat)
            child_pid = value["pid"]
            table = processes()
            require(child_pid in table, "Cannot read the child's parent process")
            child_ancestors = []
            ancestor = table[child_pid][0]
            while ancestor > 1 and ancestor not in child_ancestors:
                child_ancestors.append(ancestor)
                ancestor = table.get(ancestor, (1, None))[0]
            require(value["nonce"] == nonce, "Wrong child heartbeat")
            session = sessions / surface
            def escrow_metadata():
                value = json.loads((session / "meta.json").read_text())
                return value if value.get("escrowed") and value.get("escrowSocketPath") else None
            metadata = eventually("PTY escrow metadata", escrow_metadata)
            escrow_pid = metadata.get("childPID")
            require(escrow_pid in child_ancestors,
                    f"Escrow identity {escrow_pid} is not an ancestor of the actual child {child_pid} (ancestors {child_ancestors})")
            require(metadata.get("escrowSocketPath") == str(holder_socket), "Escrow escaped the fixture's tagged socket")
            # Track from the user-owned process right below login, which is
            # root-owned and cannot be signalled by cleanup.
            below_login = ([child_pid] + child_ancestors)[child_ancestors.index(escrow_pid)]
            owned[below_login] = table[below_login][1]
            remember_descendants()
            require(child_pid in owned, "Cannot establish child process ownership")
            eventually("marker recorded in the first session's WAL", lambda: any(
                marker.encode() in path.read_bytes() for path in session.glob("wal.log*")))
            eventually("first session in autosave snapshot", lambda: surface.lower() in primary.read_text().lower(), timeout=100)
            if profile_memory:
                fixture_ids = [row["id"] for row in workspaces()]
                require(0 < len(fixture_ids) <= 10, "Unexpected starting workspace count")
                for _ in range(10 - len(fixture_ids)):
                    created = rpc(control, "workspace.create", {"working_directory": str(root)})
                    fixture_ids.append(created["workspace_id"])
                for workspace in workspaces():
                    visit_workspace(workspace)
                def fixture_saved():
                    snapshot = primary.read_text().lower()
                    return all(workspace_id.lower() in snapshot for workspace_id in fixture_ids)

                eventually("ten workspaces in autosave snapshot", fixture_saved, timeout=100)
            before = heartbeat()["time"]
            kill_app()
            eventually("child survives first app crash", lambda: alive_after(before))

            launch(record_allocations=args.allocations is not None)
            if profile_memory:
                def complete_fixture():
                    rows = workspaces()
                    return rows if len(rows) == 10 else None

                restored_workspaces = eventually("ten restored workspaces", complete_fixture)
                if args.renderer_memory:
                    capture_memory("restored before visiting")
                else:
                    capture_allocations("restored")
                initially_selected = next(row for row in restored_workspaces if row["selected"])
                for workspace in restored_workspaces:
                    visit_workspace(workspace)
                visit_workspace(initially_selected)
                if args.renderer_memory:
                    capture_memory("after visiting ten workspaces")
                time.sleep(60)
                if args.renderer_memory:
                    capture_memory("after 60 seconds without input")
                else:
                    capture_allocations("settled")
            restored = reattached_surface()
            eventually("marker restored after the first relaunch", lambda: marker in restored_scrollback(restored))
            eventually("restored session in autosave snapshot", lambda: restored.lower() in primary.read_text().lower(),
                       timeout=100)
            # The test only means something if the restored pane recorded no PTY
            # output of its own: any WAL bytes would let a periodic frame capture
            # save the marker without the restore seed.
            quiet_bytes = wal_bytes(restored)
            require(quiet_bytes == 0,
                    f"Precondition failed: the restored pane was not quiet ({quiet_bytes} WAL bytes recorded)")
            before = heartbeat()["time"]
            kill_app()
            eventually("child survives second app crash", lambda: alive_after(before))

            launch()
            final = reattached_surface()
            try:
                eventually("marker restored after the second relaunch", lambda: marker in restored_scrollback(final))
            except RuntimeError:
                raise RuntimeError("Restored scrollback was lost: the quiet pane came back without its marker "
                                   "after the second relaunch") from None
            require(heartbeat()["pid"] == child_pid, "Second relaunch respawned the child")
            print("PASS: a quiet restored pane keeps its scrollback across the next relaunch")
        finally:
            original_error = sys.exc_info()[0] is not None
            cleanup_errors = []
            if original_error:
                # Diagnostics for CI: the app log and the terminal's current text are the only
                # evidence of why a step timed out, and neither survives the temp directory.
                for app_log in sorted(root.glob("app-*.log")):
                    try:
                        tail = app_log.read_bytes()[-12000:].decode("utf-8", "replace")
                    except OSError as error:
                        tail = f"<unreadable: {error}>"
                    print(f"--- {app_log.name} (tail) ---\n{tail}", file=sys.stderr)
                def diagnostic(label, operation):
                    try:
                        print(f"--- {label} ---\n{operation()}", file=sys.stderr)
                    except Exception as error:  # noqa: BLE001 - diagnostics must never mask the real failure
                        print(f"--- {label} unavailable: {type(error).__name__}: {error}", file=sys.stderr)

                diagnostic("window.list", lambda: json.dumps(rpc(control, "window.list"))[:2000])
                diagnostic("workspace.list (primary window)", lambda: json.dumps(rpc(control, "workspace.list"))[:3000])
                for sid in surface_ids:
                    diagnostic(f"surface {sid} text", lambda sid=sid: str(scrollback(sid))[-3000:])
                def session_files():
                    rows = []
                    for path in sorted(sessions.glob("*/*")):
                        rows.append(f"{path.parent.name}/{path.name}: {path.stat().st_size} bytes")
                    for meta_path in sorted(sessions.glob("*/meta.json")):
                        rows.append(f"{meta_path.parent.name}: {meta_path.read_text()[:600]}")
                    return "\n".join(rows) or "<no sessions>"
                diagnostic("sessions/*", session_files)
                diagnostic("expected escrow", lambda: f"escrow_pid={escrow_pid!r} holder_socket={holder_socket}")

            def cleanup(label, operation):
                try:
                    operation()
                except ProcessLookupError:
                    pass
                except Exception as error:
                    cleanup_errors.append(f"{label}: {type(error).__name__}")

            cleanup("discover owned descendants", remember_descendants)

            def kill_owned(pid, started):
                if processes().get(pid, (None, None))[1] == started:
                    os.kill(pid, signal.SIGKILL)

            for pid, started in reversed(list(owned.items())):
                cleanup(f"terminate owned PID {pid}", lambda pid=pid, started=started: kill_owned(pid, started))
            if current is not None:
                cleanup("terminate app child", lambda: current.kill() if current.poll() is None else None)
                cleanup("reap app child", lambda: current.wait(timeout=10))
            cleanup("remove control socket", lambda: control.unlink(missing_ok=True))
            cleanup("remove holder socket", lambda: holder_socket.unlink(missing_ok=True))
            for suffix in (".log", "-bg.log"):
                path = Path("/tmp") / ("programa-debug-" + tag + suffix)
                cleanup("remove tagged log", lambda path=path: path.unlink(missing_ok=True))
            if cleanup_errors:
                message = "Fixture cleanup incomplete: " + "; ".join(cleanup_errors)
                if original_error:
                    print(message, file=sys.stderr)
                else:
                    raise RuntimeError(message)


if __name__ == "__main__":
    main()
