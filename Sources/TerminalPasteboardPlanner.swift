import Foundation
import AppKit

enum TerminalPasteboardInsertionMode {
    case paste
    case drop
}

enum TerminalPasteboardInsertion: Equatable {
    case insertText(String)
    case reject
}

enum TerminalPasteboardPlanner {
    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalPasteboardInsertionMode
    ) -> TerminalPasteboardInsertion {
        switch mode {
        case .paste:
            return planPaste(pasteboard: pasteboard)
        case .drop:
            return planDrop(pasteboard: pasteboard)
        }
    }

    static func plan(fileURLs: [URL]) -> TerminalPasteboardInsertion {
        guard !fileURLs.isEmpty else { return .reject }
        return .insertText(insertedText(for: fileURLs))
    }

    private static func insertedText(for fileURLs: [URL]) -> String {
        fileURLs
            .map { GhosttyPasteboardHelper.escapeForShell($0.path) }
            .joined(separator: " ")
    }

    private static func planPaste(
        pasteboard: NSPasteboard
    ) -> TerminalPasteboardInsertion {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .insertText(insertedText(for: fileURLs))
        }

        if let string = GhosttyPasteboardHelper.stringContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return .insertText(insertedText(for: [imageURL]))
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(GhosttyPasteboardHelper.escapeForShell(rawURL))
        }

        return .reject
    }

    private static func planDrop(
        pasteboard: NSPasteboard
    ) -> TerminalPasteboardInsertion {
        let fileURLs = materializedFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .insertText(insertedText(for: fileURLs))
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(GhosttyPasteboardHelper.escapeForShell(rawURL))
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return .insertText(string)
        }

        return .reject
    }

    private static func materializedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls
        }
        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return [imageURL]
        }
        return []
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return urls.filter(\.isFileURL)
    }
}
