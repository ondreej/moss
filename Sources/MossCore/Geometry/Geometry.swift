/// Geometry used throughout the window manager.
///
/// Coordinates are in the window server's global space, which the accessibility API also
/// uses: the origin is the primary display's top-left corner and `y` grows downwards.

public struct Point: Hashable, Sendable, Codable, CustomStringConvertible {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)

    public static func + (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    public static func - (lhs: Point, rhs: Point) -> Point { Point(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }

    public func distanceSquared(to other: Point) -> Double {
        let dx = x - other.x, dy = y - other.y
        return dx * dx + dy * dy
    }

    public var description: String { "(\(x.compact), \(y.compact))" }
}

public struct Size: Hashable, Sendable, Codable, CustomStringConvertible {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)

    public var description: String { "\(width.compact)x\(height.compact)" }
}

public struct Rect: Hashable, Sendable, Codable, CustomStringConvertible {
    public var origin: Point
    public var size: Size

    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }

    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    public var x: Double { origin.x }
    public var y: Double { origin.y }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width / 2 }
    public var midY: Double { origin.y + size.height / 2 }
    public var center: Point { Point(x: midX, y: midY) }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func intersects(_ other: Rect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func intersection(_ other: Rect) -> Rect {
        let x0 = max(minX, other.minX), y0 = max(minY, other.minY)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return .zero }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Shrinks the rectangle by the given insets. Negative insets grow it.
    public func inset(by insets: Insets) -> Rect {
        Rect(
            x: minX + insets.left,
            y: minY + insets.top,
            width: max(0, width - insets.left - insets.right),
            height: max(0, height - insets.top - insets.bottom)
        )
    }

    public func inset(by amount: Double) -> Rect { inset(by: Insets(all: amount)) }

    /// A rectangle of `size` centred within this one.
    public func centered(_ size: Size) -> Rect {
        Rect(x: midX - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The rectangle moved as little as possible to lie within `area`. Along an axis where it is
    /// too long for `area`, it starts where `area` does.
    public func moved(inside area: Rect) -> Rect {
        func start(_ start: Double, length: Double, from lower: Double, to upper: Double) -> Double {
            length > upper - lower ? lower : min(max(start, lower), upper - length)
        }
        return Rect(
            x: start(minX, length: width, from: area.minX, to: area.maxX),
            y: start(minY, length: height, from: area.minY, to: area.maxY),
            width: width,
            height: height
        )
    }

    /// Splits the rectangle along `axis`; `fraction` is the share given to the first part.
    public func split(_ axis: Axis, fraction: Double) -> (first: Rect, second: Rect) {
        split(axis, at: (axis == .horizontal ? width : height) * fraction)
    }

    /// Splits the rectangle along `axis`, the first part being `length` long.
    public func split(_ axis: Axis, at length: Double) -> (first: Rect, second: Rect) {
        switch axis {
        case .horizontal:
            return (
                Rect(x: minX, y: minY, width: length, height: height),
                Rect(x: minX + length, y: minY, width: width - length, height: height)
            )
        case .vertical:
            return (
                Rect(x: minX, y: minY, width: width, height: length),
                Rect(x: minX, y: minY + length, width: width, height: height - length)
            )
        }
    }

    /// Rounds the rectangle to whole points, keeping shared edges of neighbours aligned.
    public var integral: Rect {
        let x0 = minX.rounded(), y0 = minY.rounded()
        let x1 = maxX.rounded(), y1 = maxY.rounded()
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func isApproximatelyEqual(to other: Rect, tolerance: Double = 1) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    public var description: String { "\(origin.x.compact),\(origin.y.compact) \(size)" }
}

/// Edge insets in CSS order (top, right, bottom, left), matching how gaps are configured.
public struct Insets: Hashable, Sendable, Codable, CustomStringConvertible {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(all value: Double) {
        self.init(top: value, right: value, bottom: value, left: value)
    }

    public static let zero = Insets(all: 0)

    public static func + (lhs: Insets, rhs: Insets) -> Insets {
        Insets(top: lhs.top + rhs.top, right: lhs.right + rhs.right, bottom: lhs.bottom + rhs.bottom, left: lhs.left + rhs.left)
    }

    public static func - (lhs: Insets, rhs: Insets) -> Insets {
        Insets(top: lhs.top - rhs.top, right: lhs.right - rhs.right, bottom: lhs.bottom - rhs.bottom, left: lhs.left - rhs.left)
    }

    public static func * (lhs: Insets, rhs: Double) -> Insets {
        Insets(top: lhs.top * rhs, right: lhs.right * rhs, bottom: lhs.bottom * rhs, left: lhs.left * rhs)
    }

    public var description: String {
        if top == right && right == bottom && bottom == left { return top.compact }
        return "\(top.compact) \(right.compact) \(bottom.compact) \(left.compact)"
    }
}

public enum Axis: String, Hashable, Sendable, Codable {
    /// Children are laid out side by side.
    case horizontal
    /// Children are stacked on top of each other.
    case vertical

    public var orthogonal: Axis { self == .horizontal ? .vertical : .horizontal }
}

public enum Direction: String, Hashable, Sendable, Codable, CaseIterable, CustomStringConvertible {
    case left
    case right
    case up
    case down

    public var axis: Axis { self == .left || self == .right ? .horizontal : .vertical }

    /// Whether the direction points towards the first child of a split (left or up).
    public var isTowardsStart: Bool { self == .left || self == .up }

    public var opposite: Direction {
        switch self {
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }

    /// Parses `left`, `right`, `up` or `down`.
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }

    public var description: String { rawValue }
}

extension Double {
    /// A short textual form without a trailing `.0` for whole numbers.
    var compact: String {
        if self == rounded(), abs(self) < 1e15 { return String(Int(self)) }
        return String(self)
    }
}
