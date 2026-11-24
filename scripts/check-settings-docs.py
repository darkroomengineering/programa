#!/usr/bin/env python3
"""Check that the settings and keyboard shortcut docs match the code.

Fails when:
  * a key in Resources/settings.schema.json is missing from docs/settings-json.md,
    or a documented key is missing from the schema;
  * a shortcut action in Sources/KeyboardShortcutSettings.swift is missing from the
    action id table in docs/keyboard-shortcuts.md (or the reverse);
  * a shortcut action is missing from the shortcuts.bindings enum in the schema (or the reverse);
  * a schema key has no Settings window row in the SettingsRow enum in
    Sources/SettingsRowRegistry.swift, or a row there has no schema key, unless the key or row is
    listed below in FILE_ONLY_KEYS or SETTINGS_ONLY_ROWS with a reason.

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
ROW_REGISTRY = ROOT / "Sources" / "SettingsRowRegistry.swift"

# settings.json keys with no Settings window row, on purpose.
FILE_ONLY_KEYS = {
    "sidebarAppearance.matchTerminalBackground": (
        "Only affects macOS 14 and 15, where the sidebar has no system glass; set it in the file."
    ),
    "windows.shortcuts": "Read by the Windows app only.",
    "windows.shell": "Read by the Windows app only.",
    "windows.startingDirectory": "Read by the Windows app only.",
}

# Settings window rows with no settings.json key, on purpose (SettingsRow cases with no raw value).
SETTINGS_ONLY_ROWS = {
    "desktopNotifications": "Shows the macOS notification permission, which only macOS can change.",
}

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


def settings_rows(text):
    """SettingsRow cases as {case name: settings.json key or None}."""
    start = text.index("enum SettingsRow")
    end = text.index("var settingsFileKey", start)
    rows = {}
    for match in re.finditer(r'^\s+case (\w+)(?:\s*=\s*"([^"]+)")?\s*$', text[start:end], re.M):
        rows[match.group(1)] = match.group(2)
    return rows


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

    rows = settings_rows(ROW_REGISTRY.read_text())
    if not rows:
        print("FAIL could not find any cases in the SettingsRow enum")
        return 1
    row_keys = {key for key in rows.values() if key}
    for key in sorted(from_schema - row_keys - FILE_ONLY_KEYS.keys()):
        print(
            f"FAIL settings rows: {key} has no Settings window row. Add the row and its SettingsRow "
            "case, or list the key in FILE_ONLY_KEYS with a reason"
        )
        ok = False
    for key in sorted(row_keys - from_schema):
        print(f"FAIL settings rows: SettingsRow key {key} is not in Resources/settings.schema.json")
        ok = False
    for name in sorted(n for n, key in rows.items() if key is None and n not in SETTINGS_ONLY_ROWS):
        print(
            f"FAIL settings rows: Settings row {name} has no settings.json key. Add the key, "
            "or list the row in SETTINGS_ONLY_ROWS with a reason"
        )
        ok = False
    for key in sorted(FILE_ONLY_KEYS.keys() & row_keys):
        print(f"FAIL settings rows: {key} is in FILE_ONLY_KEYS but has a Settings row; remove it from the list")
        ok = False
    for key in sorted(FILE_ONLY_KEYS.keys() - from_schema):
        print(f"FAIL settings rows: FILE_ONLY_KEYS lists {key}, which is not in the schema")
        ok = False
    for name in sorted(n for n in SETTINGS_ONLY_ROWS if rows.get(n, "missing") is not None):
        print(f"FAIL settings rows: SETTINGS_ONLY_ROWS lists {name}, which is not a SettingsRow case without a key")
        ok = False

    if ok:
        print(
            f"ok: {len(from_schema)} settings keys and {len(actions)} shortcut actions match the docs; "
            f"{len(rows)} Settings rows match the schema ({len(FILE_ONLY_KEYS)} file-only keys, "
            f"{len(SETTINGS_ONLY_ROWS)} Settings-only rows)"
        )
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
