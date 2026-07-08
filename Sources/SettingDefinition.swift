import Foundation

/// Shared plumbing for the family of boolean, UserDefaults-backed settings in
/// `ProgramaApp.swift` shaped like:
///
///     enum XSettings {
///         static let enabledKey = "..."
///         static let defaultEnabled = ...
///         static func isEnabled(defaults: UserDefaults = .standard) -> Bool { ... }
///     }
///
/// Only settings with *no* extra logic (no migrations, no side effects, no
/// non-trivial accessors) should be backed by this. Settings with real logic
/// (e.g. legacy-key migration, mode enums with special-casing) keep their
/// bespoke, fully-written-out implementations.
struct UserDefaultsFlag {
    let key: String
    let defaultValue: Bool

    /// Returns the stored value for `key`, or `defaultValue` if unset.
    func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    func setEnabled(_ isEnabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: key)
    }
}
