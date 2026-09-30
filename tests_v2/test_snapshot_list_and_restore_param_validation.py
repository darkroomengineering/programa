#!/usr/bin/env python3
"""snapshot.list/snapshot.restore parameter validation.

Seeding a fake `session-history/` directory for a *running* app instance would require
knowing its exact bundle-identifier-scoped Application Support path, which no harness in
tests_v2 resolves today (unlike `layout.save`'s well-known `~/.config/programa/layouts`).
This test therefore covers what is exercisable without that: `snapshot.list`'s result shape,
and `snapshot.restore` rejecting an unknown id. See docs/plans/snapshot-restore.md.
"""

from __future__ import annotations

import os
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def main() -> int:
    with ProgramaClient(SOCKET_PATH) as c:
        listed = c._call("snapshot.list", {}, timeout_s=10.0) or {}
        _must("snapshots" in listed, f"snapshot.list should return a 'snapshots' key: {listed}")
        _must(
            isinstance(listed.get("snapshots"), list),
            f"snapshot.list's 'snapshots' should be a list: {listed}",
        )

        unknown_id = f"nonexistent-{uuid.uuid4().hex}"
        raised = False
        try:
            c._call("snapshot.restore", {"id": unknown_id}, timeout_s=10.0)
        except ProgramaClientError as exc:
            raised = True
            message = str(exc).lower()
            _must(
                "not_found" in message,
                f"snapshot.restore with an unknown id should fail with not_found, got: {exc}",
            )
        _must(raised, "snapshot.restore with an unknown id should raise an error, not succeed")

    print("PASS: snapshot.list returns a structured result and snapshot.restore rejects an unknown id")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
