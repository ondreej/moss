/// A tiling algorithm that arranges a workspace's tiled windows.
///
/// Layouts are values holding only their own structure, such as a split tree or a list of
/// main and stack windows. They divide a work area into boxes; gaps, borders and `keep-size`
/// are applied on top of those boxes.
public protocol TilingLayout: Sendable {
    var kind: LayoutKind { get }

    /// Tiled windows in layout order.
    var windows: [WindowID] { get }

    func contains(_ window: WindowID) -> Bool

    mutating func insert(_ window: WindowID, context: InsertionContext)
    mutating func remove(_ window: WindowID)
    mutating func swap(_ a: WindowID, _ b: WindowID)
    /// Puts `new`, which is not part of the layout, exactly where `old` is, and removes `old`.
    mutating func replace(_ old: WindowID, with new: WindowID)

    /// Moves `window` one step in `direction` within the layout.
    /// Returns `false` when the layout has nothing in that direction.
    mutating func move(_ window: WindowID, _ direction: Direction, context: MoveContext) -> Bool

    /// Grows or shrinks `window` by `delta` points.
    /// `corner` is the corner being dragged during a mouse resize, `nil` for keyboard resizes.
    mutating func resize(_ window: WindowID, by delta: Size, corner: Corner?, area: Rect, settings: Settings)

    /// Changes the split ratio around `window`, either relatively or to an exact value.
    mutating func alterSplitRatio(_ window: WindowID, _ change: RatioChange, area: Rect, settings: Settings)

    /// Brings `window` into view once it has focus. Layouts that always show every window
    /// have nothing to do.
    mutating func reveal(_ window: WindowID, area: Rect, settings: Settings)

    /// Performs an action of this layout, such as `flip-split` or `column-width 0.5`.
    mutating func handle(_ message: LayoutMessage, focused: WindowID?, area: Rect, settings: Settings) throws(LayoutMessageError) -> LayoutMessageOutcome

    /// Partitions `area` into one box per window, before gaps and borders are applied.
    /// Layouts give windows at least their `minimumSizes`, in box space, where they can.
    func boxes(in area: Rect, settings: Settings, minimumSizes: [WindowID: Size]) -> [WindowID: Rect]
}

extension TilingLayout {
    public mutating func reveal(_ window: WindowID, area: Rect, settings: Settings) {}

    public func boxes(in area: Rect, settings: Settings) -> [WindowID: Rect] {
        boxes(in: area, settings: settings, minimumSizes: [:])
    }

    public var isEmpty: Bool { windows.isEmpty }
    public var count: Int { windows.count }
}

public struct InsertionContext: Sendable {
    /// The window new tiles should be placed next to, typically the focused one.
    public var target: WindowID?
    /// The cursor position, used to pick the side of a split.
    public var cursor: Point?
    /// Overrides both the split target and cursor, e.g. when moving a window in a direction.
    public var focalPoint: Point?
    /// Forces the side and orientation of the split (from a preselection).
    public var direction: Direction?
    public var area: Rect
    public var settings: Settings

    public init(
        target: WindowID? = nil,
        cursor: Point? = nil,
        focalPoint: Point? = nil,
        direction: Direction? = nil,
        area: Rect,
        settings: Settings
    ) {
        self.target = target
        self.cursor = cursor
        self.focalPoint = focalPoint
        self.direction = direction
        self.area = area
        self.settings = settings
    }
}

public struct MoveContext: Sendable {
    /// The adjacent tiled window in the requested direction, if any.
    public var neighbor: WindowID?
    /// A point just outside the moving window's edge in the requested direction.
    public var focalPoint: Point
    public var area: Rect
    public var settings: Settings

    public init(neighbor: WindowID?, focalPoint: Point, area: Rect, settings: Settings) {
        self.neighbor = neighbor
        self.focalPoint = focalPoint
        self.area = area
        self.settings = settings
    }
}

public enum Corner: String, Hashable, Sendable, Codable {
    case topLeft, topRight, bottomLeft, bottomRight

    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    public var isTop: Bool { self == .topLeft || self == .topRight }
}

public enum RatioChange: Hashable, Sendable {
    case relative(Double)
    case exact(Double)

    public func apply(to value: Double) -> Double {
        switch self {
        case .relative(let delta): value + delta
        case .exact(let value): value
        }
    }
}

/// A layout action split into its verb and arguments.
public struct LayoutMessage: Hashable, Sendable, CustomStringConvertible {
    public var command: String
    public var arguments: [String]

    public init(command: String, arguments: [String] = []) {
        self.command = command
        self.arguments = arguments
    }

    public init(parsing text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        self.init(command: words.first?.lowercased() ?? "", arguments: Array(words.dropFirst()))
    }

    public var description: String { ([command] + arguments).joined(separator: " ") }
}

public struct LayoutMessageOutcome: Hashable, Sendable {
    /// A window the layout wants focused as a result of the message.
    public var focus: WindowID?

    public init(focus: WindowID? = nil) { self.focus = focus }
}

public enum LayoutMessageError: Error, Hashable, Sendable, CustomStringConvertible {
    case unknownMessage(String, layout: LayoutKind)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .unknownMessage(let message, let layout): "'\(message)' is not an action of the \(layout.rawValue) layout"
        case .invalidArgument(let detail): detail
        }
    }
}

/// Converts layout boxes into window frames.
public enum TileGeometry {
    /// Every box keeps half the gap at each edge, the neighbouring box the other half, so `gaps`
    /// is the space between two windows. The border is then drawn inside what remains. Boxes are
    /// laid out in an area that leaves the margins at the screen's edges (`World.layoutArea`).
    public static func contentFrame(for box: Rect, gaps: Insets, border: Double) -> Rect {
        box.inset(by: gaps * 0.5 + Insets(all: border)).integral
    }

    /// Scales a frame around its own centre, as done for windows on scratchpads.
    public static func scaled(_ frame: Rect, by factor: Double) -> Rect {
        guard factor != 1 else { return frame }
        let size = Size(width: frame.width * factor, height: frame.height * factor)
        return frame.centered(size).integral
    }
}
