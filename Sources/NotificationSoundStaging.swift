import AppKit
import Foundation
import UserNotifications

// MARK: - Notification Sound Settings
//
// System-sound picker for notification delivery: exposes the built-in macOS sound names
// available to UNNotificationSound and simple playback for settings-UI previews. The
// custom-file staging/transcoding flow that used to live here was removed; see
// docs/removed/custom-notification-sounds.md. Extracted from TerminalNotificationStore.swift,
// which owns the rest of notification delivery/state and is a heavy consumer of this
// settings surface.
enum NotificationSoundSettings {
    static let key = "notificationSound"
    static let defaultValue = "default"

    static let customCommandKey = "notificationCustomCommand"
    static let defaultCustomCommand = ""

    static let systemSounds: [(label: String, value: String)] = [
        ("Default", "default"),
        ("Basso", "Basso"),
        ("Blow", "Blow"),
        ("Bottle", "Bottle"),
        ("Frog", "Frog"),
        ("Funk", "Funk"),
        ("Glass", "Glass"),
        ("Hero", "Hero"),
        ("Morse", "Morse"),
        ("Ping", "Ping"),
        ("Pop", "Pop"),
        ("Purr", "Purr"),
        ("Sosumi", "Sosumi"),
        ("Submarine", "Submarine"),
        ("Tink", "Tink"),
        ("None", "none"),
    ]

    static func sound(defaults: UserDefaults = .standard) -> UNNotificationSound? {
        let value = defaults.string(forKey: key) ?? defaultValue
        switch value {
        case "default":
            return .default
        case "none":
            return nil
        default:
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: value))
        }
    }

    static func usesSystemSound(defaults: UserDefaults = .standard) -> Bool {
        (defaults.string(forKey: key) ?? defaultValue) != "none"
    }

    static func isSilent(defaults: UserDefaults = .standard) -> Bool {
        return (defaults.string(forKey: key) ?? defaultValue) == "none"
    }

    static func playSelectedSound(defaults: UserDefaults = .standard) {
        let value = defaults.string(forKey: key) ?? defaultValue
        playSound(value: value)
    }

    static func previewSound(value: String, defaults: UserDefaults = .standard) {
        playSound(value: value)
    }

    private static func playSound(value: String) {
        switch value {
        case "default":
            NSSound.beep()
        case "none":
            break
        default:
            NSSound(named: NSSound.Name(value))?.play()
        }
    }

    private static let customCommandQueue = DispatchQueue(
        label: "com.darkroom.programa.notification-custom-command",
        qos: .utility
    )

    static func runCustomCommand(title: String, subtitle: String, body: String, defaults: UserDefaults = .standard) {
        let command = (defaults.string(forKey: customCommandKey) ?? defaultCustomCommand)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        customCommandQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            var env = ProcessInfo.processInfo.environment
            env["PROGRAMA_NOTIFICATION_TITLE"] = title
            env["PROGRAMA_NOTIFICATION_SUBTITLE"] = subtitle
            env["PROGRAMA_NOTIFICATION_BODY"] = body
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("Notification command failed to launch: \(error)")
            }
        }
    }
}
