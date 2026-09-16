#!/usr/bin/env python3
"""Extended browser.* coverage for newly added agent-browser parity families."""

import ast
import base64
import http.server
import os
import socketserver
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _expect_error_contains(label: str, fn, needle: str) -> None:
    try:
        fn()
    except cmuxError as exc:
        text = str(exc)
        if needle in text:
            return
        raise cmuxError(f"{label}: expected error containing {needle!r}, got: {text}")
    raise cmuxError(f"{label}: expected error containing {needle!r}, but call succeeded")


def _expect_error_data(label: str, fn, code: str) -> dict:
    try:
        fn()
    except cmuxError as exc:
        text = str(exc)
        _must(text.startswith(f"{code}:"), f"{label}: expected {code}, got: {text}")
        _, separator, serialized = text.partition(" (")
        _must(bool(separator) and serialized.endswith(")"), f"{label}: expected error data, got: {text}")
        try:
            data = ast.literal_eval(serialized[:-1])
        except (SyntaxError, ValueError) as parse_error:
            raise cmuxError(f"{label}: expected parseable error data, got: {text}") from parse_error
        _must(isinstance(data, dict), f"{label}: expected dictionary error data, got: {data}")
        return data
    raise cmuxError(f"{label}: expected {code}, but call succeeded")


def _wait_selector(c: cmux, surface_id: str, selector: str, timeout_s: float = 6.0) -> None:
    timeout_ms = max(1, int(timeout_s * 1000.0))
    try:
        c._call("browser.wait", {"surface_id": surface_id, "selector": selector, "timeout_ms": timeout_ms})
        return
    except cmuxError as exc:
        if "timeout" not in str(exc):
            raise

    deadline = time.time() + timeout_s
    script = f"document.querySelector({selector!r}) !== null"
    while time.time() < deadline:
        probe = c._call("browser.eval", {"surface_id": surface_id, "script": script}) or {}
        if bool(probe.get("value")):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for selector {selector}")


def _wait_function(c: cmux, surface_id: str, expression: str, timeout_s: float = 6.0) -> None:
    timeout_ms = max(1, int(timeout_s * 1000.0))
    try:
        c._call("browser.wait", {"surface_id": surface_id, "function": expression, "timeout_ms": timeout_ms})
        return
    except cmuxError as exc:
        if "timeout" not in str(exc):
            raise

    deadline = time.time() + timeout_s
    while time.time() < deadline:
        probe = c._call("browser.eval", {"surface_id": surface_id, "script": expression}) or {}
        if bool(probe.get("value")):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for function: {expression}")


