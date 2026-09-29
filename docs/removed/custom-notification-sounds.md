# Custom notification sound files

Removed 2026-09-02. Last present at commit 903027ccef. Restore with `git checkout 903027ccef -- Sources/NotificationSoundStaging.swift Sources/SettingsView.swift Sources/TerminalNotificationStore.swift Sources/ProgramaSettingsFileStore.swift Resources/settings.schema.json programaTests/NotificationAndMenuBarTests.swift` and then re-diff against the current (slimmed) versions of those files, since only `NotificationSoundStaging.swift` was a whole-file replacement — the rest were partial edits.

## What it did

Settings > Notifications let a user pick "Custom File..." from the sound dropdown, choose any
local audio file (any format `NSOpenPanel` would show for `.audio`), and Programa staged a
playable copy under `~/Library/Sounds`. If the source was already WAV/AIFF/CAF it was copied
as-is; anything else (mp3, m4a, etc.) was transcoded to CAF via `afconvert`. Staged files were
content-addressed by a hash of the source path so re-choosing the same file reused the staged
copy, and a JSON sidecar (`.source-metadata`) recorded the source's size/mtime/inode so the
staging logic could detect the source changing and re-stage. A "Choose..." button ran the
panel and transcode; "Clear" reset the path; a status line under the picker showed
staging progress/errors ("Ready for notifications." / "Prepared for notifications (converted
to CAF)." / specific failure messages for missing file, missing extension, or transcode
failure). The system-sound picker (Basso, Glass, Ping, etc., plus "Default" and "None") is
unaffected and stays.

## How it was wired

- Settings: `@AppStorage(NotificationSoundSettings.key)` (`"notificationSound"`, values
  `"default"`, a system sound name, `"custom_file"`, or `"none"`) plus
  `@AppStorage(NotificationSoundSettings.customFilePathKey)`
  (`"notificationSoundCustomFilePath"`, default `""`) for the chosen file's path.
- `settings.json` config key: `notifications.customSoundFilePath` (string, default `""`), and
  `notifications.sound` accepted `"custom_file"` as an enum value.
- No menu item, shortcut, or command-palette entry — Settings UI only.
- `Sources/NotificationSoundStaging.swift` (`NotificationSoundSettings`) owned staging,
  transcoding, playback preview, and stale-file cleanup logic; `Sources/SettingsView.swift` was
  the only UI consumer; `Sources/TerminalNotificationStore.swift` called
  `NotificationSoundSettings.sound()` to build the `UNNotificationSound` used for real
  deliveries and `playSelectedSound()` for the in-app suppressed-notification feedback beep —
  both already funnel through the slimmed system-sound-only implementation, so they needed no
  code changes.

## Files removed and files edited

Removed: none (no whole file was custom-file-only; `NotificationSoundStaging.swift` was
rewritten in place rather than deleted, since it also holds the unrelated "run a custom shell
command on notification" feature, which stays).

Edited:
- `Sources/NotificationSoundStaging.swift`: rewritten to keep only `key`/`defaultValue`,
  `systemSounds` (dropped the `"Custom File..."` entry), `sound()`, `usesSystemSound()`,
  `isSilent()`, `playSelectedSound()`/`previewSound()`, and the untouched
  `customCommandKey`/`runCustomCommand` shell-command feature. Cut staging, transcoding,
  preview-from-path, metadata sidecar, and cleanup logic (~370 lines).
- `Sources/SettingsView.swift`: dropped the `notificationSoundCustomFilePath` `@AppStorage`,
  the file-chooser/status/clear UI block, `chooseNotificationSoundFile()`,
  `refreshNotificationCustomSoundStatus()`, `notificationCustomSoundIssueMessage()`,
  `notificationCustomSoundReadyStatusMessage()`, the custom-sound-error `.alert`, and the
  related `@State` vars; kept the system-sound `Picker` and preview button.
- `Sources/ProgramaSettingsFileStore.swift`: dropped parsing/writing the
  `notifications.customSoundFilePath` config key (both the reader and the default-settings
  writer).
- `Resources/settings.schema.json`: dropped the `customSoundFilePath` property and the
  `custom_file` enum value from `notifications.sound`.
- `programaTests/NotificationAndMenuBarTests.swift`: removed 7 tests exercising staging,
  transcoding, tilde-expansion, explicit-selection, and failure paths; trimmed
  `testNotificationSoundDisablesSystemSoundForNoneAndCustomFile` to
  `testNotificationSoundDisablesSystemSoundForNone` (kept the `"none"` assertion, dropped the
  `custom_file` assertion).

## What we learned

CHANGELOG.md has no entry mentioning custom notification sound files, and no code review
finding mentions this feature — there is no recorded bug history or security finding to carry forward.
The one design detail worth keeping if this is rebuilt: staged files were content-addressed by
a hash of the source path (not the file bytes), with a metadata sidecar for change detection,
so switching between two different source files never collided on disk, and re-selecting the
same file was a no-op after the first transcode.

## Why removed and what a future version should do differently

Custom audio files added a real subprocess dependency (`afconvert`), a staging directory
under `~/Library/Sounds` that needed its own cleanup logic, and a multi-state status UI, all
for a preference most users leave on a system sound. If rebuilt, scope it down: skip
transcoding entirely and only accept formats `UNNotificationSound` already supports natively
(WAV/AIFF/CAF), which removes the `afconvert` dependency and the async staging queue while
keeping the "pick your own file" capability.
