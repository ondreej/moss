/// A connected display.
public struct Monitor: Hashable, Sendable, Identifiable {
    public let id: MonitorID
    public var name: String
    /// The full display bounds.
    public var frame: Rect
    /// The bounds minus areas reserved by the system (menu bar, Dock).
    public var visibleFrame: Rect
    public var scale: Double
    public var isBuiltin: Bool
    /// The display with the menu bar.
    public var isMain = false
    /// Extra space reserved through configuration, e.g. for a status bar.
    public var reserved: Insets = .zero

    public var activeWorkspace: WorkspaceID
    public var activeScratchpad: WorkspaceID?

    public init(
        id: MonitorID,
        name: String,
        frame: Rect,
        visibleFrame: Rect? = nil,
        scale: Double = 2,
        isBuiltin: Bool = false,
        activeWorkspace: WorkspaceID
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.scale = scale
        self.isBuiltin = isBuiltin
        self.activeWorkspace = activeWorkspace
    }

    /// The area available to windows: the visible frame minus configured reservations.
    public var usableFrame: Rect { visibleFrame.inset(by: reserved) }
}

/// The physical description of a display as reported by the platform.
public struct DisplayDescription: Hashable, Sendable {
    public var id: MonitorID
    public var name: String
    public var frame: Rect
    public var visibleFrame: Rect
    public var scale: Double
    public var isBuiltin: Bool
    public var isMain: Bool

    public init(id: MonitorID, name: String, frame: Rect, visibleFrame: Rect, scale: Double = 2, isBuiltin: Bool = false, isMain: Bool = false) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.scale = scale
        self.isBuiltin = isBuiltin
        self.isMain = isMain
    }
}
