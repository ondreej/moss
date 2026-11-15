/// A value in a TOML document.
public enum TOMLValue: Hashable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
    case array([TOMLValue])
    /// An inline table, `{ key = value, … }`, with its keys in order.
    case table([TOMLPair])

    /// The value written as TOML.
    public var text: String {
        switch self {
        case .string(let string): Self.quoted(string)
        case .integer(let number): String(number)
        case .float(let number):
            if number == number.rounded(), abs(number) < 1e15 { "\(Int(number)).0" } else { "\(number)" }
        case .boolean(let flag): flag ? "true" : "false"
        case .array(let items): "[" + items.map(\.text).joined(separator: ", ") + "]"
        case .table(let pairs): pairs.isEmpty ? "{}" : "{ " + pairs.map { "\(Self.key($0.key)) = \($0.value.text)" }.joined(separator: ", ") + " }"
        }
    }

    /// A key written bare when it can be, quoted otherwise.
    public static func key(_ key: String) -> String {
        let isBare = !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.bareKey.contains($0) }
        return isBare ? key : quoted(key)
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for character in string.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if character.value < 0x20 || character.value == 0x7F {
                    result += String(format: "\\u%04X", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result + "\""
    }

    /// A short name of the value's type, for messages.
    public var typeName: String {
        switch self {
        case .string: "a string"
        case .integer: "an integer"
        case .float: "a number"
        case .boolean: "true or false"
        case .array: "a list"
        case .table: "a table"
        }
    }
}

/// A key and its value in an inline table.
public struct TOMLPair: Hashable, Sendable {
    public var key: String
    public var value: TOMLValue

    public init(_ key: String, _ value: TOMLValue) {
        self.key = key
        self.value = value
    }
}

import Foundation

extension CharacterSet {
    /// Characters allowed in a bare TOML key.
    static let bareKey = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
}
