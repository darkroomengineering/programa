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

// MARK: - GhosttyTerminalView Support (split out, Nuclear Review #97; verbatim move)

@_silgen_name("ghostty_surface_clear_selection")
func ghostty_surface_clear_selection_compat(_ surface: ghostty_surface_t) -> Bool

@_silgen_name("ghostty_surface_select_cursor_cell")
func ghostty_surface_select_cursor_cell_compat(_ surface: ghostty_surface_t) -> Bool

#if os(macOS)
func cmuxShouldApplyWindowGlass(
    sidebarBlendMode: String,
    bgGlassEnabled: Bool,
    glassEffectAvailable _: Bool
) -> Bool {
    // Native NSGlassEffectView vs NSVisualEffectView fallback is chosen inside
    // WindowGlassEffect.apply. User settings alone decide whether glass is on.
    sidebarBlendMode == "behindWindow" && bgGlassEnabled
}

func cmuxShouldUseTransparentBackgroundWindow() -> Bool {
    let defaults = UserDefaults.standard
    let sidebarBlendMode = defaults.string(forKey: "sidebarBlendMode") ?? "withinWindow"
    let bgGlassEnabled = defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false
    return cmuxShouldApplyWindowGlass(
        sidebarBlendMode: sidebarBlendMode,
        bgGlassEnabled: bgGlassEnabled,
        glassEffectAvailable: WindowGlassEffect.isAvailable
    )
}

func cmuxShouldUseClearWindowBackground(for opacity: Double) -> Bool {
    cmuxShouldUseTransparentBackgroundWindow() || opacity < 0.999
}

// Widened from private to internal: used by both GhosttyApp.swift and
// GhosttyNSView.swift (Nuclear Review #97 split).
func programaTransparentWindowBaseColor() -> NSColor {
    // A tiny non-zero alpha matches Ghostty's window compositing behavior on macOS and
    // avoids visual artifacts that can happen with a fully clear window background.
    NSColor.white.withAlphaComponent(0.001)
}
#endif

#if DEBUG
private func programaChildExitProbePath() -> String? {
    let env = ProcessInfo.processInfo.environment
    guard env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_SETUP"] == "1",
          let path = env["PROGRAMA_UI_TEST_CHILD_EXIT_KEYBOARD_PATH"],
          !path.isEmpty else {
        return nil
    }
    return path
}

private func programaLoadChildExitProbe(at path: String) -> [String: String] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    return object
}

func programaWriteChildExitProbe(_ updates: [String: String], increments: [String: Int] = [:]) {
    guard let path = programaChildExitProbePath() else { return }
    var payload = programaLoadChildExitProbe(at: path)
    for (key, by) in increments {
        let current = Int(payload[key] ?? "") ?? 0
        payload[key] = String(current + by)
    }
    for (key, value) in updates {
        payload[key] = value
    }
    guard let out = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
}

func programaScalarHex(_ value: String?) -> String {
    guard let value else { return "" }
    return value.unicodeScalars
        .map { String(format: "%04X", $0.value) }
        .joined(separator: ",")
}
#endif

