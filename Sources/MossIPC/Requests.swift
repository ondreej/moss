public import MossCore

/// A request to the control socket: one of the named requests below, or otherwise an action,
/// such as `focus left`. `--json` before the request asks for a JSON answer.
public enum ControlCommand: Hashable, Sendable {
    /// Runs an action, written as in a shortcut.
    case action(String)
    case windows
    case workspaces
    case displays
    /// The focused window.
    case focused
    case shortcuts
    case status
    case version
    /// An option's value, or every option's when `nil`.
    case get(String?)
    /// Sets an option until the configuration is reloaded.
    case set(option: String, value: String)
    case notify(Notice)
    /// Removes every notice.
    case dismiss
    /// Shows a message in the error bar until the configuration is reloaded.
    case error(message: String, color: Color)
    case clearError

    /// Requests that only read state.
    public var isQuery: Bool {
        switch self {
        case .windows, .workspaces, .displays, .focused, .shortcuts, .status, .version, .get: true
        case .action, .set, .notify, .dismiss, .error, .clearError: false
        }
    }

    public init(parsing text: String) throws(ControlRequestError) {
        let trimmed = text.trimmingSpaces
        let name = String(trimmed.prefix { !$0.isWhitespace }).lowercased()
        let argument = trimmed.dropFirst(name.count).trimmingSpaces
        guard !name.isEmpty else { throw .missingArgument("an action or a request, such as 'windows'") }

        switch name {
        case "windows": self = .windows
        case "workspaces": self = .workspaces
        case "displays": self = .displays
        case "focused": self = .focused
        case "shortcuts": self = .shortcuts
        case "status": self = .status
        case "version": self = .version
        case "get": self = .get(argument.isEmpty ? nil : argument)
        case "set":
            let option = String(argument.prefix { !$0.isWhitespace })
            let value = argument.dropFirst(option.count).trimmingSpaces
            guard !option.isEmpty, !value.isEmpty else { throw .missingArgument("set needs an option and a value, such as 'set layout.gaps 10'") }
            self = .set(option: option, value: value)
        case "notify": self = .notify(try Self.notice(argument))
        case "dismiss": self = .dismiss
        case "error":
            if argument == "--clear" {
                self = .clearError
            } else {
                let (options, message) = try Self.options(argument, allowed: ["color"])
                guard !message.isEmpty else { throw .missingArgument("error needs a message, or --clear") }
                self = .error(message: message, color: try options["color"].map(Self.color) ?? ErrorBar.defaultColor)
            }
        default:
            self = .action(trimmed)
        }
    }

    /// Parses `[--icon NAME] [--seconds N] [--color COLOR] MESSAGE`.
    private static func notice(_ text: String) throws(ControlRequestError) -> Notice {
        let (options, message) = try options(text, allowed: ["icon", "seconds", "color"])
        guard !message.isEmpty else { throw .missingArgument("notify needs a message") }
        var icon: Notice.Icon?
        if let name = options["icon"] {
            guard let value = Notice.Icon(rawValue: name.lowercased()) else { throw .invalidArgument("--icon takes info, ok, warning or error") }
            icon = value
        }
        var seconds = 4.0
        if let text = options["seconds"] {
            guard let value = Double(text), value > 0 else { throw .invalidArgument("--seconds takes a number of seconds") }
            seconds = value
        }
        return Notice(icon: icon, message: message, color: try options["color"].map(color), milliseconds: Int(seconds * 1000))
    }

    /// Splits leading `--name value` options from the rest of the text.
    private static func options(_ text: String, allowed: Set<String>) throws(ControlRequestError) -> ([String: String], String) {
        var options: [String: String] = [:]
        var rest = Substring(text)
        while rest.hasPrefix("--") {
            let name = String(rest.dropFirst(2).prefix { !$0.isWhitespace })
            guard allowed.contains(name) else { throw .invalidArgument("unknown option --\(name)") }
            rest = rest.dropFirst(2 + name.count).drop { $0.isWhitespace }
            let value = String(rest.prefix { !$0.isWhitespace })
            guard !value.isEmpty else { throw .missingArgument("--\(name) needs a value") }
            options[name] = value
            rest = rest.dropFirst(value.count).drop { $0.isWhitespace }
        }
        return (options, String(rest).trimmingSpaces)
    }

    private static func color(_ text: String) throws(ControlRequestError) -> Color {
        guard let color = ColorNotation.parse(text) else { throw .invalidArgument("'\(text)' is not a color; use #rrggbb or accent") }
        return color
    }

    public var wireText: String {
        switch self {
        case .action(let text): text
        case .windows: "windows"
        case .workspaces: "workspaces"
        case .displays: "displays"
        case .focused: "focused"
        case .shortcuts: "shortcuts"
        case .status: "status"
        case .version: "version"
        case .get(let option): option.map { "get \($0)" } ?? "get"
        case .set(let option, let value): "set \(option) \(value)"
        case .notify(let notice):
            ["notify", notice.icon.map { "--icon \($0.rawValue)" }, "--seconds \(Double(notice.milliseconds) / 1000)", "--color \(notice.color)", notice.message]
                .compactMap { $0 }.joined(separator: " ")
        case .dismiss: "dismiss"
        case .error(let message, let color): "error --color \(color) \(message)"
        case .clearError: "error --clear"
        }
    }

    /// Every request, for help output.
    public static let catalog: [(usage: String, summary: String)] = [
        ("windows", "List windows"),
        ("workspaces", "List workspaces"),
        ("displays", "List displays"),
        ("focused", "Show the focused window"),
        ("shortcuts", "List shortcuts"),
        ("status", "Show the version, permissions, mode and configuration problems"),
        ("get [OPTION]", "Show an option's value, or every option's"),
        ("set OPTION VALUE", "Change an option until the configuration is reloaded"),
        ("notify [--icon NAME] [--seconds N] [--color C] TEXT", "Show a notice; icons are info, ok, warning and error"),
        ("dismiss", "Remove every notice"),
        ("error [--color C] TEXT | --clear", "Show a message at the top of the screen until the next reload"),
        ("version", "Show the version"),
    ]
}

public struct ControlRequest: Hashable, Sendable {
    public var json: Bool
    public var command: ControlCommand

    public static let jsonFlag = "--json"

    public init(json: Bool = false, command: ControlCommand) {
        self.json = json
        self.command = command
    }

    public init(parsing text: String) throws(ControlRequestError) {
        var body = text.trimmingSpaces
        let json = body.hasPrefix(Self.jsonFlag + " ") || body == Self.jsonFlag
        if json { body = String(body.dropFirst(Self.jsonFlag.count)) }
        self.init(json: json, command: try ControlCommand(parsing: body))
    }

    public var wireText: String { (json ? Self.jsonFlag + " " : "") + command.wireText }
}

public enum ControlRequestError: Error, Hashable, Sendable, CustomStringConvertible {
    case missingArgument(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .missingArgument(let detail): "missing argument: \(detail)"
        case .invalidArgument(let detail): detail
        }
    }
}

extension StringProtocol {
    var trimmingSpaces: String {
        var view = Substring(self)
        while let first = view.first, first.isWhitespace { view.removeFirst() }
        while let last = view.last, last.isWhitespace { view.removeLast() }
        return String(view)
    }
}
