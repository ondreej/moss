import AppKit
public import MossCore
public import MossRuntime
import QuartzCore
import os
import Synchronization

/// Draws window borders and dimming as transparent, click-through windows layered
/// directly above the windows they decorate.
public final class BorderOverlays: DecorationSystem, @unchecked Sendable {
    private let pending = Mutex<[WindowDecoration]?>(nil)
    @MainActor private var overlays: [WindowID: BorderWindow] = [:]

    @MainActor private var accentObserver: (any NSObjectProtocol)?
    @MainActor private var spaceObserver: (any NSObjectProtocol)?
    @MainActor private var dropTarget: DropTargetWindow?

    @MainActor
    public init() {
        // Borders drawn in the accent color follow it when it changes in System Settings.
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlays.values.forEach { $0.redraw() } }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // The windows of the Space shown are listed a moment after the change.
            for delay in [0, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { self?.followActiveSpace() }
                }
            }
        }
    }

    /// Borders stay with their windows when another Space is shown, as when leaving an
    /// application's fullscreen Space: a border shown while that Space was active stayed there.
    @MainActor
    private func followActiveSpace() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let shown = Set(list.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        for (window, overlay) in overlays {
            overlay.follow(windowIsShown: shown.contains(window.rawValue))
        }
    }

    public func update(_ decorations: [WindowDecoration]) {
        let needsFlush = pending.withLock { pending -> Bool in
            defer { pending = decorations }
            return pending == nil
        }
        guard needsFlush else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.flush() } }
    }

    public func restack() {
        // An application raises its window a moment after it is asked to, so look again then.
        for delay in [0, 0.15] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { self.overlays.values.forEach { $0.restack() } }
            }
        }
    }

    public func showDropTarget(_ frame: Rect?, below window: WindowID?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.placeDropTarget(frame, below: window) }
        }
    }

    @MainActor
    private func placeDropTarget(_ frame: Rect?, below window: WindowID?) {
        guard let frame else {
            dropTarget?.hide()
            return
        }
        let panel = dropTarget ?? DropTargetWindow()
        dropTarget = panel
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.show(NSRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height), below: window)
    }

    @MainActor
    private func flush() {
        guard let decorations = pending.withLock({ pending -> [WindowDecoration]? in
            defer { pending = nil }
            return pending
        }) else { return }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let wanted = Set(decorations.map(\.window))
        for (id, overlay) in overlays where !wanted.contains(id) {
            overlay.retire()
            overlays[id] = nil
        }
        for decoration in decorations {
            let visible = decoration.borderWidth > 0 || decoration.dim > 0 || decoration.tabs != nil
            if !visible {
                overlays.removeValue(forKey: decoration.window)?.retire()
                continue
            }
            let overlay = overlays[decoration.window] ?? BorderWindow()
            overlays[decoration.window] = overlay
            overlay.show(decoration, primaryHeight: primaryHeight)
        }
    }
}

@MainActor
final class BorderWindow: ClickThroughPanel {
    private let gradient = CAGradientLayer()
    private let ring = CAShapeLayer()
    private let dimming = CAShapeLayer()
    private let tabStrip = CALayer()
    private var current: WindowDecoration?
    private var primaryHeight = 0.0
    /// The window's own corner radius, read again when its size changes.
    private var corners = MeasuredCorners()
    /// A pending reading of a radius the window server did not know yet.
    private var remeasure: Task<Void, Never>?

    init() {
        super.init(level: .normal, collectionBehavior: [.transient, .ignoresCycle, .fullScreenAuxiliary])
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(dimming)
        view.layer?.addSublayer(tabStrip)
        view.layer?.addSublayer(gradient)
        gradient.mask = ring
        ring.fillRule = .evenOdd
        contentView = view
    }

    /// Draws the current decoration again, e.g. after the accent color changed.
    func redraw() {
        guard let decoration = current else { return }
        current = nil
        show(decoration, primaryHeight: primaryHeight)
    }