enum GhosttyPasteboardHelper {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
    private static let temporaryImageFilenamePrefix = "clipboard-"
    private static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)
    private static let temporaryImageOwnershipLock = NSLock()
    private static var ownedTemporaryImagePaths: Set<String> = []

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        let htmlText = attributedStringContents(from: pasteboard, type: .html, documentType: .html)
        let rtfText = attributedStringContents(from: pasteboard, type: .rtf, documentType: .rtf)
        let rtfdText = attributedStringContents(from: pasteboard, type: .rtfd, documentType: .rtfd)

        if hasImageData(in: pasteboard),
           let html = pasteboard.string(forType: .html),
           htmlHasNoVisibleText(html) {
            return nil
        }

        if hasImageData(in: pasteboard) {
            if let htmlText { return htmlText }
            if let rtfText { return rtfText }
            return rtfdText
        }

        if let value = plainTextContents(from: pasteboard) {
            return value
        }

        if let htmlText { return htmlText }
        if let rtfText { return rtfText }
        return rtfdText
    }

    static func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        return hasPasteableContents(in: pasteboard)
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    static func escapeForShell(_ value: String) -> String {
        if value.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return shellSingleQuoted(value)
        }
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func attributedStringContents(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> String? {
        let attributed = attributedString(
            from: pasteboard,
            type: type,
            documentType: documentType
        )

        let sanitized = attributed?.string
            .split(separator: objectReplacementCharacter, omittingEmptySubsequences: false)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let sanitized, !sanitized.isEmpty else { return nil }
        return sanitized
    }

    private static func plainTextContents(from pasteboard: NSPasteboard) -> String? {
        for type in pasteboard.types ?? [] {
            guard isPlainTextType(type) else { continue }
            guard let value = pasteboard.string(forType: type), !value.isEmpty else { continue }
            return value
        }

        return nil
    }

    private static func hasPasteableContents(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.html) || types.contains(.rtf) || types.contains(.rtfd) {
            return true
        }
        if types.contains(where: isPlainTextType) {
            return true
        }
        return hasImageData(in: pasteboard)
    }

    private static func isPlainTextType(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string || type == utf8PlainTextType {
            return true
        }

        guard type != .html,
              type != .rtf,
              type != .rtfd,
              type != .fileURL,
              let utType = UTType(type.rawValue) else { return false }

        return utType.conforms(to: .plainText)
    }

    private static func attributedString(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        let data =
            pasteboard.data(forType: type)
            ?? pasteboard.string(forType: type)?.data(using: .utf8)
        guard let data else { return nil }

        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: documentType,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
    }

    private static func rtfdAttachmentImageRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        guard let attributed = attributedString(
            from: pasteboard,
            type: .rtfd,
            documentType: .rtfd
        ) else { return nil }

        var result: (data: Data, fileExtension: String)?
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            guard let attachment = value as? NSTextAttachment else { return }

            if let fileWrapper = attachment.fileWrapper,
               let data = fileWrapper.regularFileContents,
               let imageRepresentation = imageAttachmentRepresentation(
                data: data,
                preferredFilename: fileWrapper.preferredFilename
               ) {
                result = imageRepresentation
                stop.pointee = true
            }
        }

        return result
    }

    private static func imageAttachmentRepresentation(
        data: Data,
        preferredFilename: String?
    ) -> (data: Data, fileExtension: String)? {
        let pathExtension =
            (preferredFilename as NSString?)?.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        if let type = !pathExtension.isEmpty ? UTType(filenameExtension: pathExtension) : nil,
           type.conforms(to: .image),
           let fileExtension = type.preferredFilenameExtension ?? nonEmpty(pathExtension) {
            return (data, fileExtension)
        }

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(imageSource) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let fileExtension = type.preferredFilenameExtension else { return nil }
        return (data, fileExtension)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasImageData(in pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        if types.contains(.tiff) || types.contains(.png) {
            return true
        }

        return types.contains { type in
            guard let utType = UTType(type.rawValue) else { return false }
            return utType.conforms(to: .image)
        }
    }

    private static func directImageRepresentation(
        in pasteboard: NSPasteboard
    ) -> (data: Data, fileExtension: String)? {
        if let pngData = pasteboard.data(forType: .png) {
            return (pngData, "png")
        }

        for type in pasteboard.types ?? [] {
            guard type != .png,
                  type != .tiff,
                  let utType = UTType(type.rawValue),
                  utType.conforms(to: .image),
                  let imageData = pasteboard.data(forType: type),
                  let fileExtension = utType.preferredFilenameExtension,
                  !fileExtension.isEmpty else { continue }
            return (imageData, fileExtension)
        }

        return nil
    }

    private static func htmlHasNoVisibleText(_ html: String) -> Bool {
        let withoutComments = html.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutComments.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let normalized = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
    }

    /// When the clipboard contains only image data (or rich text that resolves to
    /// an attachment-only image), saves it as a temporary image file and returns the
    /// file URL. Returns nil if the clipboard contains text or no image.
    static func saveImageFileURLIfNeeded(
        from pasteboard: NSPasteboard = .general,
        assumeNoText: Bool = false
    ) -> URL? {
        if !assumeNoText && stringContents(from: pasteboard) != nil { return nil }

        let imageData: Data
        let fileExtension: String
        if let directImage = directImageRepresentation(in: pasteboard) {
            imageData = directImage.data
            fileExtension = directImage.fileExtension
        } else if let rtfdAttachment = rtfdAttachmentImageRepresentation(in: pasteboard) {
            imageData = rtfdAttachment.data
            fileExtension = rtfdAttachment.fileExtension
        } else {
            guard hasImageData(in: pasteboard),
                  let image = NSImage(pasteboard: pasteboard),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }
            imageData = pngData
            fileExtension = "png"
        }

        let maxClipboardImageSize = 10 * 1024 * 1024  // 10 MB
        guard imageData.count <= maxClipboardImageSize else {
#if DEBUG
            dlog("terminal.paste.image.rejected reason=tooLarge bytes=\(imageData.count)")
#endif
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())
        let filename = "\(temporaryImageFilenamePrefix)\(timestamp)-\(UUID().uuidString.prefix(8)).\(fileExtension)"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: fileURL)
        } catch {
#if DEBUG
            dlog("terminal.paste.image.writeFailed error=\(error.localizedDescription)")
#endif
            return nil
        }

        registerOwnedTemporaryImageFile(fileURL)
        return fileURL
    }

    /// When the clipboard contains only image data (or rich text that resolves to
    /// an attachment-only image), saves it as a temporary image file and returns the
    /// shell-escaped file path. Returns nil if the clipboard contains text or no image.
    static func saveClipboardImageIfNeeded(
        from pasteboard: NSPasteboard = .general,
        assumeNoText: Bool = false
    ) -> String? {
        saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: assumeNoText)
            .map { escapeForShell($0.path) }
    }

    static func cleanupTransferredTemporaryImageFiles(_ fileURLs: [URL]) {
        for fileURL in fileURLs {
            let normalizedURL = fileURL.standardizedFileURL
            guard normalizedURL.isFileURL,
                  consumeOwnedTemporaryImageFile(normalizedURL) else {
                continue
            }
            try? FileManager.default.removeItem(at: normalizedURL)
        }
    }

    private static func registerOwnedTemporaryImageFile(_ fileURL: URL) {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        ownedTemporaryImagePaths.insert(normalizedPath)
        temporaryImageOwnershipLock.unlock()
    }

    private static func consumeOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let didOwnFile = ownedTemporaryImagePaths.remove(normalizedPath) != nil
        temporaryImageOwnershipLock.unlock()
        return didOwnFile
    }
}

