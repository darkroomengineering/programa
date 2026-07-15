import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import CoreText
import Darwin
import Carbon.HIToolbox
import Bonsplit
import IOSurface
import UniformTypeIdentifiers

// MARK: - Terminal Keyboard Copy Mode (split out, Nuclear Review #97; verbatim move)
// Four `terminalKeyTable*`/`terminalKeyboardCopyModeIndicatorText` items below
// widened private -> internal (used from GhosttyNSView.swift/GhosttySurfaceScrollView.swift).

enum TerminalKeyboardCopyModeSelectionMove: String, Equatable {
    case left
    case right
    case up
    case down
    case pageUp = "page_up"
    case pageDown = "page_down"
    case home
    case end
    case beginningOfLine = "beginning_of_line"
    case endOfLine = "end_of_line"
}

enum TerminalKeyboardCopyModeAction: Equatable {
    case exit
    case startSelection
    case clearSelection
    case copyAndExit
    case copyLineAndExit
    case scrollLines(Int)
    case scrollPage(Int)
    case scrollHalfPage(Int)
    case scrollToTop
    case scrollToBottom
    case jumpToPrompt(Int)
    case startSearch
    case searchNext
    case searchPrevious
    case adjustSelection(TerminalKeyboardCopyModeSelectionMove)
}

struct TerminalKeyboardCopyModeInputState: Equatable {
    var countPrefix: Int?
    var pendingYankLine = false
    var pendingG = false

    mutating func reset() {
        countPrefix = nil
        pendingYankLine = false
        pendingG = false
    }
}

enum TerminalKeyboardCopyModeResolution: Equatable {
    case perform(TerminalKeyboardCopyModeAction, count: Int)
    case consume
}

private let terminalKeyboardCopyModeMaxCount = 9_999

var terminalKeyboardCopyModeIndicatorText: String {
    String(localized: "ghostty.copy-mode.indicator", defaultValue: "vim")
}

private var terminalKeyTableIndicatorDefaultText: String {
    String(localized: "ghostty.key-table.indicator", defaultValue: "key table")
}

var terminalKeyTableIndicatorAccessibilityLabel: String {
    String(localized: "ghostty.key-table.icon.accessibility", defaultValue: "Key table")
}

func terminalKeyboardCopyModeClampCount(_ value: Int) -> Int {
    min(max(value, 1), terminalKeyboardCopyModeMaxCount)
}

func terminalKeyTableIndicatorText(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "", "set":
        return terminalKeyTableIndicatorDefaultText
    case "vi", "vim":
        return terminalKeyboardCopyModeIndicatorText
    default:
        let normalized = trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? terminalKeyTableIndicatorDefaultText : normalized
    }
}

func terminalKeyboardCopyModeInitialViewportRow(
    rows: Int,
    imePointY: Double,
    imeCellHeight: Double,
    topPadding: Double = 0
) -> Int {
    let clampedRows = max(rows, 1)
    guard imeCellHeight > 0 else { return clampedRows - 1 }

    // `ghostty_surface_ime_point` returns a top-origin Y coordinate at the
    // cursor baseline plus one cell-height. Convert that to a zero-based row.
    let estimatedRow = Int(floor(((imePointY - topPadding) / imeCellHeight) - 1))
    return max(0, min(clampedRows - 1, estimatedRow))
}

private func terminalKeyboardCopyModeNormalizedModifiers(
    _ modifierFlags: NSEvent.ModifierFlags
) -> NSEvent.ModifierFlags {
    modifierFlags
        .intersection(.deviceIndependentFlagsMask)
        .subtracting([.numericPad, .function, .capsLock])
}

private func terminalKeyboardCopyModeChars(
    _ charactersIgnoringModifiers: String?
) -> String {
    guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first else {
        return ""
    }
    return String(scalar).lowercased()
}

func terminalKeyboardCopyModeShouldBypassForShortcut(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    let normalized = terminalKeyboardCopyModeNormalizedModifiers(modifierFlags)
    return normalized.contains(.command)
}

