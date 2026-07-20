#!/usr/bin/env python3
"""
Regression tests for issue #131: workspace sidebar titles must keep updating
for split (multi-panel) workspaces, including while the workspace is not
selected.

Desired behavior (tmux-style "active pane titles the window"):
- Single-panel workspace: OSC title changes update the workspace title even
  while the workspace is in the background. (Worked before the fix; guarded.)
- Split workspace: OSC title changes from the FOCUSED pane update the
  workspace title, selected or not. (Broken before the fix: nothing updated
  the workspace title once a workspace had more than one panel.)
- Split workspace: switching pane focus re-derives the workspace title from
  the newly focused pane's last known title, without waiting for it to emit
  a new OSC sequence.
- Split workspace: a NON-focused pane's title change must not override the
  workspace title (it only updates that pane's in-workspace tab title).

Each test drives a real shell: it types `printf '\\033]0;TITLE\\007'; sleep N`
into the pane so the title survives until the assertion (shell integration
resets the title to the cwd at the next prompt, which would otherwise race
the check).

Usage:
    python3 tests_v2/test_workspace_split_title_updates.py
"""

import sys
import time
from typing import List, Optional, Tuple

import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cmux import cmux

# How long the shell holds a title before the prompt returns and shell
# integration resets it. Generous for slow CI runners; workspaces are closed
# at the end of each test so the sleeps never outlive the suite.
TITLE_HOLD_SECONDS = 45
WAIT_TIMEOUT = 15.0


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


def _workspace_title(client: cmux, workspace_id: str) -> Optional[str]:
    for _, wsid, title, _ in client.list_workspaces():
        if wsid == workspace_id:
            return title
    return None


def _wait_for_title(
    client: cmux, workspace_id: str, expected: str, timeout: float = WAIT_TIMEOUT
) -> Tuple[bool, Optional[str]]:
    deadline = time.time() + timeout
    last: Optional[str] = None
    while time.time() < deadline:
        last = _workspace_title(client, workspace_id)
        if last == expected:
            return True, last
        time.sleep(0.25)
    return False, last


def _assert_title_never(
    client: cmux, workspace_id: str, forbidden: str, window: float = 3.0
) -> Tuple[bool, Optional[str]]:
    deadline = time.time() + window
    last: Optional[str] = None
    while time.time() < deadline:
        last = _workspace_title(client, workspace_id)
        if last == forbidden:
            return False, last
        time.sleep(0.25)
    return True, last


def _set_title(client: cmux, surface_id: str, title: str) -> None:
    client.send_surface(
        surface_id,
        f"printf '\\033]0;{title}\\007'; sleep {TITLE_HOLD_SECONDS}\\n",
    )


def _surfaces(client: cmux, workspace_id: str) -> List[Tuple[int, str, bool]]:
    return client.list_surfaces(workspace=workspace_id)


def _new_background_workspace(client: cmux) -> Tuple[str, str]:
    """Create a workspace, wait for its shell, and return (home_ws, new_ws)."""
    home = client.current_workspace()
    ws = client.new_workspace()
    time.sleep(2.0)  # let the shell reach its prompt
    client.select_workspace(home)
    time.sleep(0.3)
    return home, ws


def _split_workspace(client: cmux, workspace_id: str) -> Tuple[str, str]:
    """Split `workspace_id` (selecting it first) and return (original_surface,
    new_focused_surface)."""
    client.select_workspace(workspace_id)
    time.sleep(0.3)
    original = _surfaces(client, workspace_id)[0][1]
    client.new_split("right")
    time.sleep(2.0)  # second shell reaches its prompt; new pane takes focus
    focused = [s for s in _surfaces(client, workspace_id) if s[2]]
    if not focused or focused[0][1] == original:
        raise RuntimeError(
            f"expected the new split surface to be focused, got {focused!r}"
        )
    return original, focused[0][1]


def _close_workspace_quietly(client: cmux, workspace_id: str) -> None:
    try:
        client.close_workspace(workspace_id)
    except Exception:
        pass


def test_single_panel_background_title(client: cmux) -> TestResult:
    result = TestResult("Single-panel background workspace title updates")
    home, ws = _new_background_workspace(client)
    try:
        surface = _surfaces(client, ws)[0][1]
        _set_title(client, surface, "T131_SINGLE")
        ok, seen = _wait_for_title(client, ws, "T131_SINGLE")
        if not ok:
            result.failure(f"background single-panel title stuck at {seen!r}")
            return result
        result.success("title updated while workspace was in the background")
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _close_workspace_quietly(client, ws)
    return result


def test_split_focused_pane_background_workspace(client: cmux) -> TestResult:
    result = TestResult("Split workspace: focused pane titles it while backgrounded")
    home, ws = _new_background_workspace(client)
    try:
        _, focused_surface = _split_workspace(client, ws)
        client.select_workspace(home)
        time.sleep(0.3)
        _set_title(client, focused_surface, "T131_SPLIT_FOCUSED")
        ok, seen = _wait_for_title(client, ws, "T131_SPLIT_FOCUSED")
        if not ok:
            result.failure(
                f"focused-pane title never reached the workspace title (stuck at {seen!r})"
            )
            return result
        result.success("focused pane's title reached the sidebar while backgrounded")
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _close_workspace_quietly(client, ws)
    return result


def test_split_focus_switch_rederives_title(client: cmux) -> TestResult:
    result = TestResult("Split workspace: focus switch re-derives the title")
    home, ws = _new_background_workspace(client)
    try:
        original_surface, focused_surface = _split_workspace(client, ws)
        # Non-focused pane records its title (workspace title must not follow it).
        _set_title(client, original_surface, "T131_PANE_ONE")
        ok, seen = _assert_title_never(client, ws, "T131_PANE_ONE")
        if not ok:
            result.failure("non-focused pane's title overrode the workspace title")
            return result
        # Focused pane sets the workspace title.
        _set_title(client, focused_surface, "T131_PANE_TWO")
        ok, seen = _wait_for_title(client, ws, "T131_PANE_TWO")
        if not ok:
            result.failure(f"focused-pane title not applied (stuck at {seen!r})")
            return result
        # Switching focus back re-derives the title from the stored pane title
        # without the pane emitting anything new.
        client.focus_surface_by_panel(original_surface)
        ok, seen = _wait_for_title(client, ws, "T131_PANE_ONE")
        if not ok:
            result.failure(
                f"focus switch did not re-derive the title (stuck at {seen!r})"
            )
            return result
        result.success("title follows pane focus using stored pane titles")
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _close_workspace_quietly(client, ws)
    return result


def run_tests() -> int:
    results = []
    with cmux() as client:
        results.append(test_single_panel_background_title(client))
        results.append(test_split_focused_pane_background_workspace(client))
        results.append(test_split_focus_switch_rederives_title(client))

    print("\nWorkspace Split Title Update Tests (#131):")
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        msg = f" - {r.message}" if r.message else ""
        print(f"{status}: {r.name}{msg}")

    passed = sum(1 for r in results if r.passed)
    total = len(results)
    if passed == total:
        print("\nAll workspace split title tests passed!")
        return 0
    print(f"\n{total - passed} test(s) failed")
    return 1


if __name__ == "__main__":
    sys.exit(run_tests())
