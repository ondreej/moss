import AppKit
import MossCore
import SwiftUI

extension MossCore.Color {
    var swiftUI: SwiftUI.Color {
        isAccent ? SwiftUI.Color.accentColor.opacity(alpha) : SwiftUI.Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(_ color: SwiftUI.Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: converted.redComponent, green: converted.greenComponent, blue: converted.blueComponent, alpha: converted.alphaComponent)
    }
}

extension MossCore.Gradient {
    /// A SwiftUI gradient for the angle of a border gradient (0° left to right, clockwise).
    var linear: LinearGradient {
        let radians = angle * .pi / 180
        let (dx, dy) = (cos(radians) / 2, sin(radians) / 2)
        let stops = colors.count == 1 ? [colors[0], colors[0]] : colors
        return LinearGradient(
            colors: stops.map(\.swiftUI),
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
}

/// Edits a border gradient: up to several colour stops and an angle.
struct GradientEditor: View {
    let gradient: MossCore.Gradient
    let onChange: (MossCore.Gradient) -> Void
    @State private var isEditing = false

    var body: some View {
        Button {
            isEditing.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(gradient.linear)
                .frame(width: 150, height: 22)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
        }
        .buttonStyle(.plain)
        .focusRing(.rect(cornerRadius: 6))
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(gradient.linear)
                    .frame(height: 36)
                ForEach(Array(gradient.colors.enumerated()), id: \.offset) { index, color in
                    HStack {
                        if color.isAccent {
                            Label("Accent", systemImage: "circle.fill")
                                .foregroundStyle(SwiftUI.Color.accentColor)
                            Slider(value: Binding(get: { color.alpha }, set: { value in update { $0.colors[index].alpha = value } }), in: 0.1...1)
                                .help("Opacity")
                        } else {
                            ColorPicker("Color \(index + 1)", selection: Binding(
                                get: { color.swiftUI },
                                set: { newColor in update { $0.colors[index] = MossCore.Color(newColor) } }
                            ), supportsOpacity: true)
                            Spacer()
                        }
                        Toggle("Accent", isOn: Binding(
                            get: { color.isAccent },
                            set: { useAccent in update { $0.colors[index] = useAccent ? .accent() : MossCore.Color(rgba: 0xFFFF_FFFF) } }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Follow the accent color chosen in System Settings")
                        Button(role: .destructive) {
                            update { $0.colors.remove(at: index) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(gradient.colors.count == 1)
                    }
                }
                Button("Add Color", systemImage: "plus") {
                    update { $0.colors.append($0.colors.last ?? MossCore.Color(rgba: 0xFFFF_FFFF)) }
                }
                .disabled(gradient.colors.count >= 6)
                if gradient.colors.count > 1 {
                    HStack {
                        Text("Angle")
                        Slider(value: Binding(get: { gradient.angle }, set: { value in update { $0.angle = value.rounded() } }), in: 0...360)
                        Text("\(Int(gradient.angle))°").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    private func update(_ body: (inout MossCore.Gradient) -> Void) {
        var copy = gradient
        body(&copy)
        onChange(copy)
    }
}

/// Edits CSS-style edge values, either linked (one value) or per side.
struct InsetsEditor: View {
    let insets: Insets
    let range: ClosedRange<Double>
    let onChange: (Insets) -> Void
    @State private var isSplit = false

    private var isUniform: Bool { insets.top == insets.right && insets.right == insets.bottom && insets.bottom == insets.left }

    var body: some View {
        HStack(spacing: 8) {
            if isSplit || !isUniform {
                side("T", \.top)
                side("R", \.right)
                side("B", \.bottom)
                side("L", \.left)
            } else {
                NumberControl(value: insets.top, range: range.lowerBound...min(range.upperBound, 100), step: 1, format: .number.precision(.fractionLength(0))) {
                    onChange(Insets(all: $0))
                }
            }
            Button {
                if isSplit || !isUniform {
                    isSplit = false
                    onChange(Insets(all: insets.top))
                } else {
                    isSplit = true
                }
            } label: {
                Image(systemName: isSplit || !isUniform ? "link.badge.plus" : "square.split.2x2")
            }
            .buttonStyle(.borderless)
            .help(isSplit || !isUniform ? "Use one value for all sides" : "Set each side separately")
        }
    }

    private func side(_ label: String, _ keyPath: WritableKeyPath<Insets, Double>) -> some View {
        VStack(spacing: 2) {
            TextField(label, value: Binding(get: { insets[keyPath: keyPath] }, set: { value in
                var copy = insets
                copy[keyPath: keyPath] = min(max(range.lowerBound, value), range.upperBound)
                onChange(copy)
            }), format: .number.precision(.fractionLength(0)))
            .multilineTextAlignment(.center)
            .textFieldStyle(.roundedBorder)
            .frame(width: 44)
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
