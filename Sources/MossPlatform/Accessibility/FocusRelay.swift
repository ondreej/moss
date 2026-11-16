import Foundation
import Synchronization

/// Moss makes itself the active application for a moment to move focus between two windows of
/// another application without raising either. Becoming active then is not the user's doing.
public enum FocusRelay {
    private static let passed = Mutex<ContinuousClock.Instant?>(nil)

    static func pass() { passed.withLock { $0 = .now } }

    /// Whether Moss became active just now only to pass focus on.
    public static var isPassing: Bool {
        passed.withLock { $0.map { ContinuousClock.now - $0 < .milliseconds(500) } ?? false }
    }
}
