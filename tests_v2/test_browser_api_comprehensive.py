#!/usr/bin/env python3
"""Comprehensive v2 browser API coverage (ported from agent-browser test themes)."""

import os
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError
from v2_support import must as _must


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")


def _data_url(html: str) -> str:
    return "data:text/html;charset=utf-8," + urllib.parse.quote(html)


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
        raise cmuxError(f"Timed out waiting for {label}: {last_exc}")
    raise cmuxError(f"Timed out waiting for {label}")


def _expect_error(label: str, fn, code_substr: str) -> None:
    try:
        fn()
    except cmuxError as exc:
        text = str(exc)
        if code_substr in text:
            return
        raise cmuxError(f"{label}: expected error containing {code_substr!r}, got: {text}")
    raise cmuxError(f"{label}: expected error containing {code_substr!r}, but call succeeded")

def _expect_error_contains(label: str, fn, *needles: str) -> None:
    try:
        fn()
    except cmuxError as exc:
        text = str(exc)
        missing = [needle for needle in needles if needle not in text]
        if missing:
            raise cmuxError(f"{label}: missing expected substrings {missing!r} in error: {text}")
        return
    raise cmuxError(f"{label}: expected failure, but call succeeded")


def _expect_exact_error(label: str, fn, expected: str) -> None:
    try:
        fn()
    except cmuxError as exc:
        actual = str(exc)
        if actual == expected:
            return
        raise cmuxError(f"{label}: expected exact error {expected!r}, got: {actual!r}")
    raise cmuxError(f"{label}: expected exact error {expected!r}, but call succeeded")


def _assert_target_context(label: str, payload: dict, expected: dict) -> None:
    for key, expected_value in expected.items():
        actual_value = payload.get(key)
        _must(bool(actual_value), f"{label}: expected nonempty {key}: {payload}")
        _must(
            actual_value == expected_value,
            f"{label}: expected {key}={expected_value!r}, got {actual_value!r}: {payload}",
        )


def _value(res: dict, key: str = "value"):
    return (res or {}).get(key)



def _wait_with_fallback(c: cmux, surface_id: str, params: dict, pred, timeout_s: float, label: str) -> None:
    call_params = dict(params)
    call_params["surface_id"] = surface_id
    try:
        c._call("browser.wait", call_params)
        return
    except cmuxError as exc:
        if "timeout" not in str(exc):
            raise
    _wait_until(pred, timeout_s=timeout_s, label=f"{label} fallback")


def _build_pages() -> tuple[str, str]:
    page1 = """
<!doctype html>
<html>
  <head>
    <title>cmux-browser-comprehensive-1</title>
    <style>
      body { margin: 0; font-family: sans-serif; min-height: 2200px; }
      #scroller { width: 220px; height: 90px; overflow: auto; border: 1px solid #666; }
      #scroller-inner { height: 520px; padding-top: 8px; }
      #style-target { color: rgb(255, 0, 0); width: 123px; height: 45px; display: block; }
      #hidden { display: none; }
    </style>
  </head>
  <body>
    <h1 id="hdr">Browser Comprehensive</h1>
    <input id="name" value="">
    <button id="btn" data-role="submit" onclick="document.querySelector('#status').textContent = document.querySelector('#name').value || 'empty';">Go</button>
    <div id="status" data-role="status">ready</div>

    <input id="chk" type="checkbox">
    <select id="sel">
      <option value="a">A</option>
      <option value="b">B</option>
    </select>

    <div id="hover" onmouseover="window.__hover = (window.__hover || 0) + 1">hover target</div>
    <div id="dbl" ondblclick="window.__dbl = (window.__dbl || 0) + 1">double target</div>

    <input id="keys" value="">
    <button id="disabled" disabled>Disabled</button>
    <div id="hidden">not visible</div>
    <div id="style-target">styles</div>

    <div id="scroller">
      <div id="scroller-inner">
        <div id="bottom">bottom-marker</div>
      </div>
    </div>

    <script>
      window.__hover = 0;
      window.__dbl = 0;
      window.__keys = { down: 0, up: 0, press: 0 };
      document.addEventListener('keydown', () => window.__keys.down++);
      document.addEventListener('keyup', () => window.__keys.up++);
      document.addEventListener('keypress', () => window.__keys.press++);
    </script>
  </body>
</html>
""".strip()

    page2 = """
<!doctype html>
<html>
  <head><title>cmux-browser-comprehensive-2</title></head>
  <body>
    <div id="page2">page-two</div>
  </body>
</html>
""".strip()

    return _data_url(page1), _data_url(page2)


