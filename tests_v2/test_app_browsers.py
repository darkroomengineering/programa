#!/usr/bin/env python3
"""Regression: `app.browsers` reports installed/running browsers and the system default.

Does not assert on which browsers are installed -- CI runners and dev
machines differ. Only checks the response shape.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from programa_client import ProgramaClient, ProgramaClientError


SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")

REQUIRED_BROWSER_KEYS = {"key", "name", "bundle_id", "installed", "running"}


def main() -> int:
    with ProgramaClient(SOCKET_PATH) as c:
        result = c._call("app.browsers", {})

        if not isinstance(result, dict):
            raise ProgramaClientError(f"Expected object result, got {type(result).__name__}: {result!r}")

        if "default" not in result:
            raise ProgramaClientError(f"Missing 'default' field: {result!r}")
        default = result["default"]
        if default is not None and not isinstance(default, str):
            raise ProgramaClientError(f"'default' should be a string or null, got {type(default).__name__}: {default!r}")

        browsers = result.get("browsers")
        if not isinstance(browsers, list):
            raise ProgramaClientError(f"Expected 'browsers' to be a list, got {type(browsers).__name__}: {browsers!r}")
        if not browsers:
            raise ProgramaClientError("Expected at least one known browser entry")

        for entry in browsers:
            if not isinstance(entry, dict):
                raise ProgramaClientError(f"Expected each browser entry to be an object, got {entry!r}")
            missing = REQUIRED_BROWSER_KEYS - entry.keys()
            if missing:
                raise ProgramaClientError(f"Browser entry missing keys {sorted(missing)}: {entry!r}")
            if not isinstance(entry["key"], str) or not entry["key"]:
                raise ProgramaClientError(f"Expected non-empty string 'key': {entry!r}")
            if not isinstance(entry["name"], str) or not entry["name"]:
                raise ProgramaClientError(f"Expected non-empty string 'name': {entry!r}")
            if not isinstance(entry["bundle_id"], str) or not entry["bundle_id"]:
                raise ProgramaClientError(f"Expected non-empty string 'bundle_id': {entry!r}")
            path = entry.get("path")
            if path is not None and not isinstance(path, str):
                raise ProgramaClientError(f"Expected 'path' to be a string or null, got {type(path).__name__}: {entry!r}")
            if not isinstance(entry["installed"], bool):
                raise ProgramaClientError(f"Expected bool 'installed': {entry!r}")
            if not isinstance(entry["running"], bool):
                raise ProgramaClientError(f"Expected bool 'running': {entry!r}")
            # A browser that isn't installed cannot be reported as running.
            if entry["running"] and not entry["installed"]:
                raise ProgramaClientError(f"Entry reports running=true but installed=false: {entry!r}")

        keys = [entry["key"] for entry in browsers]
        if len(keys) != len(set(keys)):
            raise ProgramaClientError(f"Duplicate browser keys in response: {keys!r}")

    print(f"PASS: app.browsers returned {len(browsers)} known browsers, default={default!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
