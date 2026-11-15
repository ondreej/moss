/// Something Moss does: what shortcuts trigger, what the palette offers and what
/// `moss` runs. Actions are written as a verb and its arguments, such as `focus left`,
/// `move-to-workspace 3` or `run open -a Safari`.
public enum Action: Hashable, Sendable, CustomStringConvertible {
    // Applications and windows
    /// Runs a shell command, optionally with rules for the window it opens: `run [float] …`.
    case run(String)
    case close(WindowSelector?)
    /// Quits the application that owns a window.
    case quitApp(WindowSelector?)
    /// Sends a signal to the process that owns a window.
    case signal(Int32, WindowSelector?)
    /// Presses keys in a window's application.
    case sendKeys(KeyChord, WindowSelector?)

    // Workspaces
    case workspace(WorkspaceSelector)
    /// Moves a window to a workspace, following it there or not.
    case moveToWorkspace(WorkspaceSelector, WindowSelector?, follow: Bool)
    /// Brings a workspace to the focused display.
    case bringWorkspace(WorkspaceSelector)
    case renameWorkspace(Int, String?)
    /// Shows or hides a scratchpad.
    case scratchpad(String?)

    // Window state
    case float(Switch, WindowSelector?)
    case fullscreen(Switch)
    case maximize(Switch)
    /// The window keeps its own size, centered in its tile.
    case keepSize(Switch, WindowSelector?)
    /// A floating window stays visible on every workspace.
    case pin(Switch, WindowSelector?)
    case center
    case tag(WindowRule.TagChange, WindowSelector?)
    case bringToFront

    // Focus and movement
    case focus(Direction)
    /// Focuses the window that had focus before the current one.
    case focusLast
    case focusWindow(WindowSelector)
    case cycle(CycleOptions)
    case move(Direction)
    case moveToDisplay(MonitorSelector)
    case swap(Direction)
    /// Swaps the focused window with the next or previous one in the layout's order.
    case swapInOrder(forward: Bool)

    // Sizes
    case resize(ResizeParameter)
    case position(ResizeParameter)
    case splitRatio(RatioChange)
    /// Changes the focused workspace's layout.
    case useLayout(LayoutChoice)
    /// An action of the current layout, such as `flip-split` or `column-width 0.5`.
    case layout(LayoutMessage)

    // Displays
    case focusDisplay(MonitorSelector)
    /// Moves a workspace, the shown one by default, to a display.
    case moveWorkspaceToDisplay(MonitorSelector, WorkspaceSelector?)
    case swapWorkspaces(MonitorSelector, MonitorSelector)

    // Tabs
    /// Puts the focused window into a tab group, or dissolves its group.
    case tabs
    case tab(TabTarget)
    case joinTabs(Direction)
    case leaveTabs
    case moveTab(forward: Bool)

    // Moss
    /// Switches to a mode of its own shortcuts, or back to the default one.
    case mode(String?)
    /// Sends a custom event to scripts following the event stream.
    case emit(String)
    case show(Surface)
    /// Stops arranging windows, or resumes.
    case pause(Switch)
    case reload
    case quit

    /// The layout a workspace uses: one by name, the configured one, or one by name until it
    /// is chosen again.
    public enum LayoutChoice: Hashable, Sendable {
        case style(LayoutKind)
        case configured
        case toggle(LayoutKind)
    }

    public enum TabTarget: Hashable, Sendable {
        case next, previous
        /// One-based position in the group.
        case index(Int)
    }

    /// Whether the action moves, focuses or shows windows or workspaces: the actions that wait
    /// while tiling is paused. Others, such as opening apps or sending keys, still work.
    public var arrangesWindows: Bool {
        switch self {
        case .run, .close, .quitApp, .signal, .sendKeys, .renameWorkspace, .tag, .mode, .emit, .show(.palette), .pause, .reload, .quit:
            false
        default:
            true
        }
    }

