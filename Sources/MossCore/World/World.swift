/// The complete window-management state: monitors, workspaces, windows and focus.
///
/// `World` is a pure value. The runtime feeds it platform observations and actions, then
/// brings the platform in line with the resulting `arrangement()`. Nothing here talks to the
/// operating system, so every behaviour is deterministic and testable.
public struct World: Sendable {
    public internal(set) var settings: Settings
    public internal(set) var windowRules: [WindowRule] = []
    public internal(set) var workspaceRules: [WorkspaceRule] = []
    public internal(set) var monitorReservations: [MonitorReservation] = []
    /// Space taken by Moss's own overlays, such as the error bar, on top of configured reservations.
    public internal(set) var overlayReservations: [MonitorID: Insets] = [:]

    /// Monitors ordered left to right, then top to bottom.
    public internal(set) var monitors: [Monitor] = []
    public internal(set) var workspaces: [WorkspaceID: Workspace] = [:]
    public internal(set) var windows: [WindowID: Window] = [:]
    public internal(set) var groups: [GroupID: WindowGroup] = [:]

    public internal(set) var focusedMonitorID: MonitorID?
    public internal(set) var focusedWindowID: WindowID?
    /// Names given with `rename-workspace`.
    public internal(set) var workspaceLabels: [WorkspaceID: String] = [:]

    /// The active mode of shortcuts, `nil` for the default one.
    public internal(set) var mode: String?
    /// The modes the configuration declares.
    public internal(set) var modes: Set<String> = []

    /// The last known cursor position, used for split placement and focus decisions.
    public var cursor: Point?

    /// A mouse-driven move or resize in progress.
    public internal(set) var interaction: Interaction?

    /// Rules from `run [rules] COMMAND`, waiting for the window the command opens.
    public internal(set) var pendingRunRules: [PendingRunRules] = []
    var nextRunToken = 1

    var focusClock: UInt64 = 0
    var nextGroupID = 1
    var previousWorkspace: WorkspaceID?
    var previousWorkspaceByMonitor: [MonitorID: WorkspaceID] = [:]

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    // MARK: - Lookup

    public func monitor(_ id: MonitorID) -> Monitor? { monitors.first { $0.id == id } }

    /// How many windows are on a workspace, tabs out of sight included.
    public func windowCount(on workspace: WorkspaceID) -> Int {
        windows.values.count { $0.workspace == workspace }
    }

    public var focusedMonitor: Monitor? { focusedMonitorID.flatMap(monitor) }

    public var focusedWindow: Window? { focusedWindowID.flatMap { windows[$0] } }

    /// The active workspace of the focused monitor.
    public var activeWorkspaceID: WorkspaceID? { focusedMonitor?.activeWorkspace }

    /// The workspace holding keyboard focus: an open scratchpad takes precedence.
    public var focusedWorkspaceID: WorkspaceID? {
        if let window = focusedWindow { return window.workspace }
        guard let monitor = focusedMonitor else { return nil }
        return monitor.activeScratchpad ?? monitor.activeWorkspace
    }

    func monitorIndex(_ id: MonitorID) -> Int? { monitors.firstIndex { $0.id == id } }

    /// The monitor containing `point`, or the nearest one.
    public func monitor(at point: Point) -> Monitor? {
        if let hit = monitors.first(where: { $0.frame.contains(point) }) { return hit }
        return monitors.min { a, b in
            a.frame.center.distanceSquared(to: point) < b.frame.center.distanceSquared(to: point)
        }
    }

    /// Whether the workspace is currently shown on its monitor.
    public func isVisible(_ workspace: WorkspaceID) -> Bool {
        guard let ws = workspaces[workspace], let monitor = monitor(ws.monitor) else { return false }
        return monitor.activeWorkspace == workspace || monitor.activeScratchpad == workspace
    }

    public func isVisible(window id: WindowID) -> Bool {
        guard let window = windows[id] else { return false }
        return isVisible(window.workspace)
    }

