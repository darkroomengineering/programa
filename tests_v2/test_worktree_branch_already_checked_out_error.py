#!/usr/bin/env python3
"""A second worktree.create for a branch already checked out in another worktree must return
branch_checked_out -- pre-detected via 'git worktree list --porcelain', not a silent duplicate
and not a raw git error passthrough."""

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
    (repo / "README.md").write_text("worktree branch_checked_out test\n", encoding="utf-8")
    _run_git(["add", "README.md"], repo)
    _run_git(["-c", "commit.gpgsign=false", "commit", "-m", "init"], repo)
    return repo


def main() -> int:
    temp_root = Path(tempfile.mkdtemp(prefix="programa_worktree_checked_out_"))
    branch = "feature-double-checkout"
    created_workspace = ""

    try:
        repo_path = _create_git_repo(temp_root)

        with cmux(SOCKET_PATH) as c:
            first = c._call(
                "worktree.create",
                {"repo": str(repo_path), "branch": branch},
                timeout_s=30.0,
            ) or {}
            created_workspace = str(first.get("workspace_id") or "")
            _must(bool(created_workspace), f"worktree.create returned no workspace_id: {first}")
            first_path = str((first.get("worktree") or {}).get("path") or "")
            _must(bool(first_path), f"worktree.create returned no worktree.path: {first}")

            # Second create for the same branch, at a different explicit path, must fail with
            # branch_checked_out -- not silently succeed with a duplicate worktree.
            second_path = str(Path(temp_root) / "second-worktree-location")
            error_message = ""
            try:
                c._call(
                    "worktree.create",
                    {"repo": str(repo_path), "branch": branch, "path": second_path},
                    timeout_s=30.0,
                )
            except cmuxError as exc:
                error_message = str(exc)
            _must(bool(error_message), "Second worktree.create for an already-checked-out branch should have failed")
            _must(
                error_message.startswith("branch_checked_out"),
                f"Expected branch_checked_out error, got: {error_message!r}",
            )
            _must(
                not Path(second_path).exists(),
                f"branch_checked_out must be pre-detected before creating anything at {second_path!r}",
            )

            # worktree.open with the same branch should resolve to the existing worktree, not
            # attempt to create a duplicate either.
            opened = c._call(
                "worktree.open",
                {"repo": str(repo_path), "branch": branch},
                timeout_s=30.0,
            ) or {}
            _must(
                str(opened.get("workspace_id") or "") == created_workspace,
                f"worktree.open for an already-open branch should return the existing workspace_id: {opened}",
            )
    finally:
        if created_workspace:
            try:
                with cmux(SOCKET_PATH) as c:
                    c.close_workspace(created_workspace)
            except Exception:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)

    print("PASS: worktree.create/open reject a second checkout of an already-checked-out branch with branch_checked_out")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
