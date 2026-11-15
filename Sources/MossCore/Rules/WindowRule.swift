/// A rule applied to windows that match all of its conditions. In the configuration file,
/// a `[[rules]]` table holds the conditions under `if.` and one or more effects:
///
///     [[rules]]
///     if.app = "com.apple.calculator"
///     float = true
///
/// Each effect becomes a rule of its own with the table's conditions.
public struct WindowRule: Hashable, Sendable {
    public var effect: Effect
    public var conditions: [Condition]

    public init(effect: Effect, conditions: [Condition]) {
        self.effect = effect
        self.conditions = conditions
    }

    public enum Effect: Hashable, Sendable {
        case float
        case tile
        case fullscreen
        case maximize
        case keepSize
        case pin
        case center
        case position(ResizeParameter.Amount, ResizeParameter.Amount)
        case size(ResizeParameter.Amount, ResizeParameter.Amount)
        case workspace(WorkspaceSelector, silent: Bool)
        case display(MonitorSelector)
        case noInitialFocus
        case noFocus
        case noBorder
        case borderWidth(Double)
        case borderColor(active: Gradient, inactive: Gradient?)
        case noDim
        case cornerRadius(Double)
        /// Keeps focus on the window while it is visible.
        case keepFocus
        case minSize(Double, Double)
        case maxSize(Double, Double)
        case tabs(TabsRule)
        case tag(String)
    }

    /// How a window takes part in tab groups when it opens.
    public enum TabsRule: String, Hashable, Sendable, CaseIterable {
        /// The window opens as a tab group of its own.
        case own
        /// The window never joins a tab group.
        case never
    }

    /// `tag +name` adds a tag, `tag -name` removes it and `tag name` toggles it.
    public enum TagChange: Hashable, Sendable, CustomStringConvertible {
        case add(String)
        case remove(String)
        case toggle(String)

        public init(parsing text: String) throws(ActionError) {
            let value = text.trimmingWhitespace
            switch value.first {
            case "+": self = .add(String(value.dropFirst()))
            case "-": self = .remove(String(value.dropFirst()))
            default: self = .toggle(value)
            }
            guard !name.isEmpty else { throw .missingArgument("a tag name") }
        }

        public var name: String {
            switch self {
            case .add(let name), .remove(let name), .toggle(let name): name
            }
        }

        /// Applies the change to `tags`; toggling looks at `present`, every tag the window has.
        public func apply(to tags: inout Set<String>, present: Set<String>) {
            switch self {
            case .add(let name): tags.insert(name)
            case .remove(let name): tags.remove(name)
            case .toggle(let name): if present.contains(name) { tags.remove(name) } else { tags.insert(name) }
            }
        }

        public var description: String {
            switch self {
            case .add(let name): "+\(name)"
            case .remove(let name): "-\(name)"
            case .toggle(let name): name
            }
        }
    }

    public enum Condition: Hashable, Sendable {
        /// The application's bundle identifier or name matches.
        case app(Pattern)
        case title(Pattern)
        case floating(Bool)
        case fullscreen(Bool)
        case pinned(Bool)
        case focused(Bool)
        case workspace(WorkspaceID)
        /// The window is a dialog, sheet or panel.
        case dialog(Bool)
        case tag(String)
        /// The window is in a tab group.
        case tabbed(Bool)
    }

    public func matches(_ window: Window, focused: Bool) -> Bool {
        conditions.allSatisfy { condition in
            switch condition {
            case .app(let p): p.matches(window.properties.appID) || p.matches(window.properties.appName)
            case .title(let p): p.matches(window.properties.title)
            case .floating(let value): window.isFloating == value
            case .fullscreen(let value): (window.fullscreen != nil) == value
            case .pinned(let value): window.isPinned == value
            case .focused(let value): focused == value
            case .workspace(let id): window.workspace == id
            case .dialog(let value): (window.properties.kind != .standard) == value
            case .tag(let name): window.allTags.contains(name)
            case .tabbed(let value): (window.group != nil) == value
            }
        }
    }
}

// MARK: - Reading and writing

extension WindowRule {
    /// The prefix of condition keys in a `[[rules]]` table.
    public static let conditionPrefix = "if."

    /// Builds rules from the keys and values of a `[[rules]]` table, one rule per effect.
    /// Values are written as text: `true`, `3`, `800 600`, `#ff8800`.
    public static func rules(from entries: [(key: String, value: String)]) throws(ActionError) -> [WindowRule] {
        var conditions: [Condition] = []
        var effectEntries: [(key: String, value: String)] = []
        for (key, value) in entries {
            if key.hasPrefix(conditionPrefix) {
                conditions.append(try Condition(key: String(key.dropFirst(conditionPrefix.count)), value: value))
            } else {
                effectEntries.append((key, value))
            }
        }
        guard !conditions.isEmpty else { throw .invalidArgument("a rule needs at least one condition, such as if.app = \"com.apple.Safari\"") }
        guard !effectEntries.isEmpty else { throw .invalidArgument("a rule needs at least one effect, such as float = true") }
        return try Effect.effects(from: effectEntries).map { WindowRule(effect: $0, conditions: conditions) }
    }

