public import Foundation

/// Locations of the control and event sockets.
///
/// Moss exposes two Unix sockets: one answers requests from `moss`, the other
/// streams events, each a line of JSON.
public struct SocketPaths: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The default directory: `$MOSS_RUNTIME_DIR`, or `moss` inside the per-user temporary directory.
    public static var standard: SocketPaths {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["MOSS_RUNTIME_DIR"], !override.isEmpty {
            return SocketPaths(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        return SocketPaths(directory: userTemporaryDirectory.appendingPathComponent("moss", isDirectory: true))
    }

    public var control: URL { directory.appendingPathComponent("control.sock") }
    public var events: URL { directory.appendingPathComponent("events.sock") }

    /// The per-user temporary directory, which is private to the user and stable across processes.
    private static var userTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    /// Creates the socket directory, readable only by the current user.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
