import Foundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

extension ProgramaCLI {
    func runBrowserCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        guard !commandArgs.isEmpty else {
            throw CLIError(message: "browser requires a subcommand")
        }

        var effectiveJSONOutput = jsonOutput
        var effectiveIDFormat = idFormat
        var browserArgs = commandArgs

        // Browser-skill examples often place output flags at the end of the command.
        // Strip trailing display flags so they don't become part of a URL or selector.
        var valueOrLiteralIndices: Set<Int> = []
        var argumentIndex = 0
        while argumentIndex < browserArgs.count {
            let arg = browserArgs[argumentIndex]
            if arg == "--" {
                valueOrLiteralIndices.formUnion(argumentIndex..<browserArgs.count)
                break
            }
            if ["--surface", "--selector", "--text", "--id-format"].contains(arg),
               argumentIndex + 1 < browserArgs.count {
                valueOrLiteralIndices.insert(argumentIndex + 1)
                argumentIndex += 2
            } else {
                argumentIndex += 1
            }
        }
        while !browserArgs.isEmpty {
            if browserArgs.last == "--json",
               !valueOrLiteralIndices.contains(browserArgs.count - 1) {
                effectiveJSONOutput = true
                browserArgs.removeLast()
                continue
            }

            if browserArgs.count >= 2,
               browserArgs[browserArgs.count - 2] == "--id-format",
               !valueOrLiteralIndices.contains(browserArgs.count - 2) {
                let raw = browserArgs.last!
                guard let parsed = try CLIIDFormat.parse(raw) else {
                    throw CLIError(message: "--id-format must be one of: refs, uuids, both")
                }
                effectiveIDFormat = parsed
                browserArgs.removeLast(2)
                continue
            }

            break
        }

        var surfaceRaw: String?
        var args: [String] = []
        argumentIndex = 0
        while argumentIndex < browserArgs.count {
            if browserArgs[argumentIndex] == "--surface",
               !valueOrLiteralIndices.contains(argumentIndex),
               argumentIndex + 1 < browserArgs.count {
                surfaceRaw = browserArgs[argumentIndex + 1]
                argumentIndex += 2
            } else {
                args.append(browserArgs[argumentIndex])
                argumentIndex += 1
            }
        }

        let verbsWithoutSurface: Set<String> = ["open", "open-split", "new", "identify"]
        if surfaceRaw == nil, let first = args.first {
            if !first.hasPrefix("-") && !verbsWithoutSurface.contains(first.lowercased()) {
                surfaceRaw = first
                args = Array(args.dropFirst())
            }
        }

        guard let subcommandRaw = args.first else {
            throw CLIError(message: "browser requires a subcommand")
        }
        let subcommand = subcommandRaw.lowercased()
        let subArgs = Array(args.dropFirst())

        func requireSurface() throws -> String {
            guard let raw = surfaceRaw else {
                throw CLIError(message: "browser \(subcommand) requires a surface handle (use: browser <surface> \(subcommand) ... or --surface)")
            }
            guard let resolved = try normalizeSurfaceHandle(raw, client: client) else {
                throw CLIError(message: "Invalid surface handle")
            }
            return resolved
        }

