#!/usr/bin/env python3
"""Protect tagged reloads from pruning; retain current and two inactive builds."""

import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


def process_commands():
    # Failure to inspect running apps/builds must never authorize deletion.
    return subprocess.check_output(["ps", "-axww", "-o", "args="], text=True)


def is_active(path, processes):
    # reload also exposes a /tmp symlink; launched processes may retain that path.
    return any(prefix in processes for prefix in (
        str(path), f"/tmp/{path.name}/", f"/private/tmp/{path.name}/",
    ))


def prune(root, current, commands=process_commands):
    if not shutil.rmtree.avoids_symlink_attacks:
        print("Build cache: cleanup skipped; safe directory removal unavailable.")
        return
    candidates = []
    processes = commands()
    for path in root.iterdir():
        if not re.fullmatch(r"programa-[a-z0-9]+(?:-[a-z0-9]+)*", path.name):
            continue
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            continue
        if path == current or is_active(path, processes):
            continue
        # Recognize only build products, never arbitrary programa-* directories.
        debug = path / "Build/Products/Debug"
        if not debug.is_dir() or debug.resolve().parent.parent.parent != path:
            continue
        marker = path / ".programa-last-success"
        modified = marker.stat().st_mtime if marker.is_file() and not marker.is_symlink() else debug.stat().st_mtime
        candidates.append((modified, path, info.st_ino))
    removed = 0
    for _, path, inode in sorted(candidates, reverse=True)[2:]:
        # Recheck immediately before deleting: an older app may have launched.
        info = path.lstat()
        if (is_active(path, commands()) or not stat.S_ISDIR(info.st_mode)
                or info.st_ino != inode or info.st_uid != os.getuid()):
            continue
        shutil.rmtree(path)
        removed += 1
        print(f"Build cache: removed {path} (rebuildable; not moved to Trash).")
    print(f"Build cache: removed {removed} inactive tag(s); kept current, active, and two newest inactive builds.")


def main():
    tag, derived, managed, *command = sys.argv[1:]
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", tag) or not command:
        raise ValueError("Expected a sanitized reload tag and build command")
    if managed not in ("0", "1"):
        raise ValueError("Expected managed flag to be 0 or 1")
    managed = managed == "1"
    root = Path.home() / "Library/Developer/Xcode/DerivedData"
    root.mkdir(parents=True, exist_ok=True)
    # Decline cleanup when any ancestor redirects the configured cache location.
    safe_root = root.resolve() == root
    lock_path = root / ".programa-tagged-builds.lock"
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "r+") as lock:
        if os.fstat(lock.fileno()).st_uid != os.getuid():
            raise PermissionError("Tagged build cache lock is not owned by current user")
        # Builds can overlap. Cleanup requires no managed build in progress, and
        # new builds wait until removal finishes. flock releases on crash/exit.
        fcntl.flock(lock, fcntl.LOCK_SH)
        environment = dict(os.environ, PROGRAMA_RELOAD_CACHE_MANAGED="1")
        result = subprocess.run(command, env=environment, pass_fds=(lock.fileno(),))
        if result.returncode != 0:
            return result.returncode
        # Protect whichever directory the build actually used, not the
        # tag-derived path -- shared DerivedData (multiple tags, one dir)
        # and --derived-data overrides both mean the build dir and
        # "programa-<tag>" can differ.
        current = Path(derived)
        # Custom/unsafe build locations still hold the shared lock, but do not
        # manage retention or mark an unrelated canonical tag as recently built.
        # "managed" means the caller resolved derived from the tag/shared
        # scheme itself, not an explicit --derived-data override -- a
        # user-chosen path can coincidentally match the tag/shared naming or
        # even collide with a real cache entry, so symlink-ness alone can't
        # tell a custom destination from a managed one.
        if not (managed and safe_root and not current.is_symlink()):
            return 0
        try:
            marker = os.open(current / ".programa-last-success", os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            try:
                os.utime(marker, None)
            finally:
                os.close(marker)
        except OSError as error:
            print(f"Build cache: could not record successful build: {error}", file=sys.stderr)
        fcntl.flock(lock, fcntl.LOCK_UN)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("Build cache: cleanup deferred while another tagged build is active.")
            return 0
        try:
            prune(root, current)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"Build cache: cleanup stopped safely: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
