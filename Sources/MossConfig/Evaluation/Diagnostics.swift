public import Foundation

public enum ConfigError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidValue(String, expected: String)
    case outOfRange(String, range: String)
    case unknownOption(String, suggestion: String?)
    case syntax(String)
    case unreadable(String)
    case other(String)

    public var description: String {
        switch self {
        case .invalidValue(let value, let expected): "invalid value '\(value)', expected \(expected)"
        case .outOfRange(let value, let range): "value '\(value)' is outside the allowed range \(range)"
        case .unknownOption(let path, let suggestion): "unknown option '\(path)'" + (suggestion.map { ", did you mean '\($0)'?" } ?? "")
        case .syntax(let detail): detail
        case .unreadable(let detail): detail
        case .other(let detail): detail
        }
    }
}

/// A position in a configuration file.
public struct SourceLocation: Hashable, Sendable, CustomStringConvertible {
    public var file: URL?
    /// Zero-based line index.
    public var line: Int

    public init(file: URL?, line: Int) {
        self.file = file
        self.line = line
    }

    public var description: String {
        let name = file?.lastPathComponent ?? "<config>"
        return "\(name):\(line + 1)"
    }
}

/// A problem found while evaluating a configuration.
public struct Diagnostic: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Hashable, Sendable, Comparable {
        case note, warning, error

        private var rank: Int { self == .note ? 0 : self == .warning ? 1 : 2 }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var severity: Severity
    public var message: String
    public var location: SourceLocation

    public init(_ severity: Severity, _ message: String, at location: SourceLocation) {
        self.severity = severity
        self.message = message
        self.location = location
    }

    public var description: String { "\(location): \(severity.rawValue): \(message)" }
}
