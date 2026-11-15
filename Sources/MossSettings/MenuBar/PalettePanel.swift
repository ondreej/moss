public import AppKit

/// The palette opened from the keyboard. It floats in the upper middle of the screen with the
/// pointer, as Spotlight does, instead of hanging from the menu bar, which may be hidden.
///
/// It takes the keyboard without making Moss the active application, so the application
/// in front stays so, and it closes as soon as anything else takes the keyboard.
@MainActor
public final class PalettePanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var sizeObservation: NSKeyValueObservation?
    /// Where the panel's top edge and centre stay while its content grows and shrinks.
    private var anchor = NSPoint.zero

    public override init() {}

    public var isShown: Bool { panel != nil }

    /// Shows `content`, which sizes itself, until it closes or loses the keyboard.
    public func show(_ content: NSViewController) {
        close()
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentViewController = content
        panel.delegate = self

        let visible = screen.visibleFrame
        anchor = NSPoint(x: visible.midX, y: visible.maxY - visible.height * 0.18)
        self.panel = panel
        place(size: content.view.fittingSize)
        sizeObservation = content.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue, size != .zero else { return }
            MainActor.assumeIsolated { self?.place(size: size) }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    public func close() {
        guard let panel else { return }
        self.panel = nil
        sizeObservation = nil
        panel.delegate = nil
        panel.orderOut(nil)
    }

    public func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func place(size: NSSize) {
        panel?.setFrame(NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height), display: true)
    }
}
