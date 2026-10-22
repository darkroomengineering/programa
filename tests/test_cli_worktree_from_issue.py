#!/usr/bin/env python3
"""Behavioral contract for `programa worktree create --from-issue <number> [--agent <name>]`.

Runs the built CLI against a fake unix-socket server (the harness from
`test_cli_registry_behavior.py`) with a fake `gh` first on PATH that prints
canned issue JSON or canned failures. It checks:

  - the branch sent to `worktree.create` is `issue-<number>-<title-slug>`,
    and an explicit <branch> wins over it
  - gh is called with an argv array, in the resolved repo directory
  - with --agent, the text typed into the new workspace starts the agent
    and points it at a prompt file, while the untrusted issue title and body
    appear only in that file, never in the typed command line
  - writing a prompt file removes prompt files older than 7 days
  - when the agent cannot be started, the created workspace is still
    printed (text and --json, with `agent_error`) and the exit is non-zero
  - bad arguments fail before any socket connection, and gh failures
    (missing, logged out, issue not found) fail without creating a worktree
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import time
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from test_cli_registry_behavior import CLI_PATH, SocketRecorder, merged_output, run_cli


NEW_WORKSPACE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ISSUE_TITLE = "Fix: crash when `foo` is $(rm -rf ~) -- and the big tail goes on"
ISSUE_BODY = "Steps:\n1. run $(touch PWNED_BODY)\n2. it's `broken`; echo 'quoted'\n\ttabbed line"
ISSUE_URL = "https://github.com/example/repo/issues/12"
EXPECTED_BRANCH = "issue-12-fix-crash-when-foo-is-rm-rf-and-the-big"

FAKE_GH = f"""#!{sys.executable}
import json, os, sys
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(json.dumps({{"argv": sys.argv[1:], "cwd": os.getcwd()}}) + "\\n")
args = sys.argv[1:]
if args[:2] != ["issue", "view"] or len(args) < 3:
    sys.stderr.write("fake gh: unexpected arguments\\n")
    sys.exit(2)
number = args[2]
if number == "12":
    print(json.dumps({{"number": 12, "title": {ISSUE_TITLE!r}, "body": {ISSUE_BODY!r}, "url": {ISSUE_URL!r}}}))
elif number == "7":
    print(json.dumps({{"number": 7, "title": "!!! ???", "body": "", "url": "https://github.com/example/repo/issues/7"}}))
elif number == "401":
    sys.stderr.write("To get started with GitHub CLI, please run:  gh auth login\\n")
    sys.exit(4)
else:
    sys.stderr.write("GraphQL: Could not resolve to an issue or pull request with the number of " + number + ". (repository.issue)\\n")
    sys.exit(1)
