/// Typed settings, grouped as they are in the configuration file and the settings window.
public struct Settings: Hashable, Sendable {
    public var keyboard = Keyboard()
    public var layout = Layout()
    public var borders = Borders()
    public var dimming = Dimming()
    public var animation = Animation()
    public var focus = Focus()
    public var floating = Floating()
    public var fullscreen = Fullscreen()
    public var tabs = Tabs()
    public var workspaces = Workspaces()
    public var scratchpads = Scratchpads()
    public var errors = Errors()

    public init() {}

    public struct Keyboard: Hashable, Sendable {
        /// The modifier every shortcut starts with, written `mod` in shortcuts.
        public var mainKey: Modifiers = .capsLock
        /// What Caps Lock does.
        public var capsLock: CapsLockBehavior = .hyper
    }

    public struct Layout: Hashable, Sendable {
        public var style: LayoutKind = .bsp
        /// Space between windows.
        public var gaps = Insets(all: 8)
        /// Space between windows and the edges of the screen.
        public var margins = Insets(all: 8)
        public var bsp = BSP()
        public var stack = Stack()
        public var scrolling = Scrolling()
    }

    /// Each new window splits the focused one in two.
    public struct BSP: Hashable, Sendable {
        /// Which half of a split a new window takes.
        public var newWindowSide: NewWindowSide = .cursor
        /// New windows split the focused window rather than the one under the cursor.
        public var splitsFocused = true
        /// Splits keep their direction when their area changes shape.
        public var keepsDirection = false
        /// The side of the split follows the edge of the window the cursor is closest to.
        public var smartSplit = false
        /// Resizing moves the edges nearest the dragged corner.
        public var smartResize = true
        /// A preselected direction applies to every new window until it is changed.
        public var remembersPreselection = false
        /// The share the first window of a new split gets: `0.5` is even.
        public var defaultRatio: Double = 0.5
    }

    /// One main window, with the others stacked beside it.
    public struct Stack: Hashable, Sendable {
        /// The share of the screen the main area takes.
        public var mainSize: Double = 0.55
        public var newWindow: StackNewWindow = .stack
        public var newWindowPosition: StackNewWindowPosition = .end
        public var side: StackSide = .left
        /// Stack windows needed before a centered main area takes effect.
        public var centerMinimumStack = 2
        /// The side used while a centered main area has too few stack windows.
        public var centerFallback: StackSide = .left
        /// The main area keeps its place when the stack is empty.
        public var keepsMainPosition = false
    }

    /// Columns of windows on a strip that scrolls to the focused one.
    public struct Scrolling: Hashable, Sendable {
        /// The width of new columns, as a fraction of the screen.
        public var columnWidth: Double = 0.5
        /// The widths `column-width next` and `previous` step through.
        public var columnWidthPresets: [Double] = [0.333, 0.5, 0.667, 1.0]
        /// Where new columns are added and the view scrolls.
        public var direction: ScrollingDirection = .right
        /// How the view brings the focused column into sight.
        public var scrollTo: ScrollingFitMethod = .center
        /// The view moves to show windows as they are focused.
        public var followsFocus = true
        /// How much of a window must be in view for hovering it to focus it.
        public var hoverMinimumVisible: Double = 0.4
        /// A workspace with a single column shows it across the whole screen.
        public var fillsLoneColumn = true
        /// Moving past either end with `column` or `move-column` wraps around to the other end.
        public var wraps = true
    }

    public struct Borders: Hashable, Sendable {
        public var width: Double = 1
        public var active = Gradient(.accent())
        public var inactive = Gradient(.clear)
        /// Borders follow each window's own corner radius.
        public var followsWindowCorners = true
        /// The corner radius of windows whose own corners cannot be read.
        public var cornerRadius: Double = 16
    }

    public struct Dimming: Hashable, Sendable {
        /// Dim windows other than the focused one.
        public var isEnabled = false
        public var amount: Double = 0.5
    }

    public struct Animation: Hashable, Sendable {
        public var isEnabled = true
        /// Windows moving to a new place in the layout.
        public var windows = AnimationSpec(duration: 0.18, curve: .easeOutQuint)

        /// The animation to use for window movement, or `nil` when animations are off.
        public var windowMovement: AnimationSpec? {
            isEnabled && windows.isEnabled && windows.duration > 0 ? windows : nil
        }
    }

