#!/usr/bin/env python3
"""browser.wait with `function` sees a page-world flag set later by browser.eval (SOCK-30).

The flag is set from a second client 1.5s after the wait starts; the wait must succeed rather
than time out. Depends on WebKit page-load timing, so it is not in ci_subset.txt.
"""

import os
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
WAIT_MS = 8_000


def main() -> int:
    for var in ("PROGRAMA_WORKSPACE_ID", "PROGRAMA_SURFACE_ID", "PROGRAMA_PANEL_ID", "PROGRAMA_TAB_ID"):
        os.environ.pop(var, None)

    ws = ""
    errors: list[Exception] = []
    with ProgramaClient(SOCKET_PATH) as a:
        try:
            ws = a.new_workspace()
            a.select_workspace(ws)
            time.sleep(0.4)
            browser = a.open_browser("about:blank")
            time.sleep(1.0)

            def _set_flag() -> None:
                try:
                    time.sleep(1.5)
                    with ProgramaClient(SOCKET_PATH) as b:
                        b._call("browser.eval", {"surface_id": browser, "script": "window.appReady = true"}, timeout_s=10.0)
                except Exception as exc:
                    errors.append(exc)

            t = threading.Thread(target=_set_flag)
            t.start()
            started = time.time()
            a._call(
                "browser.wait",
                {"surface_id": browser, "function": "window.appReady===true", "timeout_ms": WAIT_MS},
                timeout_s=WAIT_MS / 1000.0 + 10.0,
            )
            elapsed = time.time() - started
            t.join()
            _must(not errors, f"flag setter failed: {errors}")
            _must(elapsed >= 1.0, f"wait returned in {elapsed:.2f}s, before the flag was set")
        finally:
            if ws:
                try:
                    a.close_workspace(ws)
                except Exception:
                    pass

    print("PASS: browser.wait function observed the flag set by browser.eval")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
