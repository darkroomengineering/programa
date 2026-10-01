#!/usr/bin/env python3
"""Contract (CLIX-03): `wait-surface --agent-state` sends one surface.wait with one condition.

Orchestrators block on a sibling agent with `wait-surface --agent-state idle`. The CLI must
send exactly one `surface.wait` request carrying only `agent_state`, and must reject an
ambiguous or unknown condition locally before touching the socket.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from test_cli_registry_behavior import CLI_PATH, SURFACE_ID, SocketRecorder, merged_output, run_cli


def cli(rec: SocketRecorder, home: str, args: list[str]):
    sock = rec.path
    return run_cli(sock, args, env_overrides={
        "HOME": home, "CFFIXED_USER_HOME": home, "PROGRAMA_SOCKET": sock, "PROGRAMA_SOCKET_PATH": sock,
    })


class WaitSurfaceAgentStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.assertTrue(CLI_PATH and os.access(CLI_PATH, os.X_OK), "PROGRAMA_CLI_BIN must point to the built CLI")

    def test_agent_state_sends_a_single_frame_without_other_conditions(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory, SocketRecorder(directory) as rec:
            proc = cli(rec, directory, ["wait-surface", "--surface", SURFACE_ID, "--agent-state", "idle", "--timeout", "5"])
        self.assertEqual(rec.errors, [])
        self.assertEqual(proc.returncode, 0, merged_output(proc))
        waits = [f for f in rec.frames if f.get("method") == "surface.wait"]
        self.assertEqual(len(waits), 1, rec.frames)
        params = waits[0]["params"]
        self.assertEqual(params.get("agent_state"), "idle")
        self.assertNotIn("pattern", params)
        self.assertNotIn("exit", params)
        self.assertEqual(params.get("surface_id"), SURFACE_ID)
        self.assertEqual(params.get("timeout_ms"), 5000)

    def test_ambiguous_or_unknown_condition_is_rejected_before_any_frame(self) -> None:
        cases = {
            "agent-state with exit": ["--agent-state", "idle", "--exit"],
            "agent-state with pattern": ["--agent-state", "idle", "--pattern", "done"],
            "unknown state": ["--agent-state", "bogus"],
        }
        for name, extra in cases.items():
            with self.subTest(name), tempfile.TemporaryDirectory(prefix="pcli-", dir="/tmp") as directory, SocketRecorder(directory) as rec:
                proc = cli(rec, directory, ["wait-surface", "--surface", SURFACE_ID, *extra])
            self.assertNotEqual(proc.returncode, 0, merged_output(proc))
            self.assertEqual(rec.frames, [], f"{name}: no request may reach the socket")


if __name__ == "__main__":
    unittest.main()
