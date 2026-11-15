import MossCore

/// Turns scrolling into single steps for scroll shortcuts. A mouse wheel takes one step per
/// notch. A trackpad sends a stream of small movements for every swipe, and more as it coasts
/// after the fingers lift: a swipe takes one step once it has travelled a little way, and the
/// rest of it, coasting included, is kept from applications.
struct ScrollGesture {
    /// What one scroll event says.
    enum Input: Equatable {
        /// A notch of a mouse wheel.
        case notch(Direction)
        /// A swipe on a trackpad began.
        case began
        /// A swipe moved by this much, in points.
        case moved(dx: Double, dy: Double)
        /// The fingers lifted, or the swipe was cancelled.
        case ended
        /// The swipe coasting on after the fingers lifted; `isLast` ends it.
        case coasting(isLast: Bool)
    }

    enum Outcome: Equatable {
        /// The event goes on to the application.
        case pass
        /// The event is kept from the application.
        case consume
        /// The event runs the scroll shortcut for `direction`, and is kept from the application.
        case run(Direction)
    }

    /// How far a swipe travels before it takes its step, in points.
    static let distance = 24.0

    private var travelled = (dx: 0.0, dy: 0.0)
    private var hasRun = false
    private var keepsCoasting = false

    /// `isBound` tells whether a scroll shortcut exists for a direction with the keys held now.
    mutating func handle(_ input: Input, isBound: (Direction) -> Bool) -> Outcome {
        switch input {
        case .notch(let direction):
            return isBound(direction) ? .run(direction) : .pass

        case .began:
            travelled = (0, 0)
            hasRun = false
            keepsCoasting = false
            return Direction.allCases.contains(where: isBound) ? .consume : .pass

        case .moved(let dx, let dy):
            if hasRun { return .consume }
            guard Direction.allCases.contains(where: isBound) else { return .pass }
            travelled.dx += dx
            travelled.dy += dy
            guard let direction = Self.direction(of: travelled), isBound(direction) else { return .consume }
            hasRun = true
            keepsCoasting = true
            return .run(direction)

        case .ended:
            let wasBound = hasRun || Direction.allCases.contains(where: isBound)
            travelled = (0, 0)
            hasRun = false
            return wasBound ? .consume : .pass

        case .coasting(let isLast):
            let outcome: Outcome = keepsCoasting ? .consume : .pass
            if isLast { keepsCoasting = false }
            return outcome
        }
    }

    /// The direction a swipe has gone once it has travelled far enough, as a wheel would turn:
    /// positive vertical movement is up and positive horizontal movement is left.
    static func direction(of travelled: (dx: Double, dy: Double)) -> Direction? {
        let (dx, dy) = travelled
        guard max(abs(dx), abs(dy)) >= distance else { return nil }
        return abs(dy) >= abs(dx) ? (dy > 0 ? .up : .down) : (dx > 0 ? .left : .right)
    }
}