    /// The rule's keys and values, conditions first, as written in a `[[rules]]` table.
    public var entries: [(key: String, value: String)] {
        conditions.map { (Self.conditionPrefix + $0.key, $0.value) } + effect.entries
    }
}

extension WindowRule.Effect {
    /// Reads effects from keys and values. `silent` applies to `workspace`; effects switched
    /// off, such as `fullscreen = false`, give nothing.
    public static func effects(from entries: [(key: String, value: String)]) throws(ActionError) -> [WindowRule.Effect] {
        var effects: [WindowRule.Effect] = []
        var silent = false
        for (key, value) in entries {
            if key == "silent" {
                silent = try flag(value, key)
                continue
            }
            if let effect = try WindowRule.Effect(key: key, value: value) { effects.append(effect) }
        }
        if silent {
            guard let index = effects.firstIndex(where: { if case .workspace = $0 { true } else { false } }),
                  case .workspace(let selector, _) = effects[index] else {
                throw .invalidArgument("silent only applies together with workspace")
            }
            effects[index] = .workspace(selector, silent: true)
        }
        return effects
    }

    /// Parses one effect, or gives `nil` for an effect switched off.
    public init?(key: String, value: String) throws(ActionError) {
        func size() throws(ActionError) -> (ResizeParameter.Amount, ResizeParameter.Amount) {
            let words = value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard words.count == 2 else { throw .invalidArgument("\(key) expects two values, such as \"800 600\" or \"60% 70%\"") }
            return (try ResizeParameter.amount(words[0]), try ResizeParameter.amount(words[1]))
        }
        func points() throws(ActionError) -> (Double, Double) {
            let words = value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
            guard words.count == 2, words[0] > 0, words[1] > 0 else { throw .invalidArgument("\(key) expects a width and a height, such as \"400 300\"") }
            return (words[0], words[1])
        }
        func number() throws(ActionError) -> Double {
            guard let number = Double(value), number >= 0 else { throw .invalidArgument("\(key) expects a number") }
            return number
        }
        func whenOn(_ effect: WindowRule.Effect) throws(ActionError) -> WindowRule.Effect? {
            try Self.flag(value, key) ? effect : nil
        }
        func whenOff(_ effect: WindowRule.Effect) throws(ActionError) -> WindowRule.Effect? {
            try Self.flag(value, key) ? nil : effect
        }

        let effect: WindowRule.Effect?
        switch key {
        case "float": effect = try Self.flag(value, key) ? .float : .tile
        case "fullscreen": effect = try whenOn(.fullscreen)
        case "maximize": effect = try whenOn(.maximize)
        case "keep-size": effect = try whenOn(.keepSize)
        case "pin": effect = try whenOn(.pin)
        case "center": effect = try whenOn(.center)
        case "size":
            let (width, height) = try size()
            effect = .size(width, height)
        case "position":
            let (x, y) = try size()
            effect = .position(x, y)
        case "workspace": effect = .workspace(try WorkspaceSelector(parsing: value), silent: false)
        case "display": effect = .display(try MonitorSelector(parsing: value))
        case "focus-on-open": effect = try whenOff(.noInitialFocus)
        case "focusable": effect = try whenOff(.noFocus)
        case "border": effect = try whenOff(.noBorder)
        case "border-width": effect = .borderWidth(try number())
        case "border-color":
            let colors = value.split(whereSeparator: \.isWhitespace).map(String.init)
            guard (1...2).contains(colors.count), let active = ColorNotation.parse(colors[0]) else {
                throw .invalidArgument("border-color expects a color, or the focused and unfocused colors, such as \"#ff8800 #444444\"")
            }
            let inactive = colors.count == 2 ? ColorNotation.parse(colors[1]) : nil
            if colors.count == 2, inactive == nil { throw .invalidArgument("'\(colors[1])' is not a color") }
            effect = .borderColor(active: Gradient(active), inactive: inactive.map(Gradient.init))
        case "dim": effect = try whenOff(.noDim)
        case "corner-radius": effect = .cornerRadius(try number())
        case "keep-focus": effect = try whenOn(.keepFocus)
        case "min-size":
            let (width, height) = try points()
            effect = .minSize(width, height)
        case "max-size":
            let (width, height) = try points()
            effect = .maxSize(width, height)
        case "tabs":
            guard let rule = WindowRule.TabsRule(rawValue: value.lowercased()) else { throw .invalidArgument("tabs expects own or never") }
            effect = .tabs(rule)
        case "tag":
            guard !value.isEmpty else { throw .missingArgument("a tag name") }
            effect = .tag(value)
        default:
            throw .invalidArgument("unknown rule '\(key)'")
        }
        guard let effect else { return nil }
        self = effect
    }

