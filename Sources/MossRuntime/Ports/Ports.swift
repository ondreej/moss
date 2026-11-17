public import MossCore

// The runtime talks to the operating system only through these interfaces. The macOS
// implementations live in MossPlatform; tests use in-memory fakes.

/// A window as observed on screen.
public struct WindowSnapshot: Hashable, Sendable {
    public var id: WindowID
    public var properties: WindowProperties
    public var frame: Rect
    /// In macOS fullscreen, in a Space of its own.
    public var isFullscreen: Bool

    public init(id: WindowID, properties: WindowProperties, frame: Rect, isFullscreen: Bool = false) {
        self.id = id
        self.properties = properties
        self.frame = frame
        self.isFullscreen = isFullscreen
    }
}

/// Something that happened to windows, applications or displays.
public enum PlatformEvent: Hashable, Sendable {
    /// A new window opened.
    case windowAppeared(WindowSnapshot)
    /// A window that existed before Moss started, found late because its application
    /// was slow to answer.
    case windowDiscovered(WindowSnapshot)
    case windowDisappeared(WindowID)
    case windowFrameChanged(WindowID, Rect)
    case windowPropertiesChanged(WindowID, WindowProperties)
    /// The window was minimized (`true`) or restored (`false`).
    case windowMinimized(WindowID, Bool)
    /// The window entered (`true`) or left (`false`) macOS's own fullscreen mode, which moves
    /// it to a separate Space outside Moss's workspaces.
    case windowNativeFullscreen(WindowID, Bool)
    /// The application closed the window and covers the display with a fullscreen window of
    /// its own in its place, as browsers do for video.
    case windowReplacedByFullscreen(WindowID)
    /// Leaving that fullscreen, the application opened a new window in place of the one it
    /// closed.
    case windowReturnedFromFullscreen(WindowID, WindowSnapshot)
    case focusChanged(WindowID?)
    case applicationTerminated(pid: Int32)
    /// The application was hidden (`true`) or shown again (`false`).
    case applicationHidden(pid: Int32, Bool)
    case displaysChanged([DisplayDescription])
}

/// Window management primitives of the operating system.
public protocol WindowSystem: AnyObject, Sendable {
    /// Whether the process may control other applications' windows.
    var isTrusted: Bool { get }

    /// Starts observing; events are delivered to `sink` from arbitrary threads.
    func start(sink: @escaping @Sendable (PlatformEvent) -> Void)
    func stop()

    func displays() -> [DisplayDescription]
    /// Returns once the screen is unlocked, at once when it is not locked. A locked screen
    /// hides every window.
    func waitUntilUnlocked() async
    /// Every manageable window that currently exists. Applications that are slow to answer
    /// may report theirs later as `windowDiscovered` events.
    func discoverWindows() async -> [WindowSnapshot]
    /// The applications that are currently hidden.
    func hiddenApplications() -> Set<Int32>
    /// Which of `ids` are windows that still exist, on any Space.
    func existingWindows(among ids: [WindowID]) -> Set<WindowID>

    /// Moves and resizes windows. Returns immediately; work happens in the background.
    func setFrames(_ frames: [WindowID: Rect])
    /// Waits until previously requested window operations have been carried out.
    func drain() async
    /// Focuses `window`, bringing it to the front with `raise`, or leaving it where it is in the
    /// stacking order, below the windows over it.
    func focus(_ window: WindowID, raise: Bool)
    /// Focuses `others` one after another, bottom to top, then `window`. macOS brings another
    /// application's window to the front only by focusing it, so this is how windows coming
    /// into view are put above the ones already there.
    func focus(_ window: WindowID, raise: Bool, after others: [WindowID])
    /// Focuses the desktop, as a click on it does, when no window in view is to have focus.
    /// `fromFullscreenSpace` brings the desktop back from the fullscreen Space shown, or being
    /// brought up, on its display.
    func focusDesktop(fromFullscreenSpace: Bool)
    func close(_ window: WindowID)
    func terminate(pid: Int32)
    func signal(pid: Int32, _ signal: Int32)

    func cursorLocation() -> Point
    func warpCursor(to point: Point)
    func isPrimaryButtonDown() -> Bool
    /// The frontmost window of any kind (including menus and popovers) under `point`.
    func topmostWindow(at point: Point) -> WindowID?
}

