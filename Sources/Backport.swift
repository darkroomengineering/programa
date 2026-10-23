import SwiftUI

// Centralized backports for newer SwiftUI APIs we want to use when available.
struct Backport<Content> {
    let content: Content
}

extension View {
    var backport: Backport<Self> { Backport(content: self) }

    @ViewBuilder
    func safeHelp(_ text: String) -> some View {
        if text.isEmpty {
            self
        } else {
            self.help(text)
        }
    }
}

/// Result type for backported onKeyPress handler
enum BackportKeyPressResult {
    case handled
    case ignored
}

extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        #if canImport(AppKit)
        if #available(macOS 15, *) {
            return content.pointerStyle(style?.official)
        } else {
            return content
        }
        #else
        return content
        #endif
    }

    func onKeyPress(_ key: KeyEquivalent, action: @escaping (EventModifiers) -> BackportKeyPressResult) -> some View {
        #if canImport(AppKit)
        return content.onKeyPress(key, phases: [.down, .repeat], action: { keyPress in
            switch action(keyPress.modifiers) {
            case .handled: return .handled
            case .ignored: return .ignored
            }
        })
        #else
        return content
        #endif
    }
}

enum BackportPointerStyle {
    case link

    #if canImport(AppKit)
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .link: return .link
        }
    }
    #endif
}
