#!/usr/bin/env python3
"""Browser parity matrix: advertised methods + explicit WKWebView not_supported gaps."""

import ast
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")

# Methods expected to be present in system.capabilities for the browser v2 surface.
EXPECTED_BROWSER_METHODS = {
    "browser.open_split",
    "browser.navigate",
    "browser.back",
    "browser.forward",
    "browser.reload",
    "browser.url.get",
    "browser.focus_webview",
    "browser.is_webview_focused",
    "browser.snapshot",
    "browser.eval",
    "browser.wait",
    "browser.click",
    "browser.dblclick",
    "browser.hover",
    "browser.focus",
    "browser.type",
    "browser.fill",
    "browser.press",
    "browser.keydown",
    "browser.keyup",
    "browser.check",
    "browser.uncheck",
    "browser.select",
    "browser.scroll",
    "browser.scroll_into_view",
    "browser.screenshot",
    "browser.get.text",
    "browser.get.html",
    "browser.get.value",
    "browser.get.attr",
    "browser.get.title",
    "browser.get.count",
    "browser.get.box",
    "browser.get.styles",
    "browser.is.visible",
    "browser.is.enabled",
    "browser.is.checked",
    "browser.find.role",
    "browser.find.text",
    "browser.find.label",
    "browser.find.placeholder",
    "browser.find.alt",
    "browser.find.title",
    "browser.find.testid",
    "browser.find.first",
    "browser.find.last",
    "browser.find.nth",
    "browser.frame.select",
    "browser.frame.main",
    "browser.dialog.accept",
    "browser.dialog.dismiss",
    "browser.download.wait",
    "browser.cookies.get",
    "browser.cookies.set",
    "browser.cookies.clear",
    "browser.storage.get",
    "browser.storage.set",
    "browser.storage.clear",
    "browser.tab.new",
    "browser.tab.list",
    "browser.tab.switch",
    "browser.tab.close",
    "browser.console.list",
    "browser.console.clear",
    "browser.errors.list",
    "browser.highlight",
    "browser.state.save",
    "browser.state.load",
    "browser.addinitscript",
    "browser.addscript",
    "browser.addstyle",
    "browser.viewport.set",
    "browser.geolocation.set",
    "browser.offline.set",
    "browser.trace.start",
    "browser.trace.stop",
    "browser.network.route",
    "browser.network.unroute",
    "browser.network.requests",
    "browser.screencast.start",
    "browser.screencast.stop",
    "browser.input_mouse",
    "browser.input_keyboard",
    "browser.input_touch",
}

# Commands that are intentionally exposed but must return not_supported on WKWebView.
WKWEBVIEW_NOT_SUPPORTED = {
    "browser.viewport.set": {"width": 1280, "height": 720},
    "browser.geolocation.set": {"latitude": 37.7749, "longitude": -122.4194},
    "browser.offline.set": {"enabled": True},
    "browser.trace.start": {},
    "browser.trace.stop": {},
    "browser.network.route": {"url": "**/*"},
    "browser.network.unroute": {"url": "**/*"},
    "browser.network.requests": {},
    "browser.screencast.start": {},
    "browser.screencast.stop": {},
    "browser.input_mouse": {"args": ["move", "10", "10"]},
    "browser.input_keyboard": {"args": ["type", "hello"]},
    "browser.input_touch": {"args": ["tap", "10", "10"]},
}


def _expect_not_supported(c: cmux, method: str, params: dict) -> str:
    try:
        c._call(method, params)
    except cmuxError as exc:
        text = str(exc)
        if text.startswith("not_supported:"):
            return text
        raise cmuxError(f"Expected not_supported for {method}, got: {text}")
    raise cmuxError(f"Expected not_supported for {method}, but call succeeded")


def _error_data(text: str) -> dict:
    _, separator, serialized = text.partition(" (")
    _must(bool(separator) and serialized.endswith(")"), f"Expected error data payload, got: {text}")
    try:
        data = ast.literal_eval(serialized[:-1])
    except (SyntaxError, ValueError) as exc:
        raise cmuxError(f"Expected parseable error data payload, got: {text}") from exc
    _must(isinstance(data, dict), f"Expected dictionary error data, got: {data}")
    return data


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])

        missing = sorted(EXPECTED_BROWSER_METHODS - methods)
        _must(not missing, f"Missing expected browser methods in capabilities: {missing}")

        opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
        sid = str(opened.get("surface_id") or "")
        _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")

        url_payload = c._call("browser.url.get", {"surface_id": sid}) or {}
        _must(bool(url_payload.get("workspace_ref")), f"browser.url.get returned no workspace_ref: {url_payload}")
        _must(bool(url_payload.get("surface_ref")), f"browser.url.get returned no surface_ref: {url_payload}")

        network_methods = {
            "browser.network.route",
            "browser.network.unroute",
            "browser.network.requests",
        }
        for method, extra in WKWEBVIEW_NOT_SUPPORTED.items():
            if method in network_methods:
                continue
            payload = {"surface_id": sid}
            payload.update(extra)
            _expect_not_supported(c, method, payload)

        route_params = {
            "surface_id": sid,
            "url": "https://route.invalid/api/*",
            "method": "POST",
        }
        unroute_params = {
            "surface_id": sid,
            "url": "https://unroute.invalid/assets/*",
            "method": "DELETE",
        }
        _expect_not_supported(c, "browser.network.route", route_params)
        _expect_not_supported(c, "browser.network.unroute", unroute_params)

        requests_error = _expect_not_supported(
            c,
            "browser.network.requests",
            {"surface_id": sid},
        )
        recorded_requests = _error_data(requests_error).get("recorded_requests")
        expected_requests = [
            {"action": "route", "params": route_params},
            {"action": "unroute", "params": unroute_params},
        ]
        _must(
            recorded_requests == expected_requests,
            f"Expected ordered unsupported-network history {expected_requests}, got: {recorded_requests}",
        )

        # Without a surface, requests keeps the generic not_supported contract.
        _expect_not_supported(c, "browser.network.requests", {})

    print("PASS: browser method matrix is explicit (capabilities + WKWebView not_supported contract)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
