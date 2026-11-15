import AppKit
import Synchronization

/// A transparent panel of Moss's own that the mouse passes straight through: borders,
/// drop previews and notices. Finding the window under the cursor looks through these, but
/// not through Moss's other windows, such as settings, which cover what is behind them
/// like any other window.
@MainActor
class ClickThroughPanel: NSPanel {
    init(level: NSWindow.Level, collectionBehavior: NSWindow.CollectionBehavior) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        self.level = level
        self.collectionBehavior = collectionBehavior
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // The window server numbers a panel once it is first shown.
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        super.order(place, relativeTo: otherWindow)
        Self.remember(windowNumber)
    }

    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        Self.remember(windowNumber)
    }

    private nonisolated static let numbers = Mutex<Set<Int>>([])

    private static func remember(_ number: Int) {
        guard number > 0 else { return }
        numbers.withLock { _ = $0.insert(number) }
    }

    /// Whether the window server's window `number` is one of these panels.
    nonisolated static func contains(_ number: Int) -> Bool {
        numbers.withLock { $0.contains(number) }
    }
}
