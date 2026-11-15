import AppKit
public import MossCore
public import MossRuntime
import SwiftUI
import os

/// Notices stacked in the top-right corner of a monitor and the error bar along one of its
/// edges, drawn in click-through panels above every window.
public final class NoticeOverlays: NoticeSystem, @unchecked Sendable {
    @MainActor private var notices: [PostedNotice] = []
    @MainActor private var errorBar: (panel: OverlayPanel, frame: Rect)?
    @MainActor private var workspaceHUD: OverlayPanel?
    @MainActor private var workspaceHUDGeneration = 0

    @MainActor
    public init() {}

    public func post(_ notice: Notice, within area: Rect) {
        onMain { $0.show(notice, within: area) }
    }

    public func dismiss(oldest count: Int?) {
        onMain { overlays in
            let oldest = overlays.notices.prefix(count ?? overlays.notices.count)
            oldest.forEach { overlays.remove($0.id) }
        }
    }

    public func showErrorBar(_ bar: ErrorBar?, within area: Rect) {
        onMain { $0.place(bar, within: area) }
    }

    public func showWorkspaces(_ hud: WorkspaceHUD, within area: Rect) {
        onMain { $0.present(hud, within: area) }
    }

    private func onMain(_ body: @escaping @MainActor (NoticeOverlays) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
    }

    // MARK: - Notices

    private struct PostedNotice {
        let id = UUID()
        let panel: OverlayPanel
        let area: Rect
        let size: CGSize
    }

    /// Space around a card for its shadow, inside the panel.
    private static let shadowRoom = 14.0
    private static let errorBarMaxWidth = 760.0
    /// Distance between cards and from the edges of the monitor.
    private static let spacing = 10.0
    /// The widest a notice gets before its text wraps.
    private static let noticeWidth = 460.0

