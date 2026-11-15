public import MossCore

/// Where windows on hidden workspaces are parked.
///
/// macOS has no API for hiding single windows of other applications, so Moss moves them
/// almost entirely off screen, leaving one point visible in a corner of their monitor. The
/// corner is chosen so the window does not spill onto a neighbouring display.
public enum HiddenPlacement {
    public static func frame(for size: Size, on monitor: Rect, others: [Rect]) -> Rect {
        let candidates = [
            Rect(origin: Point(x: monitor.maxX - 1, y: monitor.maxY - 1), size: size),
            Rect(origin: Point(x: monitor.minX - size.width + 1, y: monitor.maxY - 1), size: size),
        ]
        func spill(_ frame: Rect) -> Double {
            others.reduce(0) { $0 + frame.intersection($1).area }
        }
        return candidates.min { spill($0) < spill($1) } ?? candidates[0]
    }

    /// Whether a frame looks like a parked window, e.g. after Moss was terminated abruptly.
    public static func isParked(_ frame: Rect, in monitors: [Rect]) -> Bool {
        let visibleArea = monitors.reduce(0) { $0 + frame.intersection($1).area }
        return frame.area > 0 && visibleArea < 16
    }
}
