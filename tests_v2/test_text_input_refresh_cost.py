#!/usr/bin/env python3
"""
Measuring instrument (not a regression gate): in-process cost of the text-input
refresh call on the keyDown path.

tests_v2/test_workspace_churn_up_arrow_lag.py measures a full socket RPC round trip
(IPC + JSON + DispatchQueue.main.sync + AppKit dispatch + the work under test).
That transport floor sits in the low milliseconds, which is too coarse to resolve
changes to a single call inside keyDown (e.g. swapping forceRefresh() for a
lighter redraw path). This script instead reads samples recorded in-process by
ProgramaDurationSamples (Sources/DurationSamples.swift) at the exact call site in
Sources/GhosttyTerminalView+Keyboard.swift, so the reported numbers are just the
call's own duration, not the transport around it.

Flow:
  1. debug.samples.reset the "keyDown.textInputRefresh" bucket.
  2. Send N debug.shortcut.simulate("a") calls to drive real keystrokes through
     keyDown.
  3. debug.samples.stats the bucket and print count/p50/p95/p99/max/mean.

This intentionally does not assert a latency budget -- there is no established
baseline yet, and picking a threshold now would not be grounded in anything. Once
before/after numbers exist for a real change, a budget can be added as a separate
change. Exit non-zero only on a socket/protocol error, or if the recorded sample
count is implausibly low (fewer than half of the keystrokes sent), which would
mean the refresh path was not actually exercised (e.g. sampling gated off, or the
event did not route through the text-input path).

Requires PROGRAMA_TYPING_TIMING_LOGS=1 (or PROGRAMA_KEY_LATENCY_PROBE=1) to be set
in the target app's environment -- ProgramaDurationSamples.record is a no-op
otherwise (see ProgramaTypingTiming.isEnabled).
"""

from __future__ import annotations

import os
import sys
import time

# Like tests_v2/test_workspace_churn_up_arrow_lag.py, drive the tight
# simulate-keystroke loop through v2_support.RawSocketClient rather than the
# full tests_v2/programa_client.py client.
_TESTS_V2_DIR = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests_v2")
)
sys.path.insert(0, _TESTS_V2_DIR)
from programa_client import ProgramaClientError  # noqa: E402
from v2_support import RawSocketClient, resolve_target_socket  # noqa: E402

KEY_EVENTS = int(os.environ.get("PROGRAMA_REFRESH_COST_KEY_EVENTS", "200"))
KEY_DELAY_S = float(os.environ.get("PROGRAMA_REFRESH_COST_KEY_DELAY_S", "0.0"))
KEY_COMBO = os.environ.get("PROGRAMA_REFRESH_COST_KEY_COMBO", "a")
BUCKET = os.environ.get("PROGRAMA_REFRESH_COST_BUCKET", "keyDown.textInputRefresh")
ALLOW_MAIN_SOCKET = os.environ.get("PROGRAMA_REFRESH_COST_ALLOW_MAIN_SOCKET", "0") == "1"

# If fewer than this fraction of sent keystrokes show up as recorded samples,
# the refresh path was not meaningfully exercised (e.g. sampling gated off).
MIN_SAMPLE_FRACTION = 0.5


def print_stats(bucket: str, stats: dict) -> None:
    print(f"\n{bucket}")
    print(f"  count:  {stats.get('count', 0)}")
    print(f"  p50_ms: {stats.get('p50', 0.0):.3f}")
    print(f"  p95_ms: {stats.get('p95', 0.0):.3f}")
    print(f"  p99_ms: {stats.get('p99', 0.0):.3f}")
    print(f"  max_ms: {stats.get('max', 0.0):.3f}")
    print(f"  mean_ms: {stats.get('mean', 0.0):.3f}")


def main() -> int:
    print("=" * 64)
    print("Text-Input Refresh Cost (in-process sampler)")
    print("=" * 64)

    try:
        target_socket = resolve_target_socket(ALLOW_MAIN_SOCKET)
    except ProgramaClientError as e:
        print(f"FAIL: {e}")
        return 1

    print(f"Using socket: {target_socket}")
    print(f"Bucket: {BUCKET}")
    print(f"Key events: {KEY_EVENTS}")

    try:
        with RawSocketClient(target_socket) as client:
            client.call("debug.samples.reset", {"bucket": BUCKET})

            # Warm up the command path and responder chain, matching the churn-lag
            # harness's warmup, so the warmup keystrokes' refresh samples don't
            # skew the measured distribution.
            for _ in range(5):
                client.call("debug.shortcut.simulate", {"combo": KEY_COMBO})
            client.call("debug.samples.reset", {"bucket": BUCKET})

            for _ in range(KEY_EVENTS):
                client.call("debug.shortcut.simulate", {"combo": KEY_COMBO})
                if KEY_DELAY_S > 0:
                    time.sleep(KEY_DELAY_S)

            result = client.call("debug.samples.stats", {"bucket": BUCKET})
    except ProgramaClientError as e:
        print(f"FAIL: {e}")
        return 1

    stats = result.get(BUCKET)
    if not stats:
        print(f"\nFAIL: no samples recorded for bucket '{BUCKET}'.")
        print(
            "Is the target app running with PROGRAMA_TYPING_TIMING_LOGS=1 or "
            "PROGRAMA_KEY_LATENCY_PROBE=1 set? ProgramaDurationSamples.record is a "
            "no-op otherwise."
        )
        return 1

    print_stats(BUCKET, stats)

    count = int(stats.get("count", 0))
    min_expected = int(KEY_EVENTS * MIN_SAMPLE_FRACTION)
    if count < min_expected:
        print(
            f"\nFAIL: recorded {count} samples, expected at least {min_expected} "
            f"({MIN_SAMPLE_FRACTION:.0%} of {KEY_EVENTS} keystrokes sent). The "
            "refresh path may not have been exercised."
        )
        return 1

    print("\nDONE (numbers only -- no budget asserted; see module docstring)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
