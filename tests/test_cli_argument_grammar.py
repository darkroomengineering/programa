#!/usr/bin/env python3
"""Behavioral contract for `CLIArgumentGrammar`-driven commands.

Issue #187 (CLI half): a batch of `.registered` commands were migrated off
the hand-written `validateRegisteredArguments` switch onto a typed
`CLIArgumentGrammar` declared directly on their `CommandDescriptor`, so
validation is generated from the same source that documents the command
instead of being restated by hand.

This is table-driven over exactly the commands that were migrated. For each
one it asserts, against the real built CLI binary talking to a fake
unix-socket server (mirroring `test_cli_registry_behavior.py`'s harness):

  - a valid invocation is accepted (it reaches the socket -- one accepted
    connection -- rather than failing during argument validation)
  - an invocation missing a required piece of the grammar (a required
    option, or a required positional) is rejected before any socket
    connection is attempted
  - an invocation with an unknown flag is rejected before any socket
    connection is attempted

This does not assert on `programa.swift` source text -- it only runs the
built binary and observes process exit status, stderr, and whether the fake
server ever accepted a connection.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path
from typing import NamedTuple

from test_cli_registry_behavior import CLI_PATH, SocketRecorder, merged_output, run_cli


WORKSPACE_ID = "22222222-2222-2222-2222-222222222222"
SURFACE_ID = "33333333-3333-3333-3333-333333333333"
WINDOW_ID = "11111111-1111-1111-1111-111111111111"


class Case(NamedTuple):
    name: str
    valid_args: list[str]
    invalid_args: list[str]
    invalid_needle: str
    unknown_flag_args: list[str]


# One representative command per grammar shape that was migrated off the
# switch. Names that share a grammar arm (aliases, or multiple case labels
# pointing at one `parse(...)` call) are covered once here since they are
# validated identically; the conversion itself touched every alias's
# descriptor, not just the one tested below.
CASES: list[Case] = [
    Case(
        "capabilities (no-arg command)",
        ["capabilities"],
        ["capabilities", "extra"],
        "unexpected",
        ["capabilities", "--bogus"],
    ),
    Case(
        "identify (values + boolean)",
        ["identify", "--workspace", WORKSPACE_ID],
        ["identify", "--workspace", "a", "--workspace", "b"],
        "duplicate",
        ["identify", "--bogus"],
    ),
    Case(
        "move-workspace-to-window (required options)",
        ["move-workspace-to-window", "--workspace", WORKSPACE_ID, "--window", WINDOW_ID],
        ["move-workspace-to-window", "--workspace", WORKSPACE_ID],
        "window",
        ["move-workspace-to-window", "--bogus"],
    ),
    Case(
        "new-workspace (values only)",
        ["new-workspace", "--name", "Test"],
        ["new-workspace", "extra"],
        "unexpected",
        ["new-workspace", "--bogus"],
    ),
    Case(
        "list-panes (values only)",
        ["list-panes", "--workspace", WORKSPACE_ID],
        ["list-panes", "extra"],
        "unexpected",
        ["list-panes", "--bogus"],
    ),
    Case(
        "list-pane-surfaces (values only)",
        ["list-pane-surfaces", "--workspace", WORKSPACE_ID],
        ["list-pane-surfaces", "extra"],
        "unexpected",
        ["list-pane-surfaces", "--bogus"],
    ),
    Case(
        "close-surface (values only)",
        ["close-surface", "--surface", SURFACE_ID],
        ["close-surface", "extra"],
        "unexpected",
        ["close-surface", "--bogus"],
    ),
    Case(
        "trigger-flash (values only)",
        ["trigger-flash", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID],
        ["trigger-flash", "extra"],
        "unexpected",
        ["trigger-flash", "--bogus"],
    ),
    Case(
        "rename-workspace (required positional)",
        ["rename-workspace", "--workspace", WORKSPACE_ID, "New Title"],
        ["rename-workspace"],
        "missing",
        ["rename-workspace", "--bogus", "New Title"],
    ),
    Case(
        "send (required positional)",
        ["send", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID, "hello"],
        ["send", "--workspace", WORKSPACE_ID],
        "missing",
        ["send", "--bogus", "hello"],
    ),
    Case(
        "prompt-agent (required positional + timeout)",
        [
            "prompt-agent",
            "--workspace", WORKSPACE_ID,
            "--surface", SURFACE_ID,
            "--timeout", "1",
            "do things",
        ],
        ["prompt-agent", "--workspace", WORKSPACE_ID],
        "missing",
        ["prompt-agent", "--bogus", "do things"],
    ),
    Case(
        "send-key (single positional)",
        ["send-key", "--workspace", WORKSPACE_ID, "--surface", SURFACE_ID, "enter"],
        ["send-key", "--workspace", WORKSPACE_ID],
        "missing",
        ["send-key", "--bogus", "enter"],
    ),
    Case(
        "send-panel (required option + positional)",
        ["send-panel", "--panel", SURFACE_ID, "--workspace", WORKSPACE_ID, "hi"],
        ["send-panel", "hi"],
        "panel",
        ["send-panel", "--bogus", "hi"],
    ),
    Case(
        "send-key-panel (required option + single positional)",
        ["send-key-panel", "--panel", SURFACE_ID, "--workspace", WORKSPACE_ID, "enter"],
        ["send-key-panel", "enter"],
        "panel",
        ["send-key-panel", "--bogus", "enter"],
    ),
    Case(
        "notify (values only)",
        ["notify", "--title", "Hi", "--workspace", WORKSPACE_ID],
        ["notify", "extra"],
        "unexpected",
        ["notify", "--bogus"],
    ),
    Case(
        "clear-notifications (values only)",
        ["clear-notifications", "--workspace", WORKSPACE_ID],
        ["clear-notifications", "extra"],
        "unexpected",
        ["clear-notifications", "--bogus"],
    ),
    Case(
        "clear-status (required positional + allowEquals)",
        ["clear-status", "build", "--workspace", WORKSPACE_ID],
        ["clear-status"],
        "missing",
        ["clear-status", "--bogus", "build"],
    ),
    Case(
        "list-status (values only + allowEquals)",
        ["list-status", "--workspace", WORKSPACE_ID],
        ["list-status", "extra"],
        "unexpected",
        ["list-status", "--bogus"],
    ),
    Case(
        "version (local, no-arg command)",
        ["version"],
        ["version", "extra"],
        "unexpected",
        ["version", "--bogus"],
    ),
    Case(
        "swap-pane (required options)",
        ["swap-pane", "--pane", "pane1", "--target-pane", "pane2"],
        ["swap-pane", "--pane", "pane1"],
        "target-pane",
        ["swap-pane", "--pane", "pane1", "--target-pane", "pane2", "--bogus"],
    ),
    Case(
        "break-pane (values + boolean, no required)",
        ["break-pane", "--workspace", WORKSPACE_ID],
        ["break-pane", "extra"],
        "unexpected",
        ["break-pane", "--bogus"],
    ),
    Case(
        "join-pane (required option + boolean)",
        ["join-pane", "--target-pane", "pane2"],
        ["join-pane", "--pane", "pane1"],
        "target-pane",
        ["join-pane", "--target-pane", "pane2", "--bogus"],
    ),
    Case(
        "next-window (shared no-arg grammar: next-window/previous-window/last-window/list-buffers)",
        ["next-window"],
        ["next-window", "extra"],
        "unexpected",
        ["next-window", "--bogus"],
    ),
    Case(
        "last-pane (values only)",
        ["last-pane", "--workspace", WORKSPACE_ID],
        ["last-pane", "extra"],
        "unexpected",
        ["last-pane", "--bogus"],
    ),
    Case(
        "find-window (boolean + required positional)",
        ["find-window", "myquery"],
        ["find-window"],
        "missing",
        ["find-window", "myquery", "--bogus"],
    ),
    Case(
        "clear-history (values only)",
        ["clear-history", "--workspace", WORKSPACE_ID],
        ["clear-history", "extra"],
        "unexpected",
        ["clear-history", "--bogus"],
    ),
    Case(
        "set-buffer (required positional)",
        ["set-buffer", "--name", "buf1", "hello"],
        ["set-buffer", "--name", "buf1"],
        "missing",
        ["set-buffer", "hello", "--bogus"],
    ),
    Case(
        "paste-buffer (values only)",
        ["paste-buffer", "--name", "buf1"],
        ["paste-buffer", "extra"],
        "unexpected",
        ["paste-buffer", "--bogus"],
    ),
    Case(
        "respawn-pane (values only)",
        ["respawn-pane", "--workspace", WORKSPACE_ID],
        ["respawn-pane", "extra"],
        "unexpected",
        ["respawn-pane", "--bogus"],
    ),
]


def main() -> int:
    if not CLI_PATH or not Path(CLI_PATH).is_file() or not os.access(CLI_PATH, os.X_OK):
        print("FAIL: PROGRAMA_CLI_BIN must point to an executable programa CLI")
        return 1

    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    for case in CASES:
        # Valid invocation: argument grammar must accept it and let the
        # command reach the socket. (What happens after connecting is a
        # separate business-logic concern -- we only assert it got there.)
        with tempfile.TemporaryDirectory(prefix="pcli-grammar-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                try:
                    process = run_cli(recorder.path, case.valid_args)
                except subprocess.TimeoutExpired:
                    failures.append(f"{case.name}: valid invocation timed out")
                    continue
            check(not recorder.errors, f"{case.name}: recorder errors: {recorder.errors}")
            if case.valid_args[0] == "version":
                # `version` is a local command; it never touches the socket,
                # even on success.
                check(
                    process.returncode == 0,
                    f"{case.name}: valid local invocation failed: {merged_output(process)!r}",
                )
                check(
                    recorder.accept_count == 0,
                    f"{case.name}: local command unexpectedly opened a connection",
                )
            else:
                check(
                    recorder.accept_count == 1,
                    f"{case.name}: valid invocation did not reach the socket "
                    f"(accept_count={recorder.accept_count}); output={merged_output(process)!r}",
                )

        # Invalid invocation (missing required option/positional, or an
        # unexpected extra argument): must be rejected before any socket
        # connection, with a message naming the missing/unexpected piece.
        with tempfile.TemporaryDirectory(prefix="pcli-grammar-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                try:
                    process = run_cli(recorder.path, case.invalid_args)
                except subprocess.TimeoutExpired:
                    failures.append(f"{case.name}: invalid invocation timed out")
                    continue
            output = merged_output(process)
            check(process.returncode != 0, f"{case.name}: invalid invocation unexpectedly exited 0; output={output!r}")
            check(
                recorder.accept_count == 0,
                f"{case.name}: invalid invocation reached the socket; output={output!r}",
            )
            check(
                case.invalid_needle.lower() in output.lower(),
                f"{case.name}: invalid invocation output missing {case.invalid_needle!r}: {output!r}",
            )

        # Unknown flag: must be rejected before any socket connection.
        with tempfile.TemporaryDirectory(prefix="pcli-grammar-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                try:
                    process = run_cli(recorder.path, case.unknown_flag_args)
                except subprocess.TimeoutExpired:
                    failures.append(f"{case.name}: unknown-flag invocation timed out")
                    continue
            output = merged_output(process)
            check(process.returncode != 0, f"{case.name}: unknown flag unexpectedly exited 0; output={output!r}")
            check(
                recorder.accept_count == 0,
                f"{case.name}: unknown flag reached the socket; output={output!r}",
            )
            check(
                "unknown option" in output.lower(),
                f"{case.name}: unknown flag output missing 'unknown option': {output!r}",
            )

    for args, method in [
        (["snapshot", "list"], "snapshot.list"),
        (["snapshot", "restore"], "snapshot.restore"),
        (["snapshot", "restore", "latest"], "snapshot.restore"),
        (["worktree", "open", "--all", "--repo", str(Path(__file__).resolve().parents[1])], "worktree.list"),
    ]:
        with tempfile.TemporaryDirectory(prefix="pcli-subcommand-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                process = run_cli(recorder.path, args)
            check(any(frame.get("method") == method for frame in recorder.frames),
                  f"valid {args!r} never reached {method}: {merged_output(process)}")

    for args in [
        ["snapshot", "list", "extra"], ["snapshot", "restore", "one", "two"],
        ["snapshot", "list", "--bogus"], ["snapshot", "restore", "--bogus"],
        ["worktree", "open", "--all", "--focus"],
        ["worktree", "open", "--all", "branch"],
    ]:
        with tempfile.TemporaryDirectory(prefix="pcli-invalid-", dir="/tmp") as directory:
            with SocketRecorder(directory) as recorder:
                process = run_cli(recorder.path, args)
            check(process.returncode != 0 and recorder.accept_count == 0,
                  f"invalid {args!r} must fail before connection: {recorder.frames!r}; {merged_output(process)}")

    for operation in ("type", "fill"):
        for suffix, text in [
            (["--selector", "#name", "--text", "hello world"], "hello world"),
            (["#name", "--", "--snapshot-after"], "--snapshot-after"),
        ]:
            args = ["browser", SURFACE_ID, operation, *suffix]
            with tempfile.TemporaryDirectory(prefix="pcli-browser-text-", dir="/tmp") as directory:
                with SocketRecorder(directory) as recorder:
                    process = run_cli(recorder.path, args)
                requests = [frame for frame in recorder.frames if frame.get("method") == f"browser.{operation}"]
                check(len(requests) == 1, f"{args!r} failed to dispatch: {merged_output(process)}")
                check(not any(frame.get("method") == "browser.snapshot" for frame in recorder.frames),
                      f"literal input triggered a snapshot operation: {recorder.frames!r}")
                if requests:
                    params = requests[0].get("params", {})
                    check(params.get("selector") == "#name" and params.get("text") == text,
                          f"browser input changed before transmission: {params!r}")
                    check(not params.get("snapshot_after", False),
                          f"literal text was treated as an action flag: {params!r}")

    if failures:
        print(f"FAIL: {len(failures)} CLI argument grammar assertion(s) failed")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: grammar-driven commands validate identically to the switch they replaced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
