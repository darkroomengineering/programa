import Foundation

/// Preprocesses JSONC (JSON with Comments) text into plain JSON `Data` that
/// `JSONDecoder`/`JSONSerialization` can parse.
///
/// Supports the two JSONC conveniences users actually reach for in hand-edited
/// config files: `//` and `/* */` comments, and trailing commas before a
/// closing `}` or `]`. Both are stripped with a string-literal-aware scanner
/// so a comment marker or trailing comma inside a quoted string is left alone.
///
/// Shared by `ProgramaConfigStore` (`~/.config/programa/programa.json` and
/// project-local `programa.json`/legacy `cmux.json`) and `ProgramaSettingsFileStore`
/// (`~/.config/programa/settings.json`) so both config surfaces accept the
/// same JSONC dialect.
enum JSONCParser {
    static func preprocess(data: Data) throws -> Data {
        let source = try sourceString(from: data)
        let withoutBOM = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        let stripped = try stripComments(from: withoutBOM)
        let normalized = stripTrailingCommas(from: stripped)
        return Data(normalized.utf8)
    }

    private static func sourceString(from data: Data) throws -> String {
        if let encoding = detectedJSONEncoding(for: data),
           let source = String(data: data, encoding: encoding) {
            return source
        }
        if let source = String(data: data, encoding: .utf8) {
            return source
        }

        var convertedString: NSString?
        var usedLossyConversion = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf8.rawValue,
                    String.Encoding.utf16BigEndian.rawValue,
                    String.Encoding.utf16LittleEndian.rawValue,
                    String.Encoding.utf32BigEndian.rawValue,
                    String.Encoding.utf32LittleEndian.rawValue,
                ],
                .useOnlySuggestedEncodingsKey: true,
                .allowLossyKey: false,
            ],
            convertedString: &convertedString,
            usedLossyConversion: &usedLossyConversion
        )

        if let convertedString, !usedLossyConversion.boolValue {
            return convertedString as String
        }
        if encoding != 0, !usedLossyConversion.boolValue {
            let stringEncoding = String.Encoding(rawValue: encoding)
            if let source = String(data: data, encoding: stringEncoding) {
                return source
            }
        }
        throw JSONCError.invalidTextEncoding
    }

    private static func detectedJSONEncoding(for data: Data) -> String.Encoding? {
        let bytes = Array(data.prefix(4))
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        guard bytes.count >= 4 else { return nil }

        switch (bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 0) {
        case (true, true, true, false):
            return .utf32BigEndian
        case (false, true, true, true):
            return .utf32LittleEndian
        case (true, false, true, false):
            return .utf16BigEndian
        case (false, true, false, true):
            return .utf16LittleEndian
        default:
            return nil
        }
    }

    // Both scanners walk Unicode scalars, never `Character`s: Swift merges "\r\n" into one
    // grapheme that never equals "\n", so a Character scan let a `//` comment in a CRLF file
    // swallow the rest of the file. Scalars also keep a combining mark after a quote from
    // hiding the quote.
    private static func stripComments(from source: String) throws -> String {
        let scalars = Array(source.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var inString = false
        var isEscaped = false

        while index < scalars.count {
            let scalar = scalars[index]

            if inString {
                result.append(scalar)
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                inString = true
                result.append(scalar)
                index += 1
                continue
            }

            if scalar == "/", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "/" {
                    index += 2
                    while index < scalars.count && scalars[index] != "\n" && scalars[index] != "\r" {
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    index += 2
                    var didClose = false
                    while index < scalars.count {
                        if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                            index += 2
                            didClose = true
                            break
                        }
                        index += 1
                    }
                    guard didClose else {
                        throw JSONCError.unterminatedBlockComment
                    }
                    continue
                }
            }

            result.append(scalar)
            index += 1
        }

        return String(result)
    }

    private static func stripTrailingCommas(from source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var inString = false
        var isEscaped = false

        while index < scalars.count {
            let scalar = scalars[index]

            if inString {
                result.append(scalar)
                if isEscaped {
                    isEscaped = false
                } else if scalar == "\\" {
                    isEscaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if scalar == "\"" {
                inString = true
                result.append(scalar)
                index += 1
                continue
            }

            if scalar == "," {
                var lookahead = index + 1
                while lookahead < scalars.count && scalars[lookahead].properties.isWhitespace {
                    lookahead += 1
                }
                if lookahead < scalars.count && (scalars[lookahead] == "}" || scalars[lookahead] == "]") {
                    index += 1
                    continue
                }
            }

            result.append(scalar)
            index += 1
        }

        return String(result)
    }

    /// True when any JSON object in `data` (plain JSON, already run through `preprocess`)
    /// repeats a key. Foundation's parsers do not promise which duplicate wins, and the trust
    /// digest (`JSONSerialization`) and command decoding (`JSONDecoder`) are different parsers,
    /// so a config with duplicate keys could be approved as one thing and run as another.
    /// Callers reject such configs outright. Keys compare after JSON unescaping, so `"a"` and
    /// `"\u0061"` count as the same key. Returns false for text that is not well-formed enough
    /// to scan; the real parser reports those errors.
    static func containsDuplicateObjectKeys(_ data: Data) -> Bool {
        guard let source = String(data: data, encoding: .utf8) else { return false }
        let scalars = Array(source.unicodeScalars)
        // One entry per open container: nil for an array, the keys seen so far for an object.
        var stack: [Set<String>?] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "{":
                stack.append(Set<String>())
                index += 1
            case "[":
                stack.append(nil)
                index += 1
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
                index += 1
            case "\"":
                let start = index
                index += 1
                var isEscaped = false
                while index < scalars.count {
                    let current = scalars[index]
                    index += 1
                    if isEscaped {
                        isEscaped = false
                    } else if current == "\\" {
                        isEscaped = true
                    } else if current == "\"" {
                        break
                    }
                }
                var lookahead = index
                while lookahead < scalars.count && scalars[lookahead].properties.isWhitespace {
                    lookahead += 1
                }
                guard lookahead < scalars.count, scalars[lookahead] == ":",
                      let last = stack.indices.last, var keys = stack[last] else { continue }
                var literal = String.UnicodeScalarView()
                literal.append(contentsOf: scalars[start..<index])
                let rawKey = String(literal)
                let key = (try? JSONSerialization.jsonObject(
                    with: Data("[\(rawKey)]".utf8)
                ) as? [String])?.first ?? rawKey
                if keys.contains(key) { return true }
                keys.insert(key)
                stack[last] = keys
            default:
                index += 1
            }
        }
        return false
    }

    enum JSONCError: LocalizedError {
        case invalidTextEncoding
        case unterminatedBlockComment

        var errorDescription: String? {
            switch self {
            case .invalidTextEncoding:
                return "config file text encoding is not supported"
            case .unterminatedBlockComment:
                return "unterminated block comment"
            }
        }
    }
}
