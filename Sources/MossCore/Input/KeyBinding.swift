/// Keyboard modifiers.
public struct Modifiers: OptionSet, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)
    /// Caps Lock, which Moss turns into a modifier of its own while it is used in a shortcut.
    public static let capsLock = Modifiers(rawValue: 1 << 5)

    public static let hyper: Modifiers = [.shift, .control, .option, .command]
    public static let meh: Modifiers = [.shift, .control, .option]

    /// Names written in shortcuts, in the order they are written.
    public static let names: [(name: String, modifiers: Modifiers)] = [
        ("caps", .capsLock), ("ctrl", .control), ("alt", .option), ("shift", .shift), ("cmd", .command), ("fn", .function),
        ("opt", .option), ("option", .option), ("control", .control), ("command", .command),
        ("hyper", .hyper), ("meh", .meh),
    ]

    /// The name of a single modifier, as written in shortcuts.
    static func name(of modifier: Modifiers) -> String? { names.first { $0.modifiers == modifier }?.name }

    /// Parses a modifier name, such as `cmd` or `hyper`.
    public init?(name: String) {
        guard let match = Self.names.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = match.modifiers
    }

    /// Parses modifiers joined with `-`, such as `ctrl-alt`.
    public init(parsing text: String) throws(KeyBindingError) {
        var result: Modifiers = []
        for word in text.lowercased().split(separator: "-") {
            guard let modifiers = Modifiers(name: String(word)) else { throw .unknownModifier(String(word)) }
            result.formUnion(modifiers)
        }
        self = result
    }

    /// The modifiers joined with `-`, such as `ctrl-alt`; all four of Control, Option, Shift and
    /// Command together are written `hyper`.
    public var description: String {
        var parts: [String] = []
        var rest = self
        if contains(.capsLock) { parts.append("caps"); rest.remove(.capsLock) }
        if rest.isSuperset(of: .hyper) {
            parts.append("hyper")
            rest.subtract(.hyper)
        }
        let single: [Modifiers] = [.control, .option, .shift, .command, .function]
        return (parts + single.filter(rest.contains).compactMap(Self.name(of:))).joined(separator: "-")
    }

    /// Display symbols in the conventional macOS order (⌃⌥⇧⌘).
    public var symbols: String {
        var text = ""
        if contains(.function) { text += "fn " }
        if contains(.capsLock) { text += "⇪" }
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// A mouse button that can drag windows.
public enum MouseButton: Int, Hashable, Sendable, CaseIterable {
    case left = 0
    case right = 1
    case middle = 2

    var name: String {
        switch self {
        case .left: "left"
        case .right: "right"
        case .middle: "middle"
        }
    }
}

/// What a shortcut responds to: a key, dragging with a mouse button, or scrolling.
public enum Trigger: Hashable, Sendable, CustomStringConvertible {
    /// A key named by its symbol (`q`, `return`, `left`, `f1`…), resolved through the active keyboard layout.
    case key(String)
    /// A raw macOS virtual key code, written `keycode-12`.
    case keyCode(UInt16)
    /// Dragging with a mouse button, written `left-drag`, `right-drag` or `middle-drag`.
    case drag(MouseButton)
    /// Scrolling, written `scroll-up`, `scroll-down`, `scroll-left` or `scroll-right`.
    case scroll(Direction)

    public init(parsing text: String) throws(KeyBindingError) {
        let value = text.trimmingWhitespace.lowercased()
        guard !value.isEmpty else { throw .missingKey }
        if value.hasPrefix("keycode-") {
            guard let code = UInt16(value.dropFirst("keycode-".count)) else { throw .invalidKey(value) }
            self = .keyCode(code)
        } else if value.hasSuffix("-drag") {
            guard let button = MouseButton.allCases.first(where: { "\($0.name)-drag" == value }) else { throw .invalidKey(value) }
            self = .drag(button)
        } else if value.hasPrefix("scroll-") {
            guard let direction = Direction(argument: String(value.dropFirst("scroll-".count))) else { throw .invalidKey(value) }
            self = .scroll(direction)
        } else {
            guard let key = KeyNames.canonical(value) else { throw .invalidKey(value) }
            self = .key(key)
        }
    }

    public var isPointer: Bool {
        switch self {
        case .drag, .scroll: true
        case .key, .keyCode: false
        }
    }

    public var description: String {
        switch self {
        case .key(let name): KeyNames.configName(for: name)
        case .keyCode(let code): "keycode-\(code)"
        case .drag(let button): "\(button.name)-drag"
        case .scroll(let direction): "scroll-\(direction.rawValue)"
        }
    }
}

/// What dragging a window with a mouse button does.
public enum DragAction: String, Hashable, Sendable, CaseIterable {
    case move
    case resize
}

/// A shortcut: modifiers and a trigger that run an action, or drag windows.
public struct KeyBinding: Hashable, Sendable {
    public enum Command: Hashable, Sendable {
        case action(Action)
        case drag(DragAction)
    }

    public struct Options: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// The action runs again while the keys are held.
        public static let repeats = Options(rawValue: 1 << 0)
        /// The action runs when the key is released rather than pressed.
        public static let onRelease = Options(rawValue: 1 << 1)
        /// The keys also reach the application in front.
        public static let passesThrough = Options(rawValue: 1 << 2)
    }

    public var modifiers: Modifiers
    public var trigger: Trigger
    public var command: Command
    public var options: Options
    /// A name for the shortcut, shown in the palette.
    public var summary: String?
    /// The mode the shortcut belongs to; `nil` for the default shortcuts.
    public var mode: String?

    public init(modifiers: Modifiers, trigger: Trigger, command: Command, options: Options = [], summary: String? = nil, mode: String? = nil) {
        self.modifiers = modifiers
        self.trigger = trigger
        self.command = command
        self.options = options
        self.summary = summary
        self.mode = mode
    }

    public var chord: KeyChord { KeyChord(modifiers: modifiers, key: trigger) }

    /// The action the shortcut runs, if it is not a drag.
    public var action: Action? {
        if case .action(let action) = command { return action }
        return nil
    }
}

public enum KeyBindingError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownModifier(String)
    case missingKey
    case invalidKey(String)
    case mainKeyUnavailable
    case invalidDrag(String)
    case action(ActionError)

    public var description: String {
        switch self {
        case .unknownModifier(let name): "unknown modifier '\(name)'; use cmd, ctrl, alt, shift, fn, caps, hyper, meh or mod"
        case .missingKey: "the shortcut has no key"
        case .invalidKey(let key): "unknown key '\(key)'"
        case .mainKeyUnavailable: "'mod' stands for the main key, which is only available in shortcuts"
        case .invalidDrag(let name): "dragging can move or resize a window, not '\(name)'"
        case .action(let error): error.description
        }
    }
}