        func output(_ payload: [String: Any], fallback: String) {
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                return
            }
            print(fallback)
            if let snapshot = payload["post_action_snapshot"] as? String,
               !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print(snapshot)
            }
        }

        func displaySnapshotText(_ payload: [String: Any]) -> String {
            let snapshotText = (payload["snapshot"] as? String) ?? "Empty page"
            guard snapshotText.contains("\n- (empty)") else {
                return snapshotText
            }

            let url = ((payload["url"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let readyState = ((payload["ready_state"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var lines = [snapshotText]

            if !url.isEmpty {
                lines.append("url: \(url)")
            }
            if !readyState.isEmpty {
                lines.append("ready_state: \(readyState)")
            }
            if url.isEmpty || url == "about:blank" {
                lines.append("hint: run 'programa browser <surface> get url' to verify navigation")
            }

            return lines.joined(separator: "\n")
        }

        func displayBrowserValue(_ value: Any) -> String {
            if let dict = value as? [String: Any],
               let type = dict["__programa_t"] as? String,
               type == "undefined" {
                return "undefined"
            }
            if value is NSNull {
                return "null"
            }
            if let string = value as? String {
                return string
            }
            if let bool = value as? Bool {
                return bool ? "true" : "false"
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }

        func displayBrowserLogItems(_ value: Any?) -> String? {
            guard let items = value as? [Any], !items.isEmpty else {
                return nil
            }

            let lines = items.map { item -> String in
                guard let dict = item as? [String: Any] else {
                    return displayBrowserValue(item)
                }

                let text = (dict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let levelRaw = (dict["level"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let level = levelRaw.isEmpty ? "log" : levelRaw

                if text.isEmpty {
                    if let message = (dict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !message.isEmpty {
                        return "[error] \(message)"
                    }
                    return displayBrowserValue(dict)
                }
                return "[\(level)] \(text)"
            }

            return lines.joined(separator: "\n")
        }
        func nonFlagArgs(_ values: [String]) -> [String] {
            values.filter { !$0.hasPrefix("-") }
        }

        if subcommand == "identify" {
            let surface = try normalizeSurfaceHandle(surfaceRaw, client: client, allowFocused: true)
            var payload = try client.sendV2(method: V2MethodNames.systemIdentify)
            if let surface {
                let urlPayload = try client.sendV2(method: V2MethodNames.browserUrlGet, params: ["surface_id": surface])
                let titlePayload = try client.sendV2(method: V2MethodNames.browserGetTitle, params: ["surface_id": surface])
                var browser: [String: Any] = [:]
                browser["surface"] = surface
                browser["url"] = urlPayload["url"] ?? ""
                browser["title"] = titlePayload["title"] ?? ""
                payload["browser"] = browser
            }
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "open" || subcommand == "open-split" || subcommand == "new" {
            // Parse routing flags before URL assembly so they never leak into the URL string.
            let (workspaceOpt, argsAfterWorkspace) = parseOption(subArgs, name: "--workspace")
            let (windowOpt, urlArgs) = parseOption(argsAfterWorkspace, name: "--window")
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let respectExternalOpenRules: Bool = {
                guard let raw = ProcessInfo.processInfo.environment["PROGRAMA_RESPECT_EXTERNAL_OPEN_RULES"] else {
                    return false
                }
                switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes", "on":
                    return true
                default:
                    return false
                }
            }()

            if surfaceRaw != nil, subcommand == "open" {
                // Treat `browser <surface> open <url>` as navigate for agent-browser ergonomics.
                let sid = try requireSurface()
                guard !url.isEmpty else {
                    throw CLIError(message: "browser <surface> open requires a URL")
                }
                let payload = try client.sendV2(method: V2MethodNames.browserNavigate, params: ["surface_id": sid, "url": url])
                output(payload, fallback: "OK")
                return
            }

            var params: [String: Any] = [:]
            if !url.isEmpty {
                params["url"] = url
            }
            if let sourceSurface = try normalizeSurfaceHandle(surfaceRaw, client: client) {
                params["surface_id"] = sourceSurface
            }
            let workspaceRaw = workspaceOpt ?? (windowOpt == nil ? ProcessInfo.processInfo.environment["PROGRAMA_WORKSPACE_ID"] : nil)
            if let workspaceRaw {
                if let workspace = try normalizeWorkspaceHandle(workspaceRaw, client: client) {
                    params["workspace_id"] = workspace
                }
            }
            if respectExternalOpenRules {
                params["respect_external_open_rules"] = true
            }
            if let windowRaw = windowOpt {
                if let window = try normalizeWindowHandle(windowRaw, client: client) {
                    params["window_id"] = window
                }
            }
            let payload = try client.sendV2(method: V2MethodNames.browserOpenSplit, params: params)
            let surfaceText = formatHandle(payload, kind: "surface", idFormat: effectiveIDFormat) ?? "unknown"
            let paneText = formatHandle(payload, kind: "pane", idFormat: effectiveIDFormat) ?? "unknown"
            let placement = ((payload["created_split"] as? Bool) == true) ? "split" : "reuse"
            output(payload, fallback: "OK surface=\(surfaceText) pane=\(paneText) placement=\(placement)")
            return
        }

        if subcommand == "goto" || subcommand == "navigate" {
            let sid = try requireSurface()
            var urlArgs = subArgs
            let snapshotAfter = urlArgs.last == "--snapshot-after"
            if snapshotAfter {
                urlArgs.removeLast()
            }
            let url = urlArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires a URL")
            }
            var params: [String: Any] = ["surface_id": sid, "url": url]
            if snapshotAfter {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: V2MethodNames.browserNavigate, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "back" || subcommand == "forward" || subcommand == "reload" {
            let sid = try requireSurface()
            let methodMap: [String: String] = [
                "back": V2MethodNames.browserBack,
                "forward": V2MethodNames.browserForward,
                "reload": V2MethodNames.browserReload,
            ]
            var params: [String: Any] = ["surface_id": sid]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "url" || subcommand == "get-url" {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: V2MethodNames.browserUrlGet, params: ["surface_id": sid])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print((payload["url"] as? String) ?? "")
            }
            return
        }

        if ["focus-webview", "focus_webview"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: V2MethodNames.browserFocusWebview, params: ["surface_id": sid])
            output(payload, fallback: "OK")
            return
        }

        if ["is-webview-focused", "is_webview_focused"].contains(subcommand) {
            let sid = try requireSurface()
            let payload = try client.sendV2(method: V2MethodNames.browserIsWebviewFocused, params: ["surface_id": sid])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print((payload["focused"] as? Bool) == true ? "true" : "false")
            }
            return
        }

        if subcommand == "snapshot" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (depthOpt, _) = parseOption(rem1, name: "--max-depth")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }
            if hasFlag(subArgs, name: "--interactive") || hasFlag(subArgs, name: "-i") {
                params["interactive"] = true
            }
            if hasFlag(subArgs, name: "--cursor") {
                params["cursor"] = true
            }
            if hasFlag(subArgs, name: "--compact") {
                params["compact"] = true
            }
            if let depthOpt {
                guard let depth = Int(depthOpt), depth >= 0 else {
                    throw CLIError(message: "--max-depth must be a non-negative integer")
                }
                params["max_depth"] = depth
            }

            let payload = try client.sendV2(method: V2MethodNames.browserSnapshot, params: params)
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else {
                print(displaySnapshotText(payload))
            }
            return
        }

        if subcommand == "eval" {
            let sid = try requireSurface()
            let script = optionValue(subArgs, name: "--script") ?? subArgs.joined(separator: " ")
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw CLIError(message: "browser eval requires a script")
            }
            let payload = try client.sendV2(method: V2MethodNames.browserEval, params: ["surface_id": sid, "script": trimmed])
            let fallback: String
            if let value = payload["value"] {
                fallback = displayBrowserValue(value)
            } else {
                fallback = "OK"
            }
            output(payload, fallback: fallback)
            return
        }

        if subcommand == "wait" {
            let sid = try requireSurface()
            var params: [String: Any] = ["surface_id": sid]

            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (textOpt, rem2) = parseOption(rem1, name: "--text")
            let (urlContainsOptA, rem3) = parseOption(rem2, name: "--url-contains")
            let (urlContainsOptB, rem4) = parseOption(rem3, name: "--url")
            let (loadStateOpt, rem5) = parseOption(rem4, name: "--load-state")
            let (functionOpt, rem6) = parseOption(rem5, name: "--function")
            let (timeoutOptMs, rem7) = parseOption(rem6, name: "--timeout-ms")
            let (timeoutOptSec, rem8) = parseOption(rem7, name: "--timeout")

            if let selector = selectorOpt ?? rem8.first {
                params["selector"] = selector
            }
            if let textOpt {
                params["text_contains"] = textOpt
            }
            if let urlContains = urlContainsOptA ?? urlContainsOptB {
                params["url_contains"] = urlContains
            }
            if let loadStateOpt {
                params["load_state"] = loadStateOpt
            }
            if let functionOpt {
                params["function"] = functionOpt
            }
            if let timeoutOptMs {
                guard let ms = Int(timeoutOptMs) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = ms
            } else if let timeoutOptSec {
                guard let seconds = Double(timeoutOptSec) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: V2MethodNames.browserWait, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["click", "dblclick", "hover", "focus", "check", "uncheck", "scrollintoview", "scrollinto", "scroll-into-view"].contains(subcommand) {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }
            let methodMap: [String: String] = [
                "click": V2MethodNames.browserClick,
                "dblclick": V2MethodNames.browserDblclick,
                "hover": V2MethodNames.browserHover,
                "focus": V2MethodNames.browserFocus,
                "check": V2MethodNames.browserCheck,
                "uncheck": V2MethodNames.browserUncheck,
                "scrollintoview": V2MethodNames.browserScrollIntoView,
                "scrollinto": V2MethodNames.browserScrollIntoView,
                "scroll-into-view": V2MethodNames.browserScrollIntoView,
            ]
            var params: [String: Any] = ["surface_id": sid, "selector": selector]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["type", "fill"].contains(subcommand) {
            let sid = try requireSurface()
            var selectorOpt: String?
            var textOpt: String?
            var inputArgs: [String] = []
            var snapshotAfter = false
            var pastTerminator = false
            var index = 0
            while index < subArgs.count {
                let arg = subArgs[index]
                if !pastTerminator, arg == "--" {
                    pastTerminator = true
                } else if !pastTerminator, arg == "--selector" || arg == "--text" {
                    guard index + 1 < subArgs.count else {
                        throw CLIError(message: "browser \(subcommand): \(arg) requires a value")
                    }
                    if arg == "--selector" {
                        selectorOpt = subArgs[index + 1]
                    } else {
                        textOpt = subArgs[index + 1]
                    }
                    index += 1
                } else if !pastTerminator, arg == "--snapshot-after" {
                    snapshotAfter = true
                } else {
                    inputArgs.append(arg)
                }
                index += 1
            }
            let selector = selectorOpt ?? inputArgs.first
            guard let selector else {
                throw CLIError(message: "browser \(subcommand) requires a selector")
            }

            let positional = selectorOpt != nil ? inputArgs : Array(inputArgs.dropFirst())
            let hasExplicitText = textOpt != nil || !positional.isEmpty
            let text: String
            if let textOpt {
                text = textOpt
            } else {
                text = positional.joined(separator: " ")
            }
            if subcommand == "type" {
                guard hasExplicitText, !text.isEmpty else {
                    throw CLIError(message: "browser type requires text")
                }
            }

            let method = (subcommand == "type") ? V2MethodNames.browserType : V2MethodNames.browserFill
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "text": text]
            if snapshotAfter {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if ["press", "key", "keydown", "keyup"].contains(subcommand) {
            let sid = try requireSurface()
            let (keyOpt, rem1) = parseOption(subArgs, name: "--key")
            let key = keyOpt ?? rem1.first
            guard let key else {
                throw CLIError(message: "browser \(subcommand) requires a key")
            }
            let methodMap: [String: String] = [
                "press": V2MethodNames.browserPress,
                "key": V2MethodNames.browserPress,
                "keydown": V2MethodNames.browserKeydown,
                "keyup": V2MethodNames.browserKeyup,
            ]
            var params: [String: Any] = ["surface_id": sid, "key": key]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: methodMap[subcommand]!, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "select" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let selector = selectorOpt ?? rem2.first
            guard let selector else {
                throw CLIError(message: "browser select requires a selector")
            }
            let value = valueOpt ?? (selectorOpt != nil ? rem2.first : rem2.dropFirst().first)
            guard let value else {
                throw CLIError(message: "browser select requires a value")
            }
            var params: [String: Any] = ["surface_id": sid, "selector": selector, "value": value]
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }
            let payload = try client.sendV2(method: V2MethodNames.browserSelect, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "scroll" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let (dxOpt, rem2) = parseOption(rem1, name: "--dx")
            let (dyOpt, rem3) = parseOption(rem2, name: "--dy")

            var params: [String: Any] = ["surface_id": sid]
            if let selectorOpt {
                params["selector"] = selectorOpt
            }

            if let dxOpt {
                guard let dx = Int(dxOpt) else {
                    throw CLIError(message: "--dx must be an integer")
                }
                params["dx"] = dx
            }
            if let dyOpt {
                guard let dy = Int(dyOpt) else {
                    throw CLIError(message: "--dy must be an integer")
                }
                params["dy"] = dy
            } else if let first = rem3.first, let dy = Int(first) {
                params["dy"] = dy
            }
            if hasFlag(subArgs, name: "--snapshot-after") {
                params["snapshot_after"] = true
            }

            let payload = try client.sendV2(method: V2MethodNames.browserScroll, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "screenshot" {
            let sid = try requireSurface()
            let (outPathOpt, _) = parseOption(subArgs, name: "--out")
            let localJSONOutput = hasFlag(subArgs, name: "--json")
            let outputAsJSON = effectiveJSONOutput || localJSONOutput
            var payload = try client.sendV2(method: V2MethodNames.browserScreenshot, params: ["surface_id": sid])

            func fileURL(fromPath rawPath: String) -> URL {
                let resolvedPath = resolvePath(rawPath)
                return URL(fileURLWithPath: resolvedPath).standardizedFileURL
            }

            func writeScreenshot(_ data: Data, to destinationURL: URL) throws {
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            }

            func hasText(_ value: String?) -> Bool {
                guard let value else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            var screenshotPath = payload["path"] as? String
            var screenshotURL = payload["url"] as? String

            func syncScreenshotLocationFields() {
                if !hasText(screenshotPath),
                   let rawURL = screenshotURL,
                   let fileURL = URL(string: rawURL),
                   fileURL.isFileURL,
                   !fileURL.path.isEmpty {
                    screenshotPath = fileURL.path
                }
                if !hasText(screenshotURL),
                   let screenshotPath,
                   hasText(screenshotPath) {
                    screenshotURL = URL(fileURLWithPath: screenshotPath).standardizedFileURL.absoluteString
                }
                if let screenshotPath, hasText(screenshotPath) {
                    payload["path"] = screenshotPath
                }
                if let screenshotURL, hasText(screenshotURL) {
                    payload["url"] = screenshotURL
                }
            }

            func persistPayloadScreenshot(to destinationURL: URL, allowFailure: Bool) throws -> Bool {
                if let sourcePath = screenshotPath, hasText(sourcePath) {
                    let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
                    do {
                        if sourceURL.path != destinationURL.path {
                            try FileManager.default.createDirectory(
                                at: destinationURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                            try? FileManager.default.removeItem(at: destinationURL)
                            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        }
                        return true
                    } catch {
                        if payload["png_base64"] == nil {
                            if allowFailure {
                                return false
                            }
                            throw error
                        }
                    }
                }

                if let b64 = payload["png_base64"] as? String,
                   let data = Data(base64Encoded: b64) {
                    do {
                        try writeScreenshot(data, to: destinationURL)
                        return true
                    } catch {
                        if allowFailure {
                            return false
                        }
                        throw error
                    }
                }

                return false
            }

            if let outPathOpt {
                let outputURL = fileURL(fromPath: outPathOpt)
                guard try persistPayloadScreenshot(to: outputURL, allowFailure: false) else {
                    throw CLIError(message: "browser screenshot missing image data")
                }
                screenshotPath = outputURL.path
                screenshotURL = outputURL.absoluteString
                payload["path"] = screenshotPath
                payload["url"] = screenshotURL
            } else {
                syncScreenshotLocationFields()
                if !hasText(screenshotPath) && !hasText(screenshotURL) {
                    let outputDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("programa-browser-screenshots-cli", isDirectory: true)
                    if (try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)) != nil {
                        bestEffortPruneTemporaryFiles(in: outputDir)
                        let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
                        let safeSid = sanitizedFilenameComponent(sid)
                        let filename = "surface-\(safeSid)-\(timestampMs)-\(String(UUID().uuidString.prefix(8))).png"
                        let outputURL = outputDir.appendingPathComponent(filename, isDirectory: false)
                        if (try? persistPayloadScreenshot(to: outputURL, allowFailure: true)) == true {
                            screenshotPath = outputURL.path
                            screenshotURL = outputURL.absoluteString
                            payload["path"] = screenshotPath
                            payload["url"] = screenshotURL
                        }
                    }
                }
            }

            if outputAsJSON {
                let formattedPayload = formatIDs(payload, mode: effectiveIDFormat)
                if var outputPayload = formattedPayload as? [String: Any] {
                    if hasText(screenshotPath) || hasText(screenshotURL) {
                        outputPayload.removeValue(forKey: "png_base64")
                    }
                    print(jsonString(outputPayload))
                } else {
                    print(jsonString(formattedPayload))
                }
            } else if let outPathOpt {
                print("OK \(outPathOpt)")
            } else if let screenshotURL,
                      hasText(screenshotURL) {
                print("OK \(screenshotURL)")
            } else if let screenshotPath,
                      hasText(screenshotPath) {
                print("OK \(screenshotPath)")
            } else {
                print("OK")
            }
            return
        }

        if subcommand == "get" {
            let sid = try requireSurface()
            guard let getVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser get requires a subcommand")
            }
            let getArgs = Array(subArgs.dropFirst())

            switch getVerb {
            case "url":
                let payload = try client.sendV2(method: V2MethodNames.browserUrlGet, params: ["surface_id": sid])
                output(payload, fallback: (payload["url"] as? String) ?? "")
            case "title":
                let payload = try client.sendV2(method: V2MethodNames.browserGetTitle, params: ["surface_id": sid])
                output(payload, fallback: (payload["title"] as? String) ?? "")
            case "text", "html", "value", "count", "box", "styles", "attr":
                let (selectorOpt, rem1) = parseOption(getArgs, name: "--selector")
                let selector = selectorOpt ?? rem1.first
                if getVerb != "title" && getVerb != "url" {
                    guard selector != nil else {
                        throw CLIError(message: "browser get \(getVerb) requires a selector")
                    }
                }
                var params: [String: Any] = ["surface_id": sid]
                if let selector {
                    params["selector"] = selector
                }
                if getVerb == "attr" {
                    let (attrOpt, rem2) = parseOption(rem1, name: "--attr")
                    let attr = attrOpt ?? rem2.dropFirst().first
                    guard let attr else {
                        throw CLIError(message: "browser get attr requires --attr <name>")
                    }
                    params["attr"] = attr
                }
                if getVerb == "styles" {
                    let (propOpt, _) = parseOption(rem1, name: "--property")
                    if let propOpt {
                        params["property"] = propOpt
                    }
                }

                let methodMap: [String: String] = [
                    "text": V2MethodNames.browserGetText,
                    "html": V2MethodNames.browserGetHtml,
                    "value": V2MethodNames.browserGetValue,
                    "attr": V2MethodNames.browserGetAttr,
                    "count": V2MethodNames.browserGetCount,
                    "box": V2MethodNames.browserGetBox,
                    "styles": V2MethodNames.browserGetStyles,
                ]
                let payload = try client.sendV2(method: methodMap[getVerb]!, params: params)
                if effectiveJSONOutput {
                    print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
                } else if let value = payload["value"] {
                    if let str = value as? String {
                        print(str)
                    } else {
                        print(jsonString(value))
                    }
                } else if let count = payload["count"] {
                    print("\(count)")
                } else {
                    print("OK")
                }
            default:
                throw CLIError(message: "Unsupported browser get subcommand: \(getVerb)")
            }
            return
        }

        if subcommand == "is" {
            let sid = try requireSurface()
            guard let isVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser is requires a subcommand")
            }
            let isArgs = Array(subArgs.dropFirst())
            let (selectorOpt, rem1) = parseOption(isArgs, name: "--selector")
            let selector = selectorOpt ?? rem1.first
            guard let selector else {
                throw CLIError(message: "browser is \(isVerb) requires a selector")
            }

            let methodMap: [String: String] = [
                "visible": V2MethodNames.browserIsVisible,
                "enabled": V2MethodNames.browserIsEnabled,
                "checked": V2MethodNames.browserIsChecked,
            ]
            guard let method = methodMap[isVerb] else {
                throw CLIError(message: "Unsupported browser is subcommand: \(isVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid, "selector": selector])
            if effectiveJSONOutput {
                print(jsonString(formatIDs(payload, mode: effectiveIDFormat)))
            } else if let value = payload["value"] {
                print("\(value)")
            } else {
                print("false")
            }
            return
        }


        if subcommand == "find" {
            let sid = try requireSurface()
            guard let locator = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser find requires a locator (role|text|label|placeholder|alt|title|testid|first|last|nth)")
            }
            let locatorArgs = Array(subArgs.dropFirst())

            var params: [String: Any] = ["surface_id": sid]
            let method: String

            switch locator {
            case "role":
                let (nameOpt, rem1) = parseOption(locatorArgs, name: "--name")
                let candidates = nonFlagArgs(rem1)
                guard let role = candidates.first else {
                    throw CLIError(message: "browser find role requires <role>")
                }
                params["role"] = role
                if let nameOpt {
                    params["name"] = nameOpt
                }
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = V2MethodNames.browserFindRole
            case "text", "label", "placeholder", "alt", "title", "testid":
                let keyMap: [String: String] = [
                    "text": "text",
                    "label": "label",
                    "placeholder": "placeholder",
                    "alt": "alt",
                    "title": "title",
                    "testid": "testid",
                ]
                let findMethodMap: [String: String] = [
                    "text": V2MethodNames.browserFindText,
                    "label": V2MethodNames.browserFindLabel,
                    "placeholder": V2MethodNames.browserFindPlaceholder,
                    "alt": V2MethodNames.browserFindAlt,
                    "title": V2MethodNames.browserFindTitle,
                    "testid": V2MethodNames.browserFindTestid,
                ]
                let candidates = nonFlagArgs(locatorArgs)
                guard let value = candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a value")
                }
                params[keyMap[locator]!] = value
                if hasFlag(locatorArgs, name: "--exact") {
                    params["exact"] = true
                }
                method = findMethodMap[locator]!
            case "first", "last":
                let (selectorOpt, rem1) = parseOption(locatorArgs, name: "--selector")
                let candidates = nonFlagArgs(rem1)
                guard let selector = selectorOpt ?? candidates.first else {
                    throw CLIError(message: "browser find \(locator) requires a selector")
                }
                params["selector"] = selector
                method = (locator == "first") ? V2MethodNames.browserFindFirst : V2MethodNames.browserFindLast
            case "nth":
                let (indexOpt, rem1) = parseOption(locatorArgs, name: "--index")
                let (selectorOpt, rem2) = parseOption(rem1, name: "--selector")
                let candidates = nonFlagArgs(rem2)
                let indexRaw = indexOpt ?? candidates.first
                guard let indexRaw,
                      let index = Int(indexRaw) else {
                    throw CLIError(message: "browser find nth requires an integer index")
                }
                let selector = selectorOpt ?? (candidates.count >= 2 ? candidates[1] : nil)
                guard let selector else {
                    throw CLIError(message: "browser find nth requires a selector")
                }
                params["index"] = index
                params["selector"] = selector
                method = V2MethodNames.browserFindNth
            default:
                throw CLIError(message: "Unsupported browser find locator: \(locator)")
            }

            let payload = try client.sendV2(method: method, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "frame" {
            let sid = try requireSurface()
            guard let frameVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser frame requires <selector|main>")
            }
            if frameVerb == "main" {
                let payload = try client.sendV2(method: V2MethodNames.browserFrameMain, params: ["surface_id": sid])
                output(payload, fallback: "OK")
                return
            }
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser frame requires a selector or 'main'")
            }
            let payload = try client.sendV2(method: V2MethodNames.browserFrameSelect, params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "dialog" {
            let sid = try requireSurface()
            guard let dialogVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser dialog requires <accept|dismiss> [text]")
            }
            let remainder = Array(subArgs.dropFirst())
            switch dialogVerb {
            case "accept":
                var params: [String: Any] = ["surface_id": sid]
                if !remainder.isEmpty {
                    // Preserve an explicit answer verbatim, including "" or whitespace-only text:
                    // trimming here would silently turn a deliberate empty prompt answer into "use
                    // the page's default" instead.
                    params["text"] = remainder.joined(separator: " ")
                }
                let payload = try client.sendV2(method: V2MethodNames.browserDialogAccept, params: params)
                output(payload, fallback: "OK")
            case "dismiss":
                let payload = try client.sendV2(method: V2MethodNames.browserDialogDismiss, params: ["surface_id": sid])
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser dialog subcommand: \(dialogVerb)")
            }
            return
        }

        if subcommand == "download" {
            let sid = try requireSurface()
            let argsForDownload: [String]
            if subArgs.first?.lowercased() == "wait" {
                argsForDownload = Array(subArgs.dropFirst())
            } else {
                argsForDownload = subArgs
            }

            let (pathOpt, rem1) = parseOption(argsForDownload, name: "--path")
            let (timeoutMsOpt, rem2) = parseOption(rem1, name: "--timeout-ms")
            let (timeoutSecOpt, rem3) = parseOption(rem2, name: "--timeout")

            var params: [String: Any] = ["surface_id": sid]
            if let path = pathOpt ?? nonFlagArgs(rem3).first {
                params["path"] = path
            }
            if let timeoutMsOpt {
                guard let timeoutMs = Int(timeoutMsOpt) else {
                    throw CLIError(message: "--timeout-ms must be an integer")
                }
                params["timeout_ms"] = timeoutMs
            } else if let timeoutSecOpt {
                guard let seconds = Double(timeoutSecOpt) else {
                    throw CLIError(message: "--timeout must be a number")
                }
                params["timeout_ms"] = max(1, Int(seconds * 1000.0))
            }

            let payload = try client.sendV2(method: V2MethodNames.browserDownloadWait, params: params)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "cookies" {
            let sid = try requireSurface()
            let cookieVerb = subArgs.first?.lowercased() ?? "get"
            let cookieArgs = subArgs.first != nil ? Array(subArgs.dropFirst()) : []

            let (nameOpt, rem1) = parseOption(cookieArgs, name: "--name")
            let (valueOpt, rem2) = parseOption(rem1, name: "--value")
            let (urlOpt, rem3) = parseOption(rem2, name: "--url")
            let (domainOpt, rem4) = parseOption(rem3, name: "--domain")
            let (pathOpt, rem5) = parseOption(rem4, name: "--path")
            let (expiresOpt, rem6) = parseOption(rem5, name: "--expires")
            let (sameSiteOpt, rem7) = parseOption(rem6, name: "--same-site")

            var params: [String: Any] = ["surface_id": sid]
            if let nameOpt { params["name"] = nameOpt }
            if let valueOpt { params["value"] = valueOpt }
            if let urlOpt { params["url"] = urlOpt }
            if let domainOpt { params["domain"] = domainOpt }
            if let pathOpt { params["path"] = pathOpt }
            if hasFlag(cookieArgs, name: "--secure") {
                params["secure"] = true
            }
            if hasFlag(cookieArgs, name: "--http-only") {
                params["http_only"] = true
            }
            if let sameSiteOpt { params["same_site"] = sameSiteOpt.lowercased() }
            // get/clear default to the current page's site; --all-domains (alias --all) widens.
            if hasFlag(cookieArgs, name: "--all-domains") || hasFlag(cookieArgs, name: "--all") {
                params["all_domains"] = true
            }
            if let expiresOpt {
                guard let expires = Int(expiresOpt) else {
                    throw CLIError(message: "--expires must be an integer Unix timestamp")
                }
                params["expires"] = expires
            }

            switch cookieVerb {
            case "get":
                let payload = try client.sendV2(method: V2MethodNames.browserCookiesGet, params: params)
                output(payload, fallback: "OK")
            case "set":
                var setParams = params
                let positional = nonFlagArgs(rem7)
                if setParams["name"] == nil, positional.count >= 1 {
                    setParams["name"] = positional[0]
                }
                if setParams["value"] == nil, positional.count >= 2 {
                    setParams["value"] = positional[1]
                }
                guard setParams["name"] != nil, setParams["value"] != nil else {
                    throw CLIError(message: "browser cookies set requires <name> <value> (or --name/--value)")
                }
                let payload = try client.sendV2(method: V2MethodNames.browserCookiesSet, params: setParams)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: V2MethodNames.browserCookiesClear, params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser cookies subcommand: \(cookieVerb)")
            }
            return
        }

        if subcommand == "storage" {
            let sid = try requireSurface()
            let storageArgs = subArgs
            let storageType = storageArgs.first?.lowercased() ?? "local"
            guard storageType == "local" || storageType == "session" else {
                throw CLIError(message: "browser storage requires type: local|session")
            }
            let op = storageArgs.count >= 2 ? storageArgs[1].lowercased() : "get"
            let rest = storageArgs.count > 2 ? Array(storageArgs.dropFirst(2)) : []
            let positional = nonFlagArgs(rest)

            var params: [String: Any] = ["surface_id": sid, "type": storageType]
            switch op {
            case "get":
                if let key = positional.first {
                    params["key"] = key
                }
                let payload = try client.sendV2(method: V2MethodNames.browserStorageGet, params: params)
                output(payload, fallback: "OK")
            case "set":
                guard positional.count >= 2 else {
                    throw CLIError(message: "browser storage \(storageType) set requires <key> <value>")
                }
                params["key"] = positional[0]
                params["value"] = positional[1]
                let payload = try client.sendV2(method: V2MethodNames.browserStorageSet, params: params)
                output(payload, fallback: "OK")
            case "clear":
                let payload = try client.sendV2(method: V2MethodNames.browserStorageClear, params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser storage subcommand: \(op)")
            }
            return
        }

        if subcommand == "tab" {
            let sid = try requireSurface()
            let first = subArgs.first?.lowercased()
            let tabVerb: String
            let tabArgs: [String]
            if let first, ["new", "list", "close", "switch"].contains(first) {
                tabVerb = first
                tabArgs = Array(subArgs.dropFirst())
            } else if let first, Int(first) != nil {
                tabVerb = "switch"
                tabArgs = subArgs
            } else {
                tabVerb = "list"
                tabArgs = subArgs
            }

            switch tabVerb {
            case "list":
                let payload = try client.sendV2(method: V2MethodNames.browserTabList, params: ["surface_id": sid])
                output(payload, fallback: "OK")
            case "new":
                var params: [String: Any] = ["surface_id": sid]
                let url = tabArgs.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !url.isEmpty {
                    params["url"] = url
                }
                let payload = try client.sendV2(method: V2MethodNames.browserTabNew, params: params)
                output(payload, fallback: "OK")
            case "switch", "close":
                let method = (tabVerb == "switch") ? V2MethodNames.browserTabSwitch : V2MethodNames.browserTabClose
                var params: [String: Any] = ["surface_id": sid]
                let target = tabArgs.first
                if let target {
                    if let index = Int(target) {
                        params["index"] = index
                    } else {
                        params["target_surface_id"] = target
                    }
                }
                let payload = try client.sendV2(method: method, params: params)
                output(payload, fallback: "OK")
            default:
                throw CLIError(message: "Unsupported browser tab subcommand: \(tabVerb)")
            }
            return
        }

        if subcommand == "console" {
            let sid = try requireSurface()
            let consoleVerb = subArgs.first?.lowercased() ?? "list"
            let method = (consoleVerb == "clear") ? V2MethodNames.browserConsoleClear : V2MethodNames.browserConsoleList
            if consoleVerb != "list" && consoleVerb != "clear" {
                throw CLIError(message: "Unsupported browser console subcommand: \(consoleVerb)")
            }
            let payload = try client.sendV2(method: method, params: ["surface_id": sid])
            if effectiveJSONOutput || consoleVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["entries"]) ?? "No console entries")
            }
            return
        }

        if subcommand == "errors" {
            let sid = try requireSurface()
            let errorsVerb = subArgs.first?.lowercased() ?? "list"
            var params: [String: Any] = ["surface_id": sid]
            if errorsVerb == "clear" {
                params["clear"] = true
            } else if errorsVerb != "list" {
                throw CLIError(message: "Unsupported browser errors subcommand: \(errorsVerb)")
            }
            let payload = try client.sendV2(method: V2MethodNames.browserErrorsList, params: params)
            if effectiveJSONOutput || errorsVerb == "clear" {
                output(payload, fallback: "OK")
            } else {
                print(displayBrowserLogItems(payload["errors"]) ?? "No browser errors")
            }
            return
        }

        if subcommand == "highlight" {
            let sid = try requireSurface()
            let (selectorOpt, rem1) = parseOption(subArgs, name: "--selector")
            let selector = selectorOpt ?? nonFlagArgs(rem1).first
            guard let selector else {
                throw CLIError(message: "browser highlight requires a selector")
            }
            let payload = try client.sendV2(method: V2MethodNames.browserHighlight, params: ["surface_id": sid, "selector": selector])
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "state" {
            let sid = try requireSurface()
            guard let stateVerb = subArgs.first?.lowercased() else {
                throw CLIError(message: "browser state requires save|load <path>")
            }
            let stateArgs = Array(subArgs.dropFirst())
            let allDomains = stateArgs.contains("--all-domains")
            guard let rawPath = stateArgs.first(where: { $0 != "--all-domains" }) else {
                throw CLIError(message: "browser state \(stateVerb) requires a file path")
            }
            // The app requires an absolute path; resolve against this shell's cwd.
            let path = URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath).standardizedFileURL.path
            let method: String
            var stateParams: [String: Any] = ["surface_id": sid, "path": path]
            switch stateVerb {
            case "save":
                method = V2MethodNames.browserStateSave
                if allDomains { stateParams["all_domains"] = true }
            case "load":
                method = V2MethodNames.browserStateLoad
            default:
                throw CLIError(message: "Unsupported browser state subcommand: \(stateVerb)")
            }
            let payload = try client.sendV2(method: method, params: stateParams)
            output(payload, fallback: "OK")
            return
        }

        if subcommand == "addinitscript" || subcommand == "addscript" || subcommand == "addstyle" {
            let sid = try requireSurface()
            let field = (subcommand == "addstyle") ? "css" : "script"
            let flag = (subcommand == "addstyle") ? "--css" : "--script"
            let (scriptOpt, rem1) = parseOption(subArgs, name: flag)
            let content = (scriptOpt ?? rem1.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw CLIError(message: "browser \(subcommand) requires content")
            }
            let addMethodMap: [String: String] = [
                "addinitscript": V2MethodNames.browserAddinitscript,
                "addscript": V2MethodNames.browserAddscript,
                "addstyle": V2MethodNames.browserAddstyle,
            ]
            let payload = try client.sendV2(method: addMethodMap[subcommand]!, params: ["surface_id": sid, field: content])
            output(payload, fallback: "OK")
            return
        }

        throw CLIError(message: "Unsupported browser subcommand: \(subcommand)")
    }

    /// Subcommand help text for Browser commands, split out of the
    /// central `subcommandUsage` switch (programa.swift) so each domain's
    /// help text lives next to its command descriptors. Refs #101.
    func browserSubcommandUsage(_ command: String) -> String? {
        switch command {
        case "browser":
            return """
            Usage: programa browser [--surface <id|ref|index> | <surface>] <subcommand> [args]

            Browser automation commands. Most subcommands require a surface handle.
            A surface can be passed as `--surface <handle>` or as the first positional token.
            `open`/`open-split`/`new`/`identify` can run without an explicit surface.

            Subcommands:
              open|open-split|new [url] [--workspace <id|ref|index>] [--window <id|ref|index>]
                open/open-split/new default to $PROGRAMA_WORKSPACE_ID when --workspace is omitted and --window is not set
              goto|navigate <url> [--snapshot-after]
              back|forward|reload [--snapshot-after]
              url|get-url
              focus-webview | is-webview-focused
              snapshot [--interactive|-i] [--cursor] [--compact] [--max-depth <n>] [--selector <css>]
              eval [--script <js> | <js>]
              wait [--selector <css>] [--text <text>] [--url-contains <text>|--url <text>] [--load-state <interactive|complete>] [--function <js>] [--timeout-ms <ms>|--timeout <seconds>]
              click|dblclick|hover|focus|check|uncheck|scroll-into-view [--selector <css> | <css>] [--snapshot-after]
              type|fill [--selector <css> | <css>] [--text <text> | <text>] [--snapshot-after]
              press|key|keydown|keyup [--key <key> | <key>] [--snapshot-after]
              select [--selector <css> | <css>] [--value <value> | <value>] [--snapshot-after]
              scroll [--selector <css>] [--dx <n>] [--dy <n>] [--snapshot-after]
              screenshot [--out <path>]
              get <url|title|text|html|value|attr|count|box|styles> [...]
                text|html|value|count|box|styles|attr: [--selector <css> | <css>]
                attr: [--attr <name> | <name>]
                styles: [--property <name>]
              is <visible|enabled|checked> [--selector <css> | <css>]
              find <role|text|label|placeholder|alt|title|testid|first|last|nth> [...]
                role: [--name <text>] [--exact] <role>
                text|label|placeholder|alt|title|testid: [--exact] <text>
                first|last: [--selector <css> | <css>]
                nth: [--index <n> | <n>] [--selector <css> | <css>]
              frame <main|selector> [--selector <css>]
              dialog <accept|dismiss> [text]
              download [wait] [--path <path>] [--timeout-ms <ms>|--timeout <seconds>]
              cookies <get|set|clear> [--name <name>] [--value <value>] [--url <url>] [--domain <domain>] [--path <path>] [--expires <unix>] [--secure] [--http-only] [--same-site <lax|strict>] [--all-domains]
              storage <local|session> <get|set|clear> [...]
              tab <new|list|switch|close|<index>> [...]
              console <list|clear>
              errors <list|clear>
              highlight [--selector <css> | <css>]
              state <save|load> <path>
              addinitscript|addscript [--script <js> | <js>]
              addstyle [--css <css> | <css>]
              identify [--surface <id|ref|index>]

            Example:
              programa browser open https://example.com
              programa browser surface:1 navigate https://google.com
              programa browser --surface surface:1 snapshot --interactive
            """
        // Legacy browser aliases — point users to `programa browser --help`
        case "open-browser":
            return "Legacy alias for 'programa browser open'. Run 'programa browser --help' for details."
        case "navigate":
            return "Legacy alias for 'programa browser navigate'. Run 'programa browser --help' for details."
        case "browser-back":
            return "Legacy alias for 'programa browser back'. Run 'programa browser --help' for details."
        case "browser-forward":
            return "Legacy alias for 'programa browser forward'. Run 'programa browser --help' for details."
        case "browser-reload":
            return "Legacy alias for 'programa browser reload'. Run 'programa browser --help' for details."
        case "get-url":
            return "Legacy alias for 'programa browser get-url'. Run 'programa browser --help' for details."
        case "focus-webview":
            return "Legacy alias for 'programa browser focus-webview'. Run 'programa browser --help' for details."
        case "is-webview-focused":
            return "Legacy alias for 'programa browser is-webview-focused'. Run 'programa browser --help' for details."
        default:
            return nil
        }
    }
}