def _test_browser_wait_allows_concurrent_exact_query(c: cmux, surface_id: str) -> None:
    """A pending browser.wait must not monopolize command dispatch or the main actor."""
    entered_attribute = "data-programa-concurrent-wait-entered"
    release_attribute = "data-programa-concurrent-wait-release"
    wait_result: dict = {}
    wait_errors: list[Exception] = []
    wait_finished = threading.Event()

    initialized = c._call(
        "browser.eval",
        {
            "surface_id": surface_id,
            "script": (
                f"document.documentElement.removeAttribute('{entered_attribute}'); "
                f"document.documentElement.removeAttribute('{release_attribute}'); true"
            ),
        },
    ) or {}
    _must(bool(initialized.get("value")), f"Failed to initialize browser.wait handshake: {initialized}")

    def _wait_on_client_a() -> None:
        try:
            with cmux(SOCKET_PATH) as wait_client:
                payload = wait_client._call(
                    "browser.wait",
                    {
                        "surface_id": surface_id,
                        "function": (
                            "(() => { const root = document.documentElement; "
                            f"if (root.getAttribute('{entered_attribute}') !== 'true') {{ "
                            f"root.setAttribute('{entered_attribute}', 'true'); }} "
                            f"return root.getAttribute('{release_attribute}') === 'true'; }})()"
                        ),
                        "timeout_ms": 8_000,
                    },
                    timeout_s=12.0,
                ) or {}
                wait_result.update(payload)
        except Exception as exc:  # pragma: no cover - surfaced on the controlling thread
            wait_errors.append(exc)
        finally:
            wait_finished.set()

    wait_thread = threading.Thread(target=_wait_on_client_a, daemon=True)
    wait_thread.start()

    primary_error: Exception | None = None
    cleanup_errors: list[Exception] = []
    entered = False
    try:
        entry_deadline = time.monotonic() + 4.0
        while time.monotonic() < entry_deadline:
            _must(
                not wait_finished.is_set(),
                f"browser.wait returned before publishing its entered marker: {wait_errors or wait_result}",
            )
            probe = c._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": (
                        f"document.documentElement.getAttribute('{entered_attribute}') === 'true'"
                    ),
                },
                timeout_s=2.0,
            ) or {}
            if bool(probe.get("value")):
                entered = True
                break
            wait_finished.wait(timeout=0.02)

        _must(entered, "Timed out waiting for browser.wait to publish its entered marker")
        _must(not wait_finished.is_set(), "browser.wait must remain pending until its release flag is set")

        query_started = time.monotonic()
        window_payload = c._call("window.list", timeout_s=2.0) or {}
        windows = list(window_payload.get("windows") or [])
        query_elapsed = time.monotonic() - query_started
        _must(bool(windows), f"window.list should return the running Programa window: {windows}")
        _must(
            query_elapsed < 2.0,
            f"window.list must complete promptly while browser.wait is pending; took {query_elapsed:.2f}s",
        )
        _must(
            not wait_finished.is_set(),
            "Client A's browser.wait must still be pending when client B's exact query returns",
        )
    except Exception as exc:
        primary_error = exc
    finally:
        try:
            released = c._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": (
                        f"document.documentElement.setAttribute('{release_attribute}', 'true'); true"
                    ),
                },
                timeout_s=3.0,
            ) or {}
            if not bool(released.get("value")):
                cleanup_errors.append(cmuxError(f"Failed to release browser.wait: {released}"))
        except Exception as exc:  # pragma: no cover - reported below
            cleanup_errors.append(exc)

        wait_thread.join(timeout=10.0)

        try:
            c._call(
                "browser.eval",
                {
                    "surface_id": surface_id,
                    "script": (
                        f"document.documentElement.removeAttribute('{entered_attribute}'); "
                        f"document.documentElement.removeAttribute('{release_attribute}'); true"
                    ),
                },
                timeout_s=3.0,
            )
        except Exception as exc:  # pragma: no cover - reported below
            cleanup_errors.append(exc)

    if primary_error is not None:
        raise cmuxError(
            f"{primary_error}; wait_errors={wait_errors}; wait_result={wait_result}; "
            f"cleanup_errors={cleanup_errors}; wait_thread_alive={wait_thread.is_alive()}"
        ) from primary_error
    _must(not cleanup_errors, f"browser.wait cleanup failed: {cleanup_errors}")
    _must(not wait_thread.is_alive(), "browser.wait client thread did not join after release")
    _must(not wait_errors, f"browser.wait client failed: {wait_errors}")
    _must(wait_finished.is_set(), "browser.wait client did not finish after release")
    _must(wait_result.get("waited") is True, f"Expected browser.wait waited=true: {wait_result}")


def _test_download_path_wait_allows_concurrent_exact_query(c: cmux, surface_id: str) -> None:
    """A pending path wait must not block exact queries or poison later requests."""
    wait_finished = threading.Event()
    wait_result: dict = {}
    wait_errors: list[Exception] = []

    with tempfile.TemporaryDirectory(prefix="cmux-download-wait-") as root:
        download_path = str(Path(root) / "pending.txt")
        pending_marker_path = str(Path(root) / "watcher-ready.txt")

        def _wait_on_client_a() -> None:
            try:
                with cmux(SOCKET_PATH) as wait_client:
                    payload = wait_client._call(
                        "browser.download.wait",
                        {
                            "surface_id": surface_id,
                            "path": download_path,
                            "timeout_ms": 8_000,
                            "_test_pending_marker_path": pending_marker_path,
                        },
                        timeout_s=12.0,
                    ) or {}
                    wait_result.update(payload)
            except Exception as exc:  # pragma: no cover - surfaced on the controlling thread
                wait_errors.append(exc)
            finally:
                wait_finished.set()

        wait_thread = threading.Thread(target=_wait_on_client_a, daemon=True)
        wait_thread.start()

        primary_error: Exception | None = None
        cleanup_errors: list[Exception] = []
        try:
            marker_observed = False
            marker_deadline = time.monotonic() + 4.0
            while time.monotonic() < marker_deadline:
                try:
                    marker_observed = Path(pending_marker_path).stat().st_size > 0
                except FileNotFoundError:
                    marker_observed = False
                if marker_observed:
                    break
                _must(
                    not wait_finished.is_set(),
                    f"browser.download.wait returned before publishing its pending marker: {wait_errors or wait_result}",
                )
                wait_finished.wait(timeout=0.02)

            _must(marker_observed, "Timed out waiting for browser.download.wait pending marker")
            _must(
                not wait_finished.is_set(),
                f"browser.download.wait returned before its target existed: {wait_errors or wait_result}",
            )

            query_started = time.monotonic()
            window_payload = c._call("window.list", timeout_s=2.0) or {}
            query_elapsed = time.monotonic() - query_started
            _must(bool(window_payload.get("windows")), f"window.list should return the running Programa window: {window_payload}")
            _must(
                query_elapsed < 2.0,
                f"window.list must complete promptly while browser.download.wait is pending; took {query_elapsed:.2f}s",
            )
            _must(
                not wait_finished.is_set(),
                "Client A's browser.download.wait must remain pending when client B's exact query returns",
            )
        except Exception as exc:
            primary_error = exc
        finally:
            try:
                Path(download_path).write_text("downloaded", encoding="utf-8")
            except Exception as exc:  # pragma: no cover - reported below
                cleanup_errors.append(exc)
            wait_thread.join(timeout=10.0)

        if primary_error is not None:
            raise cmuxError(
                f"{primary_error}; wait_errors={wait_errors}; wait_result={wait_result}; "
                f"cleanup_errors={cleanup_errors}; wait_thread_alive={wait_thread.is_alive()}"
            ) from primary_error
        _must(not cleanup_errors, f"browser.download.wait cleanup failed: {cleanup_errors}")
        _must(not wait_thread.is_alive(), "browser.download.wait client thread did not join after file creation")
        _must(not wait_errors, f"browser.download.wait client failed: {wait_errors}")
        _must(wait_finished.is_set(), "browser.download.wait client did not finish after file creation")
        _must(wait_result.get("downloaded") is True, f"Expected browser.download.wait downloaded=true: {wait_result}")

        timeout_path = str(Path(root) / "timeout.txt")
        timeout_data = _expect_error_data(
            "download path wait timeout",
            lambda: c._call(
                "browser.download.wait",
                {"surface_id": surface_id, "path": timeout_path, "timeout_ms": 100},
                timeout_s=3.0,
            ),
            "timeout",
        )
        _must(timeout_data.get("path") == timeout_path, f"Expected timed-out download path: {timeout_data}")
        _must(timeout_data.get("timeout_ms") == 100, f"Expected exact download timeout: {timeout_data}")

        recovery_payload = c._call("window.list", timeout_s=2.0) or {}
        _must(
            bool(recovery_payload.get("windows")),
            f"window.list should recover after browser.download.wait timeout: {recovery_payload}",
        )


