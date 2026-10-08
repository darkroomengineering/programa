# cmux upgrade shims

Removed 2026-10-08. Last present at commit 6a64a9e0bd. Restore with `git checkout 6a64a9e0bd -- Sources/ProgramaApp.swift Sources/ProgramaConfig.swift Sources/ProgramaSettingsFileStore.swift Sources/ProgramaDirectoryTrust.swift Sources/GitWorktreeManager.swift Sources/SocketControlSettings.swift Sources/ContentView.swift CLI/CLI+AgentWrappers.swift CLI/SocketClient.swift CLI/programa.swift vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift Resources/shell-integration`.

## What it did

Programa was renamed from cmux. These fallbacks let someone upgrading from a cmux install keep working without touching their setup:

- A one-time launch migration copied every `cmux`-prefixed UserDefaults key to the matching `programa` key.
- Config files were found at the old paths: `~/.config/cmux/settings.json`, `~/.config/cmux/cmux.json`, and a project-local `cmux.json` (also when migrating a version-2 directory trust store).
- `cmuxOnly` was accepted as an alias of the `programaOnly` socket mode (settings file, env var, JSON schema enum).
- `CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC`, `CMUX_DEBUG_LOG`, `CMUX_TAG` and `CMUX_SOCKET_PATH` were read as env fallbacks.
- The CLI resolved a scope from `cmux-` and `cmux-debug-` socket file names.
- The Claude wrapper detector also matched the `cmux claude wrapper` header.
- Command-palette usage history keys with a `cmux.config.` prefix were rewritten to `programa.config.`.
- Shell integration fell back to a `cmux` binary on `PATH` when `programa` was missing.
- The bonsplit debug log skipped the legacy `com.cmuxterm.app.debug` bundle id.

## Files removed and files edited

No files were deleted. The shims were edited out of the files in the restore command, plus the matching docs (`docs/settings-json.md`, `docs/environment-variables.md`, `docs/socket-api.md`, `docs/programa-json.md`, `docs/plans/rust-core-concepts.md`), `Resources/settings.schema.json`, `programaTests/GhosttyConfigTests.swift` and `vendor/bonsplit/Tests/BonsplitTests/DebugEventLogTests.swift`.

## What we learned

The UserDefaults migration was the only shim that ran unconditionally; the rest only matter when a cmux-era file or variable exists. The `cmuxPortBase` and `cmuxPortRange` defaults keys were kept: they are the live keys current users store their port settings under, so renaming them without a migration would reset those settings. Rename them together with a one-time copy if it is ever wanted. Also kept: the `"protocol": "cmux-socket"` value in the capabilities reply (other clients may read it) and the Sparkle signing keychain account name `cmux` in `scripts/sparkle_generate_keys.sh` (the existing key lives under it).

## Why removed

The cmux-to-Programa upgrade window has passed and the shims were code on hot startup paths that only helped people moving from cmux.
