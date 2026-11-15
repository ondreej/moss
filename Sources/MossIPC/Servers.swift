public import Foundation
public import MossCore
import Synchronization

/// Serves the control socket: each connection sends one request line and receives one response.
public final class ControlServer: Sendable {
    public typealias Handler = @Sendable (String) async -> String

    private let url: URL
    private let handler: Handler
    private let listener: Mutex<Int32?> = Mutex(nil)

    public init(url: URL, handler: @escaping Handler) {
        self.url = url
        self.handler = handler
    }

    public func start() throws(SocketError) {
        let fd = try UnixSocket.listen(at: url)
        listener.withLock { $0 = fd }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "moss.control-socket"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func stop() {
        let fd = listener.withLock { value -> Int32? in
            defer { value = nil }
            return value
        }
        if let fd {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(url.path)
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            UnixSocket.setTimeout(client, seconds: 5)
            DispatchQueue.global(qos: .userInitiated).async { [handler] in
                let data = UnixSocket.read(client, until: UInt8(ascii: "\n"))
                let request = String(decoding: data, as: UTF8.self)
                Task {
                    let response = await handler(request)
                    UnixSocket.writeAll(client, Data(response.utf8))
                    close(client)
                }
            }
        }
    }
}

/// Serves the event socket, broadcasting each event as a line of JSON to every connected client.
/// Slow clients are disconnected rather than allowed to stall the window manager.
public final class EventBroadcaster: Sendable {
    private let url: URL
    private let listener: Mutex<Int32?> = Mutex(nil)
    private let subscribers: Mutex<[Int32]> = Mutex([])
    private let queue = DispatchQueue(label: "moss.event-socket", qos: .utility)

    public init(url: URL) {
        self.url = url
    }

    public var subscriberCount: Int { subscribers.withLock(\.count) }

    public func start() throws(SocketError) {
        let fd = try UnixSocket.listen(at: url)
        listener.withLock { $0 = fd }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "moss.event-socket"
        thread.start()
    }

    public func stop() {
        let fd = listener.withLock { value -> Int32? in
            defer { value = nil }
            return value
        }
        if let fd {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(url.path)
        }
        for subscriber in subscribers.withLock({ value -> [Int32] in
            defer { value = [] }
            return value
        }) {
            close(subscriber)
        }
    }

    public func publish(_ events: [Event]) {
        guard !events.isEmpty, subscriberCount > 0 else { return }
        let lines = events.map(QueryResponder.line(for:))
        let payload = Data(lines.map { $0 + "\n" }.joined().utf8)
        queue.async { [self] in
            let dead = subscribers.withLock { fds in fds.filter { !UnixSocket.writeAll($0, payload) } }
            guard !dead.isEmpty else { return }
            subscribers.withLock { fds in fds.removeAll(where: dead.contains) }
            dead.forEach { close($0) }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            subscribers.withLock { $0.append(client) }
        }
    }
}