    private func cornerRadius(for decoration: WindowDecoration) -> Double {
        switch decoration.corners {
        case .fixed(let radius):
            return radius
        case .window(let fallback):
            let window = decoration.window
            let (radius, retry) = corners.radius(for: decoration.frame.size, fallback: fallback) {
                let reading = PrivateAPI.cornerRadius(of: CGWindowID(window.rawValue))
                Log.platform.debug("corner radius of \(window.address, privacy: .public): \(reading.map { String($0) } ?? "unknown", privacy: .public)")
                return reading
            }
            if let retry, remeasure == nil {
                remeasure = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(retry))
                    guard let self, !Task.isCancelled else { return }
                    self.remeasure = nil
                    self.corners.invalidate()
                    self.redraw()
                }
            }
            return radius
        }
    }

    func show(_ decoration: WindowDecoration, primaryHeight: Double) {
        self.primaryHeight = primaryHeight
        let width = decoration.borderWidth
        // A group's tab bar sits in the space reserved above the window.
        let barSpace = decoration.tabs.map { $0.height + 2 } ?? 0
        var decorated = decoration.frame
        decorated.origin.y -= barSpace
        decorated.size.height += barSpace
        let outer = decorated.inset(by: -width)
        let frame = NSRect(x: outer.minX, y: primaryHeight - outer.maxY, width: outer.width, height: outer.height)

        if decoration != current {
            setFrame(frame, display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let bounds = CGRect(origin: .zero, size: frame.size)
            gradient.frame = bounds
            ring.frame = bounds
            dimming.frame = bounds

            let colors = decoration.border.colors.map(\.cgColor)
            gradient.colors = colors.count == 1 ? [colors[0], colors[0]] : colors
            let radians = decoration.border.angle * .pi / 180
            let (dx, dy) = (cos(radians) / 2, sin(radians) / 2)
            // Layer space has its origin at the bottom left; angles turn clockwise on screen.
            gradient.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 + dy)
            gradient.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 - dy)

            let inner = bounds.insetBy(dx: width, dy: width)
            let radius = max(0, cornerRadius(for: decoration))
            let path = CGMutablePath()
            path.addRoundedRect(in: bounds, cornerWidth: radius + width, cornerHeight: radius + width)
            if inner.width > 0 && inner.height > 0 {
                path.addRoundedRect(in: inner, cornerWidth: min(radius, inner.width / 2), cornerHeight: min(radius, inner.height / 2))
            }
            ring.path = path

            drawTabs(decoration.tabs, in: inner)

            if decoration.dim > 0, inner.width > 0, inner.height > 0 {
                dimming.path = CGPath(roundedRect: inner, cornerWidth: min(radius, inner.width / 2), cornerHeight: min(radius, inner.height / 2), transform: nil)
                dimming.fillColor = CGColor(gray: 0, alpha: decoration.dim)
                dimming.isHidden = false
            } else {
                dimming.isHidden = true
            }
            CATransaction.commit()
            current = decoration
        }
        // Restack on every update: the decorated window may have been raised above its border.
        restack()
    }

    func restack() {
        guard let current else { return }
        order(.above, relativeTo: Int(current.window.rawValue))
    }

    /// Puts the border back above its window once another Space is shown, or out of sight
    /// while its window is.
    func follow(windowIsShown: Bool) {
        guard current != nil else { return }
        if !windowIsShown {
            orderOut(nil)
        } else if !isVisible || !isOnActiveSpace {
            orderOut(nil)
            restack()
        }
    }

    /// Takes the border away for good: nothing pending may show it again.
    func retire() {
        remeasure?.cancel()
        remeasure = nil
        current = nil
        orderOut(nil)
    }

    /// Lays out one rounded tab per group member along the top of `inner`, in the system's
    /// colors: the accent color for the shown tab, a translucent gray for the others.
    private func drawTabs(_ bar: TabBar?, in inner: CGRect) {
        tabStrip.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let bar, !bar.tabs.isEmpty else {
            tabStrip.isHidden = true
            return
        }
        tabStrip.isHidden = false
        tabStrip.frame = CGRect(x: inner.minX, y: inner.maxY - bar.height, width: inner.width, height: bar.height)
        let spacing: CGFloat = 2
        let tabWidth = (inner.width - spacing * CGFloat(bar.tabs.count - 1)) / CGFloat(bar.tabs.count)
        let scale = screen?.backingScaleFactor ?? 2
        for (index, tab) in bar.tabs.enumerated() {
            let frame = CGRect(x: CGFloat(index) * (tabWidth + spacing), y: 0, width: tabWidth, height: bar.height)
            let fill = CALayer()
            fill.frame = frame
            fill.cornerRadius = min(4, bar.height / 3)
            fill.backgroundColor = tab.isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
                : NSColor.systemGray.withAlphaComponent(0.35).cgColor
            tabStrip.addSublayer(fill)

            guard bar.showsTitles else { continue }
            let fontSize = max(8, min(13, bar.height * 0.6))
            let text = CATextLayer()
            text.string = tab.title
            text.font = NSFont.systemFont(ofSize: fontSize, weight: tab.isActive ? .semibold : .regular)
            text.fontSize = fontSize
            text.foregroundColor = (tab.isActive ? NSColor.textOnAccent : .white).cgColor
            text.alignmentMode = .center
            text.truncationMode = .end
            text.contentsScale = scale
            let lineHeight = fontSize * 1.25
            text.frame = frame.insetBy(dx: 6, dy: max(0, (bar.height - lineHeight) / 2))
            tabStrip.addSublayer(text)
        }
    }
}

/// The tile a dragged window would take: a tinted rounded rectangle just below the window,
/// gliding from tile to tile as the cursor moves.
@MainActor
final class DropTargetWindow: ClickThroughPanel {
    private let shape = CALayer()

    init() {
        super.init(level: .normal, collectionBehavior: [.transient, .ignoresCycle, .fullScreenAuxiliary])
        let view = NSView()
        view.wantsLayer = true
        shape.cornerRadius = 14
        shape.cornerCurve = .continuous
        shape.borderWidth = 2
        view.layer?.addSublayer(shape)
        contentView = view
    }

    func show(_ frame: NSRect, below window: WindowID?) {
        let accent = MossCore.Color.accent().cgColor
        shape.backgroundColor = accent.copy(alpha: 0.16)
        shape.borderColor = accent.copy(alpha: 0.85)
        if isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(frame, display: true)
            }
        } else {
            setFrame(frame, display: true)
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = CGRect(origin: .zero, size: frame.size)
        CATransaction.commit()
        if let window { order(.below, relativeTo: Int(window.rawValue)) } else { orderFrontRegardless() }
    }

    func hide() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { self.orderOut(nil) }
        }
    }
}

extension MossCore.Color {
    /// The color to draw with; the accent color is read from the system each time.
    @MainActor
    var cgColor: CGColor {
        guard isAccent, let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else {
            return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
        return CGColor(srgbRed: accent.redComponent, green: accent.greenComponent, blue: accent.blueComponent, alpha: accent.alphaComponent * alpha)
    }
}
