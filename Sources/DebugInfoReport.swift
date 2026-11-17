import AppKit

/// Plain-text app and system details for bug reports. The labels are product names and
/// stay in English on purpose: the text is pasted into issues, not shown in the UI.
enum DebugInfoReport {
    static func text(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> String {
        let info = bundle.infoDictionary ?? [:]
        func value(_ key: String) -> String? {
            guard let string = info[key] as? String, !string.isEmpty else { return nil }
            return string
        }
        let os = processInfo.operatingSystemVersion
        var lines = ["Programa: \(value("CFBundleShortVersionString") ?? "?") (\(value("CFBundleVersion") ?? "?"))"]
        if let commit = value("ProgramaCommit") {
            lines.append("Commit: \(commit)")
        }
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        if let ghostty = ghosttyVersion() {
            lines.append("Ghostty: \(ghostty)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text(), forType: .string)
    }

    /// libghostty's version string carries the GhosttyKit commit, e.g. `1.4.1-main+e4b6b6bc6`.
    private static func ghosttyVersion() -> String? {
        let info = ghostty_info()
        guard info.version_len > 0 else { return nil }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(info.version).assumingMemoryBound(to: UInt8.self),
            count: Int(info.version_len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }
}
