#!/usr/bin/env python3
"""`programa usage` sums the tokens agent sessions used, grouped by workspace.

The hooks record each session's transcript path; `usage` reads those transcripts when it runs.
Claude Code writes one line per content block, so a response's `message.id` repeats and is
counted once, across the main transcript and its subagent transcripts. Codex is counted once per
`token_usage_record` response id, or by its largest running total when a file has no records.

Runs the built CLI against temp state files, synthetic transcripts, and a fake socket that answers
system.tree. No app is involved.
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

OTHER_WORKSPACE_ID = "aaaaaaaa-1111-4222-8333-444444444444"
CLOSED_WORKSPACE_ID = "bbbbbbbb-1111-4222-8333-444444444444"
CLAUDE_SESSION = "c1a0de00-0000-4000-8000-000000000001"
CODEX_SESSION = "c0dec000-0000-4000-8000-000000000002"
ENDED_CODEX_SESSION = "c0dec000-0000-4000-8000-000000000003"
MISSING_SESSION = "c1a0de00-0000-4000-8000-000000000004"


class TreeRecorder(SocketRecorder):
    def _result_for(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        if method == "system.tree":
            return {"windows": [{"workspaces": [
                {"id": WORKSPACE_ID, "ref": "workspace:1", "title": "alpha", "panes": []},
                {"id": OTHER_WORKSPACE_ID, "ref": "workspace:2", "title": "beta", "panes": []},
            ]}]}
        return super()._result_for(method, params)


def claude_line(message_id: str, usage: tuple[int, int, int, int], model: str = "claude-test") -> dict[str, Any]:
    inp, out, read, write = usage
    return {"type": "assistant", "message": {"id": message_id, "model": model, "role": "assistant", "usage": {
        "input_tokens": inp, "output_tokens": out,
        "cache_read_input_tokens": read, "cache_creation_input_tokens": write,
    }}}


def codex_usage(inp: int, cached: int, out: int, write: int = 0) -> dict[str, int]:
    return {"input_tokens": inp, "cached_input_tokens": cached, "cache_write_input_tokens": write,
            "output_tokens": out, "reasoning_output_tokens": 0, "total_tokens": inp + out}


def codex_record(response_id: str, usage: dict[str, int]) -> dict[str, Any]:
    return {"type": "token_usage_record", "payload": {"response_id": response_id, "usage": usage}}


def codex_count(total: dict[str, int] | None) -> dict[str, Any]:
    info = None if total is None else {"total_token_usage": total, "last_token_usage": total}
    return {"type": "event_msg", "payload": {"type": "token_count", "info": info}}


def write_jsonl(path: Path, lines: list[Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join((line if isinstance(line, str) else json.dumps(line)) + "\n" for line in lines), encoding="utf-8")


def tokens(inp: int, out: int, read: int, write: int) -> dict[str, int]:
    return {"input": inp, "output": out, "cache_read": read, "cache_write": write, "total": inp + out + read + write}


CLAUDE_TOKENS = tokens(10 + 1 + 7, 20 + 2 + 8, 100 + 3 + 9, 5 + 4 + 6)
CODEX_TOKENS = tokens((1000 - 400) + (50 - 0), 30 + 5, 400, 2)
ENDED_CODEX_TOKENS = tokens(900 - 100, 70, 100, 0)


class Sandbox:
    def __init__(self, root: str) -> None:
        self.root = Path(root)
        self.home = self.root / "home"
        self.home.mkdir()
        self.claude_state = self.root / "claude-hook-sessions.json"
        self.codex_state = self.home / ".programa" / "codex-hook-sessions.json"
        self.last_sessions = self.root / "agent-last-sessions.json"
        self.claude_transcript = self.root / "claude" / f"{CLAUDE_SESSION}.jsonl"
        self.codex_transcript = self.root / "codex" / f"rollout-x-{CODEX_SESSION}.jsonl"
        self.ended_codex_transcript = self.root / "codex" / f"rollout-x-{ENDED_CODEX_SESSION}.jsonl"

    def write_transcripts(self) -> None:
        message_a = claude_line("msg_a", (10, 20, 100, 5))
        write_jsonl(self.claude_transcript, [
            {"type": "user", "message": {"role": "user", "content": "synthetic prompt"}},
            message_a,
            message_a,
            claude_line("msg_a", (0, 0, 0, 0)),
            claude_line("msg_b", (1, 2, 3, 4)),
            claude_line("msg_synthetic", (50, 50, 50, 50), model="<synthetic>"),
            "{not json",
        ])
        write_jsonl(self.claude_transcript.with_suffix("") / "subagents" / "agent-one.jsonl", [
            message_a,
            claude_line("msg_c", (7, 8, 9, 6)),
        ])
        write_jsonl(self.codex_transcript, [
            {"type": "session_meta", "payload": {"id": CODEX_SESSION}},
            codex_count(None),
            codex_record("resp_1", codex_usage(1000, 400, 30, 2)),
            codex_count(codex_usage(1000, 400, 30, 2)),
            codex_record("resp_1", codex_usage(1000, 400, 30, 2)),
            codex_record("resp_2", codex_usage(50, 0, 5)),
            codex_count(codex_usage(1050, 400, 35, 2)),
            codex_count(codex_usage(1050, 400, 35, 2)),
        ])
        write_jsonl(self.ended_codex_transcript, [
            codex_count(codex_usage(400, 0, 20)),
            codex_count(codex_usage(900, 100, 70)),
            codex_count(codex_usage(300, 0, 10)),
        ])

    def write_state(self) -> None:
        now = time.time()

        def live(session: str, workspace: str, transcript: Path | None) -> dict[str, Any]:
            record = {"sessionId": session, "workspaceId": workspace, "surfaceId": SURFACE_ID,
                      "startedAt": now, "updatedAt": now}
            if transcript is not None:
                record["transcriptPath"] = str(transcript)
            return record

        self.claude_state.write_text(json.dumps({"version": 1, "sessions": {
            CLAUDE_SESSION: live(CLAUDE_SESSION, WORKSPACE_ID, self.claude_transcript),
            MISSING_SESSION: live(MISSING_SESSION, WORKSPACE_ID, self.root / "gone.jsonl"),
        }}), encoding="utf-8")
        self.codex_state.parent.mkdir(parents=True, exist_ok=True)
        self.codex_state.write_text(json.dumps({"version": 1, "sessions": {
            CODEX_SESSION: live(CODEX_SESSION, WORKSPACE_ID, self.codex_transcript),
        }}), encoding="utf-8")
        self.last_sessions.write_text(json.dumps({"version": 1, "sessions": [
            {"provider": "codex", "sessionId": ENDED_CODEX_SESSION, "workspaceId": OTHER_WORKSPACE_ID,
             "surfaceId": SURFACE_ID, "endedAt": now - 30, "transcriptPath": str(self.ended_codex_transcript)},
            {"provider": "claude-code", "sessionId": "c1a0de00-0000-4000-8000-000000000005",
             "workspaceId": CLOSED_WORKSPACE_ID, "endedAt": now - 60,
             "transcriptPath": str(self.claude_transcript.with_name("closed.jsonl"))},
        ]}), encoding="utf-8")
        write_jsonl(self.claude_transcript.with_name("closed.jsonl"), [claude_line("msg_closed", (1, 1, 1, 1))])

    def cli(self, rec: SocketRecorder, args: list[str], input_text: str | None = None):
        return run_cli(rec.path, args, input_text=input_text, env_overrides={
            "HOME": str(self.home), "CFFIXED_USER_HOME": str(self.home),
            "CLAUDE_CONFIG_DIR": str(self.root / "no-claude"), "CODEX_HOME": str(self.root / "no-codex"),
            "PROGRAMA_SOCKET": rec.path, "PROGRAMA_SOCKET_PATH": rec.path,
            "PROGRAMA_SURFACE_ID": SURFACE_ID, "PROGRAMA_WORKSPACE_ID": WORKSPACE_ID,
            "PROGRAMA_CLAUDE_HOOK_STATE_PATH": str(self.claude_state),
            "PROGRAMA_AGENT_LAST_SESSIONS_PATH": str(self.last_sessions),
        })


class AgentUsageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")
        self._tmp = tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp")
        self.box = Sandbox(self._tmp.name)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def recorder(self) -> TreeRecorder:
        return TreeRecorder(tempfile.mkdtemp(dir=self._tmp.name))

    def usage_json(self, *args: str) -> dict[str, Any]:
        with self.recorder() as rec:
            proc = self.box.cli(rec, ["--id-format", "both", "usage", "--json", *args])
        self.assertEqual(rec.errors, [])
        self.assertEqual(proc.returncode, 0, merged_output(proc))
        return json.loads(proc.stdout)

    def test_sums_and_dedupes_per_session_and_workspace(self) -> None:
        self.box.write_transcripts()
        self.box.write_state()
        payload = self.usage_json()
        by_id = {w.get("id"): w for w in payload["workspaces"]}
        self.assertEqual(list(by_id), [WORKSPACE_ID, OTHER_WORKSPACE_ID, CLOSED_WORKSPACE_ID], payload)

        alpha = by_id[WORKSPACE_ID]
        sessions = {s["session_id"]: s for s in alpha["sessions"]}
        self.assertEqual(set(sessions), {CLAUDE_SESSION, CODEX_SESSION})
        self.assertEqual(sessions[CLAUDE_SESSION]["tokens"], CLAUDE_TOKENS)
        self.assertEqual(sessions[CLAUDE_SESSION]["provider"], "claude-code")
        self.assertEqual(sessions[CLAUDE_SESSION]["state"], "live")
        self.assertEqual(sessions[CODEX_SESSION]["tokens"], CODEX_TOKENS)
        alpha_sum = {k: CLAUDE_TOKENS[k] + CODEX_TOKENS[k] for k in CLAUDE_TOKENS}
        self.assertEqual(alpha["tokens"], alpha_sum)
        self.assertEqual(alpha["ref"], "workspace:1")
        self.assertTrue(alpha["open"])

        beta = by_id[OTHER_WORKSPACE_ID]
        self.assertEqual([s["session_id"] for s in beta["sessions"]], [ENDED_CODEX_SESSION])
        self.assertEqual(beta["sessions"][0]["state"], "ended")
        self.assertEqual(beta["sessions"][0]["tokens"], ENDED_CODEX_TOKENS, "no records: largest running total")

        self.assertFalse(by_id[CLOSED_WORKSPACE_ID]["open"])
        self.assertEqual(by_id[CLOSED_WORKSPACE_ID]["tokens"], tokens(1, 1, 1, 1))

        self.assertEqual(payload["skipped"], [{"provider": "claude-code", "session_id": MISSING_SESSION}])
        self.assertEqual(payload["tokens"]["total"], sum(w["tokens"]["total"] for w in payload["workspaces"]))
        self.assertNotIn("cost", json.dumps(payload))

    def test_workspace_filter_and_text_output(self) -> None:
        self.box.write_transcripts()
        self.box.write_state()
        payload = self.usage_json("--workspace", "workspace:2")
        self.assertEqual([w["id"] for w in payload["workspaces"]], [OTHER_WORKSPACE_ID])
        self.assertEqual(payload["skipped"], [])

        with self.recorder() as rec:
            text = self.box.cli(rec, ["usage"])
            unknown = self.box.cli(rec, ["usage", "--workspace", "workspace:9"])
        self.assertEqual(text.returncode, 0, merged_output(text))
        self.assertIn("workspace:1  alpha", text.stdout)
        self.assertIn(CLAUDE_SESSION, text.stdout)
        self.assertIn(f"{CLOSED_WORKSPACE_ID} (closed)", text.stdout)
        self.assertIn("Skipped 1 session with a missing or unreadable transcript", text.stdout)
        self.assertNotEqual(unknown.returncode, 0, merged_output(unknown))
        self.assertIn("workspace not found", merged_output(unknown))

    def test_hooks_record_the_transcript_path_through_session_end(self) -> None:
        self.box.write_transcripts()
        payload = json.dumps({"session_id": CLAUDE_SESSION, "cwd": str(self.box.root),
                              "transcript_path": str(self.box.claude_transcript)})
        with self.recorder() as rec:
            started = self.box.cli(rec, ["claude-hook", "session-start"], input_text=payload)
            live = json.loads(self.box.claude_state.read_text(encoding="utf-8"))["sessions"][CLAUDE_SESSION]
            during = self.box.cli(rec, ["--id-format", "both", "usage", "--json"])
            ended = self.box.cli(rec, ["claude-hook", "session-end"], input_text=json.dumps({"session_id": CLAUDE_SESSION}))
            after = self.box.cli(rec, ["--id-format", "both", "usage", "--json"])
        self.assertEqual(started.returncode, 0, merged_output(started))
        self.assertEqual(ended.returncode, 0, merged_output(ended))
        self.assertEqual(live["transcriptPath"], str(self.box.claude_transcript))
        kept = json.loads(self.box.last_sessions.read_text(encoding="utf-8"))["sessions"]
        self.assertEqual(kept[0]["transcriptPath"], str(self.box.claude_transcript))
        for proc, state in ((during, "live"), (after, "ended")):
            self.assertEqual(proc.returncode, 0, merged_output(proc))
            sessions = json.loads(proc.stdout)["workspaces"][0]["sessions"]
            self.assertEqual([(s["session_id"], s["state"], s["tokens"]) for s in sessions],
                             [(CLAUDE_SESSION, state, CLAUDE_TOKENS)])

    def test_session_without_a_recorded_path_falls_back_to_the_agent_layout(self) -> None:
        self.box.write_transcripts()
        claude_home = self.box.root / "no-claude" / "projects" / "-some-project"
        claude_home.mkdir(parents=True)
        (claude_home / f"{CLAUDE_SESSION}.jsonl").write_text(self.box.claude_transcript.read_text(encoding="utf-8"), encoding="utf-8")
        now = time.time()
        self.box.claude_state.write_text(json.dumps({"version": 1, "sessions": {CLAUDE_SESSION: {
            "sessionId": CLAUDE_SESSION, "workspaceId": WORKSPACE_ID, "surfaceId": SURFACE_ID,
            "startedAt": now, "updatedAt": now,
        }}}), encoding="utf-8")
        payload = self.usage_json()
        session = payload["workspaces"][0]["sessions"][0]
        self.assertEqual(session["session_id"], CLAUDE_SESSION)
        self.assertEqual(session["tokens"], tokens(11, 22, 103, 9), "no subagent dir next to the fallback copy")

    def test_no_sessions_prints_a_message(self) -> None:
        with self.recorder() as rec:
            proc = self.box.cli(rec, ["usage"])
        self.assertEqual(proc.returncode, 0, merged_output(proc))
        self.assertEqual(proc.stdout.strip(), "No agent token usage recorded")


if __name__ == "__main__":
    unittest.main()
