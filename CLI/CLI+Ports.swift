import Foundation

extension ProgramaCLI {
    /// `list-ports` / `stop-port`, registered from `commandDescriptors()` (programa.swift).
    func portsDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                names: ["list-ports"],
                helpLines: ["list-ports [--json]"],
                detailedUsage: """
                Usage: programa list-ports [--json]

                List TCP ports that processes started from Programa workspaces are listening on,
                grouped by workspace, followed by processes left running after their panel closed.

                Example:
                  programa list-ports
                  programa --json list-ports
                """,
                grammar: CLIArgumentGrammar(booleanOptions: ["json"]),
                execute: { ctx in
                    let payload = try ctx.client.sendV2(method: V2MethodNames.portsList)
                    if ctx.jsonOutput || ctx.commandArgs.contains("--json") {
                        print(self.jsonString(self.formatIDs(payload, mode: ctx.idFormat)))
                    } else {
                        self.printPortsText(payload, idFormat: ctx.idFormat)
                    }
                }
            ),
            CommandDescriptor(
                names: ["stop-port"],
                helpLines: ["stop-port <port> | --pid <pid>"],
                detailedUsage: """
                Usage: programa stop-port <port>
                       programa stop-port --pid <pid>

                Stop the process listening on <port>: SIGTERM first, then SIGKILL if it is still
                running after 3 seconds. Only processes listed by `programa list-ports` can be
                stopped. If more than one process listens on <port>, the command fails and lists
                them; pick one with --pid.

                Example:
                  programa stop-port 3000
                  programa stop-port --pid 4242
                """,
                grammar: CLIArgumentGrammar(valueOptions: ["pid"], maxPositionals: 1),
                execute: { ctx in
                    try self.runStopPort(ctx: ctx)
                }
            ),
        ]
    }

    private struct ListedPortProcess {
        let port: Int
        let pid: Int
        let command: String
        let origin: String
    }

    private func listedPortProcesses(_ payload: [String: Any]) -> [ListedPortProcess] {
        var result: [ListedPortProcess] = []
        for workspace in payload["workspaces"] as? [[String: Any]] ?? [] {
            let title = workspace["title"] as? String ?? ""
            for row in workspace["ports"] as? [[String: Any]] ?? [] {
                guard let port = row["port"] as? Int, let pid = row["pid"] as? Int else { continue }
                result.append(ListedPortProcess(
                    port: port, pid: pid, command: row["command"] as? String ?? "", origin: title
                ))
            }
        }
        for leftover in payload["left_running"] as? [[String: Any]] ?? [] {
            guard let pid = leftover["pid"] as? Int else { continue }
            for port in leftover["ports"] as? [Int] ?? [] {
                result.append(ListedPortProcess(
                    port: port,
                    pid: pid,
                    command: leftover["command"] as? String ?? "",
                    origin: leftover["workspace_title"] as? String ?? ""
                ))
            }
        }
        return result
    }

    private func printPortsText(_ payload: [String: Any], idFormat: CLIIDFormat) {
        let workspaces = payload["workspaces"] as? [[String: Any]] ?? []
        let leftovers = payload["left_running"] as? [[String: Any]] ?? []
        if workspaces.isEmpty && leftovers.isEmpty {
            print("No listening ports")
            return
        }
        for workspace in workspaces {
            let title = workspace["title"] as? String ?? ""
            print("\(textHandle(workspace, idFormat: idFormat))  \(title)")
            for row in workspace["ports"] as? [[String: Any]] ?? [] {
                let port = row["port"] as? Int ?? 0
                let pid = row["pid"] as? Int ?? 0
                let command = row["command"] as? String ?? ""
                print("  :\(port)  \(command)  pid \(pid)")
            }
        }
        if !leftovers.isEmpty {
            print("Left running")
            for leftover in leftovers {
                let pid = leftover["pid"] as? Int ?? 0
                let command = leftover["command"] as? String ?? ""
                let ports = (leftover["ports"] as? [Int] ?? []).map { ":\($0)" }.joined(separator: " ")
                let title = leftover["workspace_title"] as? String ?? ""
                let from = title.isEmpty ? "" : "  from \"\(title)\""
                print("  \(ports)  \(command)  pid \(pid)\(from)")
            }
        }
    }

    private func runStopPort(ctx: CommandContext) throws {
        let (pidOption, positional) = parseOption(ctx.commandArgs, name: "--pid")
        let portArgument = positional.first(where: { !$0.hasPrefix("--") })

        let pid: Int
        if let pidOption {
            guard portArgument == nil else {
                throw CLIError(message: "stop-port: pass either <port> or --pid, not both")
            }
            guard let parsed = Int(pidOption), parsed > 1 else {
                throw CLIError(message: "stop-port: invalid pid '\(pidOption)'")
            }
            pid = parsed
        } else {
            guard let portArgument else {
                throw CLIError(message: "stop-port: expected <port> or --pid <pid>")
            }
            guard let port = Int(portArgument), (1...65535).contains(port) else {
                throw CLIError(message: "stop-port: invalid port '\(portArgument)'")
            }
            let listing = try ctx.client.sendV2(method: V2MethodNames.portsList)
            let matches = listedPortProcesses(listing).filter { $0.port == port }
            let distinctPids = Set(matches.map(\.pid))
            guard let match = matches.first else {
                throw CLIError(message: "stop-port: nothing in Programa is listening on port \(port)")
            }
            guard distinctPids.count == 1 else {
                let detail = distinctPids.sorted().map { candidate in
                    let command = matches.first(where: { $0.pid == candidate })?.command ?? ""
                    return "  pid \(candidate)  \(command)"
                }.joined(separator: "\n")
                throw CLIError(
                    message: "stop-port: \(distinctPids.count) processes listen on port \(port); use --pid:\n\(detail)"
                )
            }
            pid = match.pid
        }

        let payload = try ctx.client.sendV2(method: V2MethodNames.portsStop, params: ["pid": pid])
        if ctx.jsonOutput {
            print(jsonString(formatIDs(payload, mode: ctx.idFormat)))
        } else {
            print("Sent SIGTERM to pid \(pid); it is force-stopped after 3 seconds if it keeps running")
        }
    }
}