def main() -> int:
    page1_url, page2_url = _build_pages()

    with cmux(SOCKET_PATH) as c:
        opened = c._call("browser.open_split", {"url": "about:blank"}) or {}
        sid = str(opened.get("surface_id") or "")
        sref = str(opened.get("surface_ref") or "")
        _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")
        expected_target_context = {
            key: opened.get(key)
            for key in (
                "workspace_id",
                "workspace_ref",
                "surface_id",
                "surface_ref",
                "window_id",
                "window_ref",
            )
        }
        _must(
            all(bool(value) for value in expected_target_context.values()),
            f"browser.open_split returned incomplete target context: {opened}",
        )
        target = sid

        probe_url = _data_url("<!doctype html><html><body><button id='probe'>P</button></body></html>")
        c._call("browser.navigate", {"surface_id": target, "url": probe_url})
        _wait_with_fallback(
            c,
            target,
            {"selector": "#probe", "timeout_ms": 3000},
            lambda: bool((c._call("browser.eval", {"surface_id": target, "script": "document.querySelector('#probe') !== null"}) or {}).get("value")),
            timeout_s=4.0,
            label="browser.wait selector #probe",
        )

        c._call("browser.navigate", {"surface_id": target, "url": page1_url})
        _wait_with_fallback(
            c,
            target,
            {"text_contains": "ready", "timeout_ms": 3000},
            lambda: "ready" in str((c._call("browser.eval", {"surface_id": target, "script": "document.body ? (document.body.innerText || '') : ''"}) or {}).get("value") or ""),
            timeout_s=4.0,
            label="browser.wait text_contains ready",
        )
        _wait_with_fallback(
            c,
            target,
            {"function": "document.querySelector('#hdr') !== null", "timeout_ms": 3000},
            lambda: bool((c._call("browser.eval", {"surface_id": target, "script": "document.querySelector('#hdr') !== null"}) or {}).get("value")),
            timeout_s=4.0,
            label="browser.wait function hdr",
        )
        _wait_with_fallback(
            c,
            target,
            {"load_state": "complete", "timeout_ms": 5000},
            lambda: str((c._call("browser.eval", {"surface_id": target, "script": "document.readyState"}) or {}).get("value") or "").lower() == "complete",
            timeout_s=6.0,
            label="browser.wait load_state complete",
        )
        _wait_with_fallback(
            c,
            target,
            {"url_contains": "data:text/html", "timeout_ms": 3000},
            lambda: "data:text/html" in str((c._call("browser.url.get", {"surface_id": target}) or {}).get("url") or ""),
            timeout_s=4.0,
            label="browser.wait url_contains data:text/html",
        )

        _wait_until(
            lambda: "cmux-browser-comprehensive-1"
            in str((c._call("browser.get.title", {"surface_id": target}) or {}).get("title") or ""),
            timeout_s=3.0,
            label="browser.get.title page1",
        )
        url_payload = c._call("browser.url.get", {"surface_id": sref}) or {}
        _must(url_payload.get("surface_id") == target, f"Expected canonical surface_id from browser.url.get(ref): {url_payload}")
        _must(url_payload.get("surface_ref") == sref, f"Expected surface_ref from browser.url.get(ref): {url_payload}")
        _must(
            url_payload.get("workspace_id") == opened.get("workspace_id"),
            f"Expected workspace_id from browser.url.get(ref): {url_payload}",
        )
        _must(
            url_payload.get("workspace_ref") == opened.get("workspace_ref"),
            f"Expected workspace_ref from browser.url.get(ref): {url_payload}",
        )
        _must(page1_url in str(url_payload.get("url") or ""), f"Expected page1 data URL from browser.url.get(ref): {url_payload}")

        c._call("browser.fill", {"surface_id": target, "selector": "#name", "text": "cmux"})
        click_payload = c._call("browser.click", {"surface_id": target, "selector": "#btn"}) or {}
        _must(click_payload.get("action") == "click", f"Expected click action metadata: {click_payload}")
        _must(int(click_payload.get("attempts") or 0) == 1, f"Expected first-attempt click: {click_payload}")
        _must(bool(click_payload.get("workspace_ref")), f"Expected workspace_ref from click: {click_payload}")
        _must(bool(click_payload.get("surface_ref")), f"Expected surface_ref from click: {click_payload}")
        out_text = c._call("browser.get.text", {"surface_id": target, "selector": "#status"}) or {}
        _must(str(_value(out_text)) == "cmux", f"Expected status text to be cmux: {out_text}")

        cleared = c._call("browser.fill", {"surface_id": target, "selector": "#name", "value": "", "snapshot_after": True}) or {}
        _must(bool(cleared.get("post_action_snapshot")), f"Expected post_action_snapshot from fill(snapshot_after): {cleared}")
        cleared_value = c._call("browser.get.value", {"surface_id": target, "selector": "#name"}) or {}
        _must(str(_value(cleared_value)) == "", f"Expected fill with empty text to clear input: {cleared_value}")

        c._call("browser.fill", {"surface_id": target, "selector": "#name", "text": "cmux"})
        c._call("browser.type", {"surface_id": target, "selector": "#name", "text": "-v2"})
        name_val = c._call("browser.get.value", {"surface_id": target, "selector": "#name"}) or {}
        _must(str(_value(name_val)) == "cmux-v2", f"Expected typed suffix in input value: {name_val}")

        c._call("browser.focus", {"surface_id": target, "selector": "#keys"})
        active = c._call(
            "browser.eval",
            {"surface_id": target, "script": "document.activeElement ? document.activeElement.id : ''"},
        ) or {}
        _must(str(_value(active)) == "keys", f"Expected focus on #keys: {active}")

        c._call("browser.hover", {"surface_id": target, "selector": "#hover"})
        c._call("browser.dblclick", {"surface_id": target, "selector": "#dbl"})

        press_payload = c._call("browser.press", {"surface_id": target, "key": "A"}) or {}
        _must(bool(press_payload.get("workspace_ref")), f"Expected workspace_ref from press: {press_payload}")
        _must(bool(press_payload.get("surface_ref")), f"Expected surface_ref from press: {press_payload}")
        c._call("browser.keydown", {"surface_id": target, "key": "B"})
        c._call("browser.keyup", {"surface_id": target, "key": "C"})

        key_stats = c._call(
            "browser.eval",
            {
                "surface_id": target,
                "script": "({hover: window.__hover, dbl: window.__dbl, down: window.__keys.down, up: window.__keys.up, press: window.__keys.press})",
            },
        ) or {}
        key_value = _value(key_stats)
        _must(isinstance(key_value, dict), f"Expected dict counters from eval: {key_stats}")
        _must(int(key_value.get("hover", 0)) >= 1, f"Expected hover counter >= 1: {key_stats}")
        _must(int(key_value.get("dbl", 0)) >= 1, f"Expected dbl counter >= 1: {key_stats}")
        _must(int(key_value.get("down", 0)) >= 2, f"Expected keydown counter >= 2: {key_stats}")
        _must(int(key_value.get("up", 0)) >= 2, f"Expected keyup counter >= 2: {key_stats}")
        _must(int(key_value.get("press", 0)) >= 1, f"Expected keypress counter >= 1: {key_stats}")

        c._call("browser.check", {"surface_id": target, "selector": "#chk"})
        is_checked = c._call("browser.is.checked", {"surface_id": target, "selector": "#chk"}) or {}
        _must(bool(_value(is_checked)) is True, f"Expected checked=true: {is_checked}")
        c._call("browser.uncheck", {"surface_id": target, "selector": "#chk"})
        is_unchecked = c._call("browser.is.checked", {"surface_id": target, "selector": "#chk"}) or {}
        _must(bool(_value(is_unchecked)) is False, f"Expected checked=false: {is_unchecked}")

        c._call("browser.select", {"surface_id": target, "selector": "#sel", "text": "b"})
        sel_val = c._call("browser.get.value", {"surface_id": target, "selector": "#sel"}) or {}
        _must(str(_value(sel_val)) == "b", f"Expected selected value b: {sel_val}")

        html_val = c._call("browser.get.html", {"surface_id": target, "selector": "#status"}) or {}
        _must("id=\"status\"" in str(_value(html_val) or ""), f"Expected status HTML: {html_val}")

        attr_val = c._call("browser.get.attr", {"surface_id": target, "selector": "#status", "attr": "data-role"}) or {}
        _must(str(_value(attr_val)) == "status", f"Expected data-role=status: {attr_val}")

        cnt_val = c._call("browser.get.count", {"surface_id": target, "selector": "option"}) or {}
        _must(int((cnt_val or {}).get("count") or 0) == 2, f"Expected option count=2: {cnt_val}")

        box_val = c._call("browser.get.box", {"surface_id": target, "selector": "#status"}) or {}
        box = _value(box_val)
        _must(isinstance(box, dict), f"Expected box dict: {box_val}")
        _must(float(box.get("width") or 0.0) > 0.0, f"Expected positive box width: {box_val}")

        style_prop = c._call(
            "browser.get.styles",
            {"surface_id": target, "selector": "#style-target", "property": "color"},
        ) or {}
        _must("rgb" in str(_value(style_prop) or ""), f"Expected rgb color in style property: {style_prop}")

        style_all = c._call("browser.get.styles", {"surface_id": target, "selector": "#style-target"}) or {}
        _must(isinstance(_value(style_all), dict), f"Expected style dictionary: {style_all}")
        _must("display" in (_value(style_all) or {}), f"Expected display in style dictionary: {style_all}")

        visible_status = c._call("browser.is.visible", {"surface_id": target, "selector": "#status"}) or {}
        visible_hidden = c._call("browser.is.visible", {"surface_id": target, "selector": "#hidden"}) or {}
        _must(bool(_value(visible_status)) is True, f"Expected #status visible: {visible_status}")
        _must(bool(_value(visible_hidden)) is False, f"Expected #hidden not visible: {visible_hidden}")

        enabled_btn = c._call("browser.is.enabled", {"surface_id": target, "selector": "#btn"}) or {}
        enabled_disabled = c._call("browser.is.enabled", {"surface_id": target, "selector": "#disabled"}) or {}
        _must(bool(_value(enabled_btn)) is True, f"Expected #btn enabled: {enabled_btn}")
        _must(bool(_value(enabled_disabled)) is False, f"Expected #disabled not enabled: {enabled_disabled}")

        scroll_payload = c._call("browser.scroll", {"surface_id": target, "selector": "#scroller", "dx": 0, "dy": 160}) or {}
        _must(bool(scroll_payload.get("workspace_ref")), f"Expected workspace_ref from scroll: {scroll_payload}")
        _must(bool(scroll_payload.get("surface_ref")), f"Expected surface_ref from scroll: {scroll_payload}")
        scrolled = c._call(
            "browser.eval",
            {"surface_id": target, "script": "document.querySelector('#scroller').scrollTop"},
        ) or {}
        _must(float(_value(scrolled) or 0) >= 100, f"Expected scroller scrollTop >= 100: {scrolled}")

        c._call("browser.scroll", {"surface_id": target, "dy": 240})
        c._call("browser.scroll_into_view", {"surface_id": target, "selector": "#bottom"})
        in_view = c._call(
            "browser.eval",
            {
                "surface_id": target,
                "script": "(() => { const r = document.querySelector('#bottom').getBoundingClientRect(); return r.top < window.innerHeight; })()",
            },
        ) or {}
        _must(bool(_value(in_view)) is True, f"Expected #bottom in viewport: {in_view}")

        shot = c._call("browser.screenshot", {"surface_id": target}) or {}
        _must(len(str((shot or {}).get("png_base64") or "")) > 100, f"Expected screenshot payload: {shot}")

        snap = c._call("browser.snapshot", {"surface_id": target}) or {}
        snapshot_text = str((snap or {}).get("snapshot") or "")
        _must("cmux-browser-comprehensive-1" in snapshot_text, f"Expected snapshot text for page1: {snap}")
        refs = (snap or {}).get("refs") or {}
        _must(isinstance(refs, dict), f"Expected snapshot refs dict: {snap}")
        _must(any(str(key).startswith("e") for key in refs.keys()), f"Expected eN refs from snapshot: {snap}")

        c._call("browser.navigate", {"surface_id": target, "url": page2_url})
        _wait_with_fallback(
            c,
            target,
            {"text_contains": "page-two", "timeout_ms": 4000},
            lambda: "page-two" in str((c._call("browser.eval", {"surface_id": target, "script": "document.body ? (document.body.innerText || '') : ''"}) or {}).get("value") or ""),
            timeout_s=5.0,
            label="browser.wait text_contains page-two",
        )
        _wait_until(
            lambda: "cmux-browser-comprehensive-2"
            in str((c._call("browser.get.title", {"surface_id": target}) or {}).get("title") or ""),
            timeout_s=3.0,
            label="browser.get.title page2",
        )

        back_payload = c._call("browser.back", {"surface_id": target}) or {}
        _assert_target_context("browser.back", back_payload, expected_target_context)
        _wait_with_fallback(
            c,
            target,
            {"url_contains": "cmux-browser-comprehensive-1", "timeout_ms": 4000},
            lambda: "cmux-browser-comprehensive-1" in str((c._call("browser.url.get", {"surface_id": target}) or {}).get("url") or ""),
            timeout_s=5.0,
            label="browser.wait url_contains page1 (history)",
        )
        forward_payload = c._call("browser.forward", {"surface_id": target}) or {}
        _assert_target_context("browser.forward", forward_payload, expected_target_context)
        _wait_with_fallback(
            c,
            target,
            {"url_contains": "cmux-browser-comprehensive-2", "timeout_ms": 4000},
            lambda: "cmux-browser-comprehensive-2" in str((c._call("browser.url.get", {"surface_id": target}) or {}).get("url") or ""),
            timeout_s=5.0,
            label="browser.wait url_contains page2 (history)",
        )
        reload_payload = c._call(
            "browser.reload",
            {"surface_id": target, "snapshot_after": True},
        ) or {}
        _assert_target_context("browser.reload", reload_payload, expected_target_context)
        snapshot_outcome_keys = [
            key
            for key in ("post_action_snapshot", "post_action_snapshot_error")
            if key in reload_payload
        ]
        _must(
            len(snapshot_outcome_keys) == 1,
            f"browser.reload(snapshot_after) expected exactly one snapshot outcome: {reload_payload}",
        )
        snapshot_outcome_key = snapshot_outcome_keys[0]
        snapshot_outcome = reload_payload[snapshot_outcome_key]
        if snapshot_outcome_key == "post_action_snapshot":
            _must(
                bool(snapshot_outcome),
                f"browser.reload(snapshot_after) returned an empty snapshot: {reload_payload}",
            )
        else:
            _must(
                isinstance(snapshot_outcome, dict) and bool(snapshot_outcome),
                f"browser.reload(snapshot_after) returned an invalid snapshot error: {reload_payload}",
            )
        _wait_with_fallback(
            c,
            target,
            {"url_contains": "cmux-browser-comprehensive-2", "timeout_ms": 4000},
            lambda: "cmux-browser-comprehensive-2" in str((c._call("browser.url.get", {"surface_id": target}) or {}).get("url") or ""),
            timeout_s=5.0,
            label="browser.wait url_contains page2 (reload)",
        )

        c._call("browser.focus_webview", {"surface_id": target})
        _wait_until(
            lambda: bool((c._call("browser.is_webview_focused", {"surface_id": target}) or {}).get("focused")),
            timeout_s=2.5,
            label="browser.is_webview_focused",
        )

        # Negative cases adapted from agent-browser protocol/actions tests.
        _expect_error(
            "click missing selector",
            lambda: c._call("browser.click", {"surface_id": target}),
            "invalid_params",
        )
        _expect_error(
            "get.text missing selector",
            lambda: c._call("browser.get.text", {"surface_id": target}),
            "invalid_params",
        )
        _expect_error(
            "eval missing script",
            lambda: c._call("browser.eval", {"surface_id": target}),
            "invalid_params",
        )
        _expect_error(
            "type missing text",
            lambda: c._call("browser.type", {"surface_id": target, "selector": "#name"}),
            "invalid_params",
        )
        _expect_error(
            "fill missing text/value",
            lambda: c._call("browser.fill", {"surface_id": target, "selector": "#name"}),
            "invalid_params",
        )
        _expect_error(
            "select missing value/text",
            lambda: c._call("browser.select", {"surface_id": target, "selector": "#sel"}),
            "invalid_params",
        )
        _expect_error(
            "press missing key",
            lambda: c._call("browser.press", {"surface_id": target}),
            "invalid_params",
        )
        _expect_error(
            "keydown missing key",
            lambda: c._call("browser.keydown", {"surface_id": target}),
            "invalid_params",
        )
        _expect_error(
            "keyup missing key",
            lambda: c._call("browser.keyup", {"surface_id": target}),
            "invalid_params",
        )
        _expect_error_contains(
            "click missing element",
            lambda: c._call("browser.click", {"surface_id": target, "selector": "#does-not-exist"}),
            "not_found",
            "snapshot",
            "hint",
        )
        _expect_error_contains(
            "scroll missing element",
            lambda: c._call("browser.scroll", {"surface_id": target, "selector": "#does-not-exist"}),
            "not_found",
            "snapshot",
            "hint",
        )
        _expect_error(
            "get.attr missing attr",
            lambda: c._call("browser.get.attr", {"surface_id": target, "selector": "#status"}),
            "invalid_params",
        )
        _expect_error(
            "wait timeout",
            lambda: c._call("browser.wait", {"surface_id": target, "selector": "#never", "timeout_ms": 100}),
            "timeout",
        )
        _expect_error(
            "navigate missing url",
            lambda: c._call("browser.navigate", {"surface_id": target}),
            "invalid_params",
        )
        _expect_exact_error(
            "browser.back missing surface_id",
            lambda: c._call("browser.back", {}),
            "invalid_params: Missing or invalid surface_id",
        )
        _expect_exact_error(
            "browser.url.get missing surface_id",
            lambda: c._call("browser.url.get", {}),
            "invalid_params: Missing or invalid surface_id",
        )

        terminal_surface = c.new_surface(panel_type="terminal")
        _expect_error_contains(
            "browser.forward on terminal surface",
            lambda: c._call("browser.forward", {"surface_id": terminal_surface}),
            "not_found",
            terminal_surface,
        )
        _expect_error_contains(
            "browser.url.get on terminal surface",
            lambda: c._call("browser.url.get", {"surface_id": terminal_surface}),
            "not_found",
            terminal_surface,
        )

    print("PASS: comprehensive browser.* coverage (ported/adapted from agent-browser) is green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
