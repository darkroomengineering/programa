#!/usr/bin/env python3
"""CI/VM: fresh panes lead independent jetsam coalitions (requires Debug app)."""

import ctypes
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import tempfile
import time

from programa_client import ProgramaClient


def coalition(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    info = library.proc_pidinfo
    info.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    info.restype = ctypes.c_int
    ids = (ctypes.c_uint64 * 6)()
    count = info(pid, 20, 0, ctypes.byref(ids), ctypes.sizeof(ids))
    # The struct is 40 bytes on macOS 15 and 48 on later releases; only the first two ids are read.
    if count < 2 * ctypes.sizeof(ctypes.c_uint64):
        raise RuntimeError(f"proc_pidinfo({pid}) returned {count}, errno={ctypes.get_errno()}")
    assert ids[1] != 0, f"No jetsam coalition for PID {pid}"
    return ids[1]


def wait_for(description, operation):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = operation()
        if result:
            return result
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for {description}")


def main():
    path = os.environ.get("PROGRAMA_SOCKET_PATH") or os.environ.get("PROGRAMA_SOCKET")
    assert path, "Set PROGRAMA_SOCKET_PATH to the CI/VM Debug app socket"
    with socket.socket(socket.AF_UNIX) as connection:
        connection.connect(path)
        # Darwin SOL_LOCAL / LOCAL_PEERPID identifies this socket's actual server.
        app_pid = struct.unpack("i", connection.getsockopt(0, 2, 4))[0]
    with tempfile.TemporaryDirectory(prefix="programa-coalition-") as directory:
        marker = Path(directory) / "shell-pid"
        with ProgramaClient(path) as client:
            workspace = None
            try:
                result = client._call("workspace.create", {
                    "initial_command": "printf '%s' \"$$\" > " + shlex.quote(str(marker)),
                })
                workspace = result["workspace_id"]
                shell = wait_for("shell PID", lambda: int(marker.read_text()) if marker.exists() and marker.read_text() else None)

                def root_pid():
                    rows = client._call("debug.terminals", {}).get("terminals", [])
                    for row in rows:
                        if row.get("workspace_id") == workspace and row.get("child_pid", -1) > 1:
                            return row["child_pid"]
                    return None

                root = wait_for("pane root PID", root_pid)
                assert root != shell, "Pane root must be the launchd helper, separate from its shell"
                root_coalition = coalition(root)
                assert root_coalition != coalition(app_pid), "Pane shares the app's jetsam coalition"
                assert coalition(shell) == root_coalition, "Shell does not share its pane leader's coalition"
                processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
                parents = {int(pid): int(parent) for pid, parent in (line.split() for line in processes.splitlines())}
                current = shell
                for _ in range(128):
                    if current == root:
                        break
                    current = parents.get(current, 0)
                assert current == root, "Reported shell is not descended from pane root"
                assert parents[root] == 1, "Pane root was not launched by launchd"
            finally:
                if workspace:
                    client.close_workspace(workspace)
    print("PASS: pane root and shell share a coalition independent of the app")


if __name__ == "__main__":
    main()