#if DEBUG
func cmuxPasteboardStringContentsForTesting(_ pasteboard: NSPasteboard) -> String? {
    GhosttyPasteboardHelper.stringContents(from: pasteboard)
}

func cmuxPasteboardImageFileURLForTesting(_ pasteboard: NSPasteboard) -> URL? {
    GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard)
}

func cmuxPasteboardImagePathForTesting(_ pasteboard: NSPasteboard) -> String? {
    GhosttyPasteboardHelper.saveClipboardImageIfNeeded(from: pasteboard)
}

func programaResolveQuicklookPathForTesting(
    _ rawText: String,
    cwd: String,
    existingPaths: Set<String>
) -> String? {
    programaResolveQuicklookPath(
        rawText,
        cwd: cwd,
        fileExists: { path in
            existingPaths.contains((path as NSString).standardizingPath)
        }
    )
}
#endif

func programaResolveQuicklookPath(
    _ rawText: String,
    cwd: String?,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> String? {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var seenPaths: Set<String> = []
    for token in programaQuicklookPathCandidates(from: trimmed) {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { continue }

        let expandedToken = (normalizedToken as NSString).expandingTildeInPath
        let candidatePath: String
        if expandedToken.hasPrefix("/") {
            candidatePath = expandedToken
        } else {
            guard let cwd, !cwd.isEmpty else { continue }
            candidatePath = (cwd as NSString).appendingPathComponent(expandedToken)
        }

        let standardizedPath = (candidatePath as NSString).standardizingPath
        guard seenPaths.insert(standardizedPath).inserted else { continue }
        if fileExists(standardizedPath) {
            return standardizedPath
        }
    }

    return nil
}

private func programaQuicklookPathCandidates(from rawText: String) -> [String] {
    var candidates: [String] = []

    func append(_ candidate: String?) {
        guard let candidate else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    append(rawText)

    let unescaped = programaUnescapeShellToken(rawText)
    if unescaped != rawText {
        append(unescaped)
    }

    if let unquoted = programaUnquoteShellToken(rawText) {
        append(unquoted)
        let unescapedUnquoted = programaUnescapeShellToken(unquoted)
        if unescapedUnquoted != unquoted {
            append(unescapedUnquoted)
        }
    }

    return candidates
}

private func programaUnquoteShellToken(_ token: String) -> String? {
    guard token.count >= 2,
          let first = token.first,
          let last = token.last,
          first == last,
          first == "'" || first == "\"" else {
        return nil
    }
    return String(token.dropFirst().dropLast())
}

private func programaUnescapeShellToken(_ token: String) -> String {
    var output = String.UnicodeScalarView()
    output.reserveCapacity(token.unicodeScalars.count)
    var escaping = false

    for scalar in token.unicodeScalars {
        if escaping {
            output.append(scalar)
            escaping = false
            continue
        }

        if scalar == "\\" {
            escaping = true
            continue
        }

        output.append(scalar)
    }

    if escaping {
        output.append(UnicodeScalar(0x5C)!)
    }

    return String(output)
}

func programaVisibleTerminalLines(from text: String, rows: Int) -> [String] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.count > rows {
        return Array(lines.suffix(rows))
    }
    return lines
}

private func programaShellEscapedTokenContainingColumn(
    in line: String,
    column: Int
) -> String? {
    let characters = Array(line)
    guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }

    var index = 0
    while index < characters.count {
        while index < characters.count, characters[index].isWhitespace {
            index += 1
        }
        let start = index

        while index < characters.count {
            let character = characters[index]
            guard character.isWhitespace else {
                index += 1
                continue
            }

            var backslashCount = 0
            var lookbehind = index - 1
            while lookbehind >= start, characters[lookbehind] == "\\" {
                backslashCount += 1
                lookbehind -= 1
            }

            if backslashCount % 2 == 1 {
                index += 1
                continue
            }

            break
        }

        if start < index, column >= start, column < index {
            return String(characters[start..<index])
        }
    }

    return nil
}

