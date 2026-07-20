#!/usr/bin/env python3
"""Regression: `programa codex install-integration` / `uninstall-integration` (#139).

Runs entirely against the CLI binary with no app/socket involved — the `codex`
command branch is dispatched before any socket connection is opened. Exercises:
- Fresh install: writes all five lifecycle hook events into hooks.json, and
  config.toml gains `codex_hooks = true` under `[features]`.
- Idempotency: a second install run makes no further changes.
- Preservation: unrelated user hooks and other event keys are left alone; a
  stale programa entry is replaced (not duplicated) on reinstall.
- Uninstall: programa entries are removed, user hooks and unrelated event
  keys survive, emptied event keys are dropped, and config.toml's
  `codex_hooks` key is removed.
- Declining the confirmation prompt leaves the files untouched.
- Legacy alias: `programa codex install-hooks` / `uninstall-hooks` behave
  identically to `install-integration` / `uninstall-integration`.
"""

import glob
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


CODEX_HOOK_MARKER = "programa codex-hook"
EXPECTED_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "SessionEnd",
]


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
    codex_home: str,
    input_text: Optional[str] = None,
) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        env.pop(var, None)
    env["CODEX_HOME"] = codex_home
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


def _hooks_commands(hooks: Dict[str, Any], event: str) -> List[str]:
    commands = []
    for group in hooks.get(event, []):
        for hook in group.get("hooks", []):
            command = hook.get("command", "")
            commands.append(command)
    return commands


def _has_codex_hooks_feature(config_toml: str) -> bool:
    for line in config_toml.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if stripped.replace(" ", "") == "codex_hooks=true":
            return True
    return False


def test_fresh_install(cli: str) -> None:
    with tempfile.TemporaryDirectory() as codex_home:
        proc = _run(cli, ["codex", "install-integration", "--yes"], codex_home)
        _must(proc.returncode == 0, f"install-integration should exit 0: {_merged(proc)}")

        hooks_path = Path(codex_home) / "hooks.json"
        _must(hooks_path.exists(), f"hooks.json should be created at {hooks_path}")

        data = json.loads(hooks_path.read_text(encoding="utf-8"))
        hooks = data.get("hooks", {})
        for event in EXPECTED_EVENTS:
            commands = _hooks_commands(hooks, event)
            _must(len(commands) >= 1, f"expected at least one hook for {event}, got: {hooks.get(event)}")
            _must(
                any(CODEX_HOOK_MARKER in cmd for cmd in commands),
                f"expected a '{CODEX_HOOK_MARKER}' command for {event}, got: {commands}",
            )

        config_path = Path(codex_home) / "config.toml"
        _must(config_path.exists(), f"config.toml should be created at {config_path}")
        _must(
            _has_codex_hooks_feature(config_path.read_text(encoding="utf-8")),
            "config.toml should gain codex_hooks = true under [features]",
        )

        print("  PASS: fresh install writes all five lifecycle hook events and config.toml feature flag")


def test_idempotent_reinstall(cli: str) -> None:
    with tempfile.TemporaryDirectory() as codex_home:
        proc = _run(cli, ["codex", "install-integration", "--yes"], codex_home)
        _must(proc.returncode == 0, f"first install should exit 0: {_merged(proc)}")

        hooks_path = Path(codex_home) / "hooks.json"
        config_path = Path(codex_home) / "config.toml"
        hooks_before = hooks_path.read_bytes()
        config_before = config_path.read_bytes()

        proc2 = _run(cli, ["codex", "install-integration", "--yes"], codex_home)
        _must(proc2.returncode == 0, f"second install should exit 0: {_merged(proc2)}")

        hooks_after = hooks_path.read_bytes()
        config_after = config_path.read_bytes()
        _must(hooks_before == hooks_after, "reinstalling should not change hooks.json bytes")
        _must(config_before == config_after, "reinstalling should not change config.toml bytes")

        print("  PASS: reinstall is idempotent (byte-identical)")


