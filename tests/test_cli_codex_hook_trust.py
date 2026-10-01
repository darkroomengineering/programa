#!/usr/bin/env python3
"""Behavioral contracts for installing Codex hooks and their trust state."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Any


CLI_PATH = os.environ.get("PROGRAMA_CLI_BIN", "")
OWNED_MARKER = "programa codex-hook"
FOREIGN_MARKER_COMMAND = "echo 'programa codex-hook'"
MISMATCHED_EVENT_COMMAND = "programa codex-hook stop"
OWNED_COMMAND_EVENT_BY_HOOK_EVENT = {
    "SessionStart": "session-start",
    "UserPromptSubmit": "prompt-submit",
    "Stop": "stop",
    "PermissionRequest": "notification",
    "Notification": "notification",
    "SessionEnd": "session-end",
}
EVENT_LABELS = {
    "SessionStart": "session_start",
    "UserPromptSubmit": "user_prompt_submit",
    "Stop": "stop",
    "PermissionRequest": "permission_request",
    "SessionEnd": "session_end",
}


def foreign_handler(name: str) -> dict[str, Any]:
    return {"type": "command", "command": f"foreign-{name}", "timeout": 7}


def owned_handler(event: str) -> dict[str, Any]:
    return {
        "type": "command",
        "command": f"programa codex-hook {event}",
        "timeout": 9,
    }


def is_programa_handler(hook_event: str, command: str) -> bool:
    command_event = OWNED_COMMAND_EVENT_BY_HOOK_EVENT.get(hook_event)
    if command_event is None:
        return False
    bare = f"programa codex-hook {command_event}"
    wrapped = (
        '[ -n "$PROGRAMA_SURFACE_ID" ] && command -v programa >/dev/null 2>&1 && '
        f"{bare} || echo '{{}}'"
    )
    return command in (bare, wrapped)


def initial_hooks() -> dict[str, Any]:
    """Represent user hooks plus stale Programa entries from an older install."""
    return {
        "owner": "user",
        "hooks": {
            "SessionStart": [
                {"matcher": "startup", "hooks": [foreign_handler("start-a")]},
                {"hooks": [{"type": "command", "command": FOREIGN_MARKER_COMMAND}]},
                {
                    "hooks": [
                        foreign_handler("start-b"),
                        owned_handler("session-start"),
                    ]
                },
            ],
            "UserPromptSubmit": [
                {"hooks": [foreign_handler("prompt-a")]},
                {"hooks": [foreign_handler("prompt-b")]},
                {"hooks": [owned_handler("prompt-submit")]},
            ],
            "Stop": [
                {"hooks": [foreign_handler("stop")]},
                {"hooks": [owned_handler("stop")]},
            ],
            "PermissionRequest": [
                {"hooks": [foreign_handler("permission-request")]},
            ],
            "SessionEnd": [
                {"hooks": [foreign_handler("end-a"), foreign_handler("end-b")]},
                {"hooks": [owned_handler("session-end")]},
            ],
            "Notification": [
                {"hooks": [foreign_handler("notification")]},
                {"hooks": [owned_handler("notification")]},
            ],
            "CustomEvent": [{
                "hooks": [
                    foreign_handler("custom"),
                    {"type": "command", "command": MISMATCHED_EVENT_COMMAND},
                ]
            }],
        },
    }


def foreign_commands(root: dict[str, Any]) -> set[str]:
    commands: set[str] = set()
    for event, groups in root.get("hooks", {}).items():
        if not isinstance(groups, list):
            continue
        for group in groups:
            if not isinstance(group, dict):
                continue
            for handler in group.get("hooks", []):
                command = handler.get("command") if isinstance(handler, dict) else None
                if isinstance(command, str) and not is_programa_handler(event, command):
                    commands.add(command)
    return commands


def expected_trust_hash(event_label: str, handler: dict[str, Any]) -> str:
    timeout = handler.get("timeout", 600)
    if event_label == "session_end":
        timeout = min(max(timeout, 1), 3)
    else:
        timeout = max(timeout, 1)
    identity = {
        "event_name": event_label,
        "hooks": [
            {
                "async": handler.get("async", False),
                "command": handler["command"],
                "timeout": timeout,
                "type": "command",
            }
        ],
    }
    canonical = json.dumps(
        identity,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return f"sha256:{hashlib.sha256(canonical).hexdigest()}"


class CodexHookTrustTests(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(
            prefix="programa-codex-hooks-",
            dir="/tmp",
        )
        self.root = Path(self.temporary_directory.name)
        self.codex_home = self.root / "codex-home"
        self.user_home = self.root / "user-home"
        self.codex_home.mkdir()
        self.user_home.mkdir()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def run_cli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        env = dict(os.environ)
        env.update(
            {
                "CODEX_HOME": str(self.codex_home),
                "HOME": str(self.user_home),
                "CFFIXED_USER_HOME": str(self.user_home),
            }
        )
        for name in (
            "PROGRAMA_SOCKET",
            "PROGRAMA_SOCKET_PATH",
            "PROGRAMA_SOCKET_PASSWORD",
            "PROGRAMA_WORKSPACE_ID",
            "PROGRAMA_SURFACE_ID",
        ):
            env.pop(name, None)
        return subprocess.run(
            [CLI_PATH, "codex", *arguments, "--yes"],
            capture_output=True,
            text=True,
            check=False,
            timeout=8,
            env=env,
        )

    def write_hooks(self, value: dict[str, Any]) -> bytes:
        data = json.dumps(value, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        (self.codex_home / "hooks.json").write_bytes(data)
        return data

    def read_hooks(self) -> dict[str, Any]:
        return json.loads((self.codex_home / "hooks.json").read_text(encoding="utf-8"))

    def read_config(self) -> dict[str, Any]:
        return tomllib.loads((self.codex_home / "config.toml").read_text(encoding="utf-8"))

    def assert_succeeded(self, process: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(
            process.returncode,
            0,
            f"stdout={process.stdout!r}\nstderr={process.stderr!r}",
        )

    def test_install_trusts_the_real_merged_hook_positions_and_is_idempotent(self) -> None:
        """Codex must execute Programa hooks without displacing user automation."""
        original = initial_hooks()
        expected_foreign = foreign_commands(original)
        self.write_hooks(original)
        foreign_key = "manual/hooks.json:stop:4:2"
        (self.codex_home / "config.toml").write_text(
            "# user config\n"
            'model = "gpt-5.6"\n\n'
            "[features]\n"
            "codex_hooks = true\n"
            "foreign_feature = true\n\n"
            f'[hooks.state.{json.dumps(foreign_key)}]\n'
            'trusted_hash = "sha256:foreign"\n'
            "enabled = false\n",
            encoding="utf-8",
        )

        install = self.run_cli("install-hooks")
        self.assert_succeeded(install)

        hooks = self.read_hooks()
        self.assertEqual(hooks.get("owner"), "user")
        self.assertEqual(foreign_commands(hooks), expected_foreign)
        self.assertIn(
            FOREIGN_MARKER_COMMAND,
            foreign_commands(hooks),
            "ownership requires a known Programa command, not a marker substring",
        )
        self.assertIn(
            MISMATCHED_EVENT_COMMAND,
            foreign_commands(hooks),
            "ownership requires the command to match the hook event where it is installed",
        )
        self.assertFalse(
            any(
                is_programa_handler(event, command)
                for event, command in self._all_hook_commands(hooks)
                if event == "Notification"
            ),
            "Codex has no Notification trust-state label, so the obsolete Programa hook cannot execute",
        )

        config = self.read_config()
        self.assertEqual(config.get("model"), "gpt-5.6")
        self.assertTrue(config["features"]["foreign_feature"])
        self.assertNotIn(
            "codex_hooks",
            config["features"],
            "Codex 0.151 treats hooks as stable and no longer recognizes this feature flag",
        )
        state = config["hooks"]["state"]
        self.assertEqual(state[foreign_key]["trusted_hash"], "sha256:foreign")
        self.assertFalse(state[foreign_key]["enabled"])

        canonical_hooks_path = self.codex_home.resolve() / "hooks.json"
        owned_keys: set[str] = set()
        for event, label in EVENT_LABELS.items():
            found: list[tuple[int, int, dict[str, Any]]] = []
            for group_index, group in enumerate(hooks["hooks"].get(event, [])):
                for handler_index, handler in enumerate(group.get("hooks", [])):
                    if is_programa_handler(event, handler.get("command", "")):
                        found.append((group_index, handler_index, handler))
            self.assertEqual(len(found), 1, f"{event} must have one Programa handler: {found!r}")
            group_index, handler_index, handler = found[0]
            if event == "PermissionRequest":
                self.assertIn(
                    "programa codex-hook notification",
                    handler["command"],
                    "Codex permission requests reuse Programa's notification handler",
                )
            key = f"{canonical_hooks_path}:{label}:{group_index}:{handler_index}"
            owned_keys.add(key)
            self.assertIn(
                key,
                state,
                "Codex looks up trust by the installed handler's real position",
            )
            self.assertEqual(state[key]["trusted_hash"], expected_trust_hash(label, handler))

        hooks_once = (self.codex_home / "hooks.json").read_bytes()
        config_once = (self.codex_home / "config.toml").read_bytes()
        reinstall = self.run_cli("install-hooks")
        self.assert_succeeded(reinstall)
        self.assertEqual((self.codex_home / "hooks.json").read_bytes(), hooks_once)
        self.assertEqual((self.codex_home / "config.toml").read_bytes(), config_once)

        uninstall = self.run_cli("uninstall-hooks")
        self.assert_succeeded(uninstall)
        uninstalled_hooks = self.read_hooks()
        self.assertEqual(foreign_commands(uninstalled_hooks), expected_foreign)
        self.assertFalse(
            any(
                is_programa_handler(event, command)
                for event, command in self._all_hook_commands(uninstalled_hooks)
            )
        )
        self.assertEqual(uninstalled_hooks.get("owner"), "user")
        self.assertIn(
            FOREIGN_MARKER_COMMAND,
            foreign_commands(uninstalled_hooks),
            "uninstall must not delete a foreign command that only quotes Programa's marker",
        )
        self.assertIn(
            MISMATCHED_EVENT_COMMAND,
            foreign_commands(uninstalled_hooks),
            "uninstall must preserve a Programa command installed under a foreign event",
        )
        self.assertIn(
            "foreign-permission-request",
            foreign_commands(uninstalled_hooks),
            "uninstall must preserve the user's PermissionRequest automation",
        )

        uninstalled_config = self.read_config()
        uninstalled_state = uninstalled_config["hooks"]["state"]
        self.assertEqual(uninstalled_state[foreign_key]["trusted_hash"], "sha256:foreign")
        self.assertTrue(uninstalled_config["features"]["foreign_feature"])
        self.assertNotIn("codex_hooks", uninstalled_config["features"])
        for key in owned_keys:
            self.assertNotIn(key, uninstalled_state)

    @staticmethod
    def _all_hook_commands(root: dict[str, Any]) -> list[tuple[str, str]]:
        commands: list[tuple[str, str]] = []
        for event, groups in root.get("hooks", {}).items():
            if not isinstance(groups, list):
                continue
            for group in groups:
                if not isinstance(group, dict):
                    continue
                commands.extend(
                    (event, handler["command"])
                    for handler in group.get("hooks", [])
                    if isinstance(handler, dict) and isinstance(handler.get("command"), str)
                )
        return commands

    def test_invalid_config_fails_before_hooks_are_mutated(self) -> None:
        """A failed trust preflight must not leave newly installed hooks disabled."""
        for config_content in ("not = valid = toml\n", "hooks = true\n"):
            with self.subTest(config=config_content):
                original_hooks = self.write_hooks(initial_hooks())
                original_config = config_content.encode("utf-8")
                (self.codex_home / "config.toml").write_bytes(original_config)

                install = self.run_cli("install-hooks")

                self.assertNotEqual(
                    install.returncode,
                    0,
                    "invalid syntax or a scalar hooks key must fail trust setup: "
                    f"stdout={install.stdout!r} stderr={install.stderr!r}",
                )
                self.assertEqual(
                    (self.codex_home / "hooks.json").read_bytes(),
                    original_hooks,
                )
                self.assertEqual(
                    (self.codex_home / "config.toml").read_bytes(),
                    original_config,
                )

    def test_install_refuses_to_reassign_a_foreign_positional_trust_key(self) -> None:
        """Dropping a duplicate Programa group must not shift foreign trust positions."""
        hooks = {
            "hooks": {
                "Stop": [
                    {"hooks": [owned_handler("stop")]},
                    {"hooks": [owned_handler("stop")]},
                    {"hooks": [foreign_handler("position-sensitive-stop")]},
                ]
            }
        }
        original_hooks = self.write_hooks(hooks)
        foreign_key = f"{self.codex_home.resolve() / 'hooks.json'}:stop:2:0"
        original_config = (
            f'[hooks.state.{json.dumps(foreign_key)}]\n'
            'trusted_hash = "sha256:foreign-position"\n'
        ).encode("utf-8")
        (self.codex_home / "config.toml").write_bytes(original_config)

        install = self.run_cli("install-hooks")

        self.assertNotEqual(
            install.returncode,
            0,
            "install must refuse a rewrite that would reuse a foreign positional trust key",
        )
        self.assertEqual((self.codex_home / "hooks.json").read_bytes(), original_hooks)
        self.assertEqual((self.codex_home / "config.toml").read_bytes(), original_config)

    def test_reinstall_updates_programa_in_place_when_foreign_groups_follow_it(self) -> None:
        """A later tool's groups must keep their positions across a Programa reinstall."""
        foreign_command = (
            'bun --no-env-file "/x/darkroom/source/src/scripts/codex-hook.ts" '
            '"src/hooks/session-end.ts"'
        )
        hooks: dict[str, Any] = {"hooks": {}}
        for event, command_event in (
            ("SessionEnd", "session-end"),
            ("UserPromptSubmit", "prompt-submit"),
        ):
            hooks["hooks"][event] = [
                {"hooks": [owned_handler(command_event)]},
                {"hooks": [{"type": "command", "command": foreign_command, "timeout": 5}]},
            ]
        self.write_hooks(hooks)

        install = self.run_cli("install-hooks")
        self.assert_succeeded(install)

        installed = self.read_hooks()["hooks"]
        for event in ("SessionEnd", "UserPromptSubmit"):
            groups = installed[event]
            self.assertEqual(len(groups), 2, f"{event} must not gain or lose groups")
            self.assertTrue(
                is_programa_handler(event, groups[0]["hooks"][0]["command"]),
                f"{event} Programa handler must stay at 0:0",
            )
            self.assertEqual(
                groups[1]["hooks"],
                [{"type": "command", "command": foreign_command, "timeout": 5}],
                f"{event} foreign handler must stay at 1:0",
            )

    def test_uninstall_refuses_to_delete_a_user_comment_with_stale_trust(self) -> None:
        """A positional trust table cannot own comments that follow its assignments."""
        hooks = {"hooks": {"SessionStart": [{"hooks": [owned_handler("session-start")]}]}}
        original_hooks = self.write_hooks(hooks)
        owned_key = f"{self.codex_home.resolve() / 'hooks.json'}:session_start:0:0"
        owned_hash = expected_trust_hash("session_start", owned_handler("session-start"))
        original_config = (
            f'[hooks.state.{json.dumps(owned_key)}]\n'
            f'trusted_hash = "{owned_hash}"\n'
            "# user note: keep this explanation for the following table\n"
            "[history]\n"
            'persistence = "save-all"\n'
        ).encode("utf-8")
        (self.codex_home / "config.toml").write_bytes(original_config)

        uninstall = self.run_cli("uninstall-hooks")

        self.assertNotEqual(
            uninstall.returncode,
            0,
            "uninstall must refuse when deleting a stale table would also delete a user comment",
        )
        self.assertEqual((self.codex_home / "hooks.json").read_bytes(), original_hooks)
        self.assertEqual((self.codex_home / "config.toml").read_bytes(), original_config)

    def test_unrecognized_comment_inside_managed_trust_block_fails_closed(self) -> None:
        """Programa markers do not authorize deleting user additions inside the block."""
        hooks = {"hooks": {"SessionStart": [{"hooks": [owned_handler("session-start")]}]}}
        owned_key = f"{self.codex_home.resolve() / 'hooks.json'}:session_start:0:0"
        owned_hash = expected_trust_hash("session_start", owned_handler("session-start"))
        for operation in ("install-hooks", "uninstall-hooks"):
            with self.subTest(operation=operation):
                original_hooks = self.write_hooks(hooks)
                original_config = (
                    "# >>> programa codex hook trust >>>\n"
                    f'[hooks.state.{json.dumps(owned_key)}]\n'
                    f'trusted_hash = "{owned_hash}"\n'
                    "# user note: preserve this customization\n"
                    "# <<< programa codex hook trust <<<\n"
                ).encode("utf-8")
                (self.codex_home / "config.toml").write_bytes(original_config)

                process = self.run_cli(operation)

                self.assertNotEqual(
                    process.returncode,
                    0,
                    f"{operation} must refuse to erase an unrecognized managed-block comment",
                )
                self.assertEqual((self.codex_home / "hooks.json").read_bytes(), original_hooks)
                self.assertEqual((self.codex_home / "config.toml").read_bytes(), original_config)

    def test_multiline_toml_content_is_neutral_to_trust_editing(self) -> None:
        """Config-like text inside a multiline value must remain user data, not edit syntax."""
        multiline_source = (
            '[hooks.state."pretend/hooks.json:stop:0:0"]\n'
            'trusted_hash = "sha256:not-a-real-table"\n'
            "[features]\n"
            "codex_hooks = true\n"
        )
        original_config = (
            'instructions = """\n'
            + multiline_source
            + '"""\n\n'
            + 'model = "gpt-5.6"\n\n'
            + "[features]\n"
            + "foreign_feature = true\n"
        )
        expected_instructions = tomllib.loads(original_config)["instructions"]
        (self.codex_home / "config.toml").write_text(original_config, encoding="utf-8")

        install = self.run_cli("install-hooks")

        self.assert_succeeded(install)
        rendered_text = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        rendered = tomllib.loads(rendered_text)
        self.assertEqual(rendered["instructions"], expected_instructions)
        self.assertEqual(rendered["model"], "gpt-5.6")
        self.assertTrue(rendered["features"]["foreign_feature"])
        self.assertIn(multiline_source, rendered_text)

    def test_uninstall_from_empty_codex_home_is_a_non_creating_noop(self) -> None:
        """Removing an absent integration must not materialize Codex configuration."""
        hooks_path = self.codex_home / "hooks.json"
        config_path = self.codex_home / "config.toml"
        self.assertFalse(hooks_path.exists())
        self.assertFalse(config_path.exists())

        uninstall = self.run_cli("uninstall-hooks")

        self.assert_succeeded(uninstall)
        self.assertFalse(hooks_path.exists())
        self.assertFalse(config_path.exists())

    def test_symlinked_config_updates_its_target_without_replacing_the_link(self) -> None:
        """Dotfile-managed Codex configuration must remain connected after lifecycle changes."""
        target = self.root / "managed-config.toml"
        foreign_key = "managed/hooks.json:session_start:0:0"
        target.write_text(
            'model = "gpt-5.6"\n\n'
            f'[hooks.state.{json.dumps(foreign_key)}]\n'
            'trusted_hash = "sha256:managed"\n',
            encoding="utf-8",
        )
        config_link = self.codex_home / "config.toml"
        config_link.symlink_to(target)

        install = self.run_cli("install-hooks")
        self.assert_succeeded(install)
        self.assertTrue(config_link.is_symlink())
        installed_target = target.read_bytes()
        installed_config = tomllib.loads(installed_target.decode("utf-8"))
        self.assertEqual(installed_config["model"], "gpt-5.6")
        self.assertEqual(
            installed_config["hooks"]["state"][foreign_key]["trusted_hash"],
            "sha256:managed",
        )
        self.assertGreater(len(installed_config["hooks"]["state"]), 1)

        reinstall = self.run_cli("install-hooks")
        self.assert_succeeded(reinstall)
        self.assertTrue(config_link.is_symlink())
        self.assertEqual(target.read_bytes(), installed_target)

        uninstall = self.run_cli("uninstall-hooks")
        self.assert_succeeded(uninstall)
        self.assertTrue(config_link.is_symlink())
        final_config = tomllib.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(final_config["model"], "gpt-5.6")
        self.assertEqual(
            final_config["hooks"]["state"][foreign_key]["trusted_hash"],
            "sha256:managed",
        )
        self.assertEqual(len(final_config["hooks"]["state"]), 1)

    BEGIN_MARKER = "# BEGIN programa (managed by Programa, do not edit)"
    END_MARKER = "# END programa"

    def config_bytes(self) -> bytes:
        return (self.codex_home / "config.toml").read_bytes()

    def test_fresh_install_writes_one_marker_block_and_uninstall_removes_it(self) -> None:
        """All Programa settings live in a single block that uninstall removes whole."""
        user_config = b'model = "gpt-5.6"\n\n[history]\npersistence = "save-all"\n'
        (self.codex_home / "config.toml").write_bytes(user_config)

        self.assert_succeeded(self.run_cli("install-hooks"))
        installed = self.config_bytes()
        text = installed.decode("utf-8")
        self.assertEqual(text.count(self.BEGIN_MARKER), 1)
        self.assertEqual(text.count(self.END_MARKER), 1)
        self.assertTrue(installed.startswith(user_config + b"\n" + self.BEGIN_MARKER.encode()))
        self.assertTrue(text.endswith(self.END_MARKER + "\n"))
        state = tomllib.loads(text)["hooks"]["state"]
        self.assertEqual(len(state), len(EVENT_LABELS))
        self.assertEqual(tomllib.loads(text)["history"]["persistence"], "save-all")

        self.assert_succeeded(self.run_cli("uninstall-hooks"))
        self.assertEqual(self.config_bytes(), user_config)

    def test_fresh_install_without_config_creates_only_the_block(self) -> None:
        self.assert_succeeded(self.run_cli("install-hooks"))
        text = self.config_bytes().decode("utf-8")
        self.assertTrue(text.startswith(self.BEGIN_MARKER + "\n"))
        self.assertEqual(len(tomllib.loads(text)["hooks"]["state"]), len(EVENT_LABELS))

    def test_reinstall_rewrites_the_block_whole_and_keeps_user_content(self) -> None:
        """A stale or hand-edited block is replaced; everything outside it is byte-identical."""
        before = b'# my notes\nmodel = "gpt-5.6"\n\n[tui]\nnotifications = true\n'
        after = b"\n[other]\nkey = 1\n"
        (self.codex_home / "config.toml").write_bytes(before)
        self.assert_succeeded(self.run_cli("install-hooks"))
        installed = self.config_bytes()

        stale = (
            before
            + b"\n" + self.BEGIN_MARKER.encode() + b"\n"
            + b'[hooks.state."stale/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:stale"\n'
            + self.END_MARKER.encode() + b"\n"
            + after
        )
        (self.codex_home / "config.toml").write_bytes(stale)
        self.assert_succeeded(self.run_cli("install-hooks"))
        rewritten = self.config_bytes()
        self.assertNotIn(b"stale/hooks.json", rewritten)
        self.assertTrue(rewritten.startswith(before))
        self.assertTrue(rewritten.endswith(after))
        block_start = rewritten.index(self.BEGIN_MARKER.encode())
        block_end = rewritten.index(self.END_MARKER.encode()) + len(self.END_MARKER) + 1
        self.assertEqual(
            rewritten[block_start:block_end],
            installed[installed.index(self.BEGIN_MARKER.encode()):],
        )

        self.assert_succeeded(self.run_cli("uninstall-hooks"))
        self.assertEqual(self.config_bytes(), before + after)

    def test_reinstall_is_byte_identical(self) -> None:
        (self.codex_home / "config.toml").write_bytes(b'model = "gpt-5.6"\n')
        self.assert_succeeded(self.run_cli("install-hooks"))
        first = (self.config_bytes(), (self.codex_home / "hooks.json").read_bytes())
        self.assert_succeeded(self.run_cli("install-hooks"))
        self.assertEqual((self.config_bytes(), (self.codex_home / "hooks.json").read_bytes()), first)

    def test_user_owned_trust_table_is_skipped_with_one_warning(self) -> None:
        """A table the user defines is never edited; Programa skips that entry and says so."""
        hooks_path = self.codex_home.resolve() / "hooks.json"
        key = f"{hooks_path}:stop:0:0"
        user_config = (
            f"[hooks.state.{json.dumps(key)}]\n"
            'trusted_hash = "sha256:mine"\n'
            "enabled = false\n"
        ).encode("utf-8")
        (self.codex_home / "config.toml").write_bytes(user_config)

        install = self.run_cli("install-hooks")

        self.assert_succeeded(install)
        warnings = [line for line in install.stderr.splitlines() if line.startswith("warning:")]
        self.assertEqual(len(warnings), 1, install.stderr)
        self.assertIn(key, warnings[0])
        config = self.config_bytes()
        self.assertTrue(config.startswith(user_config))
        state = tomllib.loads(config.decode("utf-8"))["hooks"]["state"]
        self.assertEqual(state[key], {"trusted_hash": "sha256:mine", "enabled": False})
        self.assertEqual(len(state), len(EVENT_LABELS))

        self.assert_succeeded(self.run_cli("uninstall-hooks"))
        self.assertEqual(self.config_bytes(), user_config)

    def test_migrates_the_older_spliced_format_into_the_block(self) -> None:
        """Keys older installers wrote outside any block are removed once, then the block is written."""
        self.write_hooks({"hooks": {"Stop": [{"hooks": [owned_handler("stop")]}]}})
        self.assert_succeeded(self.run_cli("install-hooks"))
        hooks_path = self.codex_home.resolve() / "hooks.json"
        stop_handler = self.read_hooks()["hooks"]["Stop"][0]["hooks"][0]
        stop_key = f"{hooks_path}:stop:0:0"
        stop_hash = expected_trust_hash("stop", stop_handler)
        user_prefix = 'model = "gpt-5.6"\n\n[features]\ncodex_hooks = true\nforeign_feature = true\n\n'
        user_suffix = "[history]\npersistence = \"save-all\"\n"
        (self.codex_home / "config.toml").write_text(
            user_prefix
            + f"[hooks.state.{json.dumps(stop_key)}]\ntrusted_hash = \"{stop_hash}\"\n\n"
            + user_suffix,
            encoding="utf-8",
        )

        self.assert_succeeded(self.run_cli("install-hooks"))
        text = self.config_bytes().decode("utf-8")
        self.assertNotIn("codex_hooks", text)
        self.assertEqual(text.count(stop_key), 1)
        self.assertIn(user_suffix, text)
        config = tomllib.loads(text)
        self.assertTrue(config["features"]["foreign_feature"])
        self.assertEqual(config["history"]["persistence"], "save-all")
        self.assertEqual(config["hooks"]["state"][stop_key]["trusted_hash"], stop_hash)
        self.assertLess(text.index(self.BEGIN_MARKER), text.index(stop_key))
        self.assertTrue(text.endswith(self.END_MARKER + "\n"))

        migrated = self.config_bytes()
        self.assert_succeeded(self.run_cli("install-hooks"))
        self.assertEqual(self.config_bytes(), migrated)

    def test_uninstall_migrates_the_older_spliced_format(self) -> None:
        self.write_hooks({"hooks": {"Stop": [{"hooks": [owned_handler("stop")]}]}})
        self.assert_succeeded(self.run_cli("install-hooks"))
        hooks_path = self.codex_home.resolve() / "hooks.json"
        stop_handler = self.read_hooks()["hooks"]["Stop"][0]["hooks"][0]
        stop_key = f"{hooks_path}:stop:0:0"
        stop_hash = expected_trust_hash("stop", stop_handler)
        (self.codex_home / "config.toml").write_text(
            'model = "gpt-5.6"\n\n'
            "# >>> programa managed codex hook trust v1 >>>\n"
            f"[hooks.state.{json.dumps(stop_key)}]\ntrusted_hash = \"{stop_hash}\"\n"
            "# <<< programa managed codex hook trust v1 <<<\n",
            encoding="utf-8",
        )

        self.assert_succeeded(self.run_cli("uninstall-hooks"))
        self.assertEqual(self.config_bytes(), b'model = "gpt-5.6"\n')

    def test_settings_right_after_the_block_are_refused(self) -> None:
        """A bare assignment after the END marker would move into another table."""
        for operation in ("install-hooks", "uninstall-hooks"):
            with self.subTest(operation=operation):
                original = (
                    'model = "gpt-5.6"\n\n'
                    + self.BEGIN_MARKER + "\n"
                    + '[hooks.state."x/hooks.json:stop:0:0"]\ntrusted_hash = "sha256:x"\n'
                    + self.END_MARKER + "\n"
                    + "enabled = false\n"
                ).encode("utf-8")
                (self.codex_home / "config.toml").write_bytes(original)
                process = self.run_cli(operation)
                self.assertNotEqual(process.returncode, 0, process.stdout)
                self.assertEqual(self.config_bytes(), original)
                self.assertFalse((self.codex_home / "hooks.json").exists())

    def test_foreign_entry_inside_old_markers_is_refused(self) -> None:
        """Old markers only authorize removing entries Programa owns."""
        hooks = {"hooks": {"SessionStart": [{"hooks": [owned_handler("session-start")]}]}}
        hooks_path = self.codex_home.resolve() / "hooks.json"
        owned_key = f"{hooks_path}:session_start:0:0"
        owned_hash = expected_trust_hash("session_start", owned_handler("session-start"))
        foreign_key = f"{hooks_path}:stop:5:0"
        bodies = {
            "foreign hash": (
                f'[hooks.state.{json.dumps(owned_key)}]\ntrusted_hash = "sha256:foreign"\n'
            ),
            "foreign key": (
                f'[hooks.state.{json.dumps(foreign_key)}]\ntrusted_hash = "sha256:foreign"\n'
            ),
            "extra field": (
                f'[hooks.state.{json.dumps(owned_key)}]\ntrusted_hash = "{owned_hash}"\n'
                "enabled = false\n"
            ),
        }
        for name, body in bodies.items():
            for operation in ("install-hooks", "uninstall-hooks"):
                with self.subTest(case=name, operation=operation):
                    original_hooks = self.write_hooks(hooks)
                    original = (
                        "# >>> programa managed codex hook trust v1 >>>\n"
                        + body
                        + "# <<< programa managed codex hook trust v1 <<<\n"
                    ).encode("utf-8")
                    (self.codex_home / "config.toml").write_bytes(original)
                    process = self.run_cli(operation)
                    self.assertNotEqual(process.returncode, 0, process.stdout)
                    self.assertEqual(self.config_bytes(), original)
                    self.assertEqual((self.codex_home / "hooks.json").read_bytes(), original_hooks)


if __name__ == "__main__":
    if not CLI_PATH or not Path(CLI_PATH).is_file() or not os.access(CLI_PATH, os.X_OK):
        print("FAIL: PROGRAMA_CLI_BIN must point to an executable programa CLI")
        raise SystemExit(1)
    unittest.main(verbosity=2)
