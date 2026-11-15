import MossConfig
import MossCore
import SwiftUI

/// A labelled control for one configuration option, chosen from the option's type.
struct OptionRow: View {
    let path: String
    var title: String?
    /// Replaces the option's own description where the page says more, or less.
    var summary: String?
    @Environment(SettingsStore.self) private var store

    private var option: OptionDescriptor { OptionRegistry.option(path)! }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title ?? OptionTitles.title(for: option))
                    if store.isSet(option) && store.value(of: option) != option.defaultValue {
                        Button {
                            store.reset(option)
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset to the default (\(option.defaultValue))")
                    }
                }
                Text(summary ?? option.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            OptionControl(option: option)
        }
        .padding(.vertical, 4)
        .help(option.path)
    }
}

/// The input control for an option.
struct OptionControl: View {
    let option: OptionDescriptor
    @Environment(SettingsStore.self) private var store

    private var text: String { store.value(of: option) }

    private func set(_ value: String) { store.set(option, to: value) }

    var body: some View {
        switch option.type {
        case .bool:
            Toggle("", isOn: Binding(get: { text == "true" }, set: { set($0 ? "true" : "false") }))
                .toggleStyle(.switch)
                .labelsHidden()
        case .number(let range):
            NumberControl(value: Double(text) ?? 0, range: range ?? 0...100, step: step(for: range), format: .number.precision(.fractionLength(0...2))) { set(Self.format($0)) }
        case .integer(let range):
            let bounds = range.map { Double($0.lowerBound)...Double($0.upperBound) } ?? 0...100
            NumberControl(value: Double(text) ?? 0, range: bounds, step: 1, format: .number.precision(.fractionLength(0))) { set(String(Int($0.rounded()))) }
        case .choice(let choices):
            Picker("", selection: Binding(get: { text }, set: { set($0) })) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .labelsHidden()
            .fixedSize()
        case .insets(let range):
            InsetsEditor(insets: Insets(cssNotation: text) ?? .zero, range: range) { set($0.description) }
        case .color:
            GradientEditor(gradient: ColorNotation.parseGradient(text) ?? Gradient(Color(rgba: 0xFFFF_FFFF))) { set($0.description) }
        case .string, .numbers:
            TextField("", text: Binding(get: { text }, set: { set($0) }))
                .frame(width: 220)
        case .modifiers:
            ModifierPicker(modifiers: Binding(get: { (try? Modifiers(parsing: text)) ?? [] }, set: { if !$0.isEmpty { set($0.description) } }), offersCapsLock: true)
        }
    }

    private func step(for range: ClosedRange<Double>?) -> Double {
        guard let range else { return 1 }
        return range.upperBound - range.lowerBound <= 2 ? 0.01 : 1
    }

    static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

/// A slider with an editable numeric field.
struct NumberControl: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: FloatingPointFormatStyle<Double>
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { value }, set: { onChange(($0 / step).rounded() * step) }), in: range)
                .frame(width: 160)
            TextField("", value: Binding(get: { value }, set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }), format: format)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .textFieldStyle(.roundedBorder)
        }
    }
}

/// Titles for options, where the option's name alone does not read well.
enum OptionTitles {
    static let titles: [String: String] = [
        "keyboard.main-key": "Main key",
        "keyboard.caps-lock": "Caps Lock",
        "layout.style": "Layout",
        "layout.bsp.new-window-side": "New windows go",
        "layout.bsp.split-focused": "Split the focused window",
        "layout.bsp.keep-direction": "Keep split directions",
        "layout.bsp.remember-preselection": "Remember preselection",
        "layout.stack.main-size": "Main area size",
        "layout.stack.new-window-position": "Position of new windows",
        "layout.stack.side": "Main area",
        "layout.stack.center-min-stack": "Windows before centering",
        "layout.stack.center-fallback": "Until centered",
        "layout.stack.keep-main-position": "Keep the main area in place",
        "layout.scrolling.scroll-to": "Bring columns into view",
        "layout.scrolling.hover-min-visible": "Visible to focus on hover",
        "layout.scrolling.fill-lone-column": "One column fills the screen",
        "layout.scrolling.wrap": "Wrap around",
        "borders.active": "Focused window",
        "borders.inactive": "Other windows",
        "borders.corner-radius": "Fallback corner radius",
        "dimming.enabled": "Dim unfocused windows",
        "animation.enabled": "Animate windows",
        "animation.curve": "Motion",
        "focus.move-cursor": "Move the cursor with focus",
        "focus.cross-displays": "Continue onto other displays",
        "floating.snap": "Snap floating windows",
        "fullscreen.new-window": "When a window opens",
        "tabs.auto-join": "Open new windows as tabs",
        "tabs.titles": "Show titles",
        "workspaces.show-name": "Show the name when switching",
        "scratchpads.scale": "Window size",
        "scratchpads.hide-on-workspace-switch": "Hide when switching workspaces",
        "errors.show": "Show configuration problems",
    ]

    static func title(for option: OptionDescriptor) -> String {
        if let title = titles[option.path] { return title }
        let name = option.name.replacing("-", with: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