def _test_browser_screenshot_allows_concurrent_exact_query(c: cmux, surface_id: str) -> None:
    """Completed screenshot work must not hold the main actor while routing its response."""

    def _wait_for_pending_marker(
        marker_path: str,
        finished: threading.Event,
        errors: list[Exception],
        result: dict,
        label: str,
    ) -> None:
        marker_observed = False
        marker_deadline = time.monotonic() + 4.0
        while time.monotonic() < marker_deadline:
            try:
                marker_observed = Path(marker_path).stat().st_size > 0
            except FileNotFoundError:
                marker_observed = False
            if marker_observed:
                break
            _must(
                not finished.is_set(),
                f"{label} returned before publishing its pending marker: {errors or result}",
            )
            finished.wait(timeout=0.02)
        _must(marker_observed, f"Timed out waiting for {label} pending marker")

    with tempfile.TemporaryDirectory(prefix="cmux-screenshot-wait-") as root:
        success_pending_path = str(Path(root) / "success-pending.txt")
        success_release_path = str(Path(root) / "success-release.txt")
        success_result: dict = {}
        success_errors: list[Exception] = []
        success_finished = threading.Event()

        def _take_released_screenshot() -> None:
            try:
                with cmux(SOCKET_PATH) as screenshot_client:
                    payload = screenshot_client._call(
                        "browser.screenshot",
                        {
                            "surface_id": surface_id,
                            "_test_screenshot_pending_marker_path": success_pending_path,
                            "_test_screenshot_release_marker_path": success_release_path,
                        },
                        timeout_s=10.0,
                    ) or {}
                    success_result.update(payload)
            except Exception as exc:  # pragma: no cover - surfaced on the controlling thread
                success_errors.append(exc)
            finally:
                success_finished.set()

        success_thread = threading.Thread(target=_take_released_screenshot, daemon=True)
        success_thread.start()

        success_primary_error: Exception | None = None
        success_cleanup_errors: list[Exception] = []
        try:
            _wait_for_pending_marker(
                success_pending_path,
                success_finished,
                success_errors,
                success_result,
                "browser.screenshot",
            )
            _must(not success_finished.is_set(), "browser.screenshot must remain gated before release")

            query_started = time.monotonic()
            window_payload = c._call("window.list", timeout_s=2.0) or {}
            query_elapsed = time.monotonic() - query_started
            _must(bool(window_payload.get("windows")), f"window.list should return the running Programa window: {window_payload}")
            _must(
                query_elapsed < 2.0,
                f"window.list must complete promptly while browser.screenshot is gated; took {query_elapsed:.2f}s",
            )
            _must(
                not success_finished.is_set(),
                "Client A's browser.screenshot must remain pending when client B's exact query returns",
            )
        except Exception as exc:
            success_primary_error = exc
        finally:
            try:
                Path(success_release_path).write_text("release", encoding="utf-8")
            except Exception as exc:  # pragma: no cover - reported below
                success_cleanup_errors.append(exc)
            success_thread.join(timeout=10.0)

        screenshot_path_value = str(success_result.get("path") or "")
        screenshot_path = Path(screenshot_path_value) if screenshot_path_value else None
        screenshot_path_existed = screenshot_path is not None and screenshot_path.is_file()
        success_post_join_error = success_primary_error
        try:
            if success_post_join_error is None:
                _must(not success_thread.is_alive(), "browser.screenshot client thread did not join after release")
                _must(not success_errors, f"browser.screenshot client failed: {success_errors}")
                _must(success_finished.is_set(), "browser.screenshot client did not finish after release")

                png_base64 = str(success_result.get("png_base64") or "")
                _must(len(png_base64) > 100, f"Expected non-trivial screenshot payload: {success_result}")
                _must(success_result.get("surface_id") == surface_id, f"Expected screenshot surface_id={surface_id}: {success_result}")
                _must(bool(str(success_result.get("workspace_id") or "")), f"Expected screenshot workspace_id: {success_result}")
                _must(screenshot_path_existed, f"Expected screenshot file to exist: {success_result}")
                _must(str(success_result.get("url") or "").startswith("file://"), f"Expected screenshot file URL: {success_result}")
        except Exception as exc:
            success_post_join_error = exc
        finally:
            if screenshot_path is not None and screenshot_path.is_file():
                try:
                    screenshot_path.unlink()
                except Exception as exc:  # pragma: no cover - reported below
                    success_cleanup_errors.append(exc)
        if success_post_join_error is not None:
            raise cmuxError(
                f"{success_post_join_error}; screenshot_errors={success_errors}; screenshot_result={success_result}; "
                f"cleanup_errors={success_cleanup_errors}; screenshot_thread_alive={success_thread.is_alive()}"
            ) from success_post_join_error
        _must(not success_cleanup_errors, f"browser.screenshot cleanup failed: {success_cleanup_errors}")

        timeout_pending_path = str(Path(root) / "timeout-pending.txt")
        timeout_release_path = str(Path(root) / "timeout-release.txt")
        timeout_result: dict = {}
        timeout_errors: list[Exception] = []
        timeout_finished = threading.Event()

        def _take_timed_out_screenshot() -> None:
            try:
                with cmux(SOCKET_PATH) as screenshot_client:
                    payload = screenshot_client._call(
                        "browser.screenshot",
                        {
                            "surface_id": surface_id,
                            "_test_screenshot_pending_marker_path": timeout_pending_path,
                            "_test_screenshot_release_marker_path": timeout_release_path,
                        },
                        timeout_s=12.0,
                    ) or {}
                    timeout_result.update(payload)
            except Exception as exc:  # pragma: no cover - surfaced on the controlling thread
                timeout_errors.append(exc)
            finally:
                timeout_finished.set()

        timeout_thread = threading.Thread(target=_take_timed_out_screenshot, daemon=True)
        timeout_thread.start()

        timeout_primary_error: Exception | None = None
        timeout_cleanup_errors: list[Exception] = []
        try:
            _wait_for_pending_marker(
                timeout_pending_path,
                timeout_finished,
                timeout_errors,
                timeout_result,
                "timed browser.screenshot",
            )
            _must(not timeout_finished.is_set(), "Timed browser.screenshot must remain gated before its deadline")
            timeout_thread.join(timeout=7.0)
            _must(not timeout_thread.is_alive(), "Timed browser.screenshot did not return after its fixed deadline")
            _must(timeout_finished.is_set(), "Timed browser.screenshot thread did not finish")
            _must(not timeout_result, f"Timed browser.screenshot unexpectedly succeeded: {timeout_result}")
            _must(len(timeout_errors) == 1, f"Expected one browser.screenshot timeout error: {timeout_errors}")
            _must(
                isinstance(timeout_errors[0], cmuxError)
                and str(timeout_errors[0]) == "timeout: Timed out waiting for snapshot",
                f"Expected exact browser.screenshot timeout error: {timeout_errors}",
            )
        except Exception as exc:
            timeout_primary_error = exc
        finally:
            try:
                Path(timeout_release_path).write_text("release", encoding="utf-8")
            except Exception as exc:  # pragma: no cover - reported below
                timeout_cleanup_errors.append(exc)
            timeout_thread.join(timeout=3.0)
            threading.Event().wait(timeout=0.5)

        if timeout_primary_error is not None:
            raise cmuxError(
                f"{timeout_primary_error}; screenshot_errors={timeout_errors}; screenshot_result={timeout_result}; "
                f"cleanup_errors={timeout_cleanup_errors}; screenshot_thread_alive={timeout_thread.is_alive()}"
            ) from timeout_primary_error
        _must(not timeout_cleanup_errors, f"Timed browser.screenshot release cleanup failed: {timeout_cleanup_errors}")
        _must(not timeout_thread.is_alive(), "Timed browser.screenshot client thread remained alive after release")

        recovery_payload = c._call("window.list", timeout_s=2.0) or {}
        _must(
            bool(recovery_payload.get("windows")),
            f"window.list should recover after browser.screenshot timeout: {recovery_payload}",
        )
        recovery_screenshot = c._call("browser.screenshot", {"surface_id": surface_id}, timeout_s=8.0) or {}
        recovery_path_value = str(recovery_screenshot.get("path") or "")
        recovery_path = Path(recovery_path_value) if recovery_path_value else None
        recovery_cleanup_errors: list[Exception] = []
        try:
            _must(
                len(str(recovery_screenshot.get("png_base64") or "")) > 100,
                f"Expected normal screenshot after timeout: {recovery_screenshot}",
            )
        finally:
            if recovery_path is not None and recovery_path.is_file():
                try:
                    recovery_path.unlink()
                except Exception as exc:  # pragma: no cover - reported below
                    recovery_cleanup_errors.append(exc)
        _must(not recovery_cleanup_errors, f"Normal browser.screenshot cleanup failed: {recovery_cleanup_errors}")