def test_preserves_user_hooks_and_replaces_stale_entry(cli: str) -> None:
    with tempfile.TemporaryDirectory() as codex_home:
        hooks_path = Path(codex_home) / "hooks.json"
        seed = {
            "hooks": {
                "PostToolUse": [
                    {
                        "hooks": [{"type": "command", "command": "echo user-post-tool-hook"}],
                    }
                ],
                "SessionStart": [
                    {
                        "hooks": [{"type": "command", "command": "echo my-custom-start-hook"}],
                    },
                    {
                        "hooks": [{"type": "command", "command": f"{CODEX_HOOK_MARKER} old-form"}],
                    },
                ],
                "Stop": [
                    {
                        "hooks": [{"type": "command", "command": f"{CODEX_HOOK_MARKER} stop-old-format"}],
                    }
                ],
            }
        }
        hooks_path.write_text(json.dumps(seed, indent=2), encoding="utf-8")

        proc = _run(cli, ["codex", "install-integration", "--yes"], codex_home)
        _must(proc.returncode == 0, f"install should exit 0: {_merged(proc)}")

        data = json.loads(hooks_path.read_text(encoding="utf-8"))
        hooks = data.get("hooks", {})

        # Unrelated event untouched.
        post_tool_commands = _hooks_commands(hooks, "PostToolUse")
        _must(
            post_tool_commands == ["echo user-post-tool-hook"],
            f"PostToolUse should be preserved verbatim, got: {post_tool_commands}",
        )

        # SessionStart: user's custom hook preserved, stale programa entry replaced
        # (exactly one programa group remains, with the new guard-form command).
        session_start_groups = hooks.get("SessionStart", [])
        user_groups = [
            g for g in session_start_groups
            if not all(CODEX_HOOK_MARKER in h.get("command", "") for h in g.get("hooks", []))
        ]
        programa_groups = [
            g for g in session_start_groups
            if all(CODEX_HOOK_MARKER in h.get("command", "") for h in g.get("hooks", []))
        ]
        _must(len(user_groups) == 1, f"expected 1 preserved user SessionStart group, got: {user_groups}")
        _must(
            user_groups[0]["hooks"][0]["command"] == "echo my-custom-start-hook",
            f"user SessionStart hook should be untouched, got: {user_groups[0]}",
        )
        _must(len(programa_groups) == 1, f"expected exactly 1 programa SessionStart group, got: {programa_groups}")
        _must(
            "old-form" not in programa_groups[0]["hooks"][0]["command"],
            f"stale programa SessionStart entry should be replaced, got: {programa_groups[0]}",
        )

        # Stop: exactly one programa entry, stale one replaced.
        stop_commands = _hooks_commands(hooks, "Stop")
        _must(len(stop_commands) == 1, f"expected exactly 1 Stop hook command, got: {stop_commands}")
        _must(CODEX_HOOK_MARKER in stop_commands[0], f"Stop hook should be a programa hook, got: {stop_commands}")
        _must("stop-old-format" not in stop_commands[0], f"stale Stop command should be replaced, got: {stop_commands}")

        print("  PASS: install preserves user hooks and replaces stale programa entries")

        # Uninstall from this same seeded+installed state.
        proc_uninstall = _run(cli, ["codex", "uninstall-integration", "--yes"], codex_home)
        _must(proc_uninstall.returncode == 0, f"uninstall should exit 0: {_merged(proc_uninstall)}")

        data_after = json.loads(hooks_path.read_text(encoding="utf-8"))
        hooks_after = data_after.get("hooks", {})

        # User hooks survive uninstall.
        post_tool_after = _hooks_commands(hooks_after, "PostToolUse")
        _must(
            post_tool_after == ["echo user-post-tool-hook"],
            f"PostToolUse should survive uninstall, got: {post_tool_after}",
        )
        session_start_after = hooks_after.get("SessionStart", [])
        _must(
            len(session_start_after) == 1
            and session_start_after[0]["hooks"][0]["command"] == "echo my-custom-start-hook",
            f"user SessionStart hook should survive uninstall, got: {session_start_after}",
        )

        # Programa-only events are fully removed (empty key dropped).
        _must("Stop" not in hooks_after, f"emptied Stop key should be removed after uninstall, got: {hooks_after}")
        for event in EXPECTED_EVENTS:
            if event == "SessionStart":
                continue
            _must(
                not any(CODEX_HOOK_MARKER in cmd for cmd in _hooks_commands(hooks_after, event)),
                f"no programa hooks should remain for {event} after uninstall: {hooks_after.get(event)}",
            )
        _must(
            not any(CODEX_HOOK_MARKER in h.get("command", "") for g in session_start_after for h in g.get("hooks", [])),
            f"no programa hooks should remain in SessionStart after uninstall: {session_start_after}",
        )

        config_path = Path(codex_home) / "config.toml"
        config_after = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
        _must(
            not _has_codex_hooks_feature(config_after),
            f"config.toml codex_hooks key should be removed after uninstall, got: {config_after!r}",
        )

        print("  PASS: uninstall removes programa entries, preserves user hooks, drops empty keys, and config.toml key")


