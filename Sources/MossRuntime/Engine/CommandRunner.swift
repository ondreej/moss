import Foundation
import Synchronization

/// Runs shell commands for the `run` action and startup commands.
public protocol CommandRunner: Sendable {
    func run(_ command: String, environment: [String: String])
}

/// Launches commands with `/bin/sh -c`, detached from Moss's input and output.
public final class ShellCommandRunner: CommandRunner {
    /// Running processes are retained until they exit so they are reaped properly.
    private let running = Mutex<[ObjectIdentifier: ProcessBox]>([:])

    public init() {}

    public func run(_ command: String, environment: [String: String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let key = ObjectIdentifier(process)
        process.terminationHandler = { [weak self] _ in
            _ = self?.running.withLock { $0.removeValue(forKey: key) }
        }
        running.withLock { $0[key] = ProcessBox(process) }
        do {
            try process.run()
        } catch {
            _ = running.withLock { $0.removeValue(forKey: key) }
        }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
    }
}

public enum MossVersion {
    public static let current = "0.1.0"
}
