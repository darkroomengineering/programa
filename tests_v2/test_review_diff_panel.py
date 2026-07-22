#!/usr/bin/env python3
"""Agent diff review panel (docs/plans/diff-review-panel.md): review.open on a dirty git repo
returns the panel + diff file list, review.comment.add/list round-trips, and
review.send_comments delivers the serialized `path:line — comment` text into the reviewed
terminal surface.

Uses the `cmux` v2 socket client directly (not the CLI subprocess) so the test exercises
`TerminalController+Review.swift`'s socket handlers precisely; `CLI/CLI+Review.swift` wraps the
exact same `review.*` methods, so this also covers the CLI's wire contract.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _git(repo_dir: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=str(repo_dir),
        check=True,
        capture_output=True,
        text=True,
    )


def _make_dirty_git_repo() -> Path:
    repo_dir = Path(tempfile.mkdtemp(prefix="programa_review_panel_"))
    _git(repo_dir, "init", "-q")
    _git(repo_dir, "config", "user.email", "test@example.com")
    _git(repo_dir, "config", "user.name", "Programa Test")

    tracked_file = repo_dir / "src_foo.txt"
    tracked_file.write_text("line one\nline two\nline three\n", encoding="utf-8")
    _git(repo_dir, "add", "src_foo.txt")
    _git(repo_dir, "commit", "-q", "-m", "initial commit")

    # Dirty the tracked file (uncommitted change) and add an untracked file, so
    # `review.open --mode uncommitted` has a non-empty, diffable file list.
    tracked_file.write_text("line one\nline two CHANGED\nline three\nline four\n", encoding="utf-8")
    (repo_dir / "untracked.txt").write_text("brand new file\n", encoding="utf-8")

    return repo_dir


def _read_terminal_text_until(c: cmux, surface_id: str, needle: str, timeout_s: float = 10.0) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        last_text = c.read_terminal_text(surface_id)
        if needle in last_text:
            return last_text
        time.sleep(0.2)
    raise cmuxError(f"Timed out waiting for marker {needle!r} in terminal output: {last_text!r}")


def main() -> int:
    repo_dir = _make_dirty_git_repo()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as c:
            created = c._call("workspace.create", {"cwd": str(repo_dir)}, timeout_s=15.0) or {}
            workspace_id = str(created.get("workspace_id") or "")
            _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")

            surfaces = c._call("surface.list", {"workspace_id": workspace_id}, timeout_s=10.0) or {}
            surface_rows = list(surfaces.get("surfaces") or [])
            _must(len(surface_rows) >= 1, f"Expected an initial terminal surface: {surfaces}")
            source_surface_id = str(surface_rows[0].get("id") or "")
            _must(bool(source_surface_id), f"Initial surface has no id: {surface_rows}")

            # 1. review.open on the dirty repo returns the panel + a non-empty diffable file list.
            opened = c._call(
                "review.open",
                {
                    "workspace_id": workspace_id,
                    "surface_id": source_surface_id,
                    "mode": "uncommitted",
                    "focus": False,
                },
                timeout_s=15.0,
            ) or {}
            review_surface_id = str(opened.get("surface_id") or "")
            _must(bool(review_surface_id), f"review.open returned no surface_id: {opened}")
            _must(
                str(opened.get("source_surface_id") or "") == source_surface_id,
                f"Expected review.open to report the reviewed surface: {opened}",
            )
            diffable_count = int(opened.get("diffable_file_count") or 0)
            _must(diffable_count >= 2, f"Expected at least 2 diffable files (modified + untracked): {opened}")
            _must(bool(opened.get("pane_id")), f"Expected review.open to return a pane_id: {opened}")

            # 2. review.comment.add / review.comment.list round-trip.
            added = c._call(
                "review.comment.add",
                {
                    "surface_id": review_surface_id,
                    "file_path": "src_foo.txt",
                    "start_line": 2,
                    "end_line": 2,
                    "text": "this line needs a fix",
                },
                timeout_s=10.0,
            ) or {}
            comment_id = str(added.get("comment_id") or "")
            _must(bool(comment_id), f"review.comment.add returned no comment_id: {added}")

            listed = c._call("review.comment.list", {"surface_id": review_surface_id}, timeout_s=10.0) or {}
            comments = list(listed.get("comments") or [])
            matching = [row for row in comments if str(row.get("id") or "") == comment_id]
            _must(len(matching) == 1, f"Expected the added comment to round-trip via review.comment.list: {listed}")
            _must(
                matching[0].get("file_path") == "src_foo.txt" and matching[0].get("start_line") == 2,
                f"Expected round-tripped comment to preserve file_path/start_line: {matching[0]}",
            )

            # Add a second comment carrying a unique marker, to prove review.send_comments
            # actually delivers serialized text into the *source* terminal (marker-in-echo
            # convention: the shell's local TTY echo displays exactly what was typed/sent,
            # independent of whether the shell parses it as a valid command).
            marker = f"REVIEW_SEND_MARKER_{int(time.time() * 1000)}"
            c._call(
                "review.comment.add",
                {
                    "surface_id": review_surface_id,
                    "file_path": "untracked.txt",
                    "start_line": 1,
                    "text": marker,
                },
                timeout_s=10.0,
            )

            # 3. review.send_comments delivers the serialized text into the source surface.
            sent = c._call("review.send_comments", {"surface_id": review_surface_id}, timeout_s=10.0) or {}
            _must(int(sent.get("sent_count") or 0) == 2, f"Expected 2 comments sent: {sent}")
            _must(
                str(sent.get("target_surface_id") or "") == source_surface_id,
                f"Expected review.send_comments to target the reviewed surface: {sent}",
            )

            terminal_text = _read_terminal_text_until(c, source_surface_id, marker)
            _must(marker in terminal_text, f"Expected marker {marker!r} to land in the reviewed terminal: {terminal_text!r}")
            _must("untracked.txt" in terminal_text, f"Expected serialized file path to land in the terminal: {terminal_text!r}")

            # Pending comments are cleared after a successful send.
            post_send_list = c._call("review.comment.list", {"surface_id": review_surface_id}, timeout_s=10.0) or {}
            _must(
                len(post_send_list.get("comments") or []) == 0,
                f"Expected review.send_comments to clear pending comments: {post_send_list}",
            )

            # Sending again with nothing pending is a no-op, not an error.
            resent = c._call("review.send_comments", {"surface_id": review_surface_id}, timeout_s=10.0) or {}
            _must(int(resent.get("sent_count") or 0) == 0, f"Expected sent_count 0 for an empty pending queue: {resent}")

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as c:
                    c.close_workspace(workspace_id)
            except Exception:
                pass
        shutil.rmtree(repo_dir, ignore_errors=True)

    print("PASS: review.open/comment/send_comments round-trip through the socket API")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
