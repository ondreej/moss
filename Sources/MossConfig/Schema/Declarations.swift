public import MossCore

/// Reads and writes the parts of the configuration file that are not options: shortcuts,
/// rules and workspaces. Shared by the evaluator and the settings window, so both read the
/// file the same way.
public enum Declarations {
    // MARK: Shortcuts

    /// A keyboard shortcut from `[shortcuts]` or `[modes.NAME]`: its keys and their action, in
    /// quotes or as a table with options.
    public static func binding(keys: String, value: TOMLValue, mode: String?, mainKey: Modifiers) throws(ConfigError) -> KeyBinding {
        let chord = try chord(keys, mainKey: mainKey)
        guard !chord.key.isPointer else { throw .other("mouse shortcuts belong in [mouse]") }
        let action: String, options: KeyBinding.Options, summary: String?
        switch value {
        case .string(let text):
            (action, options, summary) = (text, [], nil)
        case .table(let pairs):
            var text: String?, description: String?
            var collected: KeyBinding.Options = []
            for pair in pairs {
                switch (pair.key, pair.value) {
                case ("action", .string(let value)): text = value
                case ("description", .string(let value)): description = value
                case ("repeat", .boolean(let on)): if on { collected.insert(.repeats) }
                case ("on-release", .boolean(let on)): if on { collected.insert(.onRelease) }
                case ("pass-through", .boolean(let on)): if on { collected.insert(.passesThrough) }
                default: throw .other("unknown shortcut setting '\(pair.key)'; use action, repeat, on-release, pass-through or description")
                }
            }
            guard let text else { throw .other("the shortcut needs an action") }
            (action, options, summary) = (text, collected, description)
        default:
            throw .other("a shortcut runs an action, written in quotes")
        }
        do {
            return KeyBinding(modifiers: chord.modifiers, trigger: chord.key, command: .action(try Action(parsing: action)), options: options, summary: summary, mode: mode)
        } catch {
            throw .other(error.description)
        }
    }

    /// A mouse shortcut from `[mouse]`: dragging moves or resizes a window, scrolling runs an action.
    public static func mouseBinding(keys: String, value: TOMLValue, mainKey: Modifiers) throws(ConfigError) -> KeyBinding {
        let chord = try chord(keys, mainKey: mainKey)
        guard case .string(let text) = value else { throw .other("write the action in quotes") }
        switch chord.key {
        case .drag:
            guard let drag = DragAction(rawValue: text.lowercased()) else { throw .other(KeyBindingError.invalidDrag(text).description) }
            return KeyBinding(modifiers: chord.modifiers, trigger: chord.key, command: .drag(drag))
        case .scroll:
            do {
                return KeyBinding(modifiers: chord.modifiers, trigger: chord.key, command: .action(try Action(parsing: text)))
            } catch {
                throw .other(error.description)
            }
        case .key, .keyCode:
            throw .other("keyboard shortcuts belong in [shortcuts]")
        }
    }

    private static func chord(_ keys: String, mainKey: Modifiers) throws(ConfigError) -> KeyChord {
        do {
            return try KeyChord(parsing: keys, mainKey: mainKey)
        } catch {
            throw .other(error.description)
        }
    }

    /// How a shortcut is written: its action in quotes, or a table when it has options.
    public static func value(for binding: KeyBinding) -> TOMLValue {
        switch binding.command {
        case .drag(let drag):
            return .string(drag.rawValue)
        case .action(let action):
            var pairs: [TOMLPair] = []
            if binding.options.contains(.repeats) { pairs.append(TOMLPair("repeat", .boolean(true))) }
            if binding.options.contains(.onRelease) { pairs.append(TOMLPair("on-release", .boolean(true))) }
            if binding.options.contains(.passesThrough) { pairs.append(TOMLPair("pass-through", .boolean(true))) }
            if let summary = binding.summary { pairs.append(TOMLPair("description", .string(summary))) }
            return pairs.isEmpty ? .string(action.description) : .table([TOMLPair("action", .string(action.description))] + pairs)
        }
    }

    /// The table a shortcut is written in.
    public static func table(for binding: KeyBinding) -> [String] {
        if binding.trigger.isPointer { return ["mouse"] }
        return binding.mode.map { ["modes", $0] } ?? ["shortcuts"]
    }

    // MARK: Rules and workspaces

    /// A value as the text rules and workspace settings read: lists become words.
    public static func text(of value: TOMLValue) -> String {
        switch value {
        case .string(let text): text
        case .integer(let number): String(number)
        case .float(let number): ValueParser.format(number)
        case .boolean(let flag): flag ? "true" : "false"
        case .array(let items): items.map(text(of:)).joined(separator: " ")
        case .table: value.text
        }
    }

    /// Keys whose values are always written as text, even when they look like numbers.
    private static let textKeys: Set<String> = ["name", "display", "layout", "when-empty", "stack-side", "direction", "workspace", "tag", "tabs"]

    /// The value text is written as: `true` and `false` as booleans, numbers as numbers, several
    /// numbers as a list, anything else in quotes.
    public static func value(ofText text: String, key: String) -> TOMLValue {
        let lastKey = key.split(separator: ".").last.map(String.init) ?? key
        if textKeys.contains(lastKey) || key.hasPrefix(WindowRule.conditionPrefix) && lastKey != "floating" && lastKey != "fullscreen"
            && lastKey != "pinned" && lastKey != "focused" && lastKey != "dialog" && lastKey != "tabbed" {
            return .string(text)
        }
        switch text {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        default: break
        }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let numbers = words.compactMap(ValueParser.tomlNumber)
        if !words.isEmpty, numbers.count == words.count { return numbers.count == 1 ? numbers[0] : .array(numbers) }
        return .string(text)
    }

    /// A table's keys and values as text, with dotted keys such as `if.app` joined.
    public static func entries(of table: TOMLTable, prefix: String = "") throws(ConfigError) -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        for (key, node) in table.entries {
            switch node {
            case .value(let value, _): result.append((prefix + key, text(of: value)))
            case .table(let child): result += try entries(of: child, prefix: prefix + key + ".")
            case .arrayOfTables: throw .other("'\(key)' cannot be a list of tables")
            }
        }
        return result
    }

    /// A section's keys and values as text.
    public static func entries(of section: TOMLDocument.Section) -> [(key: String, value: String)] {
        section.entries.map { ($0.key.joined(separator: "."), text(of: $0.value)) }
    }

    /// Keys and text as TOML keys and values, ready to be written.
    public static func tomlEntries(_ entries: [(key: String, value: String)]) -> [(key: [String], value: TOMLValue)] {
        entries.map { (key: $0.key.split(separator: ".").map(String.init), value: value(ofText: $0.value, key: $0.key)) }
    }
}
