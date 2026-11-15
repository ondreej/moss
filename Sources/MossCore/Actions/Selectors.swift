/// Selects a workspace: `3`, `mail`, `next`, `previous`, `last`, `empty`, `+1`, or a scratchpad,
/// `scratchpad` or `scratchpad:notes`.
public enum WorkspaceSelector: Hashable, Sendable, CustomStringConvertible {
    /// A workspace by number.
    case id(Int)
    /// A workspace by name.
    case named(String)
    case scratchpad(String)
    /// The workspace numbered this far from the current one, e.g. `+1`.
    case relative(Int)
    /// The open workspace on the focused display this far from the current one, in order:
    /// `next` and `previous`.
    case adjacent(Int)
    /// The workspace shown before the current one.
    case last
    /// The first workspace number with no windows.
    case empty

    private static let keywords: Set<String> = ["next", "previous", "last", "empty", "scratchpad"]

    /// The selector that refers to `workspace`.
    public static func selector(for workspace: WorkspaceID) -> WorkspaceSelector {
        switch workspace {
        case .numbered(let number): .id(number)
        case .named(let name): .named(name)
        case .scratchpad(let name): .scratchpad(name)
        }
    }

    public init(parsing text: String) throws(ActionError) {
        let value = text.trimmingWhitespace
        let lower = value.lowercased()
        guard !value.isEmpty else { throw .missingArgument("a workspace") }
        if let number = Int(value), !value.hasPrefix("+"), !value.hasPrefix("-") {
            self = .id(number)
        } else if let first = value.first, first == "+" || first == "-", let delta = Int(value) {
            self = .relative(delta)
        } else if lower == "next" || lower == "previous" {
            self = .adjacent(lower == "next" ? 1 : -1)
        } else if lower == "last" {
            self = .last
        } else if lower == "empty" {
            self = .empty
        } else if lower == "scratchpad" {
            self = .scratchpad(WorkspaceID.defaultScratchpadName)
        } else if lower.hasPrefix("scratchpad:") {
            let name = String(value.dropFirst("scratchpad:".count))
            self = .scratchpad(name.isEmpty ? WorkspaceID.defaultScratchpadName : name)
        } else if lower.hasPrefix("name:") {
            let name = String(value.dropFirst("name:".count))
            guard !name.isEmpty else { throw .invalidArgument("the workspace name is empty") }
            self = .named(name)
        } else {
            self = .named(value)
        }
    }

    public var description: String {
        switch self {
        case .id(let n): return String(n)
        case .named(let name):
            // Names that read like another selector are spelled out.
            let isAmbiguous = Self.keywords.contains(name.lowercased()) || Int(name) != nil || name.lowercased().hasPrefix("scratchpad:") || name.contains(" ")
            return isAmbiguous ? "name:\(name)" : name
        case .scratchpad(let name): return name == WorkspaceID.defaultScratchpadName ? "scratchpad" : "scratchpad:\(name)"
        case .relative(let n): return n >= 0 ? "+\(n)" : "\(n)"
        case .adjacent(let n): return n >= 0 ? "next" : "previous"
        case .last: return "last"
        case .empty: return "empty"
        }
    }
}

/// Selects a window: `focused`, `floating`, `tiled`, `app:REGEX` (the bundle identifier or the
/// application's name), `title:REGEX`, `pid:N` or `id:0x1a2b`. A bare word matches the app.
public enum WindowSelector: Hashable, Sendable, CustomStringConvertible {
    case focused
    case app(Pattern)
    case title(Pattern)
    case pid(Int32)
    case id(WindowID)
    case floating
    case tiled