@contextmanager
def _local_test_server() -> str:
    with tempfile.TemporaryDirectory(prefix="cmux-browser-ext-") as root:
        root_path = Path(root)

        pixel = base64.b64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")
        (root_path / "tiny.gif").write_bytes(pixel)

        (root_path / "frame.html").write_text(
            """<!doctype html>
<html>
  <body>
    <button id="frame-btn" onclick="window.top.frameClicks = (window.top.frameClicks || 0) + 1">Frame Button</button>
    <div id="frame-text">frame-ready</div>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        (root_path / "second.html").write_text(
            """<!doctype html>
<html>
  <head>
    <title>cmux-browser-extended-second</title>
  </head>
  <body>
    <div id="second">second-page</div>
    <div id="style-target">style-target-second</div>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        (root_path / "index.html").write_text(
            """<!doctype html>
<html>
  <head>
    <title>cmux-browser-extended</title>
    <style>
      #style-target { color: rgb(255, 0, 0); }
    </style>
  </head>
  <body>
    <label for="name">Agent Name</label>
    <input id="name" placeholder="Type name" title="name-title" data-testid="name-field" />
    <img id="hero" alt="hero image" src="/tiny.gif" />
    <button id="action-btn" role="button" onclick="window.actionCount = (window.actionCount || 0) + 1; document.querySelector('#status').textContent = 'clicked';">Submit Action</button>
    <div id="status">ready</div>

    <ul id="rows">
      <li class="row">row-1</li>
      <li class="row">row-2</li>
      <li class="row">row-3</li>
    </ul>

    <iframe id="frame-a" src="/frame.html"></iframe>

    <div id="style-target">style target</div>

    <script>
      window.actionCount = 0;
      window.frameClicks = 0;
      window.__programaHighlightOutlineObserved = false;
      const highlightTarget = document.querySelector('#action-btn');
      const highlightObserver = new MutationObserver(function () {
        if (highlightTarget.style.outlineWidth === '3px') {
          window.__programaHighlightOutlineObserved = true;
          highlightObserver.disconnect();
        }
      });
      highlightObserver.observe(highlightTarget, { attributes: true, attributeFilter: ['style'] });
      window.triggerDialogs = function () {
        window.dialogResults = [];
        window.dialogsFinished = false;
        setTimeout(function () {
          window.dialogResults.push(confirm('confirm-message'));
          window.dialogResults.push(prompt('prompt-message', 'prompt-default'));
          alert('alert-message');
          window.dialogResults.push('alert-complete');
          window.dialogsFinished = true;
        }, 50);
        return true;
      };
      window.emitConsoleAndError = function () {
        console.log('cmux-console-entry');
        setTimeout(function () {
          throw new Error('cmux-boom');
        }, 0);
        return true;
      };
    </script>
  </body>
</html>
""".strip(),
            encoding="utf-8",
        )

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=root, **kwargs)

            def log_message(self, format: str, *args) -> None:  # noqa: A003
                return

        class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
            allow_reuse_address = True
            daemon_threads = True

        server = ThreadedTCPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://127.0.0.1:{server.server_address[1]}"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=1.0)


