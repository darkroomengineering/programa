#!/usr/bin/env python3
"""Regression: `programa opencode install-integration` / `uninstall-integration` (#139).

Runs entirely against the CLI binary with no app/socket involved — the `opencode`
command branch is dispatched before any socket connection is opened. Exercises:
- Fresh install: writes plugins/programa.js containing the opencode-hook marker
  and the "Managed by" marker comment, under $OPENCODE_CONFIG_DIR/plugins/.
- Idempotency: a second install run makes no further changes (byte-identical,
  "already installed" fast path).
- Modified-file reinstall: a hand-edited file triggers a diff, and --yes
  restores the canonical content.
- Uninstall: removes the file.
- Uninstall refuses when the file lacks the marker comment (user replaced the
  managed file with their own content) — the file is left intact.
- Declining the confirmation prompt leaves the file untouched.
"""

import glob
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


HOOK_MARKER = "opencode-hook"
MANAGED_MARKER = "Managed by `programa opencode install-integration`"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/programa-*/Build/Products/Debug/programa")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate programa CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run(
    cli: str,
    args: List[str],
    config_dir: str,
    input_text: Optional[str] = None,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        env.pop(var, None)
    env["OPENCODE_CONFIG_DIR"] = config_dir
    return subprocess.run(
        [cli] + args,
        capture_output=True,
        text=True,
        check=False,
        env=env,
        input=input_text,
    )


def _merged(proc: subprocess.CompletedProcess) -> str:
    return f"{proc.stdout}\n{proc.stderr}".strip()


def _plugin_path(config_dir: str) -> Path:
    return Path(config_dir) / "plugins" / "programa.js"


def test_fresh_install(cli: str) -> None:
    with tempfile.TemporaryDirectory() as config_dir:
        proc = _run(cli, ["opencode", "install-integration", "--yes"], config_dir)
        _must(proc.returncode == 0, f"install-integration should exit 0: {_merged(proc)}")

        plugin_path = _plugin_path(config_dir)
        _must(plugin_path.exists(), f"programa.js should be created at {plugin_path}")

        content = plugin_path.read_text(encoding="utf-8")
        _must(HOOK_MARKER in content, f"expected '{HOOK_MARKER}' in plugin content, got: {content}")
        _must(MANAGED_MARKER in content, f"expected marker comment in plugin content, got: {content}")

        print("  PASS: fresh install writes plugins/programa.js with hook + marker")


def test_idempotent_reinstall(cli: str) -> None:
    with tempfile.TemporaryDirectory() as config_dir:
        proc = _run(cli, ["opencode", "install-integration", "--yes"], config_dir)
        _must(proc.returncode == 0, f"first install should exit 0: {_merged(proc)}")

        plugin_path = _plugin_path(config_dir)
        before = plugin_path.read_bytes()

        proc2 = _run(cli, ["opencode", "install-integration", "--yes"], config_dir)
        _must(proc2.returncode == 0, f"second install should exit 0: {_merged(proc2)}")
        _must(
            "already installed" in _merged(proc2).lower(),
            f"reinstall should hit the already-installed fast path, got: {_merged(proc2)}",
        )

        after = plugin_path.read_bytes()
        _must(before == after, "reinstalling should not change programa.js bytes")

        print("  PASS: reinstall is idempotent (byte-identical, fast path message)")


def test_modified_file_reinstall_shows_diff_and_restores(cli: str) -> None:
    with tempfile.TemporaryDirectory() as config_dir:
        proc = _run(cli, ["opencode", "install-integration", "--yes"], config_dir)
        _must(proc.returncode == 0, f"first install should exit 0: {_merged(proc)}")

        plugin_path = _plugin_path(config_dir)
        canonical = plugin_path.read_text(encoding="utf-8")

        # Hand-edit the managed file (still contains the marker).
        modified = canonical + "\n// user tweak\n"
        plugin_path.write_text(modified, encoding="utf-8")

        proc2 = _run(cli, ["opencode", "install-integration"], config_dir, input_text="n\n")
        _must(proc2.returncode == 0, f"declining reinstall should still exit 0: {_merged(proc2)}")
        output = _merged(proc2)
        _must("+" in output or "-" in output, f"expected a diff view in output, got: {output}")
        _must(
            plugin_path.read_text(encoding="utf-8") == modified,
            "declining the reinstall prompt should leave the modified file untouched",
        )

        proc3 = _run(cli, ["opencode", "install-integration", "--yes"], config_dir)
        _must(proc3.returncode == 0, f"--yes reinstall should exit 0: {_merged(proc3)}")
        _must(
            plugin_path.read_text(encoding="utf-8") == canonical,
            "programa opencode install-integration --yes should restore canonical content",
        )

        print("  PASS: modified-file reinstall shows a diff and --yes restores canonical content")


def test_uninstall_deletes_file(cli: str) -> None:
    with tempfile.TemporaryDirectory() as config_dir:
        proc = _run(cli, ["opencode", "install-integration", "--yes"], config_dir)
        _must(proc.returncode == 0, f"install should exit 0: {_merged(proc)}")

        plugin_path = _plugin_path(config_dir)
        _must(plugin_path.exists(), "programa.js should exist before uninstall")

        proc2 = _run(cli, ["opencode", "uninstall-integration", "--yes"], config_dir)
        _must(proc2.returncode == 0, f"uninstall should exit 0: {_merged(proc2)}")
        _must(not plugin_path.exists(), "programa.js should be removed after uninstall")

        print("  PASS: uninstall deletes the managed plugin file")


def test_uninstall_refuses_without_marker(cli: str) -> None:
    with tempfile.TemporaryDirectory() as config_dir:
        plugin_path = _plugin_path(config_dir)
        plugin_path.parent.mkdir(parents=True, exist_ok=True)
        custom_content = "// my totally custom opencode plugin, not managed by programa\nexport const Custom = async () => ({})\n"
        plugin_path.write_text(custom_content, encoding="utf-8")

        proc = _run(cli, ["opencode", "uninstall-integration", "--yes"], config_dir)
        _must(
            proc.returncode != 0,
            f"uninstall should refuse (non-zero exit) when the file lacks the marker, got: {_merged(proc)}",
        )
        _must(
            plugin_path.exists() and plugin_path.read_text(encoding="utf-8") == custom_content,
            "uninstall must leave a non-programa-managed file untouched",
        )

        print("  PASS: uninstall refuses to delete a file missing the marker comment, file intact")


def test_decline_confirmation_leaves_file_untouched(cli: str) -> None:
    with tempfile.TemporaryDirectory() as config_dir:
        plugin_path = _plugin_path(config_dir)
        _must(not plugin_path.exists(), "programa.js should not pre-exist for this test")

        proc = _run(cli, ["opencode", "install-integration"], config_dir, input_text="n\n")

        if proc.returncode == 0:
            _must(
                not plugin_path.exists(),
                f"declining confirmation with exit 0 must leave programa.js untouched, but it was created: {_merged(proc)}",
            )
        # A non-zero exit code is also an acceptable "clean abort" outcome.

        print("  PASS: declining the confirmation prompt leaves programa.js untouched")


def main() -> int:
    cli = _find_cli_binary()
    print(f"Using CLI: {cli}")

    test_fresh_install(cli)
    test_idempotent_reinstall(cli)
    test_modified_file_reinstall_shows_diff_and_restores(cli)
    test_uninstall_deletes_file(cli)
    test_uninstall_refuses_without_marker(cli)
    test_decline_confirmation_leaves_file_untouched(cli)

    print("\nPASS: All opencode install-integration tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
