#!/usr/bin/env python3
"""Generates client/catalog code from contracts/v2/methods.json.

Outputs (all overwritten in place, each carrying a "GENERATED, do not edit" header):
  - Sources/V2CommandCatalog.swift   (base/debug method-name arrays)
  - tests_v2/programa_v2.py          (typed Python client, built on tests_v2/cmux.py)
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

GENERATED_HEADER_PY = '''\
"""GENERATED FILE — do not edit by hand.

Source of truth: contracts/v2/methods.json
Regenerate with: python3 scripts/gen-v2-contract.py
Verify with:      scripts/check-v2-contract.sh
"""
'''


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


def snake_case_method(method: str) -> str:
    """"browser.tab.list" -> "browser_tab_list" (Python method name)."""
    return re.sub(r"[.]", "_", method)


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
# (b) tests_v2/programa_v2.py
# ---------------------------------------------------------------------------

PY_TYPE_CHECK = {
    "string": "str",
    "integer": "int",
    "number": "(int, float)",
    "boolean": "bool",
    "array": "list",
    "object": "dict",
}


def py_param_doc(name, schema):
    t = schema.get("type", "any")
    fmt = schema.get("format")
    if fmt:
        return f"{name} ({t}, {fmt})"
    return f"{name} ({t})"


def gen_programa_v2_py(contract) -> str:
    methods = contract["methods"]
    lines = []
    lines.append(GENERATED_HEADER_PY)
    lines.append("from typing import Any, Dict, Optional")
    lines.append("")
    lines.append("from cmux import cmux, cmuxError")
    lines.append("")
    lines.append("")
    lines.append("class ProgramaV2Error(cmuxError):")
    lines.append('    """Raised by ProgramaV2Client for client-side param validation failures."""')
    lines.append("")
    lines.append("")
    lines.append("class ProgramaV2Client:")
    lines.append('    """Generated typed v2 client: one method per contract entry.')
    lines.append("")
    lines.append("    Thin wrapper over tests_v2.cmux.cmux — it owns (or is given) the transport")
    lines.append("    connection and framing, this class only adds per-method required-param")
    lines.append('    validation and a method name per contract entry."""')
    lines.append("")
    lines.append("    def __init__(self, socket_path: Optional[str] = None, client: Optional[cmux] = None):")
    lines.append("        self._client = client if client is not None else cmux(socket_path)")
    lines.append("        self._owns_client = client is None")
    lines.append("")
    lines.append("    def connect(self) -> None:")
    lines.append("        self._client.connect()")
    lines.append("")
    lines.append("    def close(self) -> None:")
    lines.append("        if self._owns_client:")
    lines.append("            self._client.close()")
    lines.append("")
    lines.append("    def __enter__(self):")
    lines.append("        self.connect()")
    lines.append("        return self")
    lines.append("")
    lines.append("    def __exit__(self, exc_type, exc_val, exc_tb):")
    lines.append("        self.close()")
    lines.append("        return False")
    lines.append("")
    lines.append("    def call(self, method: str, params: Optional[Dict[str, Any]] = None) -> Any:")
    lines.append('        """Escape hatch for a method not (yet) in the generated set below."""')
    lines.append("        return self._client._call(method, params)")
    lines.append("")

    seen_names = set()
    for method in sorted(methods.keys()):
        entry = methods[method]
        pyname = snake_case_method(method)
        if pyname in seen_names:
            continue
        seen_names.add(pyname)
        params_schema = entry.get("params", {})
        props = params_schema.get("properties", {})
        required = params_schema.get("required", [])
        any_of = params_schema.get("anyOf", [])

        arg_names = sorted(props.keys())
        sig_parts = ["self"]
        for name in arg_names:
            sig_parts.append(f"{name}: Optional[Any] = None")
        sig_parts.append("**extra_params: Any")
        sig = ", ".join(sig_parts)

        doc = entry.get("description", "").replace('"""', "'")
        debug_note = " (DEBUG builds only)" if entry.get("debug_only") else ""

        lines.append(f"    def {pyname}({sig}) -> Any:")
        lines.append(f'        """{doc}{debug_note}"""')
        lines.append("        params: Dict[str, Any] = {}")
        for name in arg_names:
            lines.append(f"        if {name} is not None:")
            lines.append(f'            params["{name}"] = {name}')
        lines.append("        params.update(extra_params)")
        for req in required:
            lines.append(f'        if params.get("{req}") is None:')
            lines.append(
                f'            raise ProgramaV2Error("{method} requires \'{req}\'")'
            )
        if any_of:
            any_of_keys = sorted({k for grp in any_of for k in grp.get("required", [])})
            if any_of_keys:
                keys_repr = ", ".join(f'"{k}"' for k in any_of_keys)
                lines.append(f"        if not any(params.get(k) is not None for k in ({keys_repr},)):")
                lines.append(
                    f'            raise ProgramaV2Error("{method} requires one of: {", ".join(any_of_keys)}")'
                )
        lines.append(f'        return self._client._call("{method}", params)')
        lines.append("")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# (d) CLI/V2MethodNames.swift
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
        os.path.join(ROOT, "tests_v2", "programa_v2.py"): gen_programa_v2_py(contract),
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
