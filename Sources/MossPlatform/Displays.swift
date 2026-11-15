import CoreGraphics
import MossCore

/// The active displays, in the global coordinates of window frames: from the top left of the
/// main display, downwards.
enum Displays {
    static var bounds: [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    /// Whether `frame` is exactly a whole display, menu bar included.
    static func isWholeDisplay(_ frame: Rect) -> Bool {
        bounds.contains { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height).isApproximatelyEqual(to: frame, tolerance: 2) }
    }
}
