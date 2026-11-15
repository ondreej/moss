/// An sRGB color with straight (non-premultiplied) alpha. Components are in `0...1`.
public struct Color: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    /// Follows the system accent color, which the platform resolves when drawing; `red`, `green`
    /// and `blue` then hold the default blue.
    public var isAccent = false

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The system accent color, written `accent` or, with an opacity, `accent(0.8)`.
    public static func accent(alpha: Double = 1) -> Color {
        var color = Color(rgba: 0x0A84_FFFF)
        color.alpha = alpha
        color.isAccent = true
        return color
    }

    public static let clear = Color(rgba: 0)

    private enum CodingKeys: String, CodingKey {
        case red, green, blue, alpha, isAccent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        red = try container.decode(Double.self, forKey: .red)
        green = try container.decode(Double.self, forKey: .green)
        blue = try container.decode(Double.self, forKey: .blue)
        alpha = try container.decode(Double.self, forKey: .alpha)
        isAccent = try container.decodeIfPresent(Bool.self, forKey: .isAccent) ?? false
    }

    /// Creates a color from a packed `0xRRGGBBAA` value.
    public init(rgba: UInt32) {
        self.init(
            red: Double((rgba >> 24) & 0xFF) / 255,
            green: Double((rgba >> 16) & 0xFF) / 255,
            blue: Double((rgba >> 8) & 0xFF) / 255,
            alpha: Double(rgba & 0xFF) / 255
        )
    }

    public var rgba: UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
    }

    /// The color as written in the configuration: `#ff8800`, `#ff880080`, `accent` or `clear`.
    public var description: String {
        if isAccent { return alpha >= 1 ? "accent" : "accent(\(alpha.compact))" }
        if self == .clear { return "clear" }
        let hex = String(rgba, radix: 16)
        let padded = String(repeating: "0", count: 8 - hex.count) + hex
        return "#" + (padded.hasSuffix("ff") ? String(padded.dropLast(2)) : padded)
    }
}

/// A linear gradient used for borders. A single color is a gradient with one stop.
public struct Gradient: Hashable, Sendable, Codable, CustomStringConvertible {
    public var colors: [Color]
    /// Angle in degrees: `0deg` runs left to right, increasing clockwise.
    public var angle: Double

    public init(colors: [Color], angle: Double = 0) {
        precondition(!colors.isEmpty, "a gradient needs at least one color")
        self.colors = colors
        self.angle = angle
    }

    public init(_ color: Color) { self.init(colors: [color]) }

    public var description: String {
        let stops = colors.map(\.description).joined(separator: " ")
        return colors.count > 1 || angle != 0 ? "\(stops) \(angle.compact)deg" : stops
    }
}

/// Reads colors as written in the configuration: `#ff8800`, `#ff880080` (with opacity),
/// `#f80`, `accent`, `accent(0.8)` and `clear`. Gradients are colors separated by spaces,
/// optionally followed by an angle such as `45deg`.
public enum ColorNotation {
    public static func parse(_ text: String) -> Color? {
        let value = text.trimmingWhitespace.lowercased()
        switch value {
        case "accent": return .accent()
        case "clear": return .clear
        default: break
        }
        if value.hasPrefix("accent("), value.hasSuffix(")"), let alpha = Double(value.dropFirst(7).dropLast()), (0...1).contains(alpha) {
            return .accent(alpha: alpha)
        }
        guard value.hasPrefix("#") else { return nil }
        var digits = String(value.dropFirst())
        if digits.count == 3 || digits.count == 4 { digits = String(digits.flatMap { [$0, $0] }) }
        if digits.count == 6 { digits += "ff" }
        guard digits.count == 8, let packed = UInt32(digits, radix: 16) else { return nil }
        return Color(rgba: packed)
    }

    public static func parseGradient(_ text: String) -> Gradient? {
        var colors: [Color] = []
        var angle = 0.0
        for token in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            if token.lowercased().hasSuffix("deg"), let degrees = Double(token.dropLast(3)) {
                angle = degrees
            } else if let color = parse(token) {
                colors.append(color)
            } else {
                return nil
            }
        }
        return colors.isEmpty ? nil : Gradient(colors: colors, angle: angle)
    }
}