"""


class WorktreeRecorder(SocketRecorder):
    def _result_for(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "worktree.create":
            return {
                "workspace_id": NEW_WORKSPACE_ID,
                "workspace_ref": "workspace:9",
                "worktree": {"path": "/tmp/fake-worktree", "branch": params.get("branch")},
            }
        return super()._result_for(method, params)


class FailingSendRecorder(WorktreeRecorder):
    """Creates the worktree but answers surface.send_text with an error."""

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
                method = request.get("method", "")
                if method == "surface.send_text":
                    response = {"id": request.get("id"), "ok": False,
                                "error": {"code": "not_found", "message": "fixture surface is gone"}}
                else:
                    response = {"id": request.get("id"), "ok": True,
                                "result": self._result_for(method, request.get("params", {}))}
                connection.sendall(json.dumps(response, separators=(",", ":")).encode("utf-8") + b"\n")


def frames_for(recorder: SocketRecorder, method: str) -> list[dict[str, Any]]:
    return [frame for frame in recorder.frames if frame.get("method") == method]


def main() -> int:
    if not CLI_PATH or not Path(CLI_PATH).is_file() or not os.access(CLI_PATH, os.X_OK):
        print("FAIL: PROGRAMA_CLI_BIN must point to an executable programa CLI")
        return 1
    git = shutil.which("git")
    if not git:
        print("FAIL: git must be on PATH")
        return 1

    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    with tempfile.TemporaryDirectory(prefix="pwti-", dir="/tmp") as root:
        repo = os.path.join(root, "repo")
        os.makedirs(repo)
        subprocess.run([git, "init", "-q", repo], check=True)
        real_repo = os.path.realpath(repo)

        fake_bin = os.path.join(root, "bin")
        os.makedirs(fake_bin)
        fake_gh = os.path.join(fake_bin, "gh")
        Path(fake_gh).write_text(FAKE_GH)
        os.chmod(fake_gh, 0o755)

        path_without_gh = ":".join(
            entry for entry in os.environ.get("PATH", "/usr/bin:/bin").split(":")
            if entry and not os.access(os.path.join(entry, "gh"), os.X_OK)
        )

        gh_log = os.path.join(root, "gh.log")

        def run(name: str, args: list[str], *, path: str | None = None, recorder_class: type = WorktreeRecorder):
            if os.path.exists(gh_log):
                os.remove(gh_log)
            socket_dir = tempfile.mkdtemp(prefix="s", dir=root)
            with recorder_class(socket_dir) as recorder:
                try:
                    process = run_cli(
                        recorder.path,
                        args,
                        env_overrides={
                            "PATH": path or f"{fake_bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
                            "FAKE_GH_LOG": gh_log,
                        },
                    )
                except subprocess.TimeoutExpired:
                    failures.append(f"{name}: CLI timed out")
                    return None, recorder, []
            for error in recorder.errors:
                failures.append(f"{name}: {error}")
            calls = []
            if os.path.exists(gh_log):
                calls = [json.loads(line) for line in Path(gh_log).read_text().splitlines() if line]
            return process, recorder, calls

        # Derived branch name, gh argv and working directory.
        process, recorder, calls = run("derived branch", ["worktree", "create", "--from-issue", "12", "--repo", repo])
        if process is not None:
            check(process.returncode == 0, f"derived branch: exit {process.returncode}: {merged_output(process)}")
            creates = frames_for(recorder, "worktree.create")
            check(len(creates) == 1, f"derived branch: expected one worktree.create, got {len(creates)}")
            if creates:
                params = creates[0].get("params", {})
                check(params.get("branch") == EXPECTED_BRANCH, f"derived branch: branch was {params.get('branch')!r}")
                check(os.path.realpath(params.get("repo", "")) == real_repo, f"derived branch: repo was {params.get('repo')!r}")
            check(not frames_for(recorder, "surface.send_text"), "derived branch: no agent was requested, but text was sent")
            check(len(calls) == 1, f"derived branch: expected one gh call, got {calls!r}")
            if calls:
                check(calls[0]["argv"] == ["issue", "view", "12", "--json", "number,title,body,url"],
                      f"derived branch: gh argv was {calls[0]['argv']!r}")
                check(os.path.realpath(calls[0]["cwd"]) == real_repo, f"derived branch: gh ran in {calls[0]['cwd']!r}")
            check("issue=#12" in process.stdout, f"derived branch: summary lacks issue=#12: {process.stdout!r}")

        # An explicit branch wins over the derived one.
        process, recorder, _ = run("explicit branch", ["worktree", "create", "my-branch", "--from-issue", "12", "--repo", repo])
        if process is not None:
            check(process.returncode == 0, f"explicit branch: exit {process.returncode}: {merged_output(process)}")
            creates = frames_for(recorder, "worktree.create")
            branch = creates[0].get("params", {}).get("branch") if creates else None
            check(branch == "my-branch", f"explicit branch: branch was {branch!r}")

        # A title with no letters or digits falls back to issue-<number>.
        process, recorder, _ = run("empty slug", ["worktree", "create", "--from-issue", "7", "--repo", repo])
        if process is not None:
            check(process.returncode == 0, f"empty slug: exit {process.returncode}: {merged_output(process)}")
            creates = frames_for(recorder, "worktree.create")
            branch = creates[0].get("params", {}).get("branch") if creates else None
            check(branch == "issue-7", f"empty slug: branch was {branch!r}")

        prompt_dirs: list[str] = []

        # --agent types a launch command that only references the prompt file.
        for agent, prefix in (("claude", "claude '"), ("opencode", "opencode --prompt '")):
            name = f"agent {agent}"
            process, recorder, _ = run(name, ["worktree", "create", "--from-issue", "12", "--agent", agent, "--repo", repo])
            if process is None:
                continue
            check(process.returncode == 0, f"{name}: exit {process.returncode}: {merged_output(process)}")
            sends = frames_for(recorder, "surface.send_text")
            check(len(sends) == 1, f"{name}: expected one surface.send_text, got {len(sends)}")
            if not sends:
                continue
            params = sends[0].get("params", {})
            text = params.get("text", "")
            check(params.get("workspace_id") == NEW_WORKSPACE_ID, f"{name}: text went to {params.get('workspace_id')!r}")
            check(text.startswith(prefix), f"{name}: launch command was {text!r}")
            check(text.endswith("\n") and text.count("\n") == 1, f"{name}: launch command must be one line: {text!r}")
            for fragment in ("PWNED_BODY", "rm -rf", "$(", "`", ISSUE_URL):
                check(fragment not in text, f"{name}: issue text {fragment!r} leaked into the typed command: {text!r}")
            match = re.search(r" in (/\S+\.md);", text)
            check(match is not None, f"{name}: no prompt file path in {text!r}")
            if match is None:
                continue
            prompt_path = match.group(1)
            prompt_dirs.append(os.path.dirname(prompt_path))
            if not os.path.isfile(prompt_path):
                failures.append(f"{name}: prompt file {prompt_path} does not exist")
                continue
            content = Path(prompt_path).read_text()
            for expected in (ISSUE_TITLE, ISSUE_URL, ISSUE_BODY):
                check(expected in content, f"{name}: prompt file lacks {expected!r}")
            mode = stat.S_IMODE(os.stat(prompt_path).st_mode)
            check(mode == 0o600, f"{name}: prompt file mode is {oct(mode)}")
            os.remove(prompt_path)

        # Writing a prompt file removes ones older than 7 days and keeps newer ones.
        if prompt_dirs:
            prompt_dir = prompt_dirs[0]
            old_file = os.path.join(prompt_dir, "issue-0-retention-old.md")
            fresh_file = os.path.join(prompt_dir, "issue-0-retention-fresh.md")
            for planted in (old_file, fresh_file):
                Path(planted).write_text("planted by test_cli_worktree_from_issue\n")
            eight_days_ago = time.time() - 8 * 24 * 60 * 60
            os.utime(old_file, (eight_days_ago, eight_days_ago))
            process, recorder, _ = run("prompt retention", ["worktree", "create", "--from-issue", "12", "--agent", "claude", "--repo", repo])
            if process is not None:
                check(process.returncode == 0, f"prompt retention: exit {process.returncode}: {merged_output(process)}")
                check(not os.path.exists(old_file), "prompt retention: a prompt file older than 7 days was kept")
                check(os.path.exists(fresh_file), "prompt retention: a recent prompt file was removed")
                for send in frames_for(recorder, "surface.send_text"):
                    found = re.search(r" in (/\S+\.md);", send.get("params", {}).get("text", ""))
                    if found and os.path.isfile(found.group(1)):
                        os.remove(found.group(1))
            for planted in (old_file, fresh_file):
                if os.path.exists(planted):
                    os.remove(planted)

        # A failed agent start still reports the workspace that was created.
        process, recorder, _ = run(
            "agent start fails",
            ["worktree", "create", "--from-issue", "12", "--agent", "claude", "--repo", repo],
            recorder_class=FailingSendRecorder,
        )
        if process is not None:
            check(process.returncode != 0, f"agent start fails: expected failure, got exit 0: {merged_output(process)}")
            check(len(frames_for(recorder, "worktree.create")) == 1, "agent start fails: worktree.create was not sent once")
            check("workspace=workspace:9" in process.stdout and f"branch={EXPECTED_BRANCH}" in process.stdout,
                  f"agent start fails: stdout lacks the created workspace: {process.stdout!r}")
            check("starting claude failed" in process.stderr and "fixture surface is gone" in process.stderr,
                  f"agent start fails: stderr lacks the agent error: {process.stderr!r}")
            leftover = re.search(r"prompt_file=(\S+)", process.stdout)
            check(leftover is not None, f"agent start fails: stdout lacks prompt_file: {process.stdout!r}")
            if leftover and os.path.isfile(leftover.group(1)):
                os.remove(leftover.group(1))

        process, recorder, _ = run(
            "agent start fails (json)",
            ["--json", "worktree", "create", "--from-issue", "12", "--agent", "claude", "--repo", repo],
            recorder_class=FailingSendRecorder,
        )
        if process is not None:
            check(process.returncode != 0, f"agent start fails (json): expected failure, got exit 0: {merged_output(process)}")
            try:
                payload = json.loads(process.stdout)
            except json.JSONDecodeError:
                payload = None
                failures.append(f"agent start fails (json): stdout is not one JSON object: {process.stdout!r}")
            if isinstance(payload, dict):
                check(payload.get("workspace_id") == NEW_WORKSPACE_ID, f"agent start fails (json): workspace_id was {payload.get('workspace_id')!r}")
                check("fixture surface is gone" in str(payload.get("agent_error", "")),
                      f"agent start fails (json): agent_error was {payload.get('agent_error')!r}")
            check("starting claude failed" in process.stderr, f"agent start fails (json): stderr was {process.stderr!r}")
            if isinstance(payload, dict) and os.path.isfile(str(payload.get("prompt_file", ""))):
                os.remove(payload["prompt_file"])

        # Bad arguments are rejected before the CLI touches the socket.
        for name, args, needle in (
            ("non-numeric issue", ["worktree", "create", "--from-issue", "abc", "--repo", repo], "positive issue number"),
            ("zero issue", ["worktree", "create", "--from-issue", "0", "--repo", repo], "positive issue number"),
            ("agent without issue", ["worktree", "create", "b", "--agent", "claude", "--repo", repo], "requires --from-issue"),
            ("unknown agent", ["worktree", "create", "--from-issue", "12", "--agent", "bogus", "--repo", repo], "--agent must be one of"),
            ("issue on open", ["worktree", "open", "b", "--from-issue", "12", "--repo", repo], "only valid for create"),
        ):
            process, recorder, calls = run(name, args)
            if process is None:
                continue
            output = merged_output(process)
            check(process.returncode != 0, f"{name}: expected failure, got exit 0: {output}")
            check(needle in output, f"{name}: expected {needle!r} in output: {output}")
            check(recorder.accept_count == 0, f"{name}: connected to the socket {recorder.accept_count} time(s)")
            check(not calls, f"{name}: gh was called: {calls!r}")

        # gh failures stop before anything is created.
        for name, args, path, needle in (
            ("gh missing", ["worktree", "create", "--from-issue", "12", "--repo", repo], path_without_gh, "GitHub CLI (gh)"),
            ("gh logged out", ["worktree", "create", "--from-issue", "401", "--repo", repo], None, "gh auth login"),
            ("issue not found", ["worktree", "create", "--from-issue", "404", "--repo", repo], None, "issue #404 not found"),
        ):
            process, recorder, _ = run(name, args, path=path)
            if process is None:
                continue
            output = merged_output(process)
            check(process.returncode != 0, f"{name}: expected failure, got exit 0: {output}")
            check(needle in output, f"{name}: expected {needle!r} in output: {output}")
            check(not frames_for(recorder, "worktree.create"), f"{name}: worktree.create was sent")

    if failures:
        print("FAIL: worktree create --from-issue")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: worktree create --from-issue")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
