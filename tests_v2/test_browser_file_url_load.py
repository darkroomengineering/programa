#!/usr/bin/env python3
"""v2 regression: browser can render local file:// HTML pages."""

import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _wait_until(pred, timeout_s: float, label: str) -> None:
    deadline = time.time() + timeout_s
    last_exc = None
    while time.time() < deadline:
        try:
            if pred():
                return
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.05)
    if last_exc is not None:
        raise ProgramaClientError(f"Timed out waiting for {label}: {last_exc}")
    raise ProgramaClientError(f"Timed out waiting for {label}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="programa-file-url-") as root:
        html_path = Path(root) / "local-test.html"
        html_path.write_text(
            """
<!doctype html>
<html>
  <head><meta charset=\"utf-8\"><title>programa file url load</title></head>
  <body>
    <h1 id=\"headline\">local HTML file loaded</h1>
    <p id=\"path\">This page is loaded via file://</p>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )
        file_url = html_path.resolve().as_uri()

        with ProgramaClient(SOCKET_PATH) as c:
            opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
            sid = str(opened.get("surface_id") or "")
            _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")

            c._call("browser.navigate", {"surface_id": sid, "url": file_url})

            _wait_until(
                lambda: str((c._call("browser.get.title", {"surface_id": sid}) or {}).get("title") or "")
                == "programa file url load",
                timeout_s=5.0,
                label="browser.get.title(file://)",
            )

            page_text = c._call(
                "browser.eval",
                {
                    "surface_id": sid,
                    "script": "document.body ? (document.body.innerText || '') : ''",
                },
            ) or {}
            _must(
                "local HTML file loaded" in str(page_text.get("value") or ""),
                f"Expected file:// page body text: {page_text}",
            )

            url_payload = c._call("browser.url.get", {"surface_id": sid}) or {}
            actual_url = str(url_payload.get("url") or "")
            _must(
                actual_url.startswith("file://"),
                f"Expected browser.url.get to stay on file:// URL: {url_payload}",
            )

    print("PASS: browser loads local file:// HTML")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
