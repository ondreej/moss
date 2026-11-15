import MossConfig
import MossCore
import SwiftUI

/// Options shown one per row, separated by dividers.
struct OptionList: View {
    let paths: [String]

    init(_ paths: String...) { self.paths = paths }

    var body: some View {
        ForEach(Array(paths.enumerated()), id: \.element) { index, path in
            if index > 0 { Divider() }
            OptionRow(path: path)
        }
    }
}

struct GeneralPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        Page {
            PageHeader(title: "General", subtitle: "The layout, spacing and floating windows.", symbol: "slider.horizontal.3")
            Card {
                LayoutPreview(settings: store.settings)
            }
            Card(title: "Startup", symbol: "power") {
                StartAtLoginRow()
            }
            Card(title: "Layout", symbol: "rectangle.split.3x1") {
                LayoutKindPicker()
            }
            Card(title: "Spacing", symbol: "arrow.left.and.right.square") {
                OptionList("layout.gaps", "layout.margins", "borders.width")
            }
            Card(title: "Floating Windows", symbol: "macwindow.on.rectangle") {
                OptionRow(path: "floating.snap")
                if store.settings.floating.snaps {
                    Divider()
                    OptionRow(path: "floating.snap-distance")
                }
            }
        }
    }
}

/// One card per layout, each with a tiny diagram.
struct LayoutKindPicker: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let current = store.settings.layout.style
        HStack(alignment: .top, spacing: 12) {
            choice(.bsp, "BSP", "Binary space partitioning: each new window splits the focused one, alternating direction like a spiral.", current)
            choice(.stack, "Stack", "One large main window with the others stacked beside it.", current)
            choice(.scrolling, "Scrolling", "Windows open in columns side by side, and the view scrolls to the focused one.", current)
        }
    }

    private func choice(_ kind: LayoutKind, _ title: String, _ detail: String, _ current: LayoutKind) -> some View {
        let selected = kind == current
        return Button {
            if let option = OptionRegistry.option("layout.style") { store.set(option, to: kind.rawValue) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                LayoutGlyph(kind: kind)
                    .frame(width: 64, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(selected ? Design.accent.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The accent outline already marks the chosen card; a focus ring around it would be a second border.
        .focusEffectDisabled()
    }
}

/// A schematic of a layout.
struct LayoutGlyph: View {
    let kind: LayoutKind

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height, g: CGFloat = 3
            let rects: [CGRect] = switch kind {
            case .bsp: [
                CGRect(x: 0, y: 0, width: w / 2 - g / 2, height: h),
                CGRect(x: w / 2 + g / 2, y: 0, width: w / 2 - g / 2, height: h / 2 - g / 2),
                CGRect(x: w / 2 + g / 2, y: h / 2 + g / 2, width: w / 4 - g, height: h / 2 - g / 2),
                CGRect(x: w * 3 / 4, y: h / 2 + g / 2, width: w / 4, height: h / 2 - g / 2),
            ]
            case .stack: [
                CGRect(x: 0, y: 0, width: w * 0.58, height: h),
                CGRect(x: w * 0.58 + g, y: 0, width: w * 0.42 - g, height: h / 3 - g),
                CGRect(x: w * 0.58 + g, y: h / 3, width: w * 0.42 - g, height: h / 3 - g),
                CGRect(x: w * 0.58 + g, y: 2 * h / 3, width: w * 0.42 - g, height: h / 3),
            ]
            case .scrolling: [
                CGRect(x: w * 0.22, y: 0, width: w * 0.56, height: h),
                CGRect(x: w * 0.22 - g - w * 0.56, y: 0, width: w * 0.56, height: h),
                CGRect(x: w * 0.78 + g, y: 0, width: w * 0.56, height: h / 2 - g / 2),
                CGRect(x: w * 0.78 + g, y: h / 2 + g / 2, width: w * 0.56, height: h / 2 - g / 2),
            ]
            }
            ForEach(Array(rects.enumerated()), id: \.offset) { index, rect in
                RoundedRectangle(cornerRadius: 3)
                    .fill(index == 0 ? AnyShapeStyle(Design.accent) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .clipped()
    }
}

struct AppearancePage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        Page {
            PageHeader(title: "Appearance", subtitle: "Borders, dimming and motion.", symbol: "paintpalette")
            Card {
                LayoutPreview(settings: store.settings)
            }
            Card(title: "Borders", symbol: "square.dashed") {
                OptionList("borders.active", "borders.inactive", "borders.width", "borders.follow-window-corners", "borders.corner-radius")
            }
            Card(title: "Dimming", symbol: "circle.lefthalf.filled") {
                OptionRow(path: "dimming.enabled")
                if store.settings.dimming.isEnabled {
                    Divider()
                    OptionRow(path: "dimming.amount")
                }
            }
            Card(title: "Motion", symbol: "wind") {
                OptionRow(path: "animation.enabled")
                if store.settings.animation.isEnabled {
                    Divider()
                    OptionList("animation.duration", "animation.curve")
                }
            }
            Card(title: "On Screen", symbol: "text.bubble") {
                OptionList("workspaces.show-name", "errors.show")
            }
        }
    }
}

struct LayoutsPage: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        Page {
            PageHeader(title: "Layouts", subtitle: "Fine-tune how windows are arranged.", symbol: "rectangle.split.3x1")
            Card {
                LayoutKindPicker()
                LayoutPreview(settings: store.settings)
                    .padding(.top, 6)
            }
            switch store.settings.layout.style {
            case .bsp:
                Card(title: "BSP", symbol: "square.split.bottomrightquarter") {
                    OptionList("layout.bsp.new-window-side", "layout.bsp.split-focused", "layout.bsp.keep-direction", "layout.bsp.smart-split",
                               "layout.bsp.smart-resize", "layout.bsp.remember-preselection", "layout.bsp.default-ratio")
                }
            case .stack:
                Card(title: "Stack", symbol: "rectangle.leadinghalf.inset.filled") {
                    OptionList("layout.stack.side", "layout.stack.main-size", "layout.stack.new-window", "layout.stack.new-window-position",
                               "layout.stack.center-min-stack", "layout.stack.center-fallback", "layout.stack.keep-main-position")
                }
            case .scrolling:
                Card(title: "Scrolling", symbol: "rectangle.split.3x1") {
                    OptionList("layout.scrolling.column-width", "layout.scrolling.column-width-presets", "layout.scrolling.direction", "layout.scrolling.scroll-to",
                               "layout.scrolling.follow-focus", "layout.scrolling.hover-min-visible", "layout.scrolling.fill-lone-column", "layout.scrolling.wrap")
                }
                Text("Shortcuts for the scrolling layout: column next and column previous move between columns, column-width next steps through the widths above, and move-column left or right moves a column.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Card(title: "Tabs", symbol: "rectangle.stack") {
                Text("A tab group holds several windows in one place in the layout. The tabs action makes one around the focused window, and tab next switches between them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                OptionRow(path: "tabs.auto-join")
                Divider()
                OptionRow(path: "tabs.bar")
                if store.settings.tabs.showsBar {
                    Divider()
                    OptionList("tabs.bar-height", "tabs.titles")
                }
            }
        }
    }
}

struct InputPage: View {
    var body: some View {
        Page {
            PageHeader(title: "Focus & Input", subtitle: "How focus follows the mouse and moves between windows.", symbol: "cursorarrow.motionlines")
            Card(title: "Focus", symbol: "scope") {
                OptionList("focus.follows-mouse", "focus.move-cursor", "focus.cross-displays")
            }
            Card(title: "Workspaces", symbol: "square.stack.3d.up") {
                OptionList("workspaces.back-and-forth")
            }
            Card(title: "Scratchpads", symbol: "square.dashed") {
                OptionList("scratchpads.scale", "scratchpads.dim-behind", "scratchpads.hide-on-workspace-switch")
            }
            Card(title: "Fullscreen", symbol: "arrow.up.left.and.arrow.down.right") {
                OptionList("fullscreen.new-window")
            }
        }
    }
}

/// Registers Moss as a login item.
struct StartAtLoginRow: View {
    @Environment(\.services) private var services
    @State private var isOn = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Start Moss at login")
                Text("Manage windows from the moment you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: { value in
                services.setStartsAtLogin(value)
                isOn = services.startsAtLogin()
            }))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .onAppear { isOn = services.startsAtLogin() }
    }
}
