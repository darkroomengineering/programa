#!/usr/bin/env python3
"""
Regression: system.capabilities' advertised method set must equal
contracts/v2/methods.json's method set for the running build configuration.

This is the runtime half of the v2-contract guard (scripts/check-v2-contract.sh is the
static half, comparing generated files against the contract at commit time). This test
instead asks the *running app* what it actually advertises and compares that against the
contract, so a handler added to the dispatch switch without a matching contract entry (or
vice versa) fails a real connection, not just a source diff.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError

SOCKET_PATH = os.environ.get("PROGRAMA_SOCKET", "/tmp/programa-debug.sock")
CONTRACT_PATH = Path(__file__).parent.parent / "contracts" / "v2" / "methods.json"


def _contract_methods(debug_build: bool) -> set:
    with open(CONTRACT_PATH, "r", encoding="utf-8") as f:
        contract = json.load(f)
    methods = contract["methods"]
    if debug_build:
        return set(methods.keys())
    return {name for name, entry in methods.items() if not entry.get("debug_only")}


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        caps = c._call("system.capabilities")
        if not isinstance(caps, dict) or "methods" not in caps:
            raise cmuxError(f"system.capabilities returned an unexpected shape: {caps!r}")
        advertised = set(caps["methods"])

        # A tagged Debug build (the only kind these tests connect to; see CLAUDE.md's
        # testing policy) always includes the debug.* methods, so this test intentionally
        # only ever checks the DEBUG-configuration method set. system.capabilities' own
        # #if DEBUG branch is exercised by the Swift unit test that checks
        # V2CommandCatalog.baseMethods against the contract directly.
        expected_debug = _contract_methods(debug_build=True)
        expected_base = _contract_methods(debug_build=False)

        if advertised == expected_debug:
            print(f"PASS: system.capabilities advertises exactly the contract's {len(expected_debug)} DEBUG-configuration methods")
            return 0

        if advertised == expected_base:
            print(f"PASS: system.capabilities advertises exactly the contract's {len(expected_base)} base (Release-configuration) methods")
            return 0

        missing_from_server = expected_debug - advertised
        extra_on_server = advertised - expected_debug
        details = []
        if missing_from_server:
            details.append(f"in contract but not advertised: {sorted(missing_from_server)}")
        if extra_on_server:
            details.append(f"advertised but not in contract: {sorted(extra_on_server)}")
        raise cmuxError(
            "system.capabilities method set does not match contracts/v2/methods.json. "
            + "; ".join(details)
        )


if __name__ == "__main__":
    raise SystemExit(main())