    public struct Focus: Hashable, Sendable {
        /// Keyboard focus moves to the window under the cursor.
        public var followsMouse = true
        /// The cursor moves to windows focused with the keyboard.
        public var movesCursor = true
        /// Moving focus or a window past the last one goes on to the next display.
        public var crossesDisplays = true
    }

    public struct Floating: Hashable, Sendable {
        /// Floating windows snap to each other and to the edges of the screen.
        public var snaps = false
        public var snapDistance: Double = 10
    }

    public struct Fullscreen: Hashable, Sendable {
        /// What a fullscreen window does when another window opens on its workspace.
        public var newWindow: FullscreenNewWindow = .behind
    }

    public struct Tabs: Hashable, Sendable {
        /// New windows join the focused window's tab group.
        public var autoJoin = true
        /// A bar of tabs is shown above windows in a tab group.
        public var showsBar = true
        public var barHeight: Double = 14
        /// Tabs show their window's title.
        public var showsTitles = true
    }

    public struct Workspaces: Hashable, Sendable {
        /// Switching to the workspace already shown returns to the previous one.
        public var backAndForth = false
        /// Briefly show the workspace's name in the middle of the screen when switching to it.
        public var showsName = true
    }

    public struct Scratchpads: Hashable, Sendable {
        /// The size of tiled windows on a scratchpad, relative to their tile.
        public var scale: Double = 1
        /// How much the workspace behind an open scratchpad is dimmed.
        public var dimBehind: Double = 0.2
        /// Switching workspaces hides an open scratchpad.
        public var hidesOnWorkspaceSwitch = false
    }

    public struct Errors: Hashable, Sendable {
        /// A bar lists configuration errors at the top of the screen.
        public var isShown = true
    }
}

/// What Caps Lock does.
public enum CapsLockBehavior: String, Hashable, Sendable, Codable, CaseIterable {
    /// It locks capitals, unless a shortcut uses it: then it is Moss's alone.
    case capsLock = "caps-lock"
    /// Held, it is Control, Option, Shift and Command together in every application, with
    /// Moss's `caps` shortcuts taking precedence; tapped alone, it still locks capitals.
    case hyper
}

public enum LayoutKind: String, Hashable, Sendable, Codable, CaseIterable {
    case bsp
    case stack
    case scrolling
}

/// Which half of a split a new window takes in the BSP layout.
public enum NewWindowSide: String, Hashable, Sendable, Codable, CaseIterable {
    /// The half under the cursor.
    case cursor
    /// The left or top half.
    case before
    /// The right or bottom half.
    case after
}

/// Whether new windows in the stack layout become the main window.
public enum StackNewWindow: String, Hashable, Sendable, Codable, CaseIterable {
    case main
    case stack
    /// Main when the focused window is a main window.
    case inherit
}

/// Where new windows go in the stack layout's order.
public enum StackNewWindowPosition: String, Hashable, Sendable, Codable, CaseIterable {
    case end
    case start
    case beforeFocused = "before-focused"
    case afterFocused = "after-focused"
}

/// Where the stack layout's main area sits.
public enum StackSide: String, Hashable, Sendable, Codable, CaseIterable {
    case left
    case right
    case top
    case bottom
    case center

    public var next: StackSide {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var previous: StackSide {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }
}

/// How the scrolling layout brings a focused column into view.
public enum ScrollingFitMethod: String, Hashable, Sendable, Codable, CaseIterable {
    /// The column is centered in the view.
    case center
    /// The view moves only as far as needed to show the whole column.
    case fit

    public var toggled: ScrollingFitMethod { self == .center ? .fit : .center }
}

/// The direction the scrolling layout's columns run in.
public enum ScrollingDirection: String, Hashable, Sendable, Codable, CaseIterable {
    case right
    case left
    case down
    case up
}

/// What a fullscreen window does when another window opens on its workspace.
public enum FullscreenNewWindow: String, Hashable, Sendable, Codable, CaseIterable {
    /// The new window opens behind it.
    case behind
    /// The new window becomes fullscreen in its place.
    case takeOver = "take-over"
    /// The fullscreen window leaves fullscreen.
    case exit
}

/// Named timing curves for animations.
public enum AnimationCurve: String, Hashable, Sendable, CaseIterable {
    /// Fast at first, settling gently.
    case smooth
    case easeInOut = "ease-in-out"
    case linear

    public var bezier: BezierCurve {
        switch self {
        case .smooth: .easeOutQuint
        case .easeInOut: BezierCurve(0.42, 0, 0.58, 1)
        case .linear: .linear
        }
    }
}
