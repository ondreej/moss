/// A message shown on screen for a while, from Moss itself or `moss notify`.
public struct Notice: Hashable, Sendable {
    public enum Icon: String, Hashable, Sendable, CaseIterable {
        case info
        case ok
        case warning
        case error

        /// The color of a notice that does not choose one: the matching macOS system color.
        public var color: Color {
            switch self {
            case .info: Color(rgba: 0x0A84_FFFF)
            case .ok: Color(rgba: 0x30D1_58FF)
            case .warning: Color(rgba: 0xFF9F_0AFF)
            case .error: Color(rgba: 0xFF45_3AFF)
            }
        }
    }

    public static let defaultFontSize = 13.0

    public var icon: Icon?
    public var message: String
    public var color: Color
    /// How long the notice stays on screen, in milliseconds.
    public var milliseconds: Int
    public var fontSize: Double

    /// Without a color, the notice takes its icon's.
    public init(icon: Icon?, message: String, color: Color? = nil, milliseconds: Int, fontSize: Double = Notice.defaultFontSize) {
        self.icon = icon
        self.message = message
        self.color = color ?? icon?.color ?? .accent()
        self.milliseconds = milliseconds
        self.fontSize = fontSize
    }
}

/// A bar at the top of the screen listing problems, such as configuration errors, until they are fixed.
public struct ErrorBar: Hashable, Sendable {
    public var lines: [String]
    public var color: Color

    public static let defaultColor = Color(rgba: 0xFF45_3AFF)

    // Layout shared by the window manager, which keeps windows clear of the bar, and the
    // overlay that draws it.
    public static let margin = 10.0
    public static let lineHeight = 16.0
    public static let lineSpacing = 2.0
    public static let verticalPadding = 9.0

    /// The height of the bar itself, without its margin.
    public var height: Double {
        let count = Double(max(1, lines.count))
        return 2 * Self.verticalPadding + count * Self.lineHeight + (count - 1) * Self.lineSpacing
    }

    /// The space the bar takes at the top of a display, margin included.
    public var reservation: Insets { Insets(top: Self.margin + height, right: 0, bottom: 0, left: 0) }

    public init(lines: [String], color: Color = ErrorBar.defaultColor) {
        self.lines = lines
        self.color = color
    }
}