    static func flag(_ value: String, _ key: String) throws(ActionError) -> Bool {
        switch value.lowercased() {
        case "true", "on", "yes", "1": return true
        case "false", "off", "no", "0": return false
        default: throw .invalidArgument("\(key) expects true or false")
        }
    }

    /// The effect as keys and values of a `[[rules]]` table.
    public var entries: [(key: String, value: String)] {
        switch self {
        case .float: [("float", "true")]
        case .tile: [("float", "false")]
        case .fullscreen: [("fullscreen", "true")]
        case .maximize: [("maximize", "true")]
        case .keepSize: [("keep-size", "true")]
        case .pin: [("pin", "true")]
        case .center: [("center", "true")]
        case .position(let x, let y): [("position", "\(x) \(y)")]
        case .size(let width, let height): [("size", "\(width) \(height)")]
        case .workspace(let selector, let silent): [("workspace", selector.description)] + (silent ? [("silent", "true")] : [])
        case .display(let selector): [("display", selector.description)]
        case .noInitialFocus: [("focus-on-open", "false")]
        case .noFocus: [("focusable", "false")]
        case .noBorder: [("border", "false")]
        case .borderWidth(let width): [("border-width", width.compact)]
        case .borderColor(let active, let inactive): [("border-color", ([active] + (inactive.map { [$0] } ?? [])).map(\.description).joined(separator: " "))]
        case .noDim: [("dim", "false")]
        case .cornerRadius(let radius): [("corner-radius", radius.compact)]
        case .keepFocus: [("keep-focus", "true")]
        case .minSize(let width, let height): [("min-size", "\(width.compact) \(height.compact)")]
        case .maxSize(let width, let height): [("max-size", "\(width.compact) \(height.compact)")]
        case .tabs(let rule): [("tabs", rule.rawValue)]
        case .tag(let name): [("tag", name)]
        }
    }

    /// Whether the effect is decided once, when the window first appears.
    public var isStatic: Bool {
        switch self {
        case .float, .tile, .fullscreen, .maximize, .keepSize, .pin, .center, .position, .size, .workspace, .display, .noInitialFocus,
             .minSize, .maxSize, .tabs: true
        case .noFocus, .noBorder, .borderWidth, .borderColor, .noDim, .cornerRadius, .keepFocus, .tag: false
        }
    }

    /// Whether the effect follows the window as it changes: its title, focus, state or tags.
    public var isDynamic: Bool { !isStatic }
}

extension WindowRule.Condition {
    /// Parses a condition from its key, without the `if.` prefix, and its value.
    public init(key: String, value: String) throws(ActionError) {
        func flag() throws(ActionError) -> Bool { try WindowRule.Effect.flag(value, "if.\(key)") }
        switch key {
        case "app": self = .app(try Pattern.compile(value))
        case "title": self = .title(try Pattern.compile(value))
        case "floating": self = .floating(try flag())
        case "fullscreen": self = .fullscreen(try flag())
        case "pinned": self = .pinned(try flag())
        case "focused": self = .focused(try flag())
        case "dialog": self = .dialog(try flag())
        case "tabbed": self = .tabbed(try flag())
        case "tag":
            guard !value.isEmpty else { throw .missingArgument("a tag name") }
            self = .tag(value)
        case "workspace":
            switch try WorkspaceSelector(parsing: value) {
            case .id(let n): self = .workspace(.numbered(n))
            case .named(let name): self = .workspace(.named(name))
            case .scratchpad(let name): self = .workspace(.scratchpad(name))
            default: throw .invalidArgument("if.workspace expects a workspace number, name or scratchpad")
            }
        default:
            throw .invalidArgument("unknown rule condition 'if.\(key)'")
        }
    }

    /// The condition's key, without the `if.` prefix.
    public var key: String {
        switch self {
        case .app: "app"
        case .title: "title"
        case .floating: "floating"
        case .fullscreen: "fullscreen"
        case .pinned: "pinned"
        case .focused: "focused"
        case .workspace: "workspace"
        case .dialog: "dialog"
        case .tag: "tag"
        case .tabbed: "tabbed"
        }
    }

    public var value: String {
        switch self {
        case .app(let p), .title(let p): p.source
        case .floating(let v), .fullscreen(let v), .pinned(let v), .focused(let v), .dialog(let v), .tabbed(let v): v ? "true" : "false"
        case .workspace(let id): id.selector
        case .tag(let name): name
        }
    }
}
