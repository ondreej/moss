import AppKit
import MossCore
import SwiftUI

/// A live miniature of the desktop, laid out by the same engine the window manager uses,
/// so every setting shows its exact effect while it is being changed.
struct LayoutPreview: View {
    let settings: MossCore.Settings
    var interactive = true
    @State private var windowCount = 3
    @State private var focusIndex: Int?

    private static let screen: CGSize = NSScreen.main?.frame.size ?? CGSize(width: 1512, height: 982)
    private static let menuBar: CGFloat = 32

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let scale = proxy.size.width / Self.screen.width
                let windows = Self.arrange(settings: settings, count: windowCount, focus: focusIndex)
                ZStack(alignment: .topLeading) {
                    Wallpaper()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                    Rectangle()
                        .fill(.bar)
                        .frame(height: Self.menuBar * scale)
                    ForEach(windows) { window in
                        PreviewWindow(window: window, settings: settings, scale: scale)
                            .frame(width: window.frame.width * scale, height: window.frame.height * scale)
                            .offset(x: window.frame.minX * scale, y: window.frame.minY * scale)
                            .onTapGesture { if interactive { focusIndex = window.index } }
                    }
                }
                .animation(.spring(duration: 0.35, bounce: 0.15), value: windows)
            }
            .aspectRatio(Self.screen.width / Self.screen.height, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }

            if interactive {
                HStack {
                    Text("\(windowCount) window\(windowCount == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    ControlGroup {
                        Button("Remove Window", systemImage: "minus") { windowCount = max(1, windowCount - 1); focusIndex = nil }
                            .disabled(windowCount <= 1)
                        Button("Add Window", systemImage: "plus") { windowCount = min(8, windowCount + 1); focusIndex = nil }
                            .disabled(windowCount >= 8)
                    }
                    .fixedSize()
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    struct PreviewWindowModel: Identifiable, Hashable {
        var id: Int { index }
        var index: Int
        var frame: CGRect
        var isFocused: Bool
    }

    /// Lays out sample windows with the real window manager model.
    static func arrange(settings: MossCore.Settings, count: Int, focus: Int?) -> [PreviewWindowModel] {
        var world = World(settings: settings)
        let frame = Rect(x: 0, y: 0, width: screen.width, height: screen.height)
        let visible = Rect(x: 0, y: menuBar, width: screen.width, height: screen.height - menuBar)
        world.updateDisplays([DisplayDescription(id: MonitorID(1), name: "Preview", frame: frame, visibleFrame: visible, isMain: true)])
        for index in 0..<count {
            let properties = WindowProperties(appID: "preview", appName: "Preview", title: "Window \(index + 1)")
            world.addWindow(WindowID(UInt32(index + 1)), properties: properties, frame: Rect(x: 200, y: 200, width: 640, height: 420))
        }
        if let focus { world.handleFocusChange(to: WindowID(UInt32(focus + 1))) }
        let arrangement = world.arrangement()
        return (0..<count).compactMap { index in
            let id = WindowID(UInt32(index + 1))
            guard let rect = arrangement.frames[id] else { return nil }
            return PreviewWindowModel(
                index: index,
                frame: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                isFocused: world.focusedWindowID == id
            )
        }
    }
}

/// A sample window: title bar, placeholder content, border and dimming.
private struct PreviewWindow: View {
    let window: LayoutPreview.PreviewWindowModel
    let settings: MossCore.Settings
    let scale: CGFloat

    /// The corner radius of a standard macOS window, which borders follow.
    private static let windowRadius = 16.0

    var body: some View {
        let corner = settings.borders.followsWindowCorners ? Self.windowRadius : settings.borders.cornerRadius
        let radius = max(2, corner * scale)
        let border = settings.borders.width * scale
        let gradient = window.isFocused ? settings.borders.active : settings.borders.inactive
        let dim = settings.dimming.isEnabled && !window.isFocused ? settings.dimming.amount : 0

        VStack(spacing: 0) {
            HStack(spacing: 3 * max(scale * 3, 0.6)) {
                ForEach([SwiftUI.Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: max(3, 11 * scale), height: max(3, 11 * scale))
                }
                Spacer()
            }
            .padding(.horizontal, max(3, 12 * scale))
            .frame(height: max(8, 34 * scale))
            VStack(alignment: .leading, spacing: max(2, 10 * scale)) {
                ForEach(0..<3, id: \.self) { line in
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: max(2, 9 * scale))
                        .frame(maxWidth: line == 2 ? 120 * scale : .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(max(4, 18 * scale))
        }
        .background(SwiftUI.Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: radius, style: .continuous))
        .overlay {
            if dim > 0 {
                RoundedRectangle(cornerRadius: radius).fill(.black.opacity(dim))
            }
        }
        .overlay {
            if border > 0 {
                RoundedRectangle(cornerRadius: radius + border)
                    .strokeBorder(gradient.linear, lineWidth: border)
                    .padding(-border)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 8 * scale, y: 3 * scale)
    }
}
