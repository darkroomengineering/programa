#!/usr/bin/env python3
"""worktree.create --layout: a saved layout with a relative cwd must resolve against the new
worktree's root, not the caller's own working directory.

The layout fixture is written directly to disk in the documented on-disk format
(~/.config/programa/layouts/<name>.json, see docs/plans/worktree-and-layouts.md) rather than
produced via layout.save, so this test can pin an exact relative cwd ("api") without depending
on OSC7 shell-integration telemetry to capture it live.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
LAYOUTS_DIR = Path(os.path.expanduser("~/.config/programa/layouts"))


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _run_git(args: list[str], cwd: Path) -> None:
    subprocess.run(
        ["git"] + args,
        cwd=cwd,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def _create_git_repo_with_subdir(root: Path) -> Path:
    repo = root / "repo"
    api_dir = repo / "api"
    api_dir.mkdir(parents=True, exist_ok=True)
    _run_git(["-c", "init.defaultBranch=main", "init"], repo)
    _run_git(["config", "user.name", "programa-test"], repo)
    _run_git(["config", "user.email", "programa-test@example.com"], repo)
    (repo / "README.md").write_text("layout relative cwd test\n", encoding="utf-8")
    (api_dir / ".gitkeep").write_text("", encoding="utf-8")
    _run_git(["add", "-A"], repo)
    _run_git(["-c", "commit.gpgsign=false", "commit", "-m", "init"], repo)
    return repo


def _write_layout_fixture(name: str) -> Path:
    LAYOUTS_DIR.mkdir(parents=True, exist_ok=True)
    path = LAYOUTS_DIR / f"{name}.json"
    path.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "name": name,
                "savedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "layout": {
                    "pane": {
                        "surfaces": [
                            {"type": "terminal", "cwd": "api"}
                        ]
                    }
                },
            }
        ),
        encoding="utf-8",
    )
    return path


def _pwd_via_terminal(c: cmux, surface_id: str, timeout_s: float = 8.0) -> str:
    token = f"WORKTREE_CWD_CHECK_{int(time.time() * 1000)}"
    c.send_surface(surface_id, f"printf '{token}:%s\\n' \"$(pwd)\"\\n")

    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        last_text = c.read_terminal_text(surface_id)
        for line in last_text.splitlines():
            if line.startswith(f"{token}:"):
                return line[len(token) + 1:].strip()
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for pwd marker {token!r} in surface output: {last_text!r}")


def main() -> int:
    layout_name = f"test_worktree_relcwd_{int(time.time() * 1000)}"
    temp_root = Path(tempfile.mkdtemp(prefix="programa_worktree_layout_relcwd_"))
    created_workspace = ""
    layout_path: Path | None = None

    # The caller's own cwd (this test process) -- the applied terminal's cwd must NOT end up
    # here; it must be under the new worktree's root instead.
    caller_cwd = os.getcwd()

    try:
        repo_path = _create_git_repo_with_subdir(temp_root)
        layout_path = _write_layout_fixture(layout_name)

        with cmux(SOCKET_PATH) as c:
            payload = c._call(
                "worktree.create",
                {
                    "repo": str(repo_path),
                    "branch": "feature-layout-relcwd",
                    "layout": layout_name,
                },
                timeout_s=30.0,
            ) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"worktree.create returned no workspace_id: {payload}")
            worktree_path = str((payload.get("worktree") or {}).get("path") or "")
            _must(bool(worktree_path), f"worktree.create returned no worktree.path: {payload}")

            surfaces = c._call("surface.list", {"workspace_id": created_workspace}, timeout_s=10.0) or {}
            rows = list(surfaces.get("surfaces") or [])
            _must(bool(rows), f"Expected at least one surface in the worktree workspace: {surfaces}")
            surface_id = str(rows[0].get("id") or "")
            _must(bool(surface_id), f"Surface row has no id: {rows[0]}")

            observed_cwd = _pwd_via_terminal(c, surface_id)
            expected_cwd = str(Path(worktree_path) / "api")
            _must(
                observed_cwd == expected_cwd,
                f"Expected terminal cwd {expected_cwd!r} (worktree root + relative layout cwd), got {observed_cwd!r}",
            )
            _must(
                not observed_cwd.startswith(caller_cwd),
                f"Terminal cwd resolved against the test process's own cwd ({caller_cwd!r}) instead of the worktree root",
            )
    finally:
        if created_workspace:
            try:
                with cmux(SOCKET_PATH) as c:
                    c._call(
                        "worktree.remove",
                        {"repo": str(temp_root / "repo"), "branch": "feature-layout-relcwd"},
                        timeout_s=30.0,
                    )
            except Exception:
                pass
        if layout_path is not None:
            try:
                layout_path.unlink(missing_ok=True)
            except Exception:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)

    print("PASS: worktree create --layout resolves relative layout cwds against the new worktree root")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