def _respond_to_pending_dialog(c: cmux, sid: str, accept: bool, **extra) -> dict:
    deadline = time.monotonic() + 8.0
    method = "browser.dialog.accept" if accept else "browser.dialog.dismiss"
    while True:
        try:
            return c._call(method, {"surface_id": sid, **extra}) or {}
        except cmuxError as exc:
            # Never probe JavaScript while the native dialog blocks the page.
            if not str(exc).startswith("not_found:") or time.monotonic() >= deadline:
                raise
            time.sleep(0.05)


def _test_find_reference_targets(c: cmux, sid: str) -> None:
    # Same fixture works in the main document and the selected same-origin frame.
    c._call("browser.eval", {"surface_id": sid, "script": """
      (() => {
        const fixture = document.createElement('section');
        fixture.id = 'find-regression';
        fixture.innerHTML = `
          <div id="duplicate-parent"><button id="duplicate-target" class="find-target" data-hit="first">first target</button></div>
          <div id="duplicate-parent"><button>nonmatching sibling</button><button id="duplicate-target" class="find-target" data-hit="second">second target</button></div>
          <div><button>another nonmatch</button><button id="unique:target[final]" class="find-final" data-hit="last">last target</button></div>`;
        fixture.addEventListener('click', event => { window.findRegressionHit = event.target.dataset.hit || 'wrong'; });
        document.body.appendChild(fixture);
        return true;
      })()
    """})
    try:
        selector = "#find-regression .find-target, #find-regression .find-final"
        cases = [
            ("browser.find.nth", {"index": 1}, "second", "second target", 1),
            ("browser.find.nth", {"index": -1}, "last", "last target", 2),
            ("browser.find.last", {}, "last", "last target", None),
            ("browser.find.last", {"selector": "#find-regression .find-target"}, "second", "second target", None),
        ]
        for method, extra, marker, text, index in cases:
            params = {"surface_id": sid, "selector": selector}
            params.update(extra)
            found = c._call(method, params) or {}
            ref = str(found.get("element_ref") or "")
            _must(ref.startswith("@e"), f"Expected usable reference: {found}")
            _must(found.get("text") == text, f"Finder must report selected target text: {found}")
            if index is not None:
                _must(found.get("index") == index, f"Expected normalized collection index {index}: {found}")
            c._call("browser.eval", {"surface_id": sid, "script": "window.findRegressionHit = null"})
            c._call("browser.click", {"surface_id": sid, "selector": ref})
            clicked = c._call("browser.eval", {"surface_id": sid, "script": "window.findRegressionHit"}) or {}
            _must(clicked.get("value") == marker, f"{method} reference clicked wrong collection member: {clicked}, {found}")
            actual_text = c._call("browser.get.text", {"surface_id": sid, "selector": ref}) or {}
            _must(actual_text.get("value") == text, f"Reference must retain selected element identity: {actual_text}")
    finally:
        c._call("browser.eval", {"surface_id": sid, "script": "document.querySelector('#find-regression').remove(); true"})