private func programaIsHardPathDelimiter(
    in characters: [Character],
    at index: Int
) -> Bool {
    let character = characters[index]
    if character == "\t" || character == "\n" || character == "\r" {
        return true
    }

    guard character.isWhitespace else { return false }
    let previousIsWhitespace = index > 0 && characters[index - 1].isWhitespace
    let nextIsWhitespace = (index + 1) < characters.count && characters[index + 1].isWhitespace
    return previousIsWhitespace || nextIsWhitespace
}

private func programaRawPathSegmentContainingColumn(
    in line: String,
    column: Int
) -> String? {
    let characters = Array(line)
    guard !characters.isEmpty, column >= 0, column < characters.count else { return nil }
    guard !programaIsHardPathDelimiter(in: characters, at: column) else { return nil }

    var start = column
    while start > 0, !programaIsHardPathDelimiter(in: characters, at: start - 1) {
        start -= 1
    }

    var end = column
    while (end + 1) < characters.count, !programaIsHardPathDelimiter(in: characters, at: end + 1) {
        end += 1
    }

    let candidate = String(characters[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    return candidate.isEmpty ? nil : candidate
}

private func programaPathCandidatesContainingColumn(
    in line: String,
    column: Int
) -> [String] {
    var candidates: [String] = []

    func append(_ candidate: String?) {
        guard let candidate else { return }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    append(programaRawPathSegmentContainingColumn(in: line, column: column))
    append(programaShellEscapedTokenContainingColumn(in: line, column: column))

    return candidates
}

func programaResolveVisibleLinePath(
    _ line: String,
    column: Int,
    cwd: String,
    fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
) -> (rawToken: String, path: String)? {
    for rawToken in programaPathCandidatesContainingColumn(in: line, column: column) {
        if let resolvedPath = programaResolveQuicklookPath(rawToken, cwd: cwd, fileExists: fileExists) {
            return (rawToken, resolvedPath)
        }
    }
    return nil
}

enum TerminalOpenURLTarget: Equatable {
    case embeddedBrowser(URL)
    case external(URL)

    var url: URL {
        switch self {
        case let .embeddedBrowser(url), let .external(url):
            return url
        }
    }
}

enum GhosttyDefaultBackgroundUpdateScope: Int {
    case unscoped = 0
    case app = 1
    case surface = 2

    var logLabel: String {
        switch self {
        case .unscoped: return "unscoped"
        case .app: return "app"
        case .surface: return "surface"
        }
    }
}

/// Coalesces Ghostty background notifications so consumers only observe
/// the latest runtime background for a burst of updates.
final class GhosttyDefaultBackgroundNotificationDispatcher {
    private let coalescer: NotificationBurstCoalescer
    private let postNotification: ([AnyHashable: Any]) -> Void
    private var pendingUserInfo: [AnyHashable: Any]?
    private var pendingEventId: UInt64 = 0
    private var pendingSource: String = "unspecified"
    private let logEvent: ((String) -> Void)?

    init(
        delay: TimeInterval = 1.0 / 30.0,
        logEvent: ((String) -> Void)? = nil,
        postNotification: @escaping ([AnyHashable: Any]) -> Void = { userInfo in
            NotificationCenter.default.post(
                name: .ghosttyDefaultBackgroundDidChange,
                object: nil,
                userInfo: userInfo
            )
        }
    ) {
        coalescer = NotificationBurstCoalescer(delay: delay)
        self.logEvent = logEvent
        self.postNotification = postNotification
    }

    func signal(backgroundColor: NSColor, opacity: Double, eventId: UInt64, source: String) {
        let signalOnMain = { [self] in
            pendingEventId = eventId
            pendingSource = source
            pendingUserInfo = [
                GhosttyNotificationKey.backgroundColor: backgroundColor,
                GhosttyNotificationKey.backgroundOpacity: opacity,
                GhosttyNotificationKey.backgroundEventId: NSNumber(value: eventId),
                GhosttyNotificationKey.backgroundSource: source
            ]
            logEvent?(
                "bg notify queued id=\(eventId) source=\(source) color=\(backgroundColor.hexString()) opacity=\(String(format: "%.3f", opacity))"
            )
            coalescer.signal { [self] in
                guard let userInfo = pendingUserInfo else { return }
                let eventId = pendingEventId
                let source = pendingSource
                pendingUserInfo = nil
                logEvent?("bg notify flushed id=\(eventId) source=\(source)")
                logEvent?("bg notify posting id=\(eventId) source=\(source)")
                postNotification(userInfo)
                logEvent?("bg notify posted id=\(eventId) source=\(source)")
            }
        }

        if Thread.isMainThread {
            signalOnMain()
        } else {
            DispatchQueue.main.async(execute: signalOnMain)
        }
    }
}

func resolveTerminalOpenURLTarget(_ rawValue: String) -> TerminalOpenURLTarget? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    #if DEBUG
    dlog("link.resolve input=\(trimmed)")
    #endif
    guard !trimmed.isEmpty else {
        #if DEBUG
        dlog("link.resolve result=nil (empty)")
        #endif
        return nil
    }

    if NSString(string: trimmed).isAbsolutePath {
        #if DEBUG
        dlog("link.resolve result=external(absolutePath) url=\(trimmed)")
        #endif
        return .external(URL(fileURLWithPath: trimmed))
    }

    if let parsed = URL(string: trimmed),
       let scheme = parsed.scheme?.lowercased() {
        if scheme == "http" || scheme == "https" {
            guard BrowserInsecureHTTPSettings.normalizeHost(parsed.host ?? "") != nil else {
                #if DEBUG
                dlog("link.resolve result=external(invalidHost) url=\(parsed)")
                #endif
                return .external(parsed)
            }
            #if DEBUG
            dlog("link.resolve result=embeddedBrowser url=\(parsed)")
            #endif
            return .embeddedBrowser(parsed)
        }
        #if DEBUG
        dlog("link.resolve result=external(scheme=\(scheme)) url=\(parsed)")
        #endif
        return .external(parsed)
    }

    if let webURL = resolveBrowserNavigableURL(trimmed) {
        guard BrowserInsecureHTTPSettings.normalizeHost(webURL.host ?? "") != nil else {
            #if DEBUG
            dlog("link.resolve result=external(bareHost-invalidHost) url=\(webURL)")
            #endif
            return .external(webURL)
        }
        #if DEBUG
        dlog("link.resolve result=embeddedBrowser(bareHost) url=\(webURL)")
        #endif
        return .embeddedBrowser(webURL)
    }

    guard let fallback = URL(string: trimmed) else {
        #if DEBUG
        dlog("link.resolve result=nil (unparseable)")
        #endif
        return nil
    }
    #if DEBUG
    dlog("link.resolve result=external(fallback) url=\(fallback)")
    #endif
    return .external(fallback)
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let surfaceId = "ghostty.surfaceId"
    static let title = "ghostty.title"
    static let backgroundColor = "ghostty.backgroundColor"
    static let backgroundOpacity = "ghostty.backgroundOpacity"
    static let backgroundEventId = "ghostty.backgroundEventId"
    static let backgroundSource = "ghostty.backgroundSource"
}

extension Notification.Name {
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttyDidReceiveWheelScroll = Notification.Name("ghosttyDidReceiveWheelScroll")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")
    static let ghosttyDefaultBackgroundDidChange = Notification.Name("ghosttyDefaultBackgroundDidChange")
    static let browserSearchFocus = Notification.Name("browserSearchFocus")
}
