import Darwin
import Foundation
import Logging
import MCP

/// Newline-delimited JSON-RPC over stdin/stdout, framed like the SDK's `StdioTransport`.
///
/// The SDK transport sets stdin to `O_NONBLOCK` and sleeps 10 ms on every `EAGAIN`,
/// which wakes an idle sidecar 100 times a second for its whole life. This one parks
/// a dedicated thread in a blocking `read`, so an idle server costs no CPU.
actor BlockingStdioTransport: Transport {
    nonisolated let logger = Logger(
        label: "programa.mcp.transport.stdio",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private let input: Int32
    private let output: Int32
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) {
        self.input = input
        self.output = output
        (messageStream, messageContinuation) = AsyncThrowingStream.makeStream()
    }

    func connect() async throws {
        guard !isConnected else { return }
        isConnected = true
        let reader = Thread { [input, messageContinuation] in
            Self.readLoop(fd: input, continuation: messageContinuation)
        }
        reader.name = "programa-mcp.stdin"
        reader.start()
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(POSIXError(.ENOTCONN))
        }
        var message = data
        message.append(UInt8(ascii: "\n"))
        try message.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(output, buffer.baseAddress! + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                    continue
                }
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    Self.waitUntilReady(fd: output, events: Int16(POLLOUT))
                default:
                    throw MCPError.transportError(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    private static func readLoop(fd: Int32, continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = Data()
        readLoop: while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                switch errno {
                case EINTR:
                    continue
                case EAGAIN:
                    // stdin can arrive with O_NONBLOCK already set on a description shared
                    // with the parent; wait in poll rather than clearing the parent's flag.
                    waitUntilReady(fd: fd, events: Int16(POLLIN))
                    continue
                default:
                    break readLoop
                }
            }
            pending.append(contentsOf: buffer[..<count])
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[..<newline]
                pending = pending[pending.index(after: newline)...]
                if !line.isEmpty {
                    continuation.yield(Data(line))
                }
            }
        }
        continuation.finish()
    }

    private static func waitUntilReady(fd: Int32, events: Int16) {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        _ = poll(&descriptor, 1, -1)
    }
}
