import MossCore

/// The corner radius of a decorated window, as read from the window server.
///
/// A window that has only just appeared has no shape in the window server yet and reads as
/// square, so a square or missing reading is provisional: the fallback radius is drawn and the
/// window is read again a few times before its corners are taken to be square.
struct MeasuredCorners {
    /// Seconds to wait before each further reading.
    static let retryDelays = [0.1, 0.25, 0.5, 1, 2]

    private(set) var size: Size?
    private(set) var reading: Double?
    private(set) var attempts = 0
    private var isStale = true

    /// The radius to draw for a window of `size`, reading it with `read` when the size changed or
    /// a reading is due; and, when the reading was provisional, how long to wait before the next.
    mutating func radius(for size: Size, fallback: Double, read: () -> Double?) -> (radius: Double, retryAfter: Double?) {
        var retry: Double?
        if isStale || self.size != size {
            if !isStale { attempts = 0 }
            reading = read()
            self.size = size
            isStale = false
            if (reading ?? 0) <= 0, attempts < Self.retryDelays.count {
                retry = Self.retryDelays[attempts]
                attempts += 1
            }
        }
        switch reading {
        case let radius? where radius > 0: return (radius, retry)
        case .some where retry == nil && attempts >= Self.retryDelays.count: return (0, nil)
        default: return (fallback, retry)
        }
    }

    /// Asks for a new reading the next time the radius is needed.
    mutating func invalidate() { isStale = true }
}
