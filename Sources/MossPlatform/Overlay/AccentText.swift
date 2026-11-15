import AppKit

extension NSColor {
    /// Text on the accent color: dark on a light accent such as yellow, white on a dark one.
    static var textOnAccent: NSColor {
        guard let accent = controlAccentColor.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * accent.redComponent + 0.7152 * accent.greenComponent + 0.0722 * accent.blueComponent
        return luminance > 0.65 ? NSColor(white: 0.1, alpha: 1) : .white
    }
}