def main() -> int:
    with _local_test_server() as base_url:
        index_url = f"{base_url}/index.html"
        second_url = f"{base_url}/second.html"

        with cmux(SOCKET_PATH) as c:
            opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
            sid = str(opened.get("surface_id") or "")
            _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")

            c._call("browser.navigate", {"surface_id": sid, "url": index_url})
            _wait_selector(c, sid, "#action-btn", timeout_s=7.0)
            _test_browser_wait_allows_concurrent_exact_query(c, sid)
            _test_browser_screenshot_allows_concurrent_exact_query(c, sid)

            find_role = c._call("browser.find.role", {"surface_id": sid, "role": "button", "name": "submit"}) or {}
            role_ref = str(find_role.get("element_ref") or "")
            _must(role_ref.startswith("@e"), f"Expected element_ref from find.role: {find_role}")
            c._call("browser.click", {"surface_id": sid, "selector": role_ref})
            status = c._call("browser.get.text", {"surface_id": sid, "selector": "#status"}) or {}
            _must(str(status.get("value") or "") == "clicked", f"Expected clicked status via element ref: {status}")

            find_cases = [
                ("browser.find.text", {"text": "row-2"}),
                ("browser.find.label", {"label": "Agent Name"}),
                ("browser.find.placeholder", {"placeholder": "Type name"}),
                ("browser.find.alt", {"alt": "hero image"}),
                ("browser.find.title", {"title": "name-title"}),
                ("browser.find.testid", {"testid": "name-field"}),
                ("browser.find.first", {"selector": "li.row"}),
                ("browser.find.last", {"selector": "li.row"}),
                ("browser.find.nth", {"selector": "li.row", "index": 1}),
            ]
            for method, extra in find_cases:
                params = {"surface_id": sid}
                params.update(extra)
                payload = c._call(method, params) or {}
                ref = str(payload.get("element_ref") or "")
                _must(ref.startswith("@e"), f"Expected element_ref from {method}: {payload}")

            _test_find_reference_targets(c, sid)

            missing_role = "dialog"
            missing_name = "programa-missing-exact-dialog"
            missing_role_data = _expect_error_data(
                "find.role exact match missing",
                lambda: c._call(
                    "browser.find.role",
                    {
                        "surface_id": sid,
                        "role": missing_role,
                        "name": missing_name,
                        "exact": True,
                    },
                ),
                "not_found",
            )
            _must(
                missing_role_data.get("role") == missing_role,
                f"Expected role in error data: {missing_role_data}",
            )
            _must(
                missing_role_data.get("name") == missing_name,
                f"Expected name in error data: {missing_role_data}",
            )
            _must(
                missing_role_data.get("exact") is True,
                f"Expected exact=true in error data: {missing_role_data}",
            )

            _expect_error_contains(
                "frame.select missing selector",
                lambda: c._call("browser.frame.select", {"surface_id": sid}),
                "invalid_params",
            )
            c._call("browser.frame.select", {"surface_id": sid, "selector": "#frame-a"})
            _wait_function(c, sid, "document.querySelector('#frame-text') !== null", timeout_s=7.0)
            _test_find_reference_targets(c, sid)
            frame_text = c._call("browser.get.text", {"surface_id": sid, "selector": "#frame-text"}) or {}
            _must(str(frame_text.get("value") or "") == "frame-ready", f"Expected frame text: {frame_text}")
            c._call("browser.click", {"surface_id": sid, "selector": "#frame-btn"})
            c._call("browser.frame.main", {"surface_id": sid})
            frame_clicks = c._call("browser.eval", {"surface_id": sid, "script": "window.frameClicks || 0"}) or {}
            _must(int(frame_clicks.get("value") or 0) >= 1, f"Expected frame click count >= 1: {frame_clicks}")

            c._call("browser.console.list", {"surface_id": sid})
            c._call("browser.addscript", {"surface_id": sid, "script": "window.triggerDialogs(); true;"})
            d1 = _respond_to_pending_dialog(c, sid, True, text="agent-text")
            d2 = _respond_to_pending_dialog(c, sid, False)
            d3 = _respond_to_pending_dialog(c, sid, True)
            _must(bool(d1.get("accepted")) is True, f"Expected first dialog accepted: {d1}")
            _must(bool(d2.get("accepted")) is False, f"Expected second dialog dismissed: {d2}")
            _must(bool(d3.get("accepted")) is True, f"Expected third dialog accepted: {d3}")
            _wait_function(c, sid, "window.dialogsFinished === true", timeout_s=7.0)
            dialog_results = c._call("browser.eval", {"surface_id": sid, "script": "window.dialogResults"}) or {}
            _must(dialog_results.get("value") == [True, None, "alert-complete"],
                  f"Dialog responses must reach the original JavaScript calls: {dialog_results}")
            _expect_error_contains(
                "dialog queue empty",
                lambda: c._call("browser.dialog.dismiss", {"surface_id": sid}),
                "not_found",
            )

            _test_download_path_wait_allows_concurrent_exact_query(c, sid)

            c._call(
                "browser.cookies.set",
                {
                    "surface_id": sid,
                    "name": "cmux_cookie",
                    "value": "cookie_value",
                    "url": index_url,
                },
            )
            got_cookie = c._call("browser.cookies.get", {"surface_id": sid, "name": "cmux_cookie"}) or {}
            cookies = got_cookie.get("cookies") or []
            _must(any(str(row.get("name")) == "cmux_cookie" for row in cookies), f"Expected cmux_cookie in cookies.get: {got_cookie}")
            c._call("browser.cookies.clear", {"surface_id": sid, "name": "cmux_cookie"})
            got_after_clear = c._call("browser.cookies.get", {"surface_id": sid, "name": "cmux_cookie"}) or {}
            _must(len(got_after_clear.get("cookies") or []) == 0, f"Expected cookie cleared: {got_after_clear}")

            _expect_error_contains(
                "storage.set missing value",
                lambda: c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "missing-value"}),
                "invalid_params",
            )
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "alpha", "value": "one"})
            c._call("browser.storage.set", {"surface_id": sid, "type": "session", "key": "beta", "value": "two"})
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "numeric", "value": 42})
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "explicit-null", "value": None})
            storage_local = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "alpha"}) or {}
            storage_session = c._call("browser.storage.get", {"surface_id": sid, "type": "session", "key": "beta"}) or {}
            storage_numeric = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "numeric"}) or {}
            storage_null = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "explicit-null"}) or {}
            _must(str(storage_local.get("value") or "") == "one", f"Expected local storage value: {storage_local}")
            _must(str(storage_session.get("value") or "") == "two", f"Expected session storage value: {storage_session}")
            _must(str(storage_numeric.get("value") or "") == "42", f"Expected normalized numeric storage value: {storage_numeric}")
            _must(storage_null.get("value") == "", f"Expected explicit null to store an empty string: {storage_null}")
            c._call("browser.storage.clear", {"surface_id": sid, "type": "session"})
            storage_session_after = c._call("browser.storage.get", {"surface_id": sid, "type": "session", "key": "beta"}) or {}
            _must(storage_session_after.get("value") is None, f"Expected session key cleared: {storage_session_after}")

            tabs_before = c._call("browser.tab.list", {"surface_id": sid}) or {}
            before_count = len(tabs_before.get("tabs") or [])
            tab_new = c._call("browser.tab.new", {"surface_id": sid, "url": second_url}) or {}
            sid2 = str(tab_new.get("surface_id") or "")
            _must(bool(sid2), f"Expected surface_id from browser.tab.new: {tab_new}")
            _wait_selector(c, sid2, "#second", timeout_s=7.0)
            tabs_after = c._call("browser.tab.list", {"surface_id": sid2}) or {}
            ids_after = {str(item.get("id") or "") for item in (tabs_after.get("tabs") or [])}
            _must(sid2 in ids_after and len(ids_after) >= before_count + 1, f"Expected new tab in list: {tabs_after}")
            c._call("browser.tab.switch", {"surface_id": sid2, "target_surface_id": sid})
            c._call("browser.tab.close", {"surface_id": sid, "target_surface_id": sid2})

            addscript_payload = c._call("browser.addscript", {"surface_id": sid, "script": "1 + 2"}) or {}
            _must(int(addscript_payload.get("value") or 0) == 3, f"Expected addscript value=3: {addscript_payload}")

            c._call("browser.addstyle", {"surface_id": sid, "css": "#style-target { color: rgb(0, 128, 0); }"})
            style_color = c._call("browser.get.styles", {"surface_id": sid, "selector": "#style-target", "property": "color"}) or {}
            _must("0, 128, 0" in str(style_color.get("value") or ""), f"Expected updated style color: {style_color}")

            c._call("browser.addinitscript", {"surface_id": sid, "script": "window.__cmuxInitMarker = 'init-ok';"})
            c._call("browser.navigate", {"surface_id": sid, "url": second_url})
            _wait_selector(c, sid, "#second", timeout_s=7.0)
            init_value = c._call("browser.eval", {"surface_id": sid, "script": "window.__cmuxInitMarker || ''"}) or {}
            _must(str(init_value.get("value") or "") == "init-ok", f"Expected init script marker after navigation: {init_value}")
            persisted_style = c._call(
                "browser.get.styles",
                {"surface_id": sid, "selector": "#style-target", "property": "color"},
            ) or {}
            _must(
                "0, 128, 0" in str(persisted_style.get("value") or ""),
                f"Expected added style to persist after navigation: {persisted_style}",
            )

            c._call("browser.navigate", {"surface_id": sid, "url": index_url})
            _wait_selector(c, sid, "#action-btn", timeout_s=7.0)
            c._call("browser.console.list", {"surface_id": sid})
            c._call("browser.addscript", {"surface_id": sid, "script": "window.emitConsoleAndError();"})
            time.sleep(0.35)
            console_entries = c._call("browser.console.list", {"surface_id": sid}) or {}
            errors_entries = c._call("browser.errors.list", {"surface_id": sid}) or {}
            _must(int(console_entries.get("count") or 0) >= 1, f"Expected console entries: {console_entries}")
            _must(int(errors_entries.get("count") or 0) >= 1, f"Expected error entries: {errors_entries}")
            c._call("browser.console.clear", {"surface_id": sid})
            console_after = c._call("browser.console.list", {"surface_id": sid}) or {}
            _must(int(console_after.get("count") or 0) == 0, f"Expected cleared console entries: {console_after}")
            cleared_errors = c._call("browser.errors.list", {"surface_id": sid, "clear": True}) or {}
            _must(
                cleared_errors.get("errors") == errors_entries.get("errors"),
                f"Expected errors.list clear response to return the errors it cleared: {cleared_errors}",
            )
            errors_after = c._call("browser.errors.list", {"surface_id": sid}) or {}
            _must(int(errors_after.get("count") or 0) == 0, f"Expected cleared error entries: {errors_after}")

            c._call("browser.highlight", {"surface_id": sid, "selector": "#action-btn"})
            highlight_observed = c._call(
                "browser.eval",
                {"surface_id": sid, "script": "window.__programaHighlightOutlineObserved === true"},
            ) or {}
            _must(bool(highlight_observed.get("value")), f"Expected highlighted outline mutation: {highlight_observed}")

            state_path = tempfile.NamedTemporaryFile(delete=False, prefix="cmux-state-", suffix=".json").name
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "persist", "value": "yes"})
            c._call("browser.state.save", {"surface_id": sid, "path": state_path})
            c._call("browser.storage.set", {"surface_id": sid, "type": "local", "key": "persist", "value": "no"})
            c._call("browser.state.load", {"surface_id": sid, "path": state_path})
            persisted = c._call("browser.storage.get", {"surface_id": sid, "type": "local", "key": "persist"}) or {}
            _must(str(persisted.get("value") or "") == "yes", f"Expected state.load to restore storage key: {persisted}")

    print("PASS: extended browser parity families are green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
