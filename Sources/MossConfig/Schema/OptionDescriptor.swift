public import MossCore

/// The type of an option's value, which decides how it is read, written and edited.
public enum OptionType: Hashable, Sendable {
    case bool
    case integer(ClosedRange<Int>?)
    case number(ClosedRange<Double>?)
    case choice([Choice])
    /// Space around something: one number for every side, or a list of up to four in CSS order,
    /// each within the range.
    case insets(ClosedRange<Double>)
    /// A color, or several and an angle for a gradient.
    case color
    case string
    /// A list of numbers.
    case numbers(ClosedRange<Double>?)
    /// Modifier keys, such as `caps` or `ctrl-alt`.
    case modifiers

    public struct Choice: Hashable, Sendable {
        /// The value as written in the configuration file.
        public var value: String
        public var label: String

        public init(_ value: String, _ label: String) {
            self.value = value
            self.label = label
        }
    }
}

/// Describes one configuration option: where it lives, what it accepts and how it maps to
/// `Settings`.
///
/// Descriptors are shared by the configuration evaluator, the settings window and
/// `moss get` and `set`. Defaults come from `Settings()`. Values are handled as plain
/// text (`5`, `bsp`, `#ff8800`), the form the settings window edits, and converted to and
/// from TOML values for the file.
public struct OptionDescriptor: Sendable, Identifiable {
    public var id: String { path }

    /// The full option path, e.g. `layout.gaps`.
    public let path: String
    public let type: OptionType
    public let summary: String

    private let read: @Sendable (Settings) -> String
    private let write: @Sendable (inout Settings, String) throws(ConfigError) -> Void

    init(
        path: String,
        type: OptionType,
        summary: String,
        read: @escaping @Sendable (Settings) -> String,
        write: @escaping @Sendable (inout Settings, String) throws(ConfigError) -> Void
    ) {
        self.path = path
        self.type = type
        self.summary = summary
        self.read = read
        self.write = write
    }

    /// The path split at its dots, as the keys of the configuration file.
    public var keyPath: [String] { path.split(separator: ".").map(String.init) }
    /// The table the option is in, e.g. `layout.bsp`.
    public var category: String { keyPath.dropLast().joined(separator: ".") }
    public var name: String { keyPath.last ?? path }

    /// The option's current value as text.
    public func value(in settings: Settings) -> String { read(settings) }

    public var defaultValue: String { read(Settings()) }

    /// Parses `text` and stores it into `settings`.
    public func apply(_ text: String, to settings: inout Settings) throws(ConfigError) {
        try write(&settings, text.trimmed)
    }

    /// Whether `text` is a valid value for this option.
    public func validate(_ text: String) -> ConfigError? {
        var scratch = Settings()
        do {
            try apply(text, to: &scratch)
            return nil
        } catch {
            return error
        }
    }

    // MARK: TOML

    /// The value `text` is written as in the configuration file.
    public func tomlValue(fromText text: String) -> TOMLValue {
        let text = text.trimmed
        switch type {
        case .bool: return .boolean(text.lowercased() == "true")
        case .integer: return Int(text).map(TOMLValue.integer) ?? .string(text)
        case .number: return ValueParser.tomlNumber(text) ?? .string(text)
        case .insets:
            let numbers = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { ValueParser.tomlNumber(String($0)) }
            return numbers.count == 1 ? numbers[0] : .array(numbers)
        case .numbers:
            return .array(text.split(separator: ",").compactMap { ValueParser.tomlNumber(String($0).trimmed) })
        case .choice, .color, .string, .modifiers: return .string(text)
        }
    }

