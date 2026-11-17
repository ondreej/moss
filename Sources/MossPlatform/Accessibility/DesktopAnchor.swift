import AppKit

/// Takes a display back from a fullscreen Space to the desktop. macOS leaves such a Space only
/// for a window on the desktop taking focus, and an empty workspace has none, so Moss focuses
/// one of its own there for a moment: a single transparent point that takes no clicks.
@MainActor
final class DesktopAnchor {
    private final class AnchorWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    /// How long the window stays while macOS switches to the desktop.
    private static let hold = Duration.milliseconds(250)

    private lazy var window: NSWindow = {
        let window = AnchorWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // A window of the desktop's Space, which a transient one would not be: it would join
        // the fullscreen Space shown. Left out of window cycling.
        window.collectionBehavior = [.managed, .ignoresCycle]
        return window
    }()

    /// Brings the desktop back on the display with keyboard focus, returning once it shows.
    func showDesktop() async {
        if let screen = NSScreen.main { window.setFrameOrigin(screen.frame.origin) }
        // Moss becoming active is not the user opening it.
        FocusRelay.pass()
        window.orderFrontRegardless()
        // Shown at first in the Space on screen when Moss has no window on the desktop yet, as
        // just after it started there.
        let number = CGWindowID(window.windowNumber)
        _ = PrivateAPI.moveToDesktop(number)
        _ = PrivateAPI.focus(window: number, pid: getpid(), raise: true)
        try? await Task.sleep(for: Self.hold)
        window.orderOut(nil)
    }
}
