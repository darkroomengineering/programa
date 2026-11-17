import AppKit
import SwiftUI

/// General > Links: the apps the external-open prompt was told to always allow, each revocable.
struct ExternalAppAllowlistSettingsSection: View {
    let isManagedBySettingsFile: Bool

    /// Observed so the list refreshes when the prompt or settings.json changes the allowlist.
    @AppStorage(ExternalOpenPolicy.allowlistKey) private var rawAllowlist = ""

    private struct Entry: Identifiable {
        let id: String
        let appName: String
        let bundleIdentifier: String
        let scheme: String
    }

    private var entries: [Entry] {
        _ = rawAllowlist
        return ExternalOpenPolicy.allowlist().map { entry in
            let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
            let bundleIdentifier = parts[0]
            let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                .map(ExternalOpenPolicy.applicationDisplayName(at:)) ?? bundleIdentifier
            return Entry(id: entry, appName: appName, bundleIdentifier: bundleIdentifier, scheme: parts[1])
        }
    }

    var body: some View {
        let entries = entries
        SettingsSectionHeader(title: String(localized: "settings.section.links", defaultValue: "Links"))
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                SettingsCardRow(
                    String(localized: "settings.links.allowedApps", defaultValue: "Apps Allowed to Open Links"),
                    subtitle: entries.isEmpty
                        ? String(
                            localized: "settings.links.allowedApps.subtitleEmpty",
                            defaultValue: "None yet. Choose Always Allow when Programa asks before a link opens another app."
                        )
                        : String(
                            localized: "settings.links.allowedApps.subtitle",
                            defaultValue: "Links of these kinds open in these apps without asking. Remove one to be asked again."
                        )
                ) {
                    EmptyView()
                }
                ForEach(entries) { entry in
                    SettingsCardDivider()
                    SettingsCardRow(
                        entry.appName,
                        subtitle: String(
                            format: String(
                                localized: "settings.links.allowedApps.entry",
                                defaultValue: "%1$@: links · %2$@"
                            ),
                            entry.scheme,
                            entry.bundleIdentifier
                        )
                    ) {
                        Button(String(localized: "settings.links.allowedApps.remove", defaultValue: "Remove")) {
                            ExternalOpenPolicy.removeFromAllowlist(entry.id)
                        }
                        .accessibilityLabel(String(
                            format: String(
                                localized: "settings.links.allowedApps.removeLabel",
                                defaultValue: "Remove %1$@ for %2$@: links"
                            ),
                            entry.appName,
                            entry.scheme
                        ))
                    }
                }
            }
            .managedBySettingsFile(isManagedBySettingsFile)
        }
    }
}

/// General > Storage: where worktrees go and the automatic cleanup that settings.json's
/// `worktrees` and `storage` sections also control. `StorageSettings.read` resolves the values.
struct StorageSettingsSection: View {
    let isManaged: (SettingsRow) -> Bool

    @AppStorage(StorageSettings.directoryKey) private var directory: String?
    @AppStorage(StorageSettings.autoRemoveMergedKey)
    private var autoRemoveMerged = StorageSettings.defaultAutoRemoveMerged
    @AppStorage(StorageSettings.autoRemoveAfterHoursKey)
    private var autoRemoveAfterHours = StorageSettings.defaultAutoRemoveAfterHours
    @AppStorage(StorageSettings.autoCleanCachesKey)
    private var autoCleanCaches = StorageSettings.defaultAutoCleanCaches
    @AppStorage(StorageSettings.lowDiskWarningGBKey)
    private var lowDiskWarningGB = StorageSettings.defaultLowDiskWarningGB

    @State private var directoryDraft = ""
    @FocusState private var directoryFieldFocused: Bool

    private static let directoryPlaceholder = "~/.programa/worktrees"