    /// The text of a value read from the configuration file.
    public func text(from value: TOMLValue) throws(ConfigError) -> String {
        func number(_ value: TOMLValue) -> String? {
            switch value {
            case .integer(let number): String(number)
            case .float(let number): ValueParser.format(number)
            default: nil
            }
        }
        switch (type, value) {
        case (.bool, .boolean(let flag)): return flag ? "true" : "false"
        case (.integer, .integer(let number)): return String(number)
        case (.number, .integer), (.number, .float): return number(value)!
        case (.insets, .integer), (.insets, .float): return number(value)!
        case (.insets, .array(let items)):
            let numbers = items.compactMap(number)
            guard numbers.count == items.count, (1...4).contains(numbers.count) else { break }
            return numbers.joined(separator: " ")
        case (.numbers, .array(let items)):
            let numbers = items.compactMap(number)
            guard numbers.count == items.count, !numbers.isEmpty else { break }
            return numbers.joined(separator: ", ")
        case (.choice, .string(let text)), (.color, .string(let text)), (.string, .string(let text)), (.modifiers, .string(let text)):
            return text
        default:
            break
        }
        throw .invalidValue(value.text, expected: expectation)
    }

    /// What the option accepts, for messages.
    var expectation: String {
        switch type {
        case .bool: "true or false"
        case .integer: "a whole number"
        case .number: "a number"
        case .choice(let choices): "one of " + choices.map { "\"\($0.value)\"" }.joined(separator: ", ")
        case .insets: "a number, or a list of up to four numbers"
        case .color: "a color in quotes, such as \"accent\" or \"#ff8800\""
        case .string: "text in quotes"
        case .numbers: "a list of numbers, such as [0.5, 1]"
        case .modifiers: "modifier keys in quotes, such as \"caps\" or \"ctrl-alt\""
        }
    }
}

// MARK: - Builders

extension OptionDescriptor {
    typealias Path<Value> = any WritableKeyPath<Settings, Value> & Sendable