    @MainActor
    private func show(_ notice: Notice, within area: Rect) {
        let panel = OverlayPanel()
        let size = panel.host(NoticeCard(notice: notice).padding(Self.shadowRoom), width: Self.noticeWidth + 2 * Self.shadowRoom)
        let posted = PostedNotice(panel: panel, area: area, size: size)
        notices.append(posted)
        layoutNotices()
        // Slide in from the right edge.
        let target = panel.frame
        panel.setFrame(target.offsetBy(dx: 24, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
        let id = posted.id
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(notice.milliseconds)) { [weak self] in
            MainActor.assumeIsolated { self?.remove(id) }
        }
    }

    @MainActor
    private func remove(_ id: UUID) {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        let panel = notices.remove(at: index).panel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
        layoutNotices(animated: true)
    }

    /// Stacks each monitor's notices downwards from its top-right corner, oldest first.
    @MainActor
    private func layoutNotices(animated: Bool = false) {
        var nextTop: [Rect: Double] = [:]
        for notice in notices {
            let area = notice.area
            var top = nextTop[area] ?? area.minY + Self.spacing
            if let bar = errorBar, nextTop[area] == nil, bar.frame.intersects(area), bar.frame.minY <= area.minY + Self.spacing {
                // Start below an error bar along the top.
                top = bar.frame.maxY - Self.shadowRoom + Self.spacing
            }
            let frame = Rect(
                x: area.maxX - Self.spacing - notice.size.width + Self.shadowRoom,
                y: top - Self.shadowRoom,
                width: notice.size.width,
                height: notice.size.height
            )
            nextTop[area] = frame.maxY - Self.shadowRoom + Self.spacing
            let target = Self.cocoaFrame(frame)
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    notice.panel.animator().setFrame(target, display: true)
                }
            } else {
                notice.panel.setFrame(target, display: true)
            }
        }
    }

    // MARK: - Workspace switches

    /// Shows the HUD near the bottom of the monitor, replacing one still on screen, and fades
    /// it out shortly after the last switch.
    @MainActor
    private func present(_ hud: WorkspaceHUD, within area: Rect) {
        let panel = workspaceHUD ?? OverlayPanel()
        workspaceHUD = panel
        let size = panel.host(WorkspaceHUDCard(hud: hud).padding(Self.shadowRoom), width: area.width)
        let frame = Rect(
            x: area.midX - size.width / 2,
            y: area.maxY - area.height * 0.14 - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.setFrame(Self.cocoaFrame(frame), display: true)
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        workspaceHUDGeneration += 1
        let generation = workspaceHUDGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.workspaceHUDGeneration == generation else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    panel.animator().alphaValue = 0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if self.workspaceHUDGeneration == generation { panel.orderOut(nil) }
                    }
                }
            }
        }
    }

    // MARK: - Error bar

    @MainActor
    private func place(_ bar: ErrorBar?, within area: Rect) {
        guard let bar else {
            errorBar?.panel.orderOut(nil)
            errorBar = nil
            layoutNotices(animated: true)
            return
        }
        let panel = errorBar?.panel ?? OverlayPanel()
        let margin = ErrorBar.margin
        // As wide as its text, centered at the top of the display.
        let widest = min(area.width - 2 * margin, Self.errorBarMaxWidth) + 2 * Self.shadowRoom
        let width = min(widest, panel.host(ErrorBarCard(bar: bar).padding(Self.shadowRoom), width: widest).width)
        // The window manager keeps windows clear of the bar's exact height.
        let height = bar.height + 2 * Self.shadowRoom
        _ = panel.host(ErrorBarCard(bar: bar).padding(Self.shadowRoom).frame(width: width, height: height), width: width)
        let frame = Rect(x: area.midX - width / 2, y: area.minY + margin - Self.shadowRoom, width: width, height: height)
        panel.setFrame(Self.cocoaFrame(frame), display: true)
        panel.orderFrontRegardless()
        errorBar = (panel, frame)
        layoutNotices(animated: true)
    }

    /// Converts from top-left global coordinates to AppKit's bottom-left ones.
    @MainActor
    private static func cocoaFrame(_ rect: Rect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A transparent panel above all windows that never takes focus or clicks.
@MainActor
private final class OverlayPanel: ClickThroughPanel {
    init() {
        super.init(level: .statusBar, collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary])
    }

    /// Shows `view` and returns the size it needs when at most `width` wide.
    func host(_ view: some View, width: Double) -> CGSize {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
        contentView = controller.view
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

// MARK: - Views

private extension MossCore.Color {
    var swiftUI: SwiftUI.Color {
        isAccent ? SwiftUI.Color.accentColor.opacity(alpha) : SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

private extension Notice.Icon {
    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// A card in the system's glass material, like macOS notifications.
private struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .glassEffect(.regular, in: shape)
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}

private struct NoticeCard: View {
    let notice: Notice

    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                if let icon = notice.icon {
                    Image(systemName: icon.symbol)
                        .font(.system(size: notice.fontSize + 3, weight: .medium))
                        .foregroundStyle(notice.color.swiftUI)
                        .symbolRenderingMode(.monochrome)
                }
                Text(notice.message)
                    .font(.system(size: notice.fontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// The workspaces of a monitor as a row of pills, the active one filled with the accent color.
private struct WorkspaceHUDCard: View {
    let hud: WorkspaceHUD

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(hud.items.enumerated()), id: \.offset) { _, item in
                Text(item.name)
                    .font(.system(size: item.isActive ? 17 : 14, weight: item.isActive ? .semibold : .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(item.isActive ? AnyShapeStyle(SwiftUI.Color(nsColor: .textOnAccent)) : AnyShapeStyle(item.windows > 0 ? .primary : .tertiary))
                    .padding(.horizontal, item.isActive ? 14 : 9)
                    .frame(minWidth: item.isActive ? 40 : 30, minHeight: item.isActive ? 34 : 28)
                    .background(item.isActive ? AnyShapeStyle(SwiftUI.Color.accentColor) : AnyShapeStyle(.clear), in: .capsule)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .animation(.snappy(duration: 0.18), value: hud)
    }
}

/// Problems in the configuration: a compact pill of glass tinted with the bar's color.
private struct ErrorBarCard: View {
    let bar: ErrorBar

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (2 * ErrorBar.verticalPadding + ErrorBar.lineHeight) / 2, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            VStack(alignment: .leading, spacing: ErrorBar.lineSpacing) {
                ForEach(Array(bar.lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(height: ErrorBar.lineHeight)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, ErrorBar.verticalPadding)
        // Glass behind a translucent wash of the bar's color, so what is underneath shows through.
        .background(bar.color.swiftUI.opacity(0.62), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
        .shadow(color: bar.color.swiftUI.opacity(0.3), radius: 12, y: 3)
    }
}