    /// The monitor a window is shown on.
    public func monitor(of window: WindowID) -> Monitor? {
        windows[window].flatMap { workspaces[$0.workspace] }.flatMap { monitor($0.monitor) }
    }

    /// Windows sorted by identifier, for stable output.
    public var sortedWindows: [Window] { windows.values.sorted { $0.id < $1.id } }

    /// Workspaces sorted numerically, then by name, then scratchpads.
    public var sortedWorkspaces: [Workspace] { workspaces.values.sorted { $0.id < $1.id } }

    /// Windows in focus history order, most recent first.
    public var focusHistory: [WindowID] {
        windows.values.filter { $0.focusStamp > 0 }.sorted { $0.focusStamp > $1.focusStamp }.map(\.id)
    }

    /// The name shown for a workspace: one given with `rename-workspace`, the name its settings
    /// give it, or its number.
    public func displayName(of workspace: WorkspaceID) -> String {
        workspaceLabels[workspace] ?? workspaceRules.last { $0.workspace == workspace && $0.name != nil }?.name ?? workspace.name
    }

    // MARK: - Effective settings

    /// Global settings with the workspace's rule overrides applied.
    public func settings(for workspace: WorkspaceID) -> Settings {
        var result = settings
        for rule in workspaceRules where rule.workspace == workspace {
            if let gaps = rule.gaps { result.layout.gaps = gaps }
            if let margins = rule.margins { result.layout.margins = margins }
            if let width = rule.borderWidth { result.borders.width = width }
            if let layout = rule.layout { result.layout.style = layout }
            if rule.squareCorners == true {
                result.borders.cornerRadius = 0
                result.borders.followsWindowCorners = false
            }
            if rule.decorations == false {
                result.borders.width = 0
                result.tabs.showsBar = false
            }
            if let side = rule.stackSide { result.layout.stack.side = side }
            if let direction = rule.scrollingDirection { result.layout.scrolling.direction = direction }
        }
        if let layout = workspaces[workspace]?.layoutOverride { result.layout.style = layout }
        return result
    }

    /// The area tiled windows are laid out in on a monitor.
    public func tilingArea(on monitor: Monitor) -> Rect { monitor.usableFrame }

    /// The area a workspace's layout divides into tiles. Every tile keeps half a gap around its
    /// window, so the area is the tiling area within the margins, widened by half a gap: windows
    /// at the edges keep the margins, and windows the layout makes equal come out equal.
    func layoutArea(on monitor: Monitor, settings: Settings) -> Rect {
        tilingArea(on: monitor).inset(by: settings.layout.margins - settings.layout.gaps * 0.5)
    }

    func layoutArea(for workspace: WorkspaceID) -> Rect {
        guard let ws = workspaces[workspace], let monitor = monitor(ws.monitor) else { return .zero }
        return layoutArea(on: monitor, settings: settings(for: workspace))
    }
}

/// Window rules from `run [rules] COMMAND`, applied to the next window the command opens.
public struct PendingRunRules: Hashable, Sendable {
    public let token: Int
    public var effects: [WindowRule.Effect]
    /// The application named in the command (`open -a NAME`), if any; only its windows match.
    public var application: String?

    func matches(_ properties: WindowProperties) -> Bool {
        guard let application = application?.lowercased() else { return true }
        return properties.appName.lowercased() == application
            || properties.appID.lowercased() == application
            || properties.appID.lowercased().hasSuffix("." + application.replacing(" ", with: ""))
    }
}

/// A mouse-driven window move or resize.
public struct Interaction: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case move
        case resize(Corner)
    }

    public var kind: Kind
    public var window: WindowID
    public var startCursor: Point
    public var lastCursor: Point
    public var startFrame: Rect
    /// Whether the window was tiled when the interaction began.
    public var wasTiled: Bool
    /// The layout the window was taken out of, to trade places within if it is dropped on
    /// another tile.
    var layoutBefore: SavedLayout?
}
