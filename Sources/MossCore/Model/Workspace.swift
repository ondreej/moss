/// A workspace: a set of tiled and floating windows shown together on one monitor.
public struct Workspace: Sendable, Identifiable {
    public let id: WorkspaceID
    public var monitor: MonitorID
    public var tiling: any TilingLayout
    /// Floating windows ordered back to front.
    public var floating: [WindowID] = []
    public var lastFocused: WindowID?
    public var fullscreenWindow: WindowID?
    public var isPersistent = false
    /// A layout chosen with the `layout` action, used instead of the configured one.
    public var layoutOverride: LayoutKind?
    /// The monitor the workspace was on before that monitor was disconnected. It moves back
    /// when the monitor returns.
    public var home: Home?

    public struct Home: Hashable, Sendable, Codable {
        public var monitor: MonitorID
        /// Display identifiers can change when a display is reconnected; names rarely do.
        public var name: String
        /// The workspace was the one shown on that monitor.
        public var wasActive: Bool
    }

    public init(id: WorkspaceID, monitor: MonitorID, layout: LayoutKind) {
        self.id = id
        self.monitor = monitor
        self.tiling = Self.makeLayout(layout)
    }

    static func makeLayout(_ kind: LayoutKind) -> any TilingLayout {
        switch kind {
        case .bsp: BSPLayout()
        case .stack: StackLayout()
        case .scrolling: ScrollingLayout()
        }
    }

    /// All windows on the workspace: tiled in layout order, then floating back to front.
    public var windows: [WindowID] { tiling.windows + floating }

    public var isEmpty: Bool { tiling.isEmpty && floating.isEmpty }

    public func contains(_ window: WindowID) -> Bool { tiling.contains(window) || floating.contains(window) }

    /// Replaces the tiling layout, re-inserting existing tiled windows in order.
    mutating func switchLayout(to kind: LayoutKind, area: Rect, settings: Settings) {
        guard tiling.kind != kind else { return }
        let order = tiling.windows
        var layout = Self.makeLayout(kind)
        for window in order {
            layout.insert(window, context: InsertionContext(target: layout.windows.last, area: area, settings: settings))
        }
        tiling = layout
    }
}
