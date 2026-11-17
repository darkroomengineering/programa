import Foundation

extension ProgramaCLI {
    /// `config check`, registered from `commandDescriptors()` (programa.swift).
    func configDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["config"],
                helpLines: ["config check [--file <path>]"],
                connectionPolicy: .local,
                // Parsed in `runConfigCheck`, so a usage error exits 2 rather than the CLI's
                // usual 1, which this command reserves for "problems found".
                argumentContract: .handlerParsed,
                detailedUsage: """
                Usage: programa config check [--file <path>]

                Check ~/.config/programa/settings.json with the parser the app uses, without
                applying anything. Programa does not need to be running.

                Prints one line per problem, as settings.json:LINE: key.path: message, and
                exits 1. Prints "settings.json is valid" and exits 0 when there are none; also
                exits 0 when no settings file exists. Exits 2 when the check cannot run: a
                usage error, a --file path that does not exist, or no Programa app found.

                Flags:
                  --file <path>   Check this file instead of the one the app loads.

                Example:
                  programa config check
                  programa config check --file ./settings.json
                """,
                execute: nil
            ),
        ]
    }

    /// Runs the app binary in its headless `--check-settings` mode (`SettingsFileCheck` in the
    /// app), so the check shares the app's parser. Its stdout, stderr and exit code pass through.
    func runConfigCheck(commandArgs: [String]) -> Never {
        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
            // 1 means "problems found", so a check that could not run exits 2.
            exit(2)
        }
        var file: String?
        var positionals: [String] = []
        var index = 0
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--file" {
                guard index + 1 < commandArgs.count else { fail("config: --file requires a path") }
                file = commandArgs[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("--file=") {
                file = String(arg.dropFirst("--file=".count))
            } else if arg.hasPrefix("-") {
                fail("config: unknown flag '\(arg)'. Run 'programa config --help'.")
            } else {
                positionals.append(arg)
            }
            index += 1
        }
        guard positionals == ["check"] else {
            fail("config: expected 'check'. Usage: programa config check [--file <path>]")
        }
        guard let appExecutable = programaAppExecutableURL() else {
            fail("could not find the Programa app this CLI belongs to. Run the programa CLI inside Programa.app (Contents/Resources/bin/programa).")
        }
        let process = Process()
        process.executableURL = appExecutable
        process.arguments = ["--check-settings"] + (file.map { [resolvePath($0)] } ?? [])
        // A semaphore rather than waitUntilExit(), which waits by spinning a run loop.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            fail("could not run \(appExecutable.path): \(error.localizedDescription)")
        }
        exited.wait()
        guard process.terminationReason == .exit else {
            fail("the settings check stopped with signal \(process.terminationStatus)")
        }
        exit(process.terminationStatus)
    }

    /// The executable of the `.app` bundle this CLI sits in, found by walking up from the
    /// resolved CLI path the same way `currentProgramaAppBundleIdentifier()` does.
    private func programaAppExecutableURL() -> URL? {
        guard let executableURL = resolvedExecutableURL() else { return nil }
        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let appExecutable = Bundle(url: current)?.executableURL,
               FileManager.default.isExecutableFile(atPath: appExecutable.path) {
                return appExecutable
            }
            guard let parent = parentSearchURL(for: current) else { return nil }
            current = parent
        }
    }
}
