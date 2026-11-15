import Foundation

/// Talks to a running Moss instance.
public struct IPCClient: Sendable {
    public var paths: SocketPaths

    public init(paths: SocketPaths = .standard) {
        self.paths = paths
    }

    /// Sends one request line and returns the full response.
    public func send(_ request: String, timeout: Double = 5) throws(SocketError) -> String {
        let fd = try UnixSocket.connect(to: paths.control)
        defer { close(fd) }
        UnixSocket.setTimeout(fd, seconds: timeout)
        guard UnixSocket.writeAll(fd, Data((request + "\n").utf8)) else { throw SocketError("write") }
        return String(decoding: UnixSocket.read(fd), as: UTF8.self)
    }

    /// Sends a request and decodes a JSON response.
    public func query<Response: Decodable>(_ command: ControlCommand, as type: Response.Type = Response.self) throws -> Response {
        let text = try send(ControlRequest(json: true, command: command).wireText)
        return try JSONDecoder().decode(Response.self, from: Data(text.utf8))
    }

    /// Streams events, each a line of JSON, until the connection closes or the task is cancelled.
    public func events() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let fd: Int32
            do {
                fd = try UnixSocket.connect(to: paths.events)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let thread = Thread {
                var pending = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex...newline)
                        continuation.yield(line)
                    }
                }
                close(fd)
                continuation.finish()
            }
            continuation.onTermination = { _ in shutdown(fd, SHUT_RDWR) }
            thread.name = "moss.event-client"
            thread.start()
        }
    }
}
