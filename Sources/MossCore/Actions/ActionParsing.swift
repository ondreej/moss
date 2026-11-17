extension Action {
    /// An entry of the action catalog: how an action is written and what it does.
    public struct CatalogEntry: Hashable, Sendable {
        public let verb: String
        /// The arguments, e.g. `left|right|up|down`.
        public let arguments: String
        public let summary: String
        /// The layout the action belongs to, for layout actions.
        public let layout: LayoutKind?
    }

    /// Every action, in the order they are documented.
    public static let catalog: [CatalogEntry] = [
        entry("run", "[rules] COMMAND", "Run a shell command; rules in brackets apply to the window it opens"),
        entry("close", "[WINDOW]", "Close a window, the focused one by default"),
        entry("quit-app", "[WINDOW]", "Quit the application that owns a window"),
        entry("signal", "SIGNAL [WINDOW]", "Send a signal, such as TERM or USR1, to a window's process"),
        entry("send-keys", "KEYS [WINDOW]", "Press keys in a window's application, e.g. cmd-shift-t"),
        entry("workspace", "WORKSPACE", "Switch to a workspace"),
        entry("move-to-workspace", "WORKSPACE [WINDOW]", "Move a window to a workspace and follow it"),
        entry("send-to-workspace", "WORKSPACE [WINDOW]", "Move a window to a workspace and stay"),
        entry("bring-workspace", "WORKSPACE", "Show a workspace on the focused display"),
        entry("rename-workspace", "NUMBER [NAME]", "Name a numbered workspace, or clear its name"),
        entry("scratchpad", "[NAME]", "Show or hide a scratchpad"),
        entry("float", "[on|off|toggle] [WINDOW]", "Float a window above the tiles, or tile it"),
        entry("fullscreen", "[on|off|toggle]", "Cover the whole display with the focused window"),
        entry("maximize", "[on|off|toggle]", "Fill the layout area with the focused window"),
        entry("keep-size", "[on|off|toggle] [WINDOW]", "Keep a window's own size, centered in its tile"),
        entry("pin", "[on|off|toggle] [WINDOW]", "Keep a floating window on every workspace"),
        entry("center", "", "Center the focused floating window"),
        entry("tag", "+NAME|-NAME|NAME [WINDOW]", "Add, remove or toggle a tag that rules can match"),
        entry("bring-to-front", "", "Raise the focused floating window above the others"),
        entry("focus", "left|right|up|down|last", "Move focus, or return it to the previous window"),
        entry("focus-window", "WINDOW", "Focus a window"),
        entry("cycle", "[next|previous] [tiled|floating]", "Focus the next window on the workspace"),
        entry("move", "left|right|up|down", "Move the focused window"),
        entry("move-to-display", "DISPLAY", "Move the focused window to another display"),
        entry("swap", "left|right|up|down|next|previous", "Swap the focused window with another"),
        entry("resize", "by X Y | to X Y", "Resize the focused window, in points or percent"),
        entry("position", "by X Y | to X Y", "Move the focused floating window"),
        entry("split-ratio", "+0.1|-0.1|SHARE", "Change the share of the split around the focused window, such as 0.6"),
        entry("layout", "bsp|stack|scrolling|default|toggle LAYOUT", "Change the focused workspace's layout; default goes back to the configured one"),
        entry("focus-display", "DISPLAY", "Focus another display"),
        entry("move-workspace-to-display", "DISPLAY [WORKSPACE]", "Move a workspace to another display"),
        entry("swap-workspaces", "DISPLAY DISPLAY", "Swap the workspaces shown on two displays"),
        entry("tabs", "", "Put the focused window into a tab group, or dissolve its group"),
        entry("tab", "next|previous|NUMBER", "Show another tab of the group"),
        entry("join-tabs", "left|right|up|down", "Move the focused window into the neighbouring tab group"),
        entry("leave-tabs", "", "Take the focused window out of its tab group"),
        entry("move-tab", "next|previous", "Move the focused tab within its group"),
        entry("mode", "NAME|default", "Switch to a mode of its own shortcuts, or back"),
        entry("emit", "TEXT", "Send a custom event to scripts following the event stream"),
        entry("palette", "", "Search windows, workspaces, actions and shortcuts"),
        entry("overview", "[next|previous]", "See every workspace at once; again while open, highlight the next or previous one"),
        entry("pause", "[on|off|toggle]", "Stop arranging windows, or resume"),
        entry("start-at-login", "[on|off|toggle]", "Open Moss when you log in, or stop"),
        entry("reload", "", "Read the configuration file again"),
        entry("quit", "", "Quit Moss"),
        entry("flip-split", "", "Turn the split around the focused window", .bsp),
        entry("swap-split", "", "Swap the two sides of the split around the focused window", .bsp),
        entry("preselect", "left|right|up|down", "Choose where the next window opens", .bsp),
        entry("promote", "", "Move the focused window to the top of the split tree", .bsp),
        entry("swap-main", "", "Swap the focused window with the main window", .stack),
        entry("focus-main", "", "Focus the main window, or the stack from it", .stack),
        entry("main-count", "+1|-1", "Add or remove a main window", .stack),
        entry("stack-side", "left|right|top|bottom|center|next|previous", "Move the main area", .stack),
        entry("main-size", "+0.05|-0.05|SIZE", "Change the share of the main area", .stack),
        entry("rotate", "next|previous", "Rotate windows through the main area", .stack),
        entry("column", "next|previous", "Focus the next or previous column", .scrolling),
        entry("column-width", "WIDTH|+0.1|-0.1|next|previous|all WIDTH", "Change the focused column's width", .scrolling),
        entry("move-column", "left|right", "Move the focused column", .scrolling),
        entry("join-column", "left|right", "Move the focused window into the neighbouring column", .scrolling),
        entry("leave-column", "", "Give the focused window a column of its own", .scrolling),
        entry("fit", "active|visible|all|to-end|to-start", "Resize columns to share the screen exactly", .scrolling),
        entry("scroll", "POINTS", "Scroll the view", .scrolling),
        entry("reveal", "", "Scroll just enough to show the whole focused column", .scrolling),
        entry("scroll-to", "center|fit|toggle", "Choose how focused columns are brought into view", .scrolling),
        entry("lock-view", "[on|off|toggle]", "Keep the view still as focus moves", .scrolling),
    ]

    private static func entry(_ verb: String, _ arguments: String, _ summary: String, _ layout: LayoutKind? = nil) -> CatalogEntry {
        CatalogEntry(verb: verb, arguments: arguments, summary: summary, layout: layout)
    }

    static let layoutVerbs = Set(catalog.filter { $0.layout != nil }.map(\.verb))

    /// Parses an action as written in a shortcut or after `moss`.
    public init(parsing text: String) throws(ActionError) {
        var reader = ArgumentReader(text)
        guard let verb = reader.word()?.lowercased() else { throw .missingArgument("an action") }

        if Self.layoutVerbs.contains(verb) {
            self = .layout(LayoutMessage(command: verb, arguments: reader.words()))
            return
        }

        switch verb {
        case "run":
            let command = reader.rest
            guard !command.isEmpty else { throw .missingArgument("a command to run") }
            _ = try Self.splitRunRules(command)
            self = .run(command)
        case "close": self = .close(try reader.window())
        case "quit-app": self = .quitApp(try reader.window())
        case "signal":
            guard let name = reader.word() else { throw .missingArgument("a signal, such as TERM") }
            self = .signal(try Self.signalNumber(name), try reader.window())
        case "send-keys":
            guard let keys = reader.word() else { throw .missingArgument("keys to press, such as cmd-shift-t") }
            let chord: KeyChord
            do throws(KeyBindingError) {
                chord = try KeyChord(parsing: keys)
            } catch {
                throw .invalidArgument(error.description)
            }
            guard !chord.key.isPointer else { throw .invalidArgument("'\(keys)' is not a key") }
            self = .sendKeys(chord, try reader.window())

        case "workspace":
            self = .workspace(try WorkspaceSelector(parsing: try reader.required("a workspace")))
        case "move-to-workspace", "send-to-workspace":
            let workspace = try WorkspaceSelector(parsing: try reader.required("a workspace"))
            self = .moveToWorkspace(workspace, try reader.window(), follow: verb == "move-to-workspace")
        case "bring-workspace":
            self = .bringWorkspace(try WorkspaceSelector(parsing: try reader.required("a workspace")))
        case "rename-workspace":
            guard let first = reader.word(), let number = Int(first) else { throw .invalidArgument("rename-workspace expects a workspace number and a name") }
            let name = reader.rest
            self = .renameWorkspace(number, name.isEmpty ? nil : name)
        case "scratchpad":
            // One word, as in the `scratchpad:NAME` of selectors.
            self = .scratchpad(reader.word())

        case "float": self = .float(try reader.switchValue(), try reader.window())
        case "fullscreen": self = .fullscreen(try reader.switchValue())
        case "maximize": self = .maximize(try reader.switchValue())
        case "keep-size": self = .keepSize(try reader.switchValue(), try reader.window())
        case "pin": self = .pin(try reader.switchValue(), try reader.window())
        case "center": self = .center
        case "tag":
            self = .tag(try WindowRule.TagChange(parsing: try reader.required("a tag")), try reader.window())
        case "bring-to-front": self = .bringToFront

        case "focus":
            let target = try reader.required("a direction or last")
            if target.lowercased() == "last" {
                self = .focusLast
            } else {
                self = .focus(try Self.direction(target))
            }
        case "focus-window":
            self = .focusWindow(try WindowSelector(parsing: reader.rest))
        case "cycle":
            var options = CycleOptions()
            for word in reader.words().map({ $0.lowercased() }) {
                switch word {
                case "next": options.previous = false
                case "previous": options.previous = true
                case "tiled": options.tiledOnly = true
                case "floating": options.floatingOnly = true
                default: throw .invalidArgument("cycle expects next or previous, and optionally tiled or floating")
                }
            }
            self = .cycle(options)
        case "move":
            self = .move(try Self.direction(try reader.required("a direction")))
        case "move-to-display":
            self = .moveToDisplay(try MonitorSelector(parsing: reader.rest))
        case "swap":
            let target = try reader.required("a direction, next or previous").lowercased()
            if target == "next" || target == "previous" {
                self = .swapInOrder(forward: target == "next")
            } else {
                self = .swap(try Self.direction(target))
            }

        case "resize": self = .resize(try ResizeParameter(parsing: reader.rest))
        case "position": self = .position(try ResizeParameter(parsing: reader.rest))
        case "split-ratio":
            let text = try reader.required("a ratio, such as +0.1 or 1.2")
            guard let value = Double(text) else { throw .invalidArgument("split-ratio expects a share or a change to it, such as 0.6 or +0.1") }
            self = .splitRatio(text.hasPrefix("+") || text.hasPrefix("-") ? .relative(value) : .exact(value))

        case "layout":
            let word = try reader.required("bsp, stack, scrolling, default or toggle").lowercased()
            if word == "default" {
                self = .useLayout(.configured)
            } else if word == "toggle" {
                let name = try reader.required("a layout to toggle").lowercased()
                guard let kind = LayoutKind(rawValue: name) else { throw .invalidArgument("layout toggle expects bsp, stack or scrolling") }
                self = .useLayout(.toggle(kind))
            } else {
                guard let kind = LayoutKind(rawValue: word) else { throw .invalidArgument("layout expects bsp, stack, scrolling, default or toggle") }
                self = .useLayout(.style(kind))
            }

        case "focus-display": self = .focusDisplay(try MonitorSelector(parsing: reader.rest))
        case "move-workspace-to-display":
            let display = try MonitorSelector(parsing: try reader.required("a display"))
            let workspace = reader.rest
            self = .moveWorkspaceToDisplay(display, workspace.isEmpty ? nil : try WorkspaceSelector(parsing: workspace))
        case "swap-workspaces":
            let words = reader.words()
            guard words.count == 2 else { throw .invalidArgument("swap-workspaces expects two displays") }
            self = .swapWorkspaces(try MonitorSelector(parsing: words[0]), try MonitorSelector(parsing: words[1]))

        case "tabs": self = .tabs
        case "tab":
            let target = try reader.required("next, previous or a number").lowercased()
            switch target {
            case "next": self = .tab(.next)
            case "previous": self = .tab(.previous)
            default:
                guard let index = Int(target), index >= 1 else { throw .invalidArgument("tab expects next, previous or a number") }
                self = .tab(.index(index))
            }
        case "join-tabs": self = .joinTabs(try Self.direction(try reader.required("a direction")))
        case "leave-tabs": self = .leaveTabs
        case "move-tab":
            let target = try reader.required("next or previous").lowercased()
            guard target == "next" || target == "previous" else { throw .invalidArgument("move-tab expects next or previous") }
            self = .moveTab(forward: target == "next")

        case "mode":
            let name = try reader.required("a mode, or default")
            self = .mode(name.lowercased() == "default" ? nil : name)
        case "emit":
            let text = reader.rest
            guard !text.isEmpty else { throw .missingArgument("the text to send") }
            self = .emit(text)
        case "palette": self = .show(.palette)
        case "overview":
            switch reader.word()?.lowercased() {
            case nil, "next": self = .show(.overview)
            case "previous": self = .show(.overviewPrevious)
            case let other?: throw .invalidArgument("overview expects next or previous, not '\(other)'")
            }
        case "pause": self = .pause(try reader.switchValue())
        case "start-at-login": self = .startAtLogin(try reader.switchValue())
        case "reload": self = .reload
        case "quit": self = .quit

        default:
            throw .unknownAction(verb, suggestion: Self.suggestion(for: verb))
        }
        try reader.finish(verb)
    }

    /// The action as it would be written in a shortcut.
    public var description: String {
        func with(_ verb: String, _ parts: String?...) -> String {
            ([verb] + parts.compactMap { $0 }.filter { !$0.isEmpty }).joined(separator: " ")
        }
        func toggle(_ change: Switch) -> String? { change == .toggle ? nil : change.rawValue }
        switch self {
        case .run(let command): return with("run", command)
        case .close(let w): return with("close", w?.description)
        case .quitApp(let w): return with("quit-app", w?.description)
        case .signal(let number, let w):
            return with("signal", Self.signals.first { $0.value == number }?.key ?? String(number), w?.description)
        case .sendKeys(let chord, let w): return with("send-keys", chord.description, w?.description)
        case .workspace(let ws): return with("workspace", ws.description)
        case .moveToWorkspace(let ws, let w, let follow): return with(follow ? "move-to-workspace" : "send-to-workspace", ws.description, w?.description)
        case .bringWorkspace(let ws): return with("bring-workspace", ws.description)
        case .renameWorkspace(let number, let name): return with("rename-workspace", String(number), name)
        case .scratchpad(let name): return with("scratchpad", name)
        case .float(let change, let w): return with("float", toggle(change), w?.description)
        case .fullscreen(let change): return with("fullscreen", toggle(change))
        case .maximize(let change): return with("maximize", toggle(change))
        case .keepSize(let change, let w): return with("keep-size", toggle(change), w?.description)
        case .pin(let change, let w): return with("pin", toggle(change), w?.description)
        case .center: return "center"
        case .tag(let change, let w): return with("tag", change.description, w?.description)
        case .bringToFront: return "bring-to-front"
        case .focus(let d): return with("focus", d.rawValue)
        case .focusLast: return "focus last"
        case .focusWindow(let w): return with("focus-window", w.description)
        case .cycle(let options):
            return with("cycle", options.previous ? "previous" : nil, options.tiledOnly ? "tiled" : nil, options.floatingOnly ? "floating" : nil)
        case .move(let d): return with("move", d.rawValue)
        case .moveToDisplay(let display): return with("move-to-display", display.description)
        case .swap(let d): return with("swap", d.rawValue)
        case .swapInOrder(let forward): return with("swap", forward ? "next" : "previous")
        case .resize(let p): return with("resize", p.description)
        case .position(let p): return with("position", p.description)
        case .splitRatio(.relative(let value)): return with("split-ratio", value >= 0 ? "+\(value.compact)" : value.compact)
        case .splitRatio(.exact(let value)): return with("split-ratio", value.compact)
        case .useLayout(.style(let kind)): return with("layout", kind.rawValue)
        case .useLayout(.configured): return "layout default"
        case .useLayout(.toggle(let kind)): return with("layout", "toggle", kind.rawValue)
        case .layout(let message): return message.description
        case .focusDisplay(let display): return with("focus-display", display.description)
        case .moveWorkspaceToDisplay(let display, let ws): return with("move-workspace-to-display", display.description, ws?.description)
        case .swapWorkspaces(let a, let b): return with("swap-workspaces", a.description, b.description)
        case .tabs: return "tabs"
        case .tab(.next): return "tab next"
        case .tab(.previous): return "tab previous"
        case .tab(.index(let index)): return with("tab", String(index))
        case .joinTabs(let d): return with("join-tabs", d.rawValue)
        case .leaveTabs: return "leave-tabs"
        case .moveTab(let forward): return with("move-tab", forward ? "next" : "previous")
        case .mode(let name): return with("mode", name ?? "default")
        case .emit(let text): return with("emit", text)
        case .show(let surface): return surface.rawValue
        case .pause(let change): return with("pause", toggle(change))
        case .startAtLogin(let change): return with("start-at-login", toggle(change))
        case .reload: return "reload"
        case .quit: return "quit"
        }
    }

    /// The verb the action starts with.
    public var verb: String { String(description.prefix { !$0.isWhitespace }) }

    /// Signal names without the `SIG` prefix, with their macOS numbers.
    static let signals: [String: Int32] = [
        "HUP": 1, "INT": 2, "QUIT": 3, "ILL": 4, "TRAP": 5, "ABRT": 6, "KILL": 9, "BUS": 10, "SEGV": 11,
        "PIPE": 13, "ALRM": 14, "TERM": 15, "STOP": 17, "TSTP": 18, "CONT": 19, "USR1": 30, "USR2": 31,
    ]

    /// A signal by macOS number (`15`) or name (`TERM`, `SIGTERM`).
    static func signalNumber(_ text: String) throws(ActionError) -> Int32 {
        let value = text.trimmingWhitespace.uppercased()
        if let number = Int32(value), (1...31).contains(number) { return number }
        let name = value.hasPrefix("SIG") ? String(value.dropFirst(3)) : value
        guard let number = signals[name] else { throw .invalidArgument("'\(text)' is not a signal number or name") }
        return number
    }

    static func direction(_ text: String) throws(ActionError) -> Direction {
        guard let direction = Direction(argument: text) else { throw .invalidArgument("'\(text)' is not a direction: left, right, up or down") }
        return direction
    }

    /// Splits `[rules] command` into the rules for the window the command opens and the command.
    public static func splitRunRules(_ text: String) throws(ActionError) -> (rules: [WindowRule.Effect], command: String) {
        let trimmed = text.trimmingWhitespace
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return ([], trimmed) }
        let body = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        let entries = body.split(separator: ",").map { $0.trimmingWhitespace }.filter { !$0.isEmpty }.map { item -> (String, String) in
            guard let equals = item.firstIndex(of: "=") else { return (item, "true") }
            return (item[..<equals].trimmingWhitespace, item[item.index(after: equals)...].trimmingWhitespace)
        }
        let rules = try WindowRule.Effect.effects(from: entries)
        return (rules, String(trimmed[trimmed.index(after: close)...]).trimmingWhitespace)
    }

    static func suggestion(for verb: String) -> String? {
        let best = catalog.map(\.verb).min { editDistance(verb, $0) < editDistance(verb, $1) }
        return best.flatMap { editDistance(verb, $0) <= max(2, verb.count / 3) ? $0 : nil }
    }
}

