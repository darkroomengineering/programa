import Foundation

/// Sizing and spacing constants for the tab bar (following macOS HIG).
/// Release builds resolve to the constants below unconditionally. DEBUG
/// builds resolve live overrides from `UserDefaults.standard` under
/// `"chromeDensity.<name>"` keys -- the SAME keys Programa's Density Debug
/// window (`Sources/DebugWindows.swift`) writes via its sliders and
/// `Sources/WindowChrome.swift`'s `ChromeDensity` enum reads for the rest of
/// the app's chrome. Bonsplit is a standalone package that Programa depends
/// on, so it cannot import Programa's `ChromeDensity` type; sharing the
/// UserDefaults key namespace avoids a cross-module bridge while keeping both
/// sides live-tunable from one slider.
enum TabBarMetrics {
    // MARK: - Tab Bar

    static var barHeight: CGFloat { resolved("tabBarHeight", default: 26) }
    static let barPadding: CGFloat = 0

    // MARK: - Individual Tabs

    static var tabHeight: CGFloat { resolved("tabBarHeight", default: 26) }
    static let tabMinWidth: CGFloat = 48
    static let tabMaxWidth: CGFloat = 220
    static let tabCornerRadius: CGFloat = 0
    static var tabHorizontalPadding: CGFloat { resolved("tabHorizontalPadding", default: 8) }
    static let tabSpacing: CGFloat = 0
    static let activeIndicatorHeight: CGFloat = 2

    // MARK: - Tab Content

    static var iconSize: CGFloat { resolved("tabIconSize", default: 13) }
    static var titleFontSize: CGFloat { resolved("tabTitleFontSize", default: 12) }
    static var closeButtonSize: CGFloat { resolved("tabCloseButtonSize", default: 14) }
    static var closeIconSize: CGFloat { resolved("tabCloseIconSize", default: 8) }
    static let dirtyIndicatorSize: CGFloat = 8
    static let notificationBadgeSize: CGFloat = 6
    static var contentSpacing: CGFloat { resolved("tabContentSpacing", default: 5) }

    // MARK: - Drop Indicator

    static let dropIndicatorWidth: CGFloat = 2
    static let dropIndicatorHeight: CGFloat = 20

    // MARK: - Split View

    static let minimumPaneWidth: CGFloat = 100
    static let minimumPaneHeight: CGFloat = 100
    static let dividerThickness: CGFloat = 1

    // MARK: - Animations

    static let selectionDuration: Double = 0.15
    static let closeDuration: Double = 0.2
    static let reorderDuration: Double = 0.3
    static let reorderBounce: Double = 0.15
    static let hoverDuration: Double = 0.1

    // MARK: - Split Animations (120fps via CADisplayLink)

    /// Duration for split entry animation (fast and snappy like Hyprland)
    static let splitAnimationDuration: Double = 0.15

    #if DEBUG
    private static func resolved(_ name: String, default defaultValue: CGFloat) -> CGFloat {
        guard let value = UserDefaults.standard.object(forKey: "chromeDensity.\(name)") as? Double else {
            return defaultValue
        }
        return CGFloat(value)
    }
    #else
    private static func resolved(_ name: String, default defaultValue: CGFloat) -> CGFloat {
        defaultValue
    }
    #endif
}
