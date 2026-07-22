#!/usr/bin/env python3
"""worktree.create against a temp git repo fixture: no focus steal, worktree.list shows it
as open with the matching workspace_id."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


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


def _create_git_repo(root: Path) -> Path:
    repo = root / "repo"
    repo.mkdir(parents=True, exist_ok=True)
    _run_git(["-c", "init.defaultBranch=main", "init"], repo)
    _run_git(["config", "user.name", "programa-test"], repo)
    _run_git(["config", "user.email", "programa-test@example.com"], repo)
    (repo / "README.md").write_text("worktree create/list test\n", encoding="utf-8")
    _run_git(["add", "README.md"], repo)
    _run_git(["-c", "commit.gpgsign=false", "commit", "-m", "init"], repo)
    return repo


def main() -> int:
    temp_root = Path(tempfile.mkdtemp(prefix="programa_worktree_create_list_"))
    created_workspace = ""

    try:
        repo_path = _create_git_repo(temp_root)

        with cmux(SOCKET_PATH) as c:
            baseline_workspace = c.current_workspace()

            payload = c._call(
                "worktree.create",
                {"repo": str(repo_path), "branch": "feature-create-list"},
                timeout_s=30.0,
            ) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"worktree.create returned no workspace_id: {payload}")

            worktree = payload.get("worktree") or {}
            worktree_path = str(worktree.get("path") or "")
            _must(bool(worktree_path), f"worktree.create returned no worktree.path: {payload}")
            _must(
                Path(worktree_path).is_dir(),
                f"worktree.create claimed success but path does not exist: {worktree_path!r}",
            )
            _must(
                worktree.get("branch") == "feature-create-list",
                f"Expected worktree.branch='feature-create-list', got {worktree.get('branch')!r}",
            )

            _must(
                c.current_workspace() == baseline_workspace,
                "worktree.create must not steal focus (focus defaults to false)",
            )

            listed = c._call("worktree.list", {"repo": str(repo_path)}, timeout_s=15.0) or {}
            rows = list(listed.get("worktrees") or [])
            matching = [row for row in rows if str(row.get("path") or "") == worktree_path]
            _must(bool(matching), f"worktree.list did not include the created worktree: {rows}")
            entry = matching[0]
            _must(
                bool(entry.get("is_open")),
                f"worktree.list should mark the open worktree as is_open=true: {entry}",
            )
            _must(
                str(entry.get("workspace_id") or "") == created_workspace,
                f"worktree.list workspace_id mismatch: expected {created_workspace}, got {entry.get('workspace_id')!r}",
            )
    finally:
        if created_workspace:
            try:
                with cmux(SOCKET_PATH) as c:
                    c.close_workspace(created_workspace)
            except Exception:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)

    print("PASS: worktree.create creates a worktree workspace without stealing focus; worktree.list reports it as open")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
