// The JSON models of `moss --json`. They are part of Moss's public interface:
// add fields freely, but rename or remove them only with care.

/// A rectangle in screen points, with the origin at the top left of the main display.
public struct FrameInfo: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

public struct WindowInfo: Codable, Hashable, Sendable, Identifiable {
    /// The window's identifier, e.g. `0x1a2b`, as `id:` selects it.
    public var id: String
    /// The application's name.
    public var app: String
    public var bundleID: String
    public var title: String
    public var pid: Int32
    /// The workspace, as written in actions: `3`, `mail` or `scratchpad:notes`.
    public var workspace: String
    public var display: String
    /// Where the window is, or would be when its workspace is shown.
    public var frame: FrameInfo
    public var isFloating: Bool
    /// `fullscreen`, `maximized`, or `nil`.
    public var fullscreen: String?
    public var isPinned: Bool
    public var keepsSize: Bool
    /// The window is out of sight: on a hidden workspace, behind another tab or scrolled away.
    public var isHidden: Bool
    /// The windows of its tab group, in tab order, if it is in one.
    public var tabs: [String]?
    /// How recently the window had focus: `0` is the focused window.
    public var focusOrder: Int?
    public var tags: [String]
}

public struct WorkspaceInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { workspace }
    /// The workspace, as written in actions: `3`, `mail` or `scratchpad:notes`.
    public var workspace: String
    /// The name shown for it.
    public var name: String
    public var number: Int?
    public var isScratchpad: Bool
    public var display: String
    public var windows: Int
    public var isFocused: Bool
    public var isVisible: Bool
    public var layout: String
    public var hasFullscreen: Bool
    public var isPersistent: Bool
    public var lastFocusedWindow: String?
}

public struct DisplayInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var frame: FrameInfo
    /// The frame without the menu bar, the Dock and reserved space.
    public var usableFrame: FrameInfo
    public var scale: Double
    public var isBuiltIn: Bool
    public var isMain: Bool
    public var isFocused: Bool
    public var workspace: String
    public var scratchpad: String?
}

public struct ShortcutInfo: Codable, Hashable, Sendable {
    /// The keys, as written in the configuration, e.g. `mod-shift-left`.
    public var keys: String
    /// The mode the shortcut belongs to, `nil` for the default shortcuts.
    public var mode: String?
    /// The action, or `move` or `resize` for dragging.
    public var action: String
    public var description: String?
    public var repeats: Bool
    public var onRelease: Bool
    public var passesThrough: Bool
}

public struct StatusInfo: Codable, Hashable, Sendable {
    public var version: String
    public var macOS: String
    public var accessibility: Bool
    public var configFile: String
    public var socketDirectory: String
    public var windows: Int
    public var displays: Int
    public var isPaused: Bool
    public var mode: String
    /// Problems in the configuration file.
    public var problems: [String]
}

public struct OptionInfo: Codable, Hashable, Sendable {
    public var option: String
    public var value: String
    public var defaultValue: String
    public var type: String
    /// Whether the configuration sets the option rather than leaving the default.
    public var isSet: Bool
}

public struct VersionInfo: Codable, Hashable, Sendable {
    public var name: String
    public var version: String
    public var macOS: String
}

/// A failure reported back to the client.
public struct ErrorInfo: Codable, Hashable, Sendable {
    public var error: String
}