    static func bool(_ path: String, _ keyPath: Path<Bool>, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .bool, summary: summary) { settings in
            settings[keyPath: keyPath] ? "true" : "false"
        } write: { settings, text throws(ConfigError) in
            settings[keyPath: keyPath] = try ValueParser.bool(text)
        }
    }

    static func number(_ path: String, _ keyPath: Path<Double>, _ range: ClosedRange<Double>? = nil, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .number(range), summary: summary) { settings in
            ValueParser.format(settings[keyPath: keyPath])
        } write: { settings, text throws(ConfigError) in
            settings[keyPath: keyPath] = try ValueParser.number(text, in: range)
        }
    }

    static func integer(_ path: String, _ keyPath: Path<Int>, _ range: ClosedRange<Int>? = nil, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .integer(range), summary: summary) { settings in
            String(settings[keyPath: keyPath])
        } write: { settings, text throws(ConfigError) in
            settings[keyPath: keyPath] = try ValueParser.integer(text, in: range)
        }
    }

    static func insets(_ path: String, _ keyPath: Path<Insets>, _ range: ClosedRange<Double>, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .insets(range), summary: summary) { settings in
            settings[keyPath: keyPath].description
        } write: { settings, text throws(ConfigError) in
            guard let insets = Insets(cssNotation: text), [insets.top, insets.right, insets.bottom, insets.left].allSatisfy(range.contains) else {
                throw .invalidValue(text, expected: "one to four numbers from \(ValueParser.format(range.lowerBound)) to \(ValueParser.format(range.upperBound))")
            }
            settings[keyPath: keyPath] = insets
        }
    }

    static func color(_ path: String, _ keyPath: Path<Gradient>, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .color, summary: summary) { settings in
            settings[keyPath: keyPath].description
        } write: { settings, text throws(ConfigError) in
            guard let gradient = ColorNotation.parseGradient(text) else {
                throw .invalidValue(text, expected: "a color such as \"accent\", \"clear\" or \"#ff8800\", or several followed by an angle like \"45deg\"")
            }
            settings[keyPath: keyPath] = gradient
        }
    }

    /// A comma-separated list of numbers, such as `0.333, 0.5, 1`.
    static func numbers(_ path: String, _ keyPath: Path<[Double]>, _ range: ClosedRange<Double>? = nil, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .numbers(range), summary: summary) { settings in
            settings[keyPath: keyPath].map(ValueParser.format).joined(separator: ", ")
        } write: { settings, text throws(ConfigError) in
            let items = text.split(separator: ",").map { String($0).trimmed }
            guard !items.isEmpty, !items.contains(where: \.isEmpty) else { throw .invalidValue(text, expected: "numbers separated by commas") }
            var values: [Double] = []
            for item in items { values.append(try ValueParser.number(item, in: range)) }
            settings[keyPath: keyPath] = values
        }
    }

    static func modifiers(_ path: String, _ keyPath: Path<Modifiers>, _ summary: String) -> OptionDescriptor {
        OptionDescriptor(path: path, type: .modifiers, summary: summary) { settings in
            settings[keyPath: keyPath].description
        } write: { settings, text throws(ConfigError) in
            let modifiers: Modifiers
            do throws(KeyBindingError) {
                modifiers = try Modifiers(parsing: text)
            } catch {
                throw .invalidValue(text, expected: "modifier keys such as caps, alt, cmd, ctrl, hyper or ctrl-alt")
            }
            guard !modifiers.isEmpty else { throw .invalidValue(text, expected: "at least one modifier key") }
            settings[keyPath: keyPath] = modifiers
        }
    }

    static func choice<Value: RawRepresentable & CaseIterable & Sendable>(
        _ path: String,
        _ keyPath: Path<Value>,
        _ labels: [Value: String],
        _ summary: String
    ) -> OptionDescriptor where Value.RawValue == String, Value: Hashable {
        let choices = Value.allCases.map { OptionType.Choice($0.rawValue, labels[$0] ?? $0.rawValue) }
        return OptionDescriptor(path: path, type: .choice(choices), summary: summary) { settings in
            settings[keyPath: keyPath].rawValue
        } write: { settings, text throws(ConfigError) in
            guard let value = Value(rawValue: text.lowercased()) else {
                throw .invalidValue(text, expected: "one of " + choices.map(\.value).joined(separator: ", "))
            }
            settings[keyPath: keyPath] = value
        }
    }

    /// The curve of window animations, by name.
    static func curve(_ path: String, _ summary: String) -> OptionDescriptor {
        let labels: [AnimationCurve: String] = [.smooth: "Smooth", .easeInOut: "Ease in and out", .linear: "Linear"]
        let choices = AnimationCurve.allCases.map { OptionType.Choice($0.rawValue, labels[$0] ?? $0.rawValue) }
        return OptionDescriptor(path: path, type: .choice(choices), summary: summary) { settings in
            (AnimationCurve.allCases.first { $0.bezier == settings.animation.windows.curve } ?? .smooth).rawValue
        } write: { settings, text throws(ConfigError) in
            guard let curve = AnimationCurve(rawValue: text.lowercased()) else {
                throw .invalidValue(text, expected: "one of " + choices.map(\.value).joined(separator: ", "))
            }
            settings.animation.windows.curve = curve.bezier
        }
    }
}

/// Parses primitive values.
enum ValueParser {
    static func bool(_ text: String) throws(ConfigError) -> Bool {
        switch text.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: throw .invalidValue(text, expected: "true or false")
        }
    }

    static func number(_ text: String, in range: ClosedRange<Double>?) throws(ConfigError) -> Double {
        guard let value = Double(text), value.isFinite else { throw .invalidValue(text, expected: "a number") }
        if let range, !range.contains(value) { throw .outOfRange(text, range: "\(format(range.lowerBound))–\(format(range.upperBound))") }
        return value
    }

    static func integer(_ text: String, in range: ClosedRange<Int>?) throws(ConfigError) -> Int {
        guard let value = Int(text) else { throw .invalidValue(text, expected: "a whole number") }
        if let range, !range.contains(value) { throw .outOfRange(text, range: "\(range.lowerBound)–\(range.upperBound)") }
        return value
    }

    /// A number written compactly: `5`, not `5.0`.
    static func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    /// A number as a TOML value: an integer when it is whole.
    static func tomlNumber(_ text: String) -> TOMLValue? {
        guard let value = Double(text) else { return nil }
        return value == value.rounded() && abs(value) < 1e15 ? .integer(Int(value)) : .float(value)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

import Foundation
