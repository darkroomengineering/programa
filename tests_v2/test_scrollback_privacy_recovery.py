#!/usr/bin/env python3
"""CI-only ordinary-app privacy/recovery contract; no XCTest launch gates."""

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


CHILD = r'''
import json, os, pathlib, select, sys, time
root = pathlib.Path(sys.argv[1])
nonce = sys.argv[2]
private = False
while True:
    temporary = root / 'heartbeat.next'
    temporary.write_text(json.dumps({'pid': os.getpid(), 'nonce': nonce, 'time': time.time()}))
    temporary.replace(root / 'heartbeat.json')
    if private:
        print('PRIVATE-' + nonce, flush=True)
    ready, _, _ = select.select([sys.stdin], [], [], 0.25)
    if ready:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if line == 'private':
            private = True
        elif line.startswith('ack '):
            print('ACK-' + nonce + '-' + line[4:], flush=True)
        elif line == 'public':
            print('PUBLIC-' + nonce, flush=True)
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    app = parser.parse_args().app.resolve()
    require(os.environ.get("CI") == "true", "This lifecycle test runs only in CI")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    bundle = info["CFBundleIdentifier"]
    nonce = uuid.uuid4().hex
    tag = "ci-wal-" + nonce[:10]
    control = Path("/tmp") / f"programa-debug-{tag}.sock"
    holder_socket = control.with_name(control.stem + "-escrow-v2.sock")
    require(not control.exists() and not holder_socket.exists(), "Unique fixture socket already exists")
    owned = {}
    current = None
    with tempfile.TemporaryDirectory(prefix="programa-wal-lifecycle-") as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        support = home / "Library/Application Support/programa"
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

        def launch(enabled):
            nonlocal current
            # Preferences ride the NSUserDefaults argument domain: cfprefsd-backed
            # UserDefaults ignore CFFIXED_USER_HOME, so a plist in the isolated home is
            # never read, and writing the real domain would touch the developer's
            # settings. `-key value` pairs are not an explicit open intent, so
            # startup session restore still runs (SessionPersistence.shouldAttemptRestore).
            launch_arguments = ["-socketControlMode", "full",
                                "-sessionPersistScrollback", "YES" if enabled else "NO"]
            log = (root / f"app-{time.time_ns()}.log").open("wb")
            try:
                current = subprocess.Popen([str(executable), *launch_arguments],
                                           env=environment, stdout=log, stderr=subprocess.STDOUT)
                # Record the root before readiness can fail. Popen remains our
                # authoritative child handle even if this identity read fails.
                table = processes()
                require(current.pid in table, "Launched app exited before identity capture")
                owned[current.pid] = table[current.pid][1]
            finally:
                log.close()
            eventually("ordinary app control socket", lambda: control.exists() and rpc(control, "system.ping").get("pong"))
            table = processes()
            require(current.poll() is None and current.pid in table, "Launched app exited or delegated to another instance")
            owned[current.pid] = table[current.pid][1]
            def durable_policy():
                # The previous launch's policy file may still be on disk; wait for the
                # one this launch derives from the startup preference.
                value = json.loads(policy.read_text())
                return value if value.get("enabled") == enabled else None
            result = eventually("startup preference reaching durable policy", durable_policy)
            remember_descendants()
            return result

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

        def send(surface, text):
            rpc(control, "surface.send_text", {"surface_id": surface, "text": text + "\n"})

        def acknowledge(expected_workspace_title=None):
            nonlocal surface
            def surface_for_original_child():
                workspaces = rpc(control, "workspace.list").get("workspaces", [])
                matches = []
                for workspace in workspaces:
                    for row in rpc(control, "surface.list", {"workspace_id": workspace["id"]}).get("surfaces", []):
                        candidate = row["id"]
                        try:
                            meta = json.loads((support / "sessions" / candidate / "meta.json").read_text())
                        except (OSError, ValueError):
                            continue
                        if (meta.get("childPID") == escrow_pid and meta.get("escrowed")
                                and meta.get("escrowSocketPath") == str(holder_socket)):
                            matches.append((candidate, workspace.get("title")))
                require(len(matches) <= 1, "Multiple surfaces claim the original child")
                return matches[0] if matches else None
            surface, workspace_title = eventually("surface bound to original child", surface_for_original_child)
            owned_surface_ids.add(surface.lower())
            if expected_workspace_title is not None:
                require(workspace_title == expected_workspace_title,
                        "Child recovered without its saved workspace title; snapshot restoration was not proved")
            challenge = uuid.uuid4().hex
            send(surface, "ack " + challenge)
            expected = "ACK-" + nonce + "-" + challenge
            eventually("original child acknowledgment", lambda: expected in rpc(
                control, "surface.read_text", {"surface_id": surface, "scrollback": True}).get("text", ""))
            require(heartbeat()["pid"] == child_pid, "Recovery respawned the child")

        def snapshots():
            return ([primary] if primary.exists() else []) + list((support / "session-history").glob(f"*-{bundle}.json"))

        def assert_private_absent():
            marker = ("PRIVATE-" + nonce).encode()
            sessions = support / "sessions"
            paths = list(sessions.glob("*/wal.log*")) + list(sessions.glob("*/frame*")) + snapshots()
            paths += list((support / "session-history").glob(f".*-{bundle}.json.staging-*"))
            for path in paths:
                if path.is_file():
                    require(marker not in path.read_bytes(), f"Private terminal output persisted in {path.name}")

        try:
            first_policy = launch(True)
            snapshot_title = "Privacy snapshot " + nonce
            created = rpc(control, "workspace.create", {
                # No leading `exec`: Ghostty already wraps shell commands as
                # `bash -c "exec -l <command>"`, so a user-supplied `exec` becomes
                # `exec -l exec ...` and fails with "exec: not found". The PTY child
                # recorded by escrow is that login/bash wrapper; the Python child is
                # its direct descendant, which is what the checks below verify.
                "initial_command": shlex.join([sys.executable, "-u", str(child_script), str(root), nonce]),
                "working_directory": str(root), "title": snapshot_title,
            })
            surface = created["surface_id"]
            require(isinstance(surface, str), "No terminal surface created")
            owned_surface_ids = {surface.lower()}
            value = eventually("real child heartbeat", heartbeat)
            child_pid = value["pid"]
            child_parent_pid = processes().get(child_pid, (None, None))[0]
            require(child_parent_pid is not None, "Cannot read the child's parent process")
            require(value["nonce"] == nonce, "Wrong child heartbeat")
            session = support / "sessions" / surface
            def escrow_metadata():
                value = json.loads((session / "meta.json").read_text())
                return value if value.get("escrowed") and value.get("escrowSocketPath") else None
            metadata = eventually("PTY escrow metadata", escrow_metadata)
            escrow_pid = metadata.get("childPID")
            require(escrow_pid == child_parent_pid,
                    f"Escrow identity {escrow_pid} is not the parent of the actual child {child_pid} (parent {child_parent_pid})")
            require(metadata.get("escrowSocketPath") == str(holder_socket), "Escrow escaped the fixture's tagged socket")
            remember_descendants()
            require(child_pid in owned, "Cannot establish child process ownership")
            send(surface, "public")
            eventually("positive enabled WAL marker", lambda: any(("PUBLIC-" + nonce).encode() in path.read_bytes()
                       for path in session.glob("wal.log*")))
            eventually("owned autosave snapshot", lambda: surface.lower() in primary.read_text().lower(), timeout=100)
            before = heartbeat()["time"]
            kill_app()
            eventually("child survives first app crash", lambda: alive_after(before))
            second_policy = launch(False)
            require(second_policy["generation"] != first_policy["generation"], "Policy generation did not change")
            acknowledge(expected_workspace_title=snapshot_title)
            send(surface, "private")
            eventually("actual private terminal output", lambda: "PRIVATE-" + nonce in rpc(
                control, "surface.read_text", {"surface_id": surface, "scrollback": True}).get("text", ""))
            end = time.monotonic() + 35
            while time.monotonic() < end:
                require(time.time() - heartbeat()["time"] < 5, "Private child stopped making progress")
                assert_private_absent()
                time.sleep(0.5)
            acknowledge()
            before = heartbeat()["time"]
            kill_app()
            eventually("child survives second app crash", lambda: alive_after(before))
            assert_private_absent()
            quarantine = root / "quarantine"
            quarantine.mkdir()
            for path in snapshots():
                contents = path.read_text().lower()
                require(any(identifier in contents for identifier in owned_surface_ids),
                        "Snapshot does not contain a tracked owned session")
                path.rename(quarantine / path.name)
            require(not primary.exists() and not snapshots(), "Snapshot-free recovery precondition failed")
            launch(False)
            acknowledge()
            assert_private_absent()
            print("PASS: disabled persistence protects output and original child survives snapshot-free recovery")
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
                try:
                    for sid in sorted(owned_surface_ids):
                        text = rpc(control, "surface.read_text", {"surface_id": sid, "scrollback": True})
                        print(f"--- created surface {sid} text ---\n{str(text.get('text', ''))[-3000:]}", file=sys.stderr)
                    workspaces = rpc(control, "workspace.list", {})
                    print(f"--- workspace.list ---\n{json.dumps(workspaces)[:3000]}", file=sys.stderr)
                    listing = rpc(control, "surface.list", {})
                    print(f"--- surface.list ---\n{json.dumps(listing)[:4000]}", file=sys.stderr)
                    for entry in listing.get("surfaces", []) if isinstance(listing, dict) else []:
                        sid = entry.get("surface_id") or entry.get("id")
                        if not sid:
                            continue
                        text = rpc(control, "surface.read_text", {"surface_id": sid, "scrollback": True})
                        print(f"--- surface {sid} text ---\n{str(text.get('text', ''))[-3000:]}", file=sys.stderr)
                except Exception as error:  # noqa: BLE001 - diagnostics must never mask the real failure
                    print(f"--- diagnostics unavailable: {type(error).__name__}: {error}", file=sys.stderr)

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
            # A startup failure may occur before ps/readiness recorded the root;
            # still terminate and reap exactly the Popen child we created.
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
