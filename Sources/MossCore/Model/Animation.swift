/// A cubic Bézier timing curve from (0, 0) to (1, 1), defined by its two control points like a CSS `cubic-bezier`.
public struct BezierCurve: Hashable, Sendable {
    public var x1, y1, x2, y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public static let linear = BezierCurve(0, 0, 1, 1)
    public static let easeOutQuint = BezierCurve(0.23, 1, 0.32, 1)

    /// The curve's progress at time `t` (`0...1`).
    public func value(at t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        // Solve x(s) = t for the curve parameter s with Newton's method, then evaluate y(s).
        var s = t
        for _ in 0..<8 {
            let x = Self.coordinate(s, x1, x2) - t
            let slope = Self.derivative(s, x1, x2)
            guard abs(x) > 1e-6, abs(slope) > 1e-6 else { break }
            s = min(max(s - x / slope, 0), 1)
        }
        return Self.coordinate(s, y1, y2)
    }

    private static func coordinate(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - s
        return 3 * inverse * inverse * s * p1 + 3 * inverse * s * s * p2 + s * s * s
    }

    private static func derivative(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - s
        return 3 * inverse * inverse * p1 + 6 * inverse * s * (p2 - p1) + 3 * s * s * (1 - p2)
    }
}

/// How one kind of change is animated.
public struct AnimationSpec: Hashable, Sendable {
    public var isEnabled: Bool
    /// Duration in seconds.
    public var duration: Double
    public var curve: BezierCurve

    public init(isEnabled: Bool = true, duration: Double, curve: BezierCurve) {
        self.isEnabled = isEnabled
        self.duration = duration
        self.curve = curve
    }
}
