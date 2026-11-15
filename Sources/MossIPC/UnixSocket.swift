import Foundation

public struct SocketError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32

    init(_ operation: String, code: Int32 = errno) {
        self.operation = operation
        self.code = code
    }

    public var description: String { "\(operation) failed: \(String(cString: strerror(code)))" }

    public var isConnectionRefused: Bool { code == ECONNREFUSED || code == ENOENT }
}

/// Thin wrappers around POSIX Unix-domain stream sockets.
enum UnixSocket {
    static func address(for url: URL) throws(SocketError) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count <= capacity else { throw SocketError("socket path too long", code: ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.enumerated() { buffer[index] = UInt8(bitPattern: byte) }
        }
        return address
    }

    static func makeSocket() throws(SocketError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// Binds and listens on `url`, replacing a stale socket file.
    static func listen(at url: URL) throws(SocketError) -> Int32 {
        let fd = try makeSocket()
        unlink(url.path)
        var address = try address(for: url)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = SocketError("bind")
            close(fd)
            throw error
        }
        chmod(url.path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else {
            let error = SocketError("listen")
            close(fd)
            throw error
        }
        return fd
    }

    static func connect(to url: URL) throws(SocketError) -> Int32 {
        let fd = try makeSocket()
        var address = try address(for: url)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let error = SocketError("connect")
            close(fd)
            throw error
        }
        return fd
    }

    static func setTimeout(_ fd: Int32, seconds: Double) {
        var interval = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all of `data`, retrying on partial writes.
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    /// Reads until `delimiter` (exclusive) or end of stream.
    static func read(_ fd: Int32, until delimiter: UInt8? = nil, limit: Int = 1 << 20) -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while result.count < limit {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            let chunk = buffer[0..<count]
            if let delimiter, let end = chunk.firstIndex(of: delimiter) {
                result.append(contentsOf: chunk[..<end])
                break
            }
            result.append(contentsOf: chunk)
        }
        return result
    }
}
