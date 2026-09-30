#!/usr/bin/env python3
"""Check that the settings and keyboard shortcut docs match the code.

Fails when:
  * a key in Resources/settings.schema.json is missing from docs/settings-json.md,
    or a documented key is missing from the schema;
  * a shortcut action in Sources/KeyboardShortcutSettings.swift is missing from the
    action id table in docs/keyboard-shortcuts.md (or the reverse);
  * a shortcut action is missing from the shortcuts.bindings enum in the schema (or the reverse).

Standard library only. Run from anywhere: python3 scripts/check-settings-docs.py
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "Resources" / "settings.schema.json"
SETTINGS_DOC = ROOT / "docs" / "settings-json.md"
SHORTCUTS_DOC = ROOT / "docs" / "keyboard-shortcuts.md"
SWIFT = ROOT / "Sources" / "KeyboardShortcutSettings.swift"

# Top-level schema keys that are file metadata rather than settings.
METADATA_KEYS = {"$schema", "schemaVersion"}


def schema_keys(schema):
    keys = set()
    for section, body in schema["properties"].items():
        if section in METADATA_KEYS:
            continue
        for key in body.get("properties", {}):
            keys.add(f"{section}.{key}")
    return keys


def doc_keys(text):
    """Rows of tables whose header starts with `| Key |`, grouped by `## `section`` heading."""
    keys = set()
    section = None
    in_key_table = False
    for line in text.splitlines():
        heading = re.match(r"^## `(\w+)`\s*$", line)
        if heading:
            section = heading.group(1)
            in_key_table = False
            continue
        if line.startswith("| Key |"):
            in_key_table = True
            continue
        if not line.startswith("|"):
            in_key_table = False
            continue
        row = re.match(r"^\| `(\w+)` \|", line)
        if row and section and in_key_table:
            keys.add(f"{section}.{row.group(1)}")
    return keys


def swift_actions(text):
    start = text.index("enum Action")
    end = text.index("var id: String", start)
    return set(re.findall(r"^\s+case (\w+)\s*$", text[start:end], re.M))


def shortcut_doc_ids(text):
    return set(re.findall(r"^\| `(\w+)` \|", text, re.M))


def report(label, missing, extra, missing_where, extra_where):
    ok = True
    for item in sorted(missing):
        print(f"FAIL {label}: {item} is missing from {missing_where}")
        ok = False
    for item in sorted(extra):
        print(f"FAIL {label}: {item} is present in {extra_where} but not in the source of truth")
        ok = False
    return ok


def main():
    schema = json.loads(SCHEMA.read_text())
    ok = True

    from_schema = schema_keys(schema)
    from_doc = doc_keys(SETTINGS_DOC.read_text())
    ok &= report(
        "settings-json.md",
        from_schema - from_doc,
        from_doc - from_schema,
        "docs/settings-json.md",
        "docs/settings-json.md",
    )

    actions = swift_actions(SWIFT.read_text())
    if not actions:
        print("FAIL could not find any actions in the KeyboardShortcutSettings.Action enum")
        return 1
    ids = shortcut_doc_ids(SHORTCUTS_DOC.read_text())
    ok &= report(
        "keyboard-shortcuts.md",
        actions - ids,
        ids - actions,
        "the action id table in docs/keyboard-shortcuts.md",
        "docs/keyboard-shortcuts.md",
    )

    enum = set(
        schema["properties"]["shortcuts"]["properties"]["bindings"]["propertyNames"]["enum"]
    )
    ok &= report(
        "settings.schema.json shortcuts.bindings",
        actions - enum,
        enum - actions,
        "the shortcuts.bindings enum in Resources/settings.schema.json",
        "Resources/settings.schema.json",
    )

    if ok:
        print(
            f"ok: {len(from_schema)} settings keys and {len(actions)} shortcut actions match the docs"
        )
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