    /// Commits on Return, focus loss or Choose, never per keystroke, so a half-typed path never
    /// becomes the folder that cleanup scans. An empty field returns to the default folder.
    private func commitDirectory(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        directory = trimmed.isEmpty ? nil : trimmed
        directoryDraft = trimmed
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: StorageSettings.read().directory, isDirectory: true)
        panel.prompt = String(localized: "settings.storage.worktreeDirectory.choosePrompt", defaultValue: "Use Folder")
        if panel.runModal() == .OK, let url = panel.url {
            commitDirectory((url.path as NSString).abbreviatingWithTildeInPath)
        }
    }

    /// Unit names and plurals come from the locale ("1 hour", "24 hours", "24時間").
    private static func formatted<UnitType: Dimension>(
        _ value: Double,
        _ unit: UnitType,
        width: Measurement<UnitType>.FormatStyle.UnitWidth
    ) -> String {
        Measurement(value: value, unit: unit).formatted(
            .measurement(width: width, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
        )
    }

    var body: some View {
        SettingsSectionHeader(title: String(localized: "settings.section.storage", defaultValue: "Storage"))
        SettingsCard {
            SettingsCardRow(
                String(localized: "settings.storage.worktreeDirectory", defaultValue: "Worktree Folder"),
                subtitle: String(
                    localized: "settings.storage.worktreeDirectory.subtitle",
                    defaultValue: "programa worktree create puts new worktrees here, one folder per repository."
                )
            ) {
                HStack(spacing: 6) {
                    TextField(Self.directoryPlaceholder, text: $directoryDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .focused($directoryFieldFocused)
                        .onSubmit { commitDirectory(directoryDraft) }
                        .onChange(of: directoryFieldFocused) { _, isFocused in
                            if !isFocused { commitDirectory(directoryDraft) }
                        }
                        .accessibilityLabel(
                            String(localized: "settings.storage.worktreeDirectory", defaultValue: "Worktree Folder")
                        )
                    Button(String(localized: "settings.storage.worktreeDirectory.choose", defaultValue: "Choose…")) {
                        chooseDirectory()
                    }
                }
            }
            .managedBySettingsFile(isManaged(.worktreeDirectory))
            .onAppear { directoryDraft = directory ?? "" }
            .onChange(of: directory) { _, newValue in
                if !directoryFieldFocused { directoryDraft = newValue ?? "" }
            }

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.storage.autoRemoveMerged", defaultValue: "Remove Merged Worktrees"),
                subtitle: autoRemoveMerged
                    ? String(
                        localized: "settings.storage.autoRemoveMerged.subtitleOn",
                        defaultValue: "Every 6 hours, merged worktrees in the worktree folder with no changes are removed. Branches are kept."
                    )
                    : String(
                        localized: "settings.storage.autoRemoveMerged.subtitleOff",
                        defaultValue: "Merged worktrees stay until you remove them, for example with programa storage clean."
                    )
            ) {
                Toggle("", isOn: $autoRemoveMerged)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.storage.autoRemoveMerged", defaultValue: "Remove Merged Worktrees")
                    )
            }
            .managedBySettingsFile(isManaged(.autoRemoveMergedWorktrees))

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.storage.autoRemoveAfterHours", defaultValue: "Remove After"),
                subtitle: String(
                    localized: "settings.storage.autoRemoveAfterHours.subtitle",
                    defaultValue: "How long a merged worktree must go unused before it is removed."
                )
            ) {
                Stepper(value: $autoRemoveAfterHours, in: 1...720, step: 1) {
                    Text(Self.formatted(autoRemoveAfterHours, UnitDuration.hours, width: .wide))
                    .monospacedDigit()
                }
                .accessibilityLabel(
                    String(localized: "settings.storage.autoRemoveAfterHours", defaultValue: "Remove After")
                )
            }
            .disabled(!autoRemoveMerged)
            .managedBySettingsFile(isManaged(.autoRemoveWorktreesAfterHours))

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.storage.autoCleanCaches", defaultValue: "Clean Developer Caches"),
                subtitle: autoCleanCaches
                    ? String(
                        localized: "settings.storage.autoCleanCaches.subtitleOn",
                        defaultValue: "Every 6 hours, eligible Xcode, Android and package manager caches are cleaned while their tools are idle."
                    )
                    : String(
                        localized: "settings.storage.autoCleanCaches.subtitleOff",
                        defaultValue: "Caches are cleaned only when you run programa storage clean."
                    )
            ) {
                Toggle("", isOn: $autoCleanCaches)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(
                        String(localized: "settings.storage.autoCleanCaches", defaultValue: "Clean Developer Caches")
                    )
            }
            .managedBySettingsFile(isManaged(.autoCleanCaches))

            SettingsCardDivider()

            SettingsCardRow(
                String(localized: "settings.storage.lowDiskWarning", defaultValue: "Low Disk Space Warning"),
                subtitle: lowDiskWarningGB > 0
                    ? String(
                        localized: "settings.storage.lowDiskWarning.subtitleOn",
                        defaultValue: "Warn when free space on the home volume falls below this amount."
                    )
                    : String(
                        localized: "settings.storage.lowDiskWarning.subtitleOff",
                        defaultValue: "No warning when the disk runs low."
                    )
            ) {
                Stepper(value: $lowDiskWarningGB, in: 0...1_000, step: 5) {
                    Text(lowDiskWarningGB > 0
                        ? Self.formatted(lowDiskWarningGB, UnitInformationStorage.gigabytes, width: .abbreviated)
                        : String(localized: "settings.storage.lowDiskWarning.off", defaultValue: "Off"))
                    .monospacedDigit()
                }
                .accessibilityLabel(
                    String(localized: "settings.storage.lowDiskWarning", defaultValue: "Low Disk Space Warning")
                )
            }
            .managedBySettingsFile(isManaged(.lowDiskWarning))
        }
    }

    /// Clears every value this section writes, so `StorageSettings` falls back to its defaults.
    static func resetToDefaults(defaults: UserDefaults = .standard) {
        for key in [
            StorageSettings.directoryKey,
            StorageSettings.autoRemoveMergedKey,
            StorageSettings.autoRemoveAfterHoursKey,
            StorageSettings.autoCleanCachesKey,
            StorageSettings.lowDiskWarningGBKey,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}
