/// Identifies a window. On macOS this is the window server's `CGWindowID`.
public struct WindowID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }

    public static func < (lhs: WindowID, rhs: WindowID) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The identifier written in hexadecimal, e.g. `0x1a2b`.
    public var address: String { "0x" + String(rawValue, radix: 16) }

    /// Parses `0x…` addresses and plain decimal identifiers.
    public init?(address: String) {
        let text = address.trimmingWhitespace
        if text.lowercased().hasPrefix("0x"), let value = UInt32(text.dropFirst(2), radix: 16) {
            self.init(value)
        } else if let value = UInt32(text) {
            self.init(value)
        } else {
            return nil
        }
    }

    public var description: String { address }
}

/// Identifies a display. On macOS this is the `CGDirectDisplayID`.
public struct MonitorID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }

    public static func < (lhs: MonitorID, rhs: MonitorID) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { String(rawValue) }
}

/// Identifies a workspace. Workspaces are created on demand: numbered (`3`), named (`mail`),
/// or scratchpads (`scratchpad`, `scratchpad:notes`), which drop down over the workspace
/// shown and hide again.
public enum WorkspaceID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    case numbered(Int)
    case named(String)
    case scratchpad(String)

    public static let defaultScratchpadName = "scratchpad"

    public var isScratchpad: Bool {
        if case .scratchpad = self { return true }
        return false
    }

    public var number: Int? {
        if case .numbered(let n) = self { return n }
        return nil
    }

    /// The name shown for the workspace: its number, its name, or `scratchpad:NAME`.
    public var name: String {
        switch self {
        case .numbered(let n): String(n)
        case .named(let name): name
        case .scratchpad(let name): name == Self.defaultScratchpadName ? name : "scratchpad:\(name)"
        }
    }

    /// The selector that refers back to this workspace.
    public var selector: String { WorkspaceSelector.selector(for: self).description }

    public var description: String { name }

    private var sortKey: (Int, Int, String) {
        switch self {
        case .numbered(let n): (0, n, "")
        case .named(let name): (1, 0, name)
        case .scratchpad(let name): (2, 0, name)
        }
    }

    public static func < (lhs: WorkspaceID, rhs: WorkspaceID) -> Bool { lhs.sortKey < rhs.sortKey }
}

extension StringProtocol {
    var trimmingWhitespace: String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view.removeFirst() }
        while let last = view.last, last.isWhitespace { view.removeLast() }
        return String(view)
    }
}