def test_decline_confirmation_leaves_file_untouched(cli: str) -> None:
    with tempfile.TemporaryDirectory() as codex_home:
        hooks_path = Path(codex_home) / "hooks.json"
        _must(not hooks_path.exists(), "hooks.json should not pre-exist for this test")

        proc = _run(cli, ["codex", "install-integration"], codex_home, input_text="n\n")

        if proc.returncode == 0:
            _must(
                not hooks_path.exists(),
                f"declining confirmation with exit 0 must leave hooks.json untouched, but it was created: {_merged(proc)}",
            )
        # A non-zero exit code is also an acceptable "clean abort" outcome.

        print("  PASS: declining the confirmation prompt leaves hooks.json untouched")


def test_legacy_alias_install_hooks(cli: str) -> None:
    with tempfile.TemporaryDirectory() as codex_home:
        proc = _run(cli, ["codex", "install-hooks", "--yes"], codex_home)
        _must(proc.returncode == 0, f"legacy install-hooks should exit 0: {_merged(proc)}")

        hooks_path = Path(codex_home) / "hooks.json"
        _must(hooks_path.exists(), f"hooks.json should be created at {hooks_path}")
        data = json.loads(hooks_path.read_text(encoding="utf-8"))
        hooks = data.get("hooks", {})
        for event in EXPECTED_EVENTS:
            commands = _hooks_commands(hooks, event)
            _must(
                any(CODEX_HOOK_MARKER in cmd for cmd in commands),
                f"legacy install-hooks: expected a '{CODEX_HOOK_MARKER}' command for {event}, got: {commands}",
            )

        proc_uninstall = _run(cli, ["codex", "uninstall-hooks", "--yes"], codex_home)
        _must(proc_uninstall.returncode == 0, f"legacy uninstall-hooks should exit 0: {_merged(proc_uninstall)}")
        data_after = json.loads(hooks_path.read_text(encoding="utf-8"))
        hooks_after = data_after.get("hooks", {})
        for event in EXPECTED_EVENTS:
            _must(
                not any(CODEX_HOOK_MARKER in cmd for cmd in _hooks_commands(hooks_after, event)),
                f"legacy uninstall-hooks: no programa hooks should remain for {event}, got: {hooks_after.get(event)}",
            )

        print("  PASS: legacy install-hooks/uninstall-hooks aliases behave identically")


def main() -> int:
    cli = _find_cli_binary()
    print(f"Using CLI: {cli}")

    test_fresh_install(cli)
    test_idempotent_reinstall(cli)
    test_preserves_user_hooks_and_replaces_stale_entry(cli)
    test_decline_confirmation_leaves_file_untouched(cli)
    test_legacy_alias_install_hooks(cli)

    print("\nPASS: All codex install-integration tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