func terminalKeyboardCopyModeAction(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool
) -> TerminalKeyboardCopyModeAction? {
    let normalized = terminalKeyboardCopyModeNormalizedModifiers(modifierFlags)
    let chars = terminalKeyboardCopyModeChars(charactersIgnoringModifiers)

    if keyCode == 53 { // Escape
        return .exit
    }

    switch keyCode {
    case 126: // Up
        return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
    case 125: // Down
        return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
    case 123: // Left
        return hasSelection ? .adjustSelection(.left) : nil
    case 124: // Right
        return hasSelection ? .adjustSelection(.right) : nil
    case 116: // Page Up
        return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
    case 121: // Page Down
        return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
    case 115: // Home
        return hasSelection ? .adjustSelection(.home) : .scrollToTop
    case 119: // End
        return hasSelection ? .adjustSelection(.end) : .scrollToBottom
    default:
        break
    }

    if normalized == [.control] {
        if chars == "u" || chars == "\u{15}" {
            return hasSelection ? .adjustSelection(.pageUp) : .scrollHalfPage(-1)
        }
        if chars == "d" || chars == "\u{04}" {
            return hasSelection ? .adjustSelection(.pageDown) : .scrollHalfPage(1)
        }
        if chars == "b" || chars == "\u{02}" {
            return hasSelection ? .adjustSelection(.pageUp) : .scrollPage(-1)
        }
        if chars == "f" || chars == "\u{06}" {
            return hasSelection ? .adjustSelection(.pageDown) : .scrollPage(1)
        }
        if chars == "y" || chars == "\u{19}" {
            return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
        }
        if chars == "e" || chars == "\u{05}" {
            return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
        }
        return nil
    }

    guard normalized.isEmpty || normalized == [.shift] else { return nil }

    switch chars {
    case "q":
        return .exit
    case "v":
        return hasSelection ? .clearSelection : .startSelection
    case "y":
        if normalized == [.shift], !hasSelection {
            return .copyLineAndExit
        }
        return hasSelection ? .copyAndExit : nil
    case "j":
        return hasSelection ? .adjustSelection(.down) : .scrollLines(1)
    case "k":
        return hasSelection ? .adjustSelection(.up) : .scrollLines(-1)
    case "h":
        return hasSelection ? .adjustSelection(.left) : nil
    case "l":
        return hasSelection ? .adjustSelection(.right) : nil
    case "g":
        if normalized == [.shift] {
            return hasSelection ? .adjustSelection(.end) : .scrollToBottom
        }
        // Bare "g" is a prefix key (e.g. gg); handled in resolve.
        return nil
    case "0", "^":
        return hasSelection ? .adjustSelection(.beginningOfLine) : nil
    case "$", "4":
        guard chars == "$" || normalized == [.shift] else { return nil }
        return hasSelection ? .adjustSelection(.endOfLine) : nil
    case "{", "[":
        guard chars == "{" || normalized == [.shift] else { return nil }
        return .jumpToPrompt(-1)
    case "}", "]":
        guard chars == "}" || normalized == [.shift] else { return nil }
        return .jumpToPrompt(1)
    case "/":
        return .startSearch
    case "n":
        return normalized == [.shift] ? .searchPrevious : .searchNext
    default:
        return nil
    }
}

func terminalKeyboardCopyModeResolve(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?,
    modifierFlags: NSEvent.ModifierFlags,
    hasSelection: Bool,
    state: inout TerminalKeyboardCopyModeInputState
) -> TerminalKeyboardCopyModeResolution {
    let normalized = terminalKeyboardCopyModeNormalizedModifiers(modifierFlags)
    let chars = terminalKeyboardCopyModeChars(charactersIgnoringModifiers)

    if keyCode == 53 { // Escape
        state.reset()
        return .perform(.exit, count: 1)
    }

    if state.pendingYankLine {
        if chars == "y", normalized.isEmpty || normalized == [.shift] {
            let count = terminalKeyboardCopyModeClampCount(state.countPrefix ?? 1)
            state.reset()
            return .perform(.copyLineAndExit, count: count)
        }
        // Only `yy`/`Y` are supported as line-yank operators, so cancel the
        // pending yank and treat this key as a fresh command.
        state.pendingYankLine = false
    }

    if state.pendingG {
        if chars == "g", normalized.isEmpty {
            let count = terminalKeyboardCopyModeClampCount(state.countPrefix ?? 1)
            let action: TerminalKeyboardCopyModeAction = hasSelection ? .adjustSelection(.home) : .scrollToTop
            state.reset()
            return .perform(action, count: count)
        }
        // Not `gg`, cancel and treat as fresh command.
        state.pendingG = false
    }

    if normalized.isEmpty,
       let scalar = chars.unicodeScalars.first,
       scalar.isASCII,
       scalar.value >= 48,
       scalar.value <= 57 {
        let digit = Int(scalar.value - 48)
        if digit == 0 {
            if let currentCount = state.countPrefix {
                state.countPrefix = terminalKeyboardCopyModeClampCount(currentCount * 10)
                return .consume
            }
        } else {
            let currentCount = state.countPrefix ?? 0
            state.countPrefix = terminalKeyboardCopyModeClampCount((currentCount * 10) + digit)
            return .consume
        }
    }

    if !hasSelection, chars == "y", normalized.isEmpty {
        state.pendingYankLine = true
        return .consume
    }

    if chars == "g", normalized.isEmpty {
        state.pendingG = true
        return .consume
    }

    guard let action = terminalKeyboardCopyModeAction(
        keyCode: keyCode,
        charactersIgnoringModifiers: charactersIgnoringModifiers,
        modifierFlags: modifierFlags,
        hasSelection: hasSelection
    ) else {
        state.reset()
        return .consume
    }

    let count = terminalKeyboardCopyModeClampCount(state.countPrefix ?? 1)
    state.reset()
    return .perform(action, count: count)
}