/// Input events relevant to the window manager.
public enum InputEvent: Hashable, Sendable {
    /// A keyboard or scroll binding fired.
    case binding(KeyBinding)
    /// A mouse drag shortcut began over `point`.
    case mouseBindingBegan(DragAction, at: Point)
    case mouseBindingMoved(to: Point)
    case mouseBindingEnded(at: Point)
    /// The cursor moved without a mouse binding active.
    case cursorMoved(to: Point)
    /// The primary button was pressed or released outside of a mouse binding.
    case primaryButton(isDown: Bool, at: Point)
}

/// What Caps Lock does while Moss runs.
public enum CapsLockRole: Int, Hashable, Sendable {
    /// Left alone.
    case unchanged
    /// The `caps` modifier of Moss's own shortcuts, seen by no application.
    case modifier
    /// Control, Option, Shift and Command together for every application while held, and
    /// Caps Lock when tapped alone.
    case hyper
}

/// Global keyboard and mouse handling.
public protocol InputSystem: AnyObject, Sendable {
    func start(sink: @escaping @Sendable (InputEvent) -> Void) throws
    func stop()
    func setBindings(_ bindings: [KeyBinding])
    /// Uses the shortcuts of a mode, or the default ones.
    func setMode(_ name: String?)
    /// Gives Caps Lock a role, or gives it back.
    func setCapsLock(_ role: CapsLockRole)
    /// Presses and releases keys in an application, or in the frontmost one when `pid` is
    /// `nil`. Sent keys never trigger shortcuts.
    func send(_ chord: KeyChord, to pid: Int32?)
}

/// The radius of a border's corners.
public enum CornerStyle: Hashable, Sendable {
    /// Follow the window's own corners, or use `fallback` when they cannot be read.
    case window(fallback: Double)
    case fixed(Double)
}

/// What to draw around a window.
public struct WindowDecoration: Hashable, Sendable {
    public var window: WindowID
    /// The window's frame; borders are drawn outside it.
    public var frame: Rect
    public var borderWidth: Double
    public var border: Gradient
    public var corners: CornerStyle
    /// How much to dim the window, `0...1`.
    public var dim: Double
    public var isActive: Bool
    /// The group's tab bar, drawn above the window.
    public var tabs: TabBar?

    public init(window: WindowID, frame: Rect, borderWidth: Double, border: Gradient, corners: CornerStyle, dim: Double, isActive: Bool, tabs: TabBar? = nil) {
        self.window = window
        self.frame = frame
        self.borderWidth = borderWidth
        self.border = border
        self.corners = corners
        self.dim = dim
        self.isActive = isActive
        self.tabs = tabs
    }
}

/// The tabs of a window group.
public struct TabBar: Hashable, Sendable {
    public struct Tab: Hashable, Sendable {
        public var title: String
        public var isActive: Bool

        public init(title: String, isActive: Bool) {
            self.title = title
            self.isActive = isActive
        }
    }

    public var tabs: [Tab]
    public var height: Double
    public var showsTitles: Bool

    public init(tabs: [Tab], height: Double, showsTitles: Bool) {
        self.tabs = tabs
        self.height = height
        self.showsTitles = showsTitles
    }
}

/// Draws borders and dimming over windows.
public protocol DecorationSystem: AnyObject, Sendable {
    /// Replaces the full set of decorations.
    func update(_ decorations: [WindowDecoration])
    /// Shows where a dragged window would land, just below it, or hides the preview.
    func showDropTarget(_ frame: Rect?, below window: WindowID?)
    /// Puts every decoration back directly above its window, once windows have been raised.
    func restack()
}

/// Messages on screen: notices that come and go, and the error bar.
public protocol NoticeSystem: AnyObject, Sendable {
    /// Shows a notice in a top corner of `area`, the part of a monitor clear of menu and status bars.
    func post(_ notice: Notice, within area: Rect)
    /// Removes the oldest `count` notices, or all of them when `nil`.
    func dismiss(oldest count: Int?)
    /// Shows, replaces or, with `nil`, hides the error bar along an edge of `area`.
    func showErrorBar(_ bar: ErrorBar?, within area: Rect)
    /// Briefly shows the workspaces of a monitor after switching between them.
    func showWorkspaces(_ hud: WorkspaceHUD, within area: Rect)
}

/// A monitor's workspaces, with the one just switched to.
public struct WorkspaceHUD: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var name: String
        public var windows: Int
        public var isActive: Bool

        public init(name: String, windows: Int, isActive: Bool) {
            self.name = name
            self.windows = windows
            self.isActive = isActive
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}