    /// Moss's own interfaces that a shortcut can open.
    public enum Surface: String, Hashable, Sendable, CaseIterable {
        /// Search windows, workspaces, actions and shortcuts.
        case palette
        /// Every workspace at a glance; once open, the next workspace.
        case overview
        /// Every workspace at a glance; once open, the previous workspace.
        case overviewPrevious = "overview previous"
    }

    public enum Switch: String, Hashable, Sendable {
        case on, off, toggle

        public func apply(to value: Bool) -> Bool {
            switch self {
            case .on: true
            case .off: false
            case .toggle: !value
            }
        }
    }

    public struct CycleOptions: Hashable, Sendable {
        public var previous = false
        public var tiledOnly = false
        public var floatingOnly = false

        public init(previous: Bool = false, tiledOnly: Bool = false, floatingOnly: Bool = false) {
            self.previous = previous
            self.tiledOnly = tiledOnly
            self.floatingOnly = floatingOnly
        }
    }
}

/// A size or position: `by 20 -20` changes it, `to 1280 720` or `to 50% 50%` sets it.
public struct ResizeParameter: Hashable, Sendable, CustomStringConvertible {
    public enum Amount: Hashable, Sendable, CustomStringConvertible {
        case points(Double)
        case percent(Double)

        func resolve(relativeTo total: Double) -> Double {
            switch self {
            case .points(let value): value
            case .percent(let value): total * value / 100
            }
        }

        public var description: String {
            switch self {
            case .points(let value): value.compact
            case .percent(let value): "\(value.compact)%"
            }
        }
    }

    public var exact: Bool
    public var x: Amount
    public var y: Amount

    public init(exact: Bool, x: Amount, y: Amount) {
        self.exact = exact
        self.x = x
        self.y = y
    }

    /// Parses `by X Y` or `to X Y`, where each value is points or a percentage of the display.
    public init(parsing text: String) throws(ActionError) {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let mode = words.first?.lowercased(), mode == "by" || mode == "to" else {
            throw .invalidArgument("expected 'by' or 'to' and two values, such as 'by 20 -20' or 'to 50% 50%'")
        }
        words.removeFirst()
        guard words.count == 2 else { throw .invalidArgument("expected two values, such as 'by 20 -20' or 'to 50% 50%'") }
        self.init(exact: mode == "to", x: try Self.amount(words[0]), y: try Self.amount(words[1]))
    }

    /// Parses `800`, `-20` or `50%`.
    static func amount(_ word: String) throws(ActionError) -> Amount {
        if word.hasSuffix("%"), let value = Double(word.dropLast()) { return .percent(value) }
        if let value = Double(word) { return .points(value) }
        throw .invalidArgument("'\(word)' is not a number or percentage")
    }

    public func resolve(relativeTo size: Size) -> Size {
        Size(width: x.resolve(relativeTo: size.width), height: y.resolve(relativeTo: size.height))
    }

    public var description: String { "\(exact ? "to" : "by") \(x) \(y)" }
}

public enum ActionError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownAction(String, suggestion: String?)
    case invalidArgument(String)
    case missingArgument(String)
    case noSuchWindow(String)
    case noSuchMonitor(String)
    case noSuchWorkspace(String)
    case noSuchMode(String)
    /// Tiling is paused, and the action would arrange windows.
    case tilingPaused
    case layout(LayoutMessageError)

    public var description: String {
        switch self {
        case .unknownAction(let name, let suggestion):
            "unknown action '\(name)'" + (suggestion.map { ", did you mean '\($0)'?" } ?? "")
        case .invalidArgument(let detail): detail
        case .missingArgument(let detail): "missing argument: \(detail)"
        case .noSuchWindow(let selector): "no window matches '\(selector)'"
        case .noSuchMonitor(let selector): "no display matches '\(selector)'"
        case .noSuchWorkspace(let selector): "no workspace matches '\(selector)'"
        case .noSuchMode(let name): "there is no mode '\(name)'"
        case .tilingPaused: "tiling is paused; 'pause off' resumes it"
        case .layout(let error): error.description
        }
    }
}
