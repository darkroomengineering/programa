#!/usr/bin/env python3
"""worktree.create -> worktree.remove: the branch must still resolve afterward (git never
deletes it), and the associated workspace must be closed."""

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


def _git_branch_exists(repo: Path, branch: str) -> bool:
    proc = subprocess.run(
        ["git", "branch", "--list", branch],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return bool(proc.stdout.strip())


def _create_git_repo(root: Path) -> Path:
    repo = root / "repo"
    repo.mkdir(parents=True, exist_ok=True)
    _run_git(["-c", "init.defaultBranch=main", "init"], repo)
    _run_git(["config", "user.name", "programa-test"], repo)
    _run_git(["config", "user.email", "programa-test@example.com"], repo)
    (repo / "README.md").write_text("worktree remove test\n", encoding="utf-8")
    _run_git(["add", "README.md"], repo)
    _run_git(["-c", "commit.gpgsign=false", "commit", "-m", "init"], repo)
    return repo


def main() -> int:
    temp_root = Path(tempfile.mkdtemp(prefix="programa_worktree_remove_"))
    branch = "feature-remove-keeps-branch"
    created_workspace = ""

    try:
        repo_path = _create_git_repo(temp_root)

        with cmux(SOCKET_PATH) as c:
            baseline_workspace = c.current_workspace()

            created = c._call(
                "worktree.create",
                {"repo": str(repo_path), "branch": branch},
                timeout_s=30.0,
            ) or {}
            created_workspace = str(created.get("workspace_id") or "")
            _must(bool(created_workspace), f"worktree.create returned no workspace_id: {created}")

            _must(
                _git_branch_exists(repo_path, branch),
                f"Branch {branch!r} should exist immediately after worktree.create",
            )

            removed = c._call(
                "worktree.remove",
                {"repo": str(repo_path), "branch": branch},
                timeout_s=30.0,
            ) or {}
            _must(bool(removed.get("removed")), f"worktree.remove did not report removed=true: {removed}")
            _must(
                str(removed.get("closed_workspace_id") or "") == created_workspace,
                f"worktree.remove should close the associated workspace: {removed}",
            )
            created_workspace = ""  # already closed by worktree.remove; skip the finally-block close

            _must(
                c.current_workspace() == baseline_workspace,
                "worktree.remove should not change the selected workspace",
            )

            _must(
                _git_branch_exists(repo_path, branch),
                f"Branch {branch!r} must still exist after worktree.remove -- worktree.remove must never delete branches",
            )

            listed = c._call("worktree.list", {"repo": str(repo_path)}, timeout_s=15.0) or {}
            rows = list(listed.get("worktrees") or [])
            _must(
                not any(str(row.get("branch") or "") == branch for row in rows),
                f"worktree.list should no longer show a worktree for removed branch {branch!r}: {rows}",
            )
    finally:
        if created_workspace:
            try:
                with cmux(SOCKET_PATH) as c:
                    c.close_workspace(created_workspace)
            except Exception:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)

    print("PASS: worktree.remove closes the workspace and removes the worktree, but never deletes the branch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
