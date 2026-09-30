#!/usr/bin/env python3
"""
Regression test: the workspace split cap (4 panes).

Three splits from a fresh workspace succeed (1 baseline pane + 3 = 4 panes,
exactly at the cap). A fourth split must be refused — surface.split returns
no surface_id — and the pane count must stay at 4. The refusal must not
disturb the existing panes.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")

MAX_PANES = 4
SPLIT_WAIT = 0.25


def main() -> int:
    with ProgramaClient(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        c.new_workspace()
        time.sleep(0.35)

        # Splits up to the cap succeed.
        for i in range(MAX_PANES - 1):
            c.new_split("right" if i % 2 == 0 else "down")
            time.sleep(SPLIT_WAIT)

        panes = c.list_panes()
        if len(panes) != MAX_PANES:
            raise ProgramaClientError(f"expected {MAX_PANES} panes at the cap, got {len(panes)}: {panes}")

        # The split past the cap is refused.
        try:
            c.new_split("right")
        except ProgramaClientError:
            pass
        else:
            raise ProgramaClientError(f"split past the {MAX_PANES}-pane cap unexpectedly succeeded")
        time.sleep(SPLIT_WAIT)

        # The refusal left the existing layout intact.
        panes = c.list_panes()
        if len(panes) != MAX_PANES:
            raise ProgramaClientError(f"expected {MAX_PANES} panes after refused split, got {len(panes)}: {panes}")

    print("OK: split refused at the 4-pane cap; layout intact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
