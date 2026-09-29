#!/usr/bin/env python3
"""Generates client/catalog code from contracts/v2/methods.json.

Outputs (all overwritten in place, each carrying a "GENERATED, do not edit" header):
  - Sources/V2CommandCatalog.swift   (base/debug method-name arrays)
  - CLI/V2MethodNames.swift          (one named constant per v2 method)

Handlers change only after the contract does (see docs/v2-api-migration.md "Contract").
Run scripts/check-v2-contract.sh to verify the checked-in files match this contract.
"""
from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT_PATH = os.path.join(ROOT, "contracts", "v2", "methods.json")

GENERATED_HEADER_SWIFT = """\
// GENERATED FILE — do not edit by hand.
// Source of truth: contracts/v2/methods.json
// Regenerate with: python3 scripts/gen-v2-contract.py
// Verify with:      scripts/check-v2-contract.sh
"""

def load_contract():
    with open(CONTRACT_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def camel_case(method: str) -> str:
    """"browser.tab.list" -> "browserTabList"; "surface.read_text" -> "surfaceReadText"."""
    parts = re.split(r"[._]", method)
    out = parts[0]
    for p in parts[1:]:
        out += p[:1].upper() + p[1:]
    return out


def pascal_case(method: str) -> str:
    c = camel_case(method)
    return c[:1].upper() + c[1:]


# ---------------------------------------------------------------------------
# (a) Sources/V2CommandCatalog.swift
# ---------------------------------------------------------------------------

def gen_v2_command_catalog(contract) -> str:
    methods = contract["methods"]
    base = [m for m, e in methods.items() if not e.get("debug_only")]
    debug = [m for m, e in methods.items() if e.get("debug_only")]

    # Preserve the historical ordering (dispatch-switch order) rather than sorting,
    # so diffs against the previous hand-kept file stay minimal. The contract itself
    # doesn't carry order, so we sort here; `system.capabilities` sorts its output
    # anyway (see TerminalController.v2Capabilities), so catalog order is cosmetic.
    base.sort()
    debug.sort()

    def swift_array(name, items, doc):
        lines = [f"    /// {doc}", f"    static let {name}: [String] = ["]
        for m in items:
            lines.append(f'        "{m}",')
        lines.append("    ]")
        return "\n".join(lines)

    body = GENERATED_HEADER_SWIFT + "\n"
    body += "import Foundation\n\n"
    body += "// MARK: - V2 Command Catalog\n"
    body += "//\n"
    body += "// Single source of truth for the method-name list advertised by\n"
    body += "// `system.capabilities`, generated from contracts/v2/methods.json so it cannot\n"
    body += "// drift from the contract or from the handler dispatch switch it mirrors.\n"
    body += "enum V2CommandCatalog {\n"
    body += swift_array(
        "baseMethods", base, "Methods available in all build configurations (Debug and Release)."
    )
    body += "\n\n"
    body += swift_array("debugMethods", debug, "Methods only available in DEBUG builds, appended after `baseMethods`.")
    body += "\n\n"
    body += "    /// Full method list for the current build configuration, mirroring the\n"
    body += "    /// conditional `#if DEBUG` append that used to live inline in\n"
    body += "    /// `TerminalController.v2Capabilities()`.\n"
    body += "    static var methods: [String] {\n"
    body += "        #if DEBUG\n"
    body += "        return baseMethods + debugMethods\n"
    body += "        #else\n"
    body += "        return baseMethods\n"
    body += "        #endif\n"
    body += "    }\n"
    body += "}\n"
    return body


# ---------------------------------------------------------------------------
# (b) CLI/V2MethodNames.swift
# ---------------------------------------------------------------------------

def gen_v2_method_names(contract) -> str:
    methods = sorted(contract["methods"].keys())
    body = GENERATED_HEADER_SWIFT + "\n"
    body += "import Foundation\n\n"
    body += "/// Named constants for every v2 socket method, generated from\n"
    body += "/// contracts/v2/methods.json. The CLI sends v2 methods through these constants\n"
    body += "/// (rather than repeating string literals) so a contract rename shows up as a\n"
    body += "/// compile error at every call site instead of a silent runtime mismatch.\n"
    body += "enum V2MethodNames {\n"
    seen = set()
    for m in methods:
        name = camel_case(m)
        if name in seen:
            continue
        seen.add(name)
        body += f'    static let {name} = "{m}"\n'
    body += "}\n"
    return body


def write_if_changed(path, content):
    existing = None
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            existing = f.read()
    if existing != content:
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return True
    return False


def main():
    contract = load_contract()
    outputs = {
        os.path.join(ROOT, "Sources", "V2CommandCatalog.swift"): gen_v2_command_catalog(contract),
        os.path.join(ROOT, "CLI", "V2MethodNames.swift"): gen_v2_method_names(contract),
    }
    out_dir = None
    if len(sys.argv) > 1 and sys.argv[1] == "--out-dir":
        out_dir = sys.argv[2]

    changed = []
    for path, content in outputs.items():
        target = path
        if out_dir:
            rel = os.path.relpath(path, ROOT)
            target = os.path.join(out_dir, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
        if write_if_changed(target, content):
            changed.append(target)

    print(f"Generated {len(outputs)} file(s); {len(changed)} changed.")
    for c in changed:
        print(f"  updated: {c}")


if __name__ == "__main__":
    main()
