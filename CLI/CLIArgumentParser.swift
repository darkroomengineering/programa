import Foundation

/// The argument grammar every `programa` command shares (the `__tmux-compat` shim keeps
/// tmux's own grammar in `CLI+TmuxCompat.swift`):
/// - an option is `--name value` or `--name=value`;
/// - a bare `--` ends option parsing, and every later token is positional;
/// - a `--`-prefixed token is never taken as an option's value; pass such a value as
///   `--name=--value`;
/// - a bounded positional slot (an id, name, or subcommand) rejects an option-looking token
///   (see `looksLikeOption`) before `--` unless the command declares it as a short flag
///   (`resize-pane -L`). Unbounded free-text positionals (`send`, `log`) accept it.
extension ProgramaCLI {
    /// `-` followed by a letter or a second `-`. A bare `-`, a negative number, or text
    /// such as `- note` is an ordinary word.
    static func looksLikeOption(_ token: String) -> Bool {
        guard token.count >= 2, token.hasPrefix("-") else { return false }
        let second = token[token.index(after: token.startIndex)]
        return second == "-" || second.isLetter
    }

    /// Walks `args` collecting every value of `name` and returning the leftover args with
    /// those option/value pairs removed. A `--` terminator stays in the leftovers so a later
    /// scan of the same args still stops at it. A `name` with no usable value is left in place.
    func scanOption(_ args: [String], name: String) -> ([String], [String]) {
        var remaining: [String] = []
        var values: [String] = []
        var pastTerminator = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if pastTerminator {
                remaining.append(arg)
                continue
            }
            if arg == "--" {
                pastTerminator = true
            } else if arg == name, index < args.count, !args[index].hasPrefix("--") {
                values.append(args[index])
                index += 1
                continue
            } else if arg.hasPrefix(name + "=") {
                values.append(String(arg.dropFirst(name.count + 1)))
                continue
            }
            remaining.append(arg)
        }
        return (values, remaining)
    }

    /// The last value of `name` and the args without it.
    func parseOption(_ args: [String], name: String) -> (String?, [String]) {
        let (values, remaining) = scanOption(args, name: name)
        return (values.last, remaining)
    }

    func parseRepeatedOption(_ args: [String], name: String) -> ([String], [String]) {
        scanOption(args, name: name)
    }

    func optionValue(_ args: [String], name: String) -> String? {
        scanOption(args, name: name).0.last
    }

    /// The value of `name`, else the first positional. Every other `--flag` is assumed to
    /// take a value, so use this only for commands without boolean flags.
    func optionOrFirstPositional(_ args: [String], name: String) -> String? {
        optionValue(args, name: name) ?? parseFlagArgs(args).positional.first
    }

    func hasFlag(_ args: [String], name: String) -> Bool {
        args.prefix(while: { $0 != "--" }).contains(name)
    }

    /// Whether boolean flag `name` appears before `--`, and the args with it removed.
    func extractFlag(_ args: [String], name: String) -> (Bool, [String]) {
        let terminator = args.firstIndex(of: "--") ?? args.endIndex
        let head = args[..<terminator]
        return (head.contains(name), head.filter { $0 != name } + args[terminator...])
    }

    /// Strict parse used to validate a command before the socket opens: unknown, duplicate,
    /// or valueless options throw.
    func preflightFlagArguments(
        _ args: [String],
        command: String,
        valueFlags: Set<String>,
        booleanFlags: Set<String> = [],
        shortFlags: Set<String> = [],
        rejectOptionLikePositionals: Bool = true
    ) throws -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var pastTerminator = false
        var index = 0

        while index < args.count {
            let token = args[index]
            if pastTerminator {
                positional.append(token)
                index += 1
                continue
            }
            if token == "--" {
                pastTerminator = true
                index += 1
                continue
            }
            guard token.hasPrefix("--") else {
                if rejectOptionLikePositionals, Self.looksLikeOption(token), !shortFlags.contains(token) {
                    throw CLIError(message: "\(command): unknown option \(token) (put -- before an argument that starts with -)")
                }
                positional.append(token)
                index += 1
                continue
            }

            let body = String(token.dropFirst(2))
            let parts = body.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let hasEqualsValue = parts.count == 2

            guard valueFlags.contains(name) || booleanFlags.contains(name) else {
                throw CLIError(message: "\(command): unknown option --\(name)")
            }
            guard options[name] == nil else {
                throw CLIError(message: "\(command): duplicate option --\(name)")
            }

            if booleanFlags.contains(name) {
                guard !hasEqualsValue else {
                    throw CLIError(message: "\(command): --\(name) does not take a value")
                }
                options[name] = "true"
                index += 1
                continue
            }

            if hasEqualsValue {
                let value = String(parts[1])
                guard !value.isEmpty else {
                    throw CLIError(message: "\(command): --\(name) requires a value")
                }
                options[name] = value
                index += 1
                continue
            }

            guard index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw CLIError(message: "\(command): --\(name) requires a value (use --\(name)=<value> for a value that starts with --)")
            }
            options[name] = args[index + 1]
            index += 2
        }
        return (positional, options)
    }

    /// Lenient parse into positional args + an options dict, mirroring the v1 server-side
    /// `parseOptions`/`parseOptionsNoStop` grammar so v2-backed sidebar commands can rebuild
    /// the same structured params client-side. A `--name` with no usable value maps to "".
    /// `stopAtDashDash: true` matches `parseOptions` (a bare `--` ends flag parsing);
    /// `false` matches `parseOptionsNoStop` (a bare `--` is skipped, used by
    /// `report_meta_block`-style commands whose caller already split the markdown body out).
    func parseFlagArgs(_ args: [String], stopAtDashDash: Bool = true) -> (positional: [String], options: [String: String]) {
        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var index = 0
        while index < args.count {
            let token = args[index]
            index += 1
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = stopAtDashDash
            } else if token.hasPrefix("--") {
                let body = token.dropFirst(2)
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if index < args.count, !args[index].hasPrefix("--") {
                    options[String(body)] = args[index]
                    index += 1
                } else {
                    options[String(body)] = ""
                }
            } else {
                positional.append(token)
            }
        }
        return (positional, options)
    }

    /// Reads a global option at `args[index]` given as `name value` or `name=value`.
    /// Returns nil when `args[index]` is a different token, otherwise the value and the
    /// number of tokens it spans. A missing or `--`-prefixed value throws `missingMessage`;
    /// `allowsDashValue` is for secrets such as `--password`, which may start with `--`.
    func globalOptionValue(
        _ args: [String],
        at index: Int,
        name: String,
        missingMessage: String,
        allowsDashValue: Bool = false
    ) throws -> (value: String, width: Int)? {
        let token = args[index]
        if token.hasPrefix(name + "=") {
            let value = String(token.dropFirst(name.count + 1))
            guard !value.isEmpty else { throw CLIError(message: missingMessage) }
            return (value, 1)
        }
        guard token == name else { return nil }
        guard index + 1 < args.count, allowsDashValue || !args[index + 1].hasPrefix("--") else {
            throw CLIError(message: missingMessage)
        }
        return (args[index + 1], 2)
    }
}