    public init(parsing text: String) throws(ActionError) {
        let value = text.trimmingWhitespace
        guard let colon = value.firstIndex(of: ":") else {
            switch value.lowercased() {
            case "focused": self = .focused
            case "floating": self = .floating
            case "tiled": self = .tiled
            case "": throw .missingArgument("a window")
            default: self = .app(try Pattern.compile(value))
            }
            return
        }
        let key = value[..<colon].lowercased()
        let argument = String(value[value.index(after: colon)...])
        switch key {
        case "app": self = .app(try Pattern.compile(argument))
        case "title": self = .title(try Pattern.compile(argument))
        case "pid":
            guard let pid = Int32(argument.trimmingWhitespace) else { throw .invalidArgument("'\(argument)' is not a process identifier") }
            self = .pid(pid)
        case "id":
            guard let id = WindowID(address: argument) else { throw .invalidArgument("'\(argument)' is not a window identifier") }
            self = .id(id)
        default:
            throw .invalidArgument("unknown window selector '\(key):'; use app:, title:, pid: or id:")
        }
    }

    public func matches(_ window: Window, focusedWindow: WindowID?) -> Bool {
        switch self {
        case .focused: window.id == focusedWindow
        case .app(let pattern): pattern.matches(window.properties.appID) || pattern.matches(window.properties.appName)
        case .title(let pattern): pattern.matches(window.properties.title)
        case .pid(let pid): window.properties.pid == pid
        case .id(let id): window.id == id
        case .floating: window.isFloating
        case .tiled: window.isTiled
        }
    }

    public var description: String {
        switch self {
        case .focused: "focused"
        case .app(let p): "app:\(p)"
        case .title(let p): "title:\(p)"
        case .pid(let pid): "pid:\(pid)"
        case .id(let id): "id:\(id.address)"
        case .floating: "floating"
        case .tiled: "tiled"
        }
    }
}

/// Selects a display: `left`, `right`, `up`, `down`, `next`, `previous`, `main`, `current`,
/// `built-in`, `external`, a number, or (part of) its name.
public enum MonitorSelector: Hashable, Sendable, CustomStringConvertible {
    case current
    case main
    case direction(Direction)
    case relative(Int)
    case id(MonitorID)
    case name(String)

    public init(parsing text: String) throws(ActionError) {
        let value = text.trimmingWhitespace
        let lower = value.lowercased()
        guard !value.isEmpty else { throw .missingArgument("a display") }
        switch lower {
        case "current": self = .current
        case "main": self = .main
        case "next": self = .relative(1)
        case "previous": self = .relative(-1)
        case "left", "right", "up", "down": self = .direction(Direction(argument: lower)!)
        default:
            if let first = value.first, first == "+" || first == "-", let delta = Int(value) {
                self = .relative(delta)
            } else if let id = UInt32(value) {
                self = .id(MonitorID(id))
            } else {
                self = .name(value)
            }
        }
    }

    public var description: String {
        switch self {
        case .current: "current"
        case .main: "main"
        case .direction(let d): d.rawValue
        case .relative(1): "next"
        case .relative(-1): "previous"
        case .relative(let n): n >= 0 ? "+\(n)" : "\(n)"
        case .id(let id): String(id.rawValue)
        case .name(let name): name
        }
    }
}

/// A compiled regular expression that compares and hashes by its source.
public struct Pattern: Hashable, Sendable, CustomStringConvertible {
    public let source: String
    // `Regex` is an immutable value; it is only marked non-`Sendable` because of its type-erased output.
    nonisolated(unsafe) private let regex: Regex<AnyRegexOutput>

    public static func compile(_ source: String) throws(ActionError) -> Pattern {
        do {
            return Pattern(source: source, regex: try Regex(source))
        } catch {
            throw .invalidArgument("invalid regular expression '\(source)'")
        }
    }

    private init(source: String, regex: Regex<AnyRegexOutput>) {
        self.source = source
        self.regex = regex
    }

    /// Whether the expression matches anywhere in `text`. Anchor with `^…$` for exact matches.
    public func matches(_ text: String) -> Bool {
        (try? regex.firstMatch(in: text)) != nil
    }

    public static func == (lhs: Pattern, rhs: Pattern) -> Bool { lhs.source == rhs.source }
    public func hash(into hasher: inout Hasher) { hasher.combine(source) }
    public var description: String { source }
}
