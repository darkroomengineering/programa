// Extracted from Workspace.swift (nuclear-review #98): theming (split-button tooltips, bonsplit
// chrome/divider appearance, and applyGhosttyChrome).

import Foundation
import SwiftUI
import AppKit
import Bonsplit
import Combine
import CryptoKit
import Darwin
import Network
import CoreText

extension Workspace {
    static func currentSplitButtonTooltips() -> BonsplitConfiguration.SplitButtonTooltips {
        BonsplitConfiguration.SplitButtonTooltips(
            newTerminal: KeyboardShortcutSettings.Action.newSurface.tooltip("New Terminal"),
            newBrowser: KeyboardShortcutSettings.Action.openBrowser.tooltip("New Browser"),
            splitRight: KeyboardShortcutSettings.Action.splitRight.tooltip("Split Right"),
            splitDown: KeyboardShortcutSettings.Action.splitDown.tooltip("Split Down")
        )
    }

    static func bonsplitAppearance(from config: GhosttyConfig) -> BonsplitConfiguration.Appearance {
        bonsplitAppearance(
            from: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity
        )
    }

    static func bonsplitChromeHex(backgroundColor: NSColor, backgroundOpacity: Double) -> String {
        let themedColor = GhosttyBackgroundTheme.color(
            backgroundColor: backgroundColor,
            opacity: backgroundOpacity
        )
        let includeAlpha = themedColor.alphaComponent < 0.999
        return themedColor.hexString(includeAlpha: includeAlpha)
    }

    /// Returns a clearly-perceptible divider hex derived from the chrome background hex.
    /// Dark backgrounds are lightened ~28% toward white; light backgrounds are darkened ~20% toward
    /// black. These factors are meaningfully stronger than bonsplit's built-in weak fallback (0.16/0.12
    /// tone at reduced alpha), ensuring the 1pt split divider is visible in both dark and light themes.
    /// The result is always an opaque #RRGGBB string (no alpha), matching hexString(includeAlpha:false).
    static func bonsplitDividerHex(fromChromeHex chromeHex: String) -> String {
        // Parse #RRGGBB or #RRGGBBAA produced by hexString(includeAlpha:)
        let stripped = chromeHex.hasPrefix("#") ? String(chromeHex.dropFirst()) : chromeHex
        guard stripped.count >= 6,
              let rByte = UInt8(stripped.prefix(2), radix: 16),
              let gByte = UInt8(stripped.dropFirst(2).prefix(2), radix: 16),
              let bByte = UInt8(stripped.dropFirst(4).prefix(2), radix: 16)
        else {
            return chromeHex  // fallback: return unchanged on parse failure
        }

        var r = CGFloat(rByte) / 255.0
        var g = CGFloat(gByte) / 255.0
        var b = CGFloat(bByte) / 255.0

        // Perceptual luminance check (sRGB coefficients, no gamma expansion needed for light/dark)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b

        if luminance < 0.5 {
            // Dark background: lighten 28% toward white
            r += (1.0 - r) * 0.28
            g += (1.0 - g) * 0.28
            b += (1.0 - b) * 0.28
        } else {
            // Light background: darken 20% toward black
            r *= 0.80
            g *= 0.80
            b *= 0.80
        }

        let rOut = min(255, max(0, Int((r * 255).rounded())))
        let gOut = min(255, max(0, Int((g * 255).rounded())))
        let bOut = min(255, max(0, Int((b * 255).rounded())))
        return String(format: "#%02X%02X%02X", rOut, gOut, bOut)
    }

    nonisolated static func resolvedChromeColors(
        from backgroundColor: NSColor
    ) -> BonsplitConfiguration.Appearance.ChromeColors {
        .init(backgroundHex: backgroundColor.hexString())
    }

    static func bonsplitAppearance(
        from backgroundColor: NSColor,
        backgroundOpacity: Double
    ) -> BonsplitConfiguration.Appearance {
        let chromeHex = Self.bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        return BonsplitConfiguration.Appearance(
            splitButtonTooltips: Self.currentSplitButtonTooltips(),
            enableAnimations: false,
            chromeColors: .init(
                backgroundHex: chromeHex,
                borderHex: Self.bonsplitDividerHex(fromChromeHex: chromeHex)
            )
        )
    }

    func applyGhosttyChrome(from config: GhosttyConfig, reason: String = "unspecified") {
        applyGhosttyChrome(
            backgroundColor: config.backgroundColor,
            backgroundOpacity: config.backgroundOpacity,
            reason: reason
        )
    }

    func applyGhosttyChrome(backgroundColor: NSColor, backgroundOpacity: Double, reason: String = "unspecified") {
        let nextHex = Self.bonsplitChromeHex(
            backgroundColor: backgroundColor,
            backgroundOpacity: backgroundOpacity
        )
        let currentChromeColors = bonsplitController.configuration.appearance.chromeColors
        let isNoOp = currentChromeColors.backgroundHex == nextHex

        if GhosttyApp.shared.backgroundLogEnabled {
            let currentBackgroundHex = currentChromeColors.backgroundHex ?? "nil"
            GhosttyApp.shared.logBackground(
                "theme apply workspace=\(id.uuidString) reason=\(reason) currentBg=\(currentBackgroundHex) nextBg=\(nextHex) noop=\(isNoOp)"
            )
        }

        if isNoOp {
            return
        }
        bonsplitController.configuration.appearance.chromeColors.backgroundHex = nextHex
        bonsplitController.configuration.appearance.chromeColors.borderHex = Self.bonsplitDividerHex(fromChromeHex: nextHex)
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground(
                "theme applied workspace=\(id.uuidString) reason=\(reason) resultingBg=\(bonsplitController.configuration.appearance.chromeColors.backgroundHex ?? "nil")"
            )
        }
    }

    func refreshSplitButtonTooltips() {
        let tooltips = Self.currentSplitButtonTooltips()
        var configuration = bonsplitController.configuration
        guard configuration.appearance.splitButtonTooltips != tooltips else { return }
        configuration.appearance.splitButtonTooltips = tooltips
        bonsplitController.configuration = configuration
    }
}