/// Reads an action's arguments word by word.
struct ArgumentReader {
    private var remaining: Substring

    init(_ text: String) { remaining = Substring(text.trimmingWhitespace) }

    /// Everything not read yet.
    var rest: String {
        mutating get {
            let text = remaining.trimmingWhitespace
            remaining = ""
            return text
        }
    }

    mutating func word() -> String? {
        remaining = remaining.drop { $0.isWhitespace }
        guard !remaining.isEmpty else { return nil }
        let word = remaining.prefix { !$0.isWhitespace }
        remaining = remaining.dropFirst(word.count)
        return String(word)
    }

    mutating func words() -> [String] {
        var result: [String] = []
        while let word = word() { result.append(word) }
        return result
    }

    mutating func required(_ what: String) throws(ActionError) -> String {
        guard let word = word() else { throw .missingArgument(what) }
        return word
    }

    /// An optional `on`, `off` or `toggle`, which is the default.
    mutating func switchValue() throws(ActionError) -> Action.Switch {
        let saved = remaining
        guard let word = word() else { return .toggle }
        if let value = Action.Switch(rawValue: word.lowercased()) { return value }
        remaining = saved
        return .toggle
    }

    /// The rest of the arguments as a window, if any.
    mutating func window() throws(ActionError) -> WindowSelector? {
        let text = rest
        return text.isEmpty ? nil : try WindowSelector(parsing: text)
    }

    func finish(_ verb: String) throws(ActionError) {
        let extra = remaining.trimmingWhitespace
        guard extra.isEmpty else { throw .invalidArgument("\(verb) does not take '\(extra)'") }
    }
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var previous = Array(0...b.count)
    var current = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        current[0] = i
        for j in 1...b.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}
