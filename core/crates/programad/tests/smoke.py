#!/usr/bin/env python3
"""Smoke a running programad using the real v2 envelope and SCM_RIGHTS."""

from __future__ import annotations

import argparse
import array
import base64
import json
import os
import socket
import time
from typing import Any


class Client:
    def __init__(self, path: str) -> None:
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(path)
        self.buffer = bytearray()
        self.fds: list[int] = []
        self.next_id = 1

    def _receive(self) -> None:
        fd_space = socket.CMSG_SPACE(array.array("i").itemsize * 16)
        data, ancillary, flags, _ = self.socket.recvmsg(65536, fd_space)
        if flags & socket.MSG_CTRUNC:
            raise RuntimeError("truncated SCM_RIGHTS data")
        if not data:
            raise EOFError("programad closed the connection")

        received: list[int] = []
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                values = array.array("i")
                values.frombytes(payload[: len(payload) - len(payload) % values.itemsize])
                received.extend(values)
        for fd in received:
            os.set_inheritable(fd, False)

        markers = len(received)
        for byte in data:
            if byte == 0 and markers:
                markers -= 1
            else:
                self.buffer.append(byte)
        if markers:
            for fd in received:
                os.close(fd)
            raise RuntimeError("descriptor handoff lacked its NUL marker")
        self.fds.extend(received)

    def _line(self) -> bytes:
        while b"\n" not in self.buffer:
            self._receive()
        line, _, rest = self.buffer.partition(b"\n")
        self.buffer = bytearray(rest)
        return bytes(line)

    def call(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        frame = {"id": request_id, "method": method, "params": params or {}}
        self.socket.sendall(json.dumps(frame, separators=(",", ":")).encode() + b"\n")
        response = json.loads(self._line().decode("utf-8", errors="strict"))
        if response.get("id") != request_id:
            raise RuntimeError(f"response id mismatch: {response!r}")
        if response.get("ok") is not True:
            raise RuntimeError(f"{method} failed: {response.get('error')!r}")
        return response["result"]

    def take_fd(self) -> int:
        while not self.fds:
            self._receive()
        return self.fds.pop(0)

    def close(self) -> None:
        for fd in self.fds:
            os.close(fd)
        self.socket.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--password")
    args = parser.parse_args()

    client = Client(args.socket)
    session_id: str | None = None
    input_fd: int | None = None
    try:
        login = client.call("auth.login", {"password": args.password} if args.password else {})
        if login.get("authenticated") is not True:
            raise RuntimeError(f"authentication failed: {login!r}")
        if client.call("system.ping") != {"pong": True}:
            raise RuntimeError("unexpected ping result")

        opened = client.call(
            "session.open",
            {"argv": ["/bin/sh", "-c", "cat"], "cols": 80, "rows": 24},
        )
        session_id = opened["id"]
        attached = client.call(
            "session.attach",
            {"id": session_id, "cols": 80, "rows": 24},
        )
        if attached.get("fd_mode") != "write_only_input":
            raise RuntimeError(f"unexpected attach mode: {attached!r}")
        input_fd = client.take_fd()
        marker = f"programad-smoke-{os.getpid()}".encode()
        os.write(input_fd, marker + b"\n")

        offset = int(attached["replay_from"])
        captured = bytearray()
        deadline = time.monotonic() + 5
        while marker not in captured and time.monotonic() < deadline:
            result = client.call(
                "session.read",
                {"id": session_id, "offset": offset, "max_len": 65536},
            )
            captured.extend(base64.b64decode(result["data"], validate=True))
            offset = int(result["tail_offset"])
            if marker not in captured:
                time.sleep(0.05)
        if marker not in captured:
            raise RuntimeError(f"marker missing from WAL: {bytes(captured)!r}")

        client.call(
            "session.detach",
            {"id": session_id, "attach_id": attached["attach_id"]},
        )
        os.close(input_fd)
        input_fd = None
        client.call("session.close", {"id": session_id, "kill": True})
        session_id = None
        print("programad smoke: ok")
    finally:
        if input_fd is not None:
            os.close(input_fd)
        if session_id is not None:
            try:
                client.call("session.close", {"id": session_id, "kill": True})
            except Exception:
                pass
        client.close()


if __name__ == "__main__":
    main()
