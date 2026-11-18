/// What the platform reports about a window. These properties are owned by the
/// application and only observed by the window manager.
public struct WindowProperties: Hashable, Sendable, Codable {
    /// The application's bundle identifier, which rules match as `app`.
    public var appID: String
    public var appName: String
    public var title: String
    public var pid: Int32
    public var kind: Kind
    public var isResizable: Bool
    public var minimumSize: Size?

    public enum Kind: String, Hashable, Sendable, Codable {
        /// A regular document or application window.
        case standard
        /// A dialog, alert or other transient window that should float.
        case dialog
        /// A utility panel (inspectors, palettes) that should float.
        case panel
    }

    public init(
        appID: String,
        appName: String,
        title: String = "",
        pid: Int32 = 0,
        kind: Kind = .standard,
        isResizable: Bool = true,
        minimumSize: Size? = nil
    ) {
        self.appID = appID
        self.appName = appName
        self.title = title
        self.pid = pid
        self.kind = kind
        self.isResizable = isResizable
        self.minimumSize = minimumSize
    }

    /// Whether the window should float when no rule says otherwise.
    public var prefersFloating: Bool { kind != .standard || !isResizable }
}

public enum FullscreenMode: Int, Hashable, Sendable, Codable, CustomStringConvertible {
    /// Covers the whole usable monitor area without gaps.
    case fullscreen = 0
    /// Covers the monitor's work area, inside the margins.
    case maximized = 1

    public var description: String { self == .fullscreen ? "fullscreen" : "maximized" }
}

/// A window managed by Moss.
public struct Window: Hashable, Sendable, Identifiable {
    public let id: WindowID
    public var properties: WindowProperties
    public var initialProperties: WindowProperties
    public var workspace: WorkspaceID
    public var isFloating: Bool
    /// Where the window sits while floating, and the size it keeps in its tile with `keep-size`.
    public var floatingFrame: Rect {
        didSet { floatingFrame.size = sizeLimits.clamp(floatingFrame.size) }
    }
    /// The smallest size the window accepted when tiled: learned when its application keeps it
    /// larger than its tile, and forgotten once the window is seen smaller. Layouts make room for it.
    public var minimumTileSize: Size?
    /// Bounds on the floating size, from the `min-size` and `max-size` rules.
    public var sizeLimits = SizeLimits() {
        didSet { floatingFrame.size = sizeLimits.clamp(floatingFrame.size) }
    }
    /// The window keeps its own size, centered in its tile, instead of filling it.
    public var keepsSize: Bool = false
    public var isPinned: Bool = false
    public var fullscreen: FullscreenMode?
    /// The group the window belongs to, if any.
    public var group: GroupID?
    /// Kept out of tab groups by a `tabs = "never"` rule.
    public var isDeniedFromGroups = false
    /// What the window's dynamic rules set, re-evaluated as the window changes.
    public var overrides = WindowOverrides()
    /// Tags added with the `tag` action.
    public var tags: Set<String> = []
    /// Tags added by `tag` rules, re-evaluated with the other dynamic rules.
    public var ruleTags: Set<String> = []
    /// A monotonically increasing stamp of the last time the window had focus.
    public var focusStamp: UInt64 = 0

    public init(id: WindowID, properties: WindowProperties, workspace: WorkspaceID, isFloating: Bool, floatingFrame: Rect) {
        self.id = id
        self.properties = properties
        self.initialProperties = properties
        self.workspace = workspace
        self.isFloating = isFloating
        self.floatingFrame = floatingFrame
    }

    public var isTiled: Bool { !isFloating }

    public var allTags: Set<String> { tags.union(ruleTags) }
}

/// Minimum and maximum floating sizes.
public struct SizeLimits: Hashable, Sendable {
    public var minimum: Size?
    public var maximum: Size?

    public init(minimum: Size? = nil, maximum: Size? = nil) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func clamp(_ size: Size) -> Size {
        var result = size
        if let maximum {
            result.width = min(result.width, maximum.width)
            result.height = min(result.height, maximum.height)
        }
        if let minimum {
            result.width = max(result.width, minimum.width)
            result.height = max(result.height, minimum.height)
        }
        return result
    }
}

/// Per-window settings that window rules change during a window's life, over the global ones.
public struct WindowOverrides: Hashable, Sendable, Codable {
    public var borderWidth: Double?
    public var activeBorder: Gradient?
    public var inactiveBorder: Gradient?
    public var noBorder = false
    public var noFocus = false
    public var noDim = false
    public var cornerRadius: Double?
    /// Keeps focus while the window is visible.
    public var keepsFocus = false

    public init() {}
}
