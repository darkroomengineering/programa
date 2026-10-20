import Foundation
import SwiftUI

/// Configuration for the split tab bar appearance
public struct BonsplitConfiguration: Sendable {

    // MARK: - Appearance

    /// Tab bar appearance customization
    public var appearance: Appearance

    // MARK: - Presets

    public static let `default` = BonsplitConfiguration()

    // MARK: - Initializer

    public init(appearance: Appearance = .default) {
        self.appearance = appearance
    }
}

// MARK: - Appearance Configuration

extension BonsplitConfiguration {
    public struct SplitButtonTooltips: Sendable, Equatable {
        public var newTerminal: String
        public var splitRight: String
        public var splitDown: String

        public static let `default` = SplitButtonTooltips()

        public init(
            newTerminal: String = "New Terminal",
            splitRight: String = "Split Right",
            splitDown: String = "Split Down"
        ) {
            self.newTerminal = newTerminal
            self.splitRight = splitRight
            self.splitDown = splitDown
        }
    }

    public struct Appearance: Sendable {
        public struct ChromeColors: Sendable {
            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for tab/pane chrome backgrounds.
            /// When unset, Bonsplit uses native system colors.
            public var backgroundHex: String?

            /// Optional hex color (`#RRGGBB` or `#RRGGBBAA`) for separators/dividers.
            /// When unset, Bonsplit derives separators from the chrome background.
            public var borderHex: String?

            public init(
                backgroundHex: String? = nil,
                borderHex: String? = nil
            ) {
                self.backgroundHex = backgroundHex
                self.borderHex = borderHex
            }
        }

        /// Extra leading inset for the tab bar (e.g. for traffic light buttons when sidebar is collapsed)
        public var tabBarLeadingInset: CGFloat

        /// Whether each visible tab pill uses native AppKit Liquid Glass where available.
        public var tabBarLiquidGlassEnabled: Bool

        /// Whether compact tab overlays such as shortcut hints use native AppKit Liquid Glass.
        public var overlayLiquidGlassEnabled: Bool

        /// Tooltip text for the tab bar's right-side action buttons
        public var splitButtonTooltips: SplitButtonTooltips

        // MARK: - Theme Overrides

        /// Optional color overrides for tab/pane chrome.
        public var chromeColors: ChromeColors

        // MARK: - Presets

        public static let `default` = Appearance()

        // MARK: - Initializer

        public init(
            tabBarLeadingInset: CGFloat = 0,
            tabBarLiquidGlassEnabled: Bool = false,
            overlayLiquidGlassEnabled: Bool = false,
            splitButtonTooltips: SplitButtonTooltips = .default,
            chromeColors: ChromeColors = .init()
        ) {
            self.tabBarLeadingInset = tabBarLeadingInset
            self.tabBarLiquidGlassEnabled = tabBarLiquidGlassEnabled
            self.overlayLiquidGlassEnabled = overlayLiquidGlassEnabled
            self.splitButtonTooltips = splitButtonTooltips
            self.chromeColors = chromeColors
        }
    }
}
