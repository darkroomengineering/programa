import Foundation
import MCP

/// Entry point for `programa-mcp`, a stdio MCP server sidecar for Programa.
///
/// The server runs in its own process and reaches the app only through the
/// existing v2 control socket, so nothing here can touch AppKit, Ghostty, or
/// the typing-latency-sensitive paths in the app process.
///
/// Tools and resources are registered from their own catalogs rather than
/// inline, so the tool surface stays auditable in one table each.
@main
struct ProgramaMCPMain {
    static func main() async {
        let server = Server(
            name: ProgramaMCPServerInfo.name,
            version: ProgramaMCPServerInfo.version,
            capabilities: ProgramaMCPCapabilities.make()
        )

        logResolvedSocket()

        await ToolCatalog.register(on: server)
        await ResourceCatalog.register(on: server)

        do {
            let transport = BlockingStdioTransport()
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
        } catch {
            FileHandle.standardError.write(Data("programa-mcp: fatal error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Announces which control socket this server will talk to, and says so loudly
    /// when the choice came from the environment rather than discovery.
    ///
    /// Anything that can set this process's environment can point it at a socket
    /// of its choosing, and a substituted socket both observes every tool argument
    /// and chooses what the agent reads back. Naming the path at startup puts that
    /// redirection in the client's server log instead of leaving it invisible.
    private static func logResolvedSocket() {
        let environment = ProcessInfo.processInfo.environment
        let overrideKey = ["PROGRAMA_SOCKET_PATH", "PROGRAMA_SOCKET"].first { key in
            (environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)).map { !$0.isEmpty } ?? false
        }
        let path = MCPSocketBridge.resolveSocketPath(environment: environment)
        let origin = overrideKey.map { "\($0) override" } ?? "discovery"
        FileHandle.standardError.write(Data("programa-mcp: control socket \(path) (via \(origin))\n".utf8))
    }
}
