import SwiftUI

/// Shared visual language of the settings window: native materials and the system accent
/// color, like the rest of macOS.
enum Design {
    static let accent = Color.accentColor
    /// Text and symbols on the accent color: dark on a light accent such as yellow, white on a
    /// dark one.
    static var onAccent: Color { Color(nsColor: .textOnAccent) }
    static let cornerRadius: CGFloat = 14
}

extension NSColor {
    static var textOnAccent: NSColor {
        guard let accent = controlAccentColor.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * accent.redComponent + 0.7152 * accent.greenComponent + 0.0722 * accent.blueComponent
        return luminance > 0.65 ? NSColor(white: 0.1, alpha: 1) : .white
    }
}

extension View {
    /// Draws the keyboard focus ring around `shape`, not the square bounds of a plain button.
    func focusRing(_ shape: some Shape) -> some View {
        contentShape(.focusEffect, shape)
    }
}

/// A large page title with a symbol tile.
struct PageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Design.onAccent)
                .frame(width: 44, height: 44)
                .background(Design.accent.gradient, in: .rect(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 4)
    }
}

/// A rounded container for grouped content.
struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let symbol { Image(systemName: symbol).foregroundStyle(Design.accent) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary.opacity(0.6), in: .rect(cornerRadius: Design.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Design.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
    }
}

/// A scrollable page layout with consistent margins.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A small coloured capsule label.
struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: .capsule)
    }
}

/// A status dot with a label.
struct StatusLabel: View {
    let text: String
    let isOK: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOK ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(text).font(.callout)
        }
    }
}
