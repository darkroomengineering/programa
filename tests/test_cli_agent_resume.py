#!/usr/bin/env python3
"""`programa resume` brings back the last agent session that ended in a pane.

A provider's session-end hook keeps the ended session in the last-sessions file even though it
consumes the live hook record. `resume` picks the newest entry for the pane (or the pane's
directory), builds the provider's resume command, and types it plus Enter into the pane, or
only prints it with --print. It refuses while an agent still runs in the pane.

Runs the built CLI against temp state files and a fake socket that answers system.tree. No
app is involved.
"""

from __future__ import annotations

import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

from test_cli_registry_behavior import CLI_PATH, SURFACE_ID, WORKSPACE_ID, SocketRecorder, merged_output, run_cli

SESSION_ID = "5f0c2a9e-1b2d-4c3e-8f4a-6b7c8d9e0f1a"
OTHER_SURFACE_ID = "44444444-aaaa-4bbb-8ccc-dddddddddddd"
OPENCODE_SESSION_ID = "ses_3a1f2b9c0ffeYq7RkT2mNp4LwX"


class TreeRecorder(SocketRecorder):
    """Answers system.tree with one terminal surface in a given directory, agent and shell state."""

    def __init__(
        self, directory: str, pane_dir: str, agent_state: str | None = None, shell_state: str | None = "promptIdle"
    ):
        super().__init__(directory)
        self.pane_dir = pane_dir
        self.agent_state = agent_state
        self.shell_state = shell_state

    def _result_for(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "system.tree":
            surface = {
                "id": SURFACE_ID, "ref": "surface:1", "type": "terminal", "focused": True,
                "current_directory": self.pane_dir, "agent_state": self.agent_state,
                "shell_state": self.shell_state,
            }
            workspace = {"id": WORKSPACE_ID, "ref": "workspace:1", "panes": [{"surfaces": [surface]}]}
            return {"windows": [{"workspaces": [workspace]}]}
        return super()._result_for(method, params)


class Sandbox:
    def __init__(self, root: str) -> None:
        self.root = Path(root)
        self.home = self.root / "home"
        self.home.mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        self.elsewhere = self.root / "elsewhere"
        self.elsewhere.mkdir()
        self.hook_state = self.root / "claude-hook-sessions.json"
        self.last_sessions = self.root / "agent-last-sessions.json"

    def write_last_sessions(self, *entries: dict[str, Any]) -> None:
        self.last_sessions.write_text(json.dumps({"version": 1, "sessions": list(entries)}), encoding="utf-8")

    def entry(self, **overrides: Any) -> dict[str, Any]:
        base = {
            "provider": "claude-code", "sessionId": SESSION_ID, "cwd": str(self.project),
            "workspaceId": WORKSPACE_ID, "surfaceId": SURFACE_ID, "endedAt": time.time(),
        }
        base.update(overrides)
        return base

    def cli(self, rec: SocketRecorder, args: list[str], input_text: str | None = None):
        return run_cli(rec.path, args, input_text=input_text, env_overrides={
            "HOME": str(self.home), "CFFIXED_USER_HOME": str(self.home),
            "PROGRAMA_SOCKET": rec.path, "PROGRAMA_SOCKET_PATH": rec.path,
            "PROGRAMA_SURFACE_ID": SURFACE_ID, "PROGRAMA_WORKSPACE_ID": WORKSPACE_ID,
            "PROGRAMA_CLAUDE_HOOK_STATE_PATH": str(self.hook_state),
            "PROGRAMA_AGENT_LAST_SESSIONS_PATH": str(self.last_sessions),
        })


def sent(rec: SocketRecorder) -> list[dict[str, Any]]:
    return [f for f in rec.frames if f.get("method") in ("surface.send_text", "surface.send_key")]


class AgentResumeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self._tmp = tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp")
        self.box = Sandbox(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def recorder(
        self, pane_dir: Path | None = None, agent_state: str | None = None, shell_state: str | None = "promptIdle"
    ) -> TreeRecorder:
        # A fresh directory per recorder: SocketRecorder never unlinks its socket file.
        return TreeRecorder(
            tempfile.mkdtemp(dir=self._tmp.name), str(pane_dir or self.box.project), agent_state, shell_state
        )

    def test_session_end_keeps_the_session_and_print_shows_the_resume_command(self) -> None:
        now = time.time()
        self.box.hook_state.write_text(json.dumps({"version": 1, "sessions": {SESSION_ID: {
            "sessionId": SESSION_ID, "workspaceId": WORKSPACE_ID, "surfaceId": SURFACE_ID,
            "cwd": str(self.box.project), "startedAt": now, "updatedAt": now,
        }}}), encoding="utf-8")
        payload = json.dumps({"session_id": SESSION_ID, "cwd": str(self.box.project)})
        with self.recorder() as rec:
            ended = self.box.cli(rec, ["claude-hook", "session-end"], input_text=payload)
            printed = self.box.cli(rec, ["resume", "--print"])
        self.assertEqual(rec.errors, [])
        self.assertEqual(ended.returncode, 0, merged_output(ended))
        live = json.loads(self.box.hook_state.read_text(encoding="utf-8"))
        self.assertNotIn(SESSION_ID, live["sessions"], "session-end must still consume the live record")
        kept = json.loads(self.box.last_sessions.read_text(encoding="utf-8"))["sessions"]
        self.assertEqual(len(kept), 1, kept)
        self.assertEqual(kept[0]["provider"], "claude-code")
        self.assertEqual(kept[0]["sessionId"], SESSION_ID)
        self.assertEqual(kept[0]["surfaceId"], SURFACE_ID)
        self.assertEqual(kept[0]["cwd"], str(self.box.project))
        self.assertEqual(printed.returncode, 0, merged_output(printed))
        self.assertEqual(printed.stdout.strip(), f"claude --resume '{SESSION_ID}'")
        self.assertEqual(sent(rec), [], "--print must not type anything")

    def test_resume_types_the_command_then_enter_into_the_pane(self) -> None:
        self.box.write_last_sessions(self.box.entry())
        with self.recorder() as rec:
            proc = self.box.cli(rec, ["resume"])
        self.assertEqual(rec.errors, [])
        self.assertEqual(proc.returncode, 0, merged_output(proc))
        frames = sent(rec)
        self.assertEqual([f["method"] for f in frames], ["surface.send_text", "surface.send_key"], frames)
        self.assertEqual(frames[0]["params"]["text"], f"claude --resume '{SESSION_ID}'")
        self.assertEqual(frames[0]["params"]["surface_id"], SURFACE_ID)
        self.assertEqual(frames[1]["params"]["key"], "enter")
        self.assertEqual(frames[1]["params"]["surface_id"], SURFACE_ID)

    def test_session_from_another_directory_is_resumed_there(self) -> None:
        self.box.write_last_sessions(self.box.entry())
        with self.recorder(pane_dir=self.box.elsewhere) as rec:
            proc = self.box.cli(rec, ["resume", "--print"])
        self.assertEqual(proc.returncode, 0, merged_output(proc))
        self.assertEqual(proc.stdout.strip(), f"cd '{self.box.project}' && claude --resume '{SESSION_ID}'")

    def test_falls_back_to_the_newest_session_in_the_pane_directory(self) -> None:
        older = self.box.entry(
            sessionId="older-session", surfaceId=OTHER_SURFACE_ID, cwd=str(self.box.elsewhere), endedAt=time.time() - 60
        )
        self.box.write_last_sessions(self.box.entry(surfaceId=OTHER_SURFACE_ID, provider="codex"), older)
        with self.recorder() as rec:
            proc = self.box.cli(rec, ["resume", "--print"])
        self.assertEqual(proc.returncode, 0, merged_output(proc))
        self.assertEqual(proc.stdout.strip(), f"codex resume '{SESSION_ID}'")

    def test_opencode_session_end_without_an_id_keeps_the_pane_session(self) -> None:
        # The OpenCode plugin's dispose hook passes no --session, so the id comes from the live
        # record that prompt-submit/stop stored for the pane.
        live_state = self.box.home / ".programa" / "opencode-hook-sessions.json"
        live_state.parent.mkdir()
        now = time.time()
        live_state.write_text(json.dumps({"version": 1, "sessions": {OPENCODE_SESSION_ID: {
            "sessionId": OPENCODE_SESSION_ID, "workspaceId": WORKSPACE_ID, "surfaceId": SURFACE_ID,
            "cwd": str(self.box.project), "startedAt": now, "updatedAt": now,
        }}}), encoding="utf-8")
        with self.recorder() as rec:
            ended = self.box.cli(rec, ["opencode-hook", "session-end", "--cwd", str(self.box.project)], input_text="")
            printed = self.box.cli(rec, ["resume", "--print"])
        self.assertEqual(ended.returncode, 0, merged_output(ended))
        kept = json.loads(self.box.last_sessions.read_text(encoding="utf-8"))["sessions"]
        self.assertEqual([(e["provider"], e["sessionId"]) for e in kept], [("opencode", OPENCODE_SESSION_ID)], kept)
        self.assertEqual(printed.returncode, 0, merged_output(printed))
        self.assertEqual(printed.stdout.strip(), f"opencode --session '{OPENCODE_SESSION_ID}'")
        self.assertEqual(sent(rec), [], "--print must not type anything")

    def test_refuses_while_an_agent_runs_in_the_pane(self) -> None:
        self.box.write_last_sessions(self.box.entry())
        for state in ("working", "idle"):
            with self.subTest(state), self.recorder(agent_state=state) as rec:
                proc = self.box.cli(rec, ["resume"])
            self.assertNotEqual(proc.returncode, 0, merged_output(proc))
            self.assertIn("still running", merged_output(proc))
            self.assertEqual(sent(rec), [], "nothing may be typed into a running agent")

    def test_refuses_unless_the_pane_is_at_its_shell_prompt(self) -> None:
        # commandRunning is vim, ssh or a REPL; unknown and None mean no shell integration.
        self.box.write_last_sessions(self.box.entry())
        for state in ("commandRunning", "unknown", None):
            with self.subTest(state):
                with self.recorder(shell_state=state) as rec:
                    refused = self.box.cli(rec, ["resume"])
                self.assertNotEqual(refused.returncode, 0, merged_output(refused))
                self.assertIn("the pane is running a program; return to the shell prompt or pass --force", merged_output(refused))
                self.assertEqual(sent(rec), [], "nothing may be typed into a running program")
                with self.recorder(shell_state=state) as rec:
                    printed = self.box.cli(rec, ["resume", "--print"])
                    forced = self.box.cli(rec, ["resume", "--force"])
                self.assertEqual(printed.stdout.strip(), f"claude --resume '{SESSION_ID}'", merged_output(printed))
                self.assertEqual(forced.returncode, 0, merged_output(forced))
                self.assertEqual([f["params"].get("text") for f in sent(rec)][:1], [f"claude --resume '{SESSION_ID}'"])

    def test_missing_or_unsupported_session_fails_with_a_clear_error(self) -> None:
        cases = {
            "no record": ((), "no ended agent session"),
            "unknown provider": ((self.box.entry(provider="gemini"),), "cannot be resumed"),
            "unsafe id": ((self.box.entry(sessionId="x'; rm -rf ~"),), "invalid session id"),
        }
        for name, (entries, message) in cases.items():
            with self.subTest(name):
                self.box.write_last_sessions(*entries)
                with self.recorder() as rec:
                    proc = self.box.cli(rec, ["resume"])
                self.assertNotEqual(proc.returncode, 0, merged_output(proc))
                self.assertIn(message, merged_output(proc))
                self.assertEqual(sent(rec), [])

    def test_claude_session_without_its_reported_transcript_is_not_resumed(self) -> None:
        # Claude writes the transcript only after the first prompt; resuming before that fails
        # with "No conversation found".
        transcript = self.box.home / ".claude" / "projects" / "-project" / f"{SESSION_ID}.jsonl"
        transcript.parent.mkdir(parents=True)
        self.box.write_last_sessions(self.box.entry(transcriptPath=str(transcript)))
        with self.recorder() as rec:
            missing = self.box.cli(rec, ["resume"])
        self.assertNotEqual(missing.returncode, 0, merged_output(missing))
        self.assertIn("has no saved conversation to resume", merged_output(missing))
        self.assertEqual(sent(rec), [])

        transcript.write_text('{"type":"user"}\n', encoding="utf-8")
        with self.recorder() as rec:
            present = self.box.cli(rec, ["resume", "--print"])
        self.assertEqual(present.returncode, 0, merged_output(present))
        self.assertEqual(present.stdout.strip(), f"claude --resume '{SESSION_ID}'")

    def test_explicit_session_uses_its_recorded_provider_or_the_provider_flag(self) -> None:
        self.box.write_last_sessions(self.box.entry(sessionId="codex-thread-1", provider="codex"))
        with self.recorder() as rec:
            recorded = self.box.cli(rec, ["resume", "--print", "--session", "codex-thread-1"])
            unknown = self.box.cli(rec, ["resume", "--print", "--session", "abc123"])
            flagged = self.box.cli(rec, ["resume", "--print", "--session", "abc123", "--provider", "codex"])
            unsupported = self.box.cli(rec, ["resume", "--print", "--session", "abc123", "--provider", "gemini"])
        self.assertEqual(recorded.stdout.strip(), "codex resume 'codex-thread-1'", merged_output(recorded))
        self.assertNotEqual(unknown.returncode, 0, merged_output(unknown))
        self.assertIn("session abc123 isn't recorded; pass --provider", merged_output(unknown))
        self.assertEqual(flagged.returncode, 0, merged_output(flagged))
        self.assertEqual(flagged.stdout.strip(), "codex resume 'abc123'")
        self.assertNotEqual(unsupported.returncode, 0, merged_output(unsupported))
        self.assertIn("unsupported --provider", merged_output(unsupported))
        self.assertEqual(sent(rec), [])

    def test_a_directory_with_a_quote_or_backslash_is_never_cd_into(self) -> None:
        # fish reads \' inside single quotes as an escaped quote, so POSIX quoting cannot
        # contain these names; the line falls back to the bare command.
        for name in ("x'; touch pwned; #", "x\\'; touch pwned; #", "back\\slash"):
            with self.subTest(name):
                hostile = self.box.root / name
                hostile.mkdir()
                self.box.write_last_sessions(self.box.entry(cwd=str(hostile)))
                with self.recorder(pane_dir=self.box.elsewhere) as rec:
                    proc = self.box.cli(rec, ["resume", "--print"])
                self.assertEqual(proc.returncode, 0, merged_output(proc))
                self.assertEqual(proc.stdout.strip(), f"claude --resume '{SESSION_ID}'")

    def test_unknown_workspace_is_reported_as_a_workspace(self) -> None:
        self.box.write_last_sessions(self.box.entry())
        with self.recorder() as rec:
            proc = self.box.cli(rec, ["resume", "--print", "--workspace", "workspace:999"])
        self.assertNotEqual(proc.returncode, 0, merged_output(proc))
        self.assertIn("workspace not found: workspace:999", merged_output(proc))


if __name__ == "__main__":
    unittest.main()
