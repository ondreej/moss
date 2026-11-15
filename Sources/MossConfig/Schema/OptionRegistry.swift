import MossCore

/// Every configuration option, in the order they are documented.
public enum OptionRegistry {
    public static let all: [OptionDescriptor] = keyboard + layout + split + stack + scrolling + borders + dimming + animation
        + focus + floating + fullscreen + tabs + workspaces + scratchpads + errors

    private static let byPath: [String: OptionDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.path, $0) })

    public static func option(_ path: String) -> OptionDescriptor? { byPath[path.lowercased()] }

    /// Options grouped by table, in registry order.
    public static var categories: [(name: String, options: [OptionDescriptor])] {
        var order: [String] = []
        var groups: [String: [OptionDescriptor]] = [:]
        for option in all {
            if groups[option.category] == nil { order.append(option.category) }
            groups[option.category, default: []].append(option)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// Whether `path` names a table of options, such as `layout` or `layout.bsp`.
    public static func isCategory(_ path: String) -> Bool {
        all.contains { $0.category == path || $0.category.hasPrefix(path + ".") }
    }

    /// The closest known option path, for "did you mean" messages.
    public static func suggestion(for path: String) -> String? {
        let lower = path.lowercased()
        let best = all.min { editDistance(lower, $0.path) < editDistance(lower, $1.path) }
        guard let best, editDistance(lower, best.path) <= max(2, lower.count / 4) else { return nil }
        return best.path
    }

    // MARK: - Tables

    static let keyboard: [OptionDescriptor] = [
        .modifiers("keyboard.main-key", \.keyboard.mainKey, "The key every shortcut starts with, written mod in shortcuts."),
        .choice("keyboard.caps-lock", \.keyboard.capsLock, [.capsLock: "Caps Lock", .hyper: "Hyper (⌃⌥⇧⌘) when held"], "What Caps Lock does. As Hyper it is ⌃⌥⇧⌘ for every app while held, with Moss's caps shortcuts first, and locks capitals when tapped."),
    ]

    static let layout: [OptionDescriptor] = [
        .choice("layout.style", \.layout.style, [.bsp: "BSP", .stack: "Stack", .scrolling: "Scrolling"], "How tiled windows are arranged."),
        .insets("layout.gaps", \.layout.gaps, 0...200, "Space between windows, in points."),
        .insets("layout.margins", \.layout.margins, 0...1000, "Space between windows and the edges of the screen. A list sets the top, right, bottom and left."),
    ]

    static let split: [OptionDescriptor] = [
        .choice("layout.bsp.new-window-side", \.layout.bsp.newWindowSide, [.cursor: "Where the cursor is", .before: "Left or top", .after: "Right or bottom"], "Which half of a split a new window takes."),
        .bool("layout.bsp.split-focused", \.layout.bsp.splitsFocused, "New windows split the focused window rather than the one under the cursor."),
        .bool("layout.bsp.keep-direction", \.layout.bsp.keepsDirection, "Splits keep their direction when their area changes shape."),
        .bool("layout.bsp.smart-split", \.layout.bsp.smartSplit, "The side of a split follows the edge of the window the cursor is closest to."),
        .bool("layout.bsp.smart-resize", \.layout.bsp.smartResize, "Resizing moves the edges nearest the dragged corner."),
        .bool("layout.bsp.remember-preselection", \.layout.bsp.remembersPreselection, "A preselected direction applies to every new window until it is changed."),
        .number("layout.bsp.default-ratio", \.layout.bsp.defaultRatio, 0.05...0.95, "The share of a new split the first window gets: 0.5 is even, more favours the first window."),
    ]

    static let stack: [OptionDescriptor] = [
        .number("layout.stack.main-size", \.layout.stack.mainSize, 0.05...0.95, "The share of the screen the main area takes."),
        .choice("layout.stack.new-window", \.layout.stack.newWindow, [.stack: "Joins the stack", .main: "Becomes the main window", .inherit: "Same as the focused window"], "Where new windows go."),
        .choice("layout.stack.new-window-position", \.layout.stack.newWindowPosition, [.end: "At the end", .start: "At the start", .beforeFocused: "Before the focused window", .afterFocused: "After the focused window"], "Where new windows go in the order."),
        .choice("layout.stack.side", \.layout.stack.side, [.left: "Left", .right: "Right", .top: "Top", .bottom: "Bottom", .center: "Center"], "Where the main area is."),
        .integer("layout.stack.center-min-stack", \.layout.stack.centerMinimumStack, 0...100, "Stack windows needed before a centered main area takes effect."),
        .choice("layout.stack.center-fallback", \.layout.stack.centerFallback, [.left: "Left", .right: "Right", .top: "Top", .bottom: "Bottom", .center: "Center"], "Where the main area is while the stack is too small to center it."),
        .bool("layout.stack.keep-main-position", \.layout.stack.keepsMainPosition, "The main area keeps its place when the stack is empty."),
    ]

    static let scrolling: [OptionDescriptor] = [
        .number("layout.scrolling.column-width", \.layout.scrolling.columnWidth, 0.1...1, "The width of new columns, as a fraction of the screen."),
        .numbers("layout.scrolling.column-width-presets", \.layout.scrolling.columnWidthPresets, 0.1...1, "The widths column-width next and previous step through."),
        .choice("layout.scrolling.direction", \.layout.scrolling.direction, [.right: "Right", .left: "Left", .down: "Down", .up: "Up"], "Where new columns are added and the view scrolls."),
        .choice("layout.scrolling.scroll-to", \.layout.scrolling.scrollTo, [.center: "Center the column", .fit: "Scroll just enough"], "How the view brings the focused column into sight."),
        .bool("layout.scrolling.follow-focus", \.layout.scrolling.followsFocus, "The view scrolls to windows as they are focused."),
        .number("layout.scrolling.hover-min-visible", \.layout.scrolling.hoverMinimumVisible, 0...1, "How much of a window must be in view for hovering it to focus it."),
        .bool("layout.scrolling.fill-lone-column", \.layout.scrolling.fillsLoneColumn, "A workspace with a single column shows it across the whole screen."),
        .bool("layout.scrolling.wrap", \.layout.scrolling.wraps, "Moving past either end with column or move-column wraps around to the other end."),
    ]

    static let borders: [OptionDescriptor] = [
        .number("borders.width", \.borders.width, 0...100, "The width of the border around windows, in points."),
        .color("borders.active", \.borders.active, "The border of the focused window. Several colors and an angle make a gradient."),
        .color("borders.inactive", \.borders.inactive, "The border of other windows."),
        .bool("borders.follow-window-corners", \.borders.followsWindowCorners, "Borders follow each window's own rounded corners."),
        .number("borders.corner-radius", \.borders.cornerRadius, 0...100, "The corner radius of borders around windows whose own corners cannot be read."),
    ]

    static let dimming: [OptionDescriptor] = [
        .bool("dimming.enabled", \.dimming.isEnabled, "Dim windows other than the focused one."),
        .number("dimming.amount", \.dimming.amount, 0...1, "How much windows are dimmed."),
    ]

    static let animation: [OptionDescriptor] = [
        .bool("animation.enabled", \.animation.isEnabled, "Windows glide to their new places."),
        .number("animation.duration", \.animation.windows.duration, 0...5, "How long windows take to move, in seconds."),
        .curve("animation.curve", "How windows speed up and slow down as they move."),
    ]

    static let focus: [OptionDescriptor] = [
        .bool("focus.follows-mouse", \.focus.followsMouse, "Keyboard focus moves to the window under the cursor."),
        .bool("focus.move-cursor", \.focus.movesCursor, "The cursor moves to windows focused with the keyboard."),
        .bool("focus.cross-displays", \.focus.crossesDisplays, "Moving focus or a window past the last one goes on to the next display."),
    ]

    static let floating: [OptionDescriptor] = [
        .bool("floating.snap", \.floating.snaps, "Floating windows snap to each other and to the edges of the screen."),
        .number("floating.snap-distance", \.floating.snapDistance, 0...500, "How close a floating window must come to snap, in points."),
    ]

    static let fullscreen: [OptionDescriptor] = [
        .choice("fullscreen.new-window", \.fullscreen.newWindow, [.behind: "Opens behind it", .takeOver: "Takes over fullscreen", .exit: "Ends fullscreen"], "What happens when a window opens on a workspace with a fullscreen window."),
    ]

    static let tabs: [OptionDescriptor] = [
        .bool("tabs.auto-join", \.tabs.autoJoin, "New windows join the focused window's tab group."),
        .bool("tabs.bar", \.tabs.showsBar, "A bar of tabs is shown above windows in a tab group."),
        .number("tabs.bar-height", \.tabs.barHeight, 4...64, "The height of the bar of tabs, in points."),
        .bool("tabs.titles", \.tabs.showsTitles, "Tabs show their window's title."),
    ]

    static let workspaces: [OptionDescriptor] = [
        .bool("workspaces.back-and-forth", \.workspaces.backAndForth, "Switching to the workspace already shown returns to the previous one."),
        .bool("workspaces.show-name", \.workspaces.showsName, "The workspace's name appears briefly in the middle of the screen when switching to it."),
    ]

    static let scratchpads: [OptionDescriptor] = [
        .number("scratchpads.scale", \.scratchpads.scale, 0.1...1, "The size of tiled windows on a scratchpad, relative to their tile."),
        .number("scratchpads.dim-behind", \.scratchpads.dimBehind, 0...1, "How much the workspace behind an open scratchpad is dimmed."),
        .bool("scratchpads.hide-on-workspace-switch", \.scratchpads.hidesOnWorkspaceSwitch, "Switching workspaces hides an open scratchpad."),
    ]

    static let errors: [OptionDescriptor] = [
        .bool("errors.show", \.errors.isShown, "A bar at the top of the screen lists problems in the configuration file."),
    ]
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
