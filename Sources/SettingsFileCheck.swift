import Foundation

/// One problem in settings.json: a value the app skipped, or the whole file when it failed to
/// parse. `config check` prints these and the main window shows how many there are.
struct ProgramaSettingsFileProblem: Equatable {
    /// Dotted path of the skipped key, such as `app.appearance`; nil for a whole-file problem.
    let keyPath: String?
    let message: String
    /// 1-based line of the key in the file, when it could be found.
    let line: Int?

    func withLine(_ line: Int?) -> ProgramaSettingsFileProblem {
        ProgramaSettingsFileProblem(keyPath: keyPath, message: message, line: line)
    }

    /// `settings.json:12: app.appearance: expected ...`, the form editors and terminals link.
    func formattedLine(fileName: String) -> String {
        var parts = [fileName]
        if let line { parts.append(String(line)) }
        var text = parts.joined(separator: ":") + ": "
        if let keyPath { text += keyPath + ": " }
        return text + message
    }

    static func sortsBefore(_ lhs: ProgramaSettingsFileProblem, _ rhs: ProgramaSettingsFileProblem) -> Bool {
        switch (lhs.line, rhs.line) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return (lhs.keyPath ?? "") < (rhs.keyPath ?? "")
        }
    }
}

/// Finds the line of each object key in a JSONC file, skipping comments and string contents, so
/// a problem can point at the key that caused it. Keys inside arrays are not indexed.
struct SettingsFileKeyLocator {
    private var lineByKeyPath: [String: Int] = [:]

    init(data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        index(Array(text.unicodeScalars))
    }

    /// The line of `keyPath`, or of its nearest parent that is in the file.
    func line(forKeyPath keyPath: String?) -> Int? {
        guard var components = keyPath?.split(separator: ".").map(String.init) else { return nil }
        while !components.isEmpty {
            if let line = lineByKeyPath[components.joined(separator: ".")] { return line }
            components.removeLast()
        }
        return nil
    }

    static func line(atByteOffset offset: Int, in data: Data) -> Int {
        var line = 1
        var previous: UInt8 = 0
        for byte in data.prefix(max(0, offset)) {
            if byte == UInt8(ascii: "\n") {
                if previous != UInt8(ascii: "\r") { line += 1 }
            } else if byte == UInt8(ascii: "\r") {
                line += 1
            }
            previous = byte
        }
        return line
    }

    private enum Container {
        /// `path` is nil inside an array, where keys are not indexed.
        case object(path: [String]?, expectingKey: Bool, lastKey: String?)
        case array
    }

    private mutating func index(_ scalars: [Unicode.Scalar]) {
        var stack: [Container] = []
        var line = 1
        var position = 0

        func childPath() -> [String]? {
            guard case .object(let path?, _, let lastKey?)? = stack.last else { return nil }
            return path + [lastKey]
        }

        while position < scalars.count {
            let scalar = scalars[position]
            let next: Unicode.Scalar? = position + 1 < scalars.count ? scalars[position + 1] : nil
            switch scalar {
            case "\r":
                line += 1
                if next == "\n" { position += 1 }
            case "\n":
                line += 1
            case "/" where next == "/":
                while position + 1 < scalars.count, scalars[position + 1] != "\n", scalars[position + 1] != "\r" {
                    position += 1
                }
            case "/" where next == "*":
                position += 2
                while position < scalars.count, !(scalars[position] == "*" && position + 1 < scalars.count && scalars[position + 1] == "/") {
                    let following: Unicode.Scalar? = position + 1 < scalars.count ? scalars[position + 1] : nil
                    if scalars[position] == "\n" || (scalars[position] == "\r" && following != "\n") {
                        line += 1
                    }
                    position += 1
                }
                position += 1
            case "\"":
                let startLine = line
                var value = String.UnicodeScalarView()
                position += 1
                while position < scalars.count, scalars[position] != "\"" {
                    if scalars[position] == "\\", position + 1 < scalars.count { position += 1 }
                    value.append(scalars[position])
                    position += 1
                }
                if case .object(let path, true, _)? = stack.last {
                    let key = String(value)
                    if let path { lineByKeyPath[(path + [key]).joined(separator: ".")] = startLine }
                    stack[stack.count - 1] = .object(path: path, expectingKey: false, lastKey: key)
                }
            case "{":
                stack.append(.object(path: stack.isEmpty ? [] : childPath(), expectingKey: true, lastKey: nil))
            case "[":
                stack.append(.array)
            case "}", "]":
                if !stack.isEmpty { stack.removeLast() }
            case ",":
                if case .object(let path, _, let lastKey)? = stack.last {
                    stack[stack.count - 1] = .object(path: path, expectingKey: true, lastKey: lastKey)
                }
            default:
                break
            }
            position += 1
        }
    }
}

/// Headless mode of the app binary behind `programa config check`: the CLI runs
/// `Programa --check-settings [PATH]`, so the check uses the same parser as the running app.
/// It reads the file only: it never builds `ProgramaSettingsFileStore`, so nothing is
/// bootstrapped and no setting is applied.
enum SettingsFileCheck {
    static let launchArgument = "--check-settings"

    /// Exits 0 when the file is valid or absent, 1 when it has problems, 2 when an explicit
    /// path does not exist. Returns without doing anything unless the argument is present.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let flagIndex = arguments.firstIndex(of: launchArgument) else { return }
        let explicitPath = arguments.indices.contains(flagIndex + 1) ? arguments[flagIndex + 1] : nil
        exit(run(explicitPath: explicitPath))
    }

    private static func run(explicitPath: String?) -> Int32 {
        let fileManager = FileManager.default
        let path: String
        if let explicitPath {
            path = (explicitPath as NSString).expandingTildeInPath
            guard fileManager.fileExists(atPath: path) else {
                FileHandle.standardError.write(Data("No settings file at \(path)\n".utf8))
                return 2
            }
        } else {
            // The same file the app loads: the primary path, else the Application Support fallback.
            let candidates = [ProgramaSettingsFileStore.defaultPrimaryPath, ProgramaSettingsFileStore.defaultFallbackPath]
            guard let found = candidates.compactMap({ $0 }).first(where: fileManager.fileExists(atPath:)) else {
                print("No settings.json at \(ProgramaSettingsFileStore.defaultPrimaryPath); the defaults are in use")
                return 0
            }
            path = found
        }

        let fileName = (path as NSString).lastPathComponent
        let problems = ProgramaSettingsFileStore.problems(inFileAt: path, fileManager: fileManager) ?? []
        guard !problems.isEmpty else {
            print("\(fileName) is valid")
            return 0
        }
        for problem in problems {
            print(problem.formattedLine(fileName: fileName))
        }
        return 1
    }
}
