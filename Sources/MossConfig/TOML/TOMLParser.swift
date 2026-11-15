/// A table header or a key and its value in a TOML document, with the lines it spans.
public struct TOMLStatement: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// `[a.b]`
        case table([String])
        /// `[[a.b]]`, one element of an array of tables.
        case arrayTable([String])
        /// `a.b = value`; the key is split at its dots.
        case keyValue(key: [String], value: TOMLValue)
    }

    public var kind: Kind
    /// Zero-based lines; a value may span several, such as a list written one item per line.
    public var lines: ClosedRange<Int>
}

public struct TOMLSyntaxError: Error, Hashable, Sendable {
    public var message: String
    /// Zero-based line.
    public var line: Int
}

/// Reads the statements of a TOML document. A statement that cannot be read is reported and
/// skipped, so the rest of the document is still read.
enum TOMLParser {
    static func parse(_ text: String) -> (statements: [TOMLStatement], errors: [TOMLSyntaxError]) {
        var scanner = Scanner(text)
        var statements: [TOMLStatement] = []
        var errors: [TOMLSyntaxError] = []
        while true {
            scanner.skipBlankLinesAndComments()
            guard scanner.current != nil else { break }
            let start = scanner.line
            do {
                let kind = try scanner.statement()
                let end = scanner.line
                try scanner.endOfLine()
                statements.append(TOMLStatement(kind: kind, lines: start...end))
            } catch {
                errors.append(error)
                if scanner.resumesHere {
                    scanner.resumesHere = false
                } else {
                    scanner.skipRestOfLine()
                }
            }
        }
        return (statements, errors)
    }
}

private struct Scanner {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private(set) var line = 0
    /// After an error, reading goes on where the scanner stopped instead of on the next line,
    /// as at a table header that a list left open ran into.
    var resumesHere = false

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    var current: Unicode.Scalar? { index < scalars.count ? scalars[index] : nil }

    private func peek(_ offset: Int) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    private func error(_ message: String) -> TOMLSyntaxError { TOMLSyntaxError(message: message, line: line) }

    private mutating func advance() {
        if current == "\n" { line += 1 }
        index += 1
    }

    private mutating func skipSpaces() {
        while current == " " || current == "\t" { advance() }
    }

    private mutating func skipComment() {
        guard current == "#" else { return }
        while let character = current, character != "\n" { advance() }
    }

    mutating func skipBlankLinesAndComments() {
        while let character = current {
            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                advance()
            } else if character == "#" {
                skipComment()
            } else {
                break
            }
        }
    }

    mutating func skipRestOfLine() {
        while let character = current, character != "\n" { advance() }
        if current == "\n" { advance() }
    }

    /// Spaces, an optional comment and the end of the line.
    mutating func endOfLine() throws(TOMLSyntaxError) {
        skipSpaces()
        skipComment()
        if current == "\r" { advance() }
        guard current == nil || current == "\n" else { throw error("unexpected text after the value") }
        if current == "\n" { advance() }
    }

    private mutating func expect(_ text: String, _ what: String) throws(TOMLSyntaxError) {
        for scalar in text.unicodeScalars {
            guard current == scalar else { throw error("expected \(what)") }
            advance()
        }
    }

    // MARK: Statements

    mutating func statement() throws(TOMLSyntaxError) -> TOMLStatement.Kind {
        if current == "[" {
            let isArray = peek(1) == "["
            advance()
            if isArray { advance() }
            skipSpaces()
            let key = try key()
            skipSpaces()
            try expect(isArray ? "]]" : "]", isArray ? "']]' to close the table header" : "']' to close the table header")
            return isArray ? .arrayTable(key) : .table(key)
        }
        let key = try key()
        skipSpaces()
        try expect("=", "'=' after the key")
        skipSpaces()
        return .keyValue(key: key, value: try value())
    }

    /// A key, split at its dots: `a`, `"quoted key"`, `a.b.c`.
    private mutating func key() throws(TOMLSyntaxError) -> [String] {
        var parts: [String] = []
        repeat {
            skipSpaces()
            parts.append(try keyPart())
            skipSpaces()
            guard current == "." else { break }
            advance()
        } while true
        return parts
    }

    private mutating func keyPart() throws(TOMLSyntaxError) -> String {
        switch current {
        case "\"": return try basicString()
        case "'": return try literalString()
        default:
            var part = ""
            while let character = current, CharacterSet.bareKey.contains(character) {
                part.unicodeScalars.append(character)
                advance()
            }
            guard !part.isEmpty else { throw error("expected a key") }
            return part
        }
    }

    // MARK: Values

    private mutating func value() throws(TOMLSyntaxError) -> TOMLValue {
        switch current {
        case "\"":
            return .string(peek(1) == "\"" && peek(2) == "\"" ? try multilineBasicString() : try basicString())
        case "'":
            return .string(peek(1) == "'" && peek(2) == "'" ? try multilineLiteralString() : try literalString())
        case "[": return try array()
        case "{": return try inlineTable()
        case nil, "\n", "#": throw error("expected a value")
        default: return try scalar()
        }
    }

    private mutating func array() throws(TOMLSyntaxError) -> TOMLValue {
        let start = line
        advance()
        var items: [TOMLValue] = []
        // A missing ']' would otherwise swallow the table that follows.
        func stopAtTableHeader() throws(TOMLSyntaxError) {
            guard startsTableHeader() else { return }
            resumesHere = true
            throw TOMLSyntaxError(message: "the list is not closed with ']'", line: start)
        }
        while true {
            skipBlankLinesAndComments()
            try stopAtTableHeader()
            if current == "]" {
                advance()
                return .array(items)
            }
            items.append(try value())
            skipBlankLinesAndComments()
            try stopAtTableHeader()
            if current == "," {
                advance()
            } else if current == "]" {
                advance()
                return .array(items)
            } else {
                throw error("expected ',' or ']' in the list")
            }
        }
    }

    /// Whether a table header such as `[borders]` starts at the beginning of this line.
    private func startsTableHeader() -> Bool {
        guard current == "[", index == 0 || scalars[index - 1] == "\n" else { return false }
        var probe = self
        guard let kind = try? probe.statement(), (try? probe.endOfLine()) != nil else { return false }
        switch kind {
        case .table, .arrayTable: return true
        case .keyValue: return false
        }
    }

    private mutating func inlineTable() throws(TOMLSyntaxError) -> TOMLValue {
        advance()
        var pairs: [TOMLPair] = []
        skipSpaces()
        if current == "}" {
            advance()
            return .table(pairs)
        }
        while true {
            skipSpaces()
            let key = try key()
            skipSpaces()
            try expect("=", "'=' after the key")
            skipSpaces()
            let value = try value()
            guard key.count == 1 else { throw error("dotted keys are not supported in inline tables") }
            guard !pairs.contains(where: { $0.key == key[0] }) else { throw error("'\(key[0])' is set twice") }
            pairs.append(TOMLPair(key[0], value))
            skipSpaces()
            if current == "," {
                advance()
            } else if current == "}" {
                advance()
                return .table(pairs)
            } else {
                throw error("expected ',' or '}' in the inline table")
            }
        }
    }

    /// `true`, `false`, or a number.
    private mutating func scalar() throws(TOMLSyntaxError) -> TOMLValue {
        var word = ""
        while let character = current, !" \t\r\n,]}#".unicodeScalars.contains(character) {
            word.unicodeScalars.append(character)
            advance()
        }
        switch word {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if word.contains(":") || (word.count >= 10 && word.dropFirst(4).first == "-") {
            throw error("dates and times are not supported")
        }
        let digits = word.replacing("_", with: "")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            guard let number = Int(digits.dropFirst(2), radix: radix) else { break }
            return .integer(number)
        }
        if let number = Int(digits) { return .integer(number) }
        if let number = Double(digits), digits.contains(where: { ".eE".contains($0) }) { return .float(number) }
        throw error(word.isEmpty ? "expected a value" : "'\(word)' is not a value; text needs quotes")
    }

    // MARK: Strings

    private mutating func basicString() throws(TOMLSyntaxError) -> String {
        advance()
        var result = ""
        while let character = current {
            switch character {
            case "\"":
                advance()
                return result
            case "\\":
                result.unicodeScalars.append(try escape())
            case "\n":
                throw error("the string is not closed on its line")
            default:
                result.unicodeScalars.append(character)
                advance()
            }
        }
        throw error("the string is not closed")
    }

    private mutating func literalString() throws(TOMLSyntaxError) -> String {
        advance()
        var result = ""
        while let character = current {
            if character == "'" {
                advance()
                return result
            }
            if character == "\n" { throw error("the string is not closed on its line") }
            result.unicodeScalars.append(character)
            advance()
        }
        throw error("the string is not closed")
    }

    private mutating func multilineBasicString() throws(TOMLSyntaxError) -> String {
        advance(); advance(); advance()
        skipNewlineAfterOpeningQuotes()
        var result = ""
        while let character = current {
            if character == "\"", peek(1) == "\"", peek(2) == "\"" {
                advance(); advance(); advance()
                return result
            }
            if character == "\\" {
                if peek(1) == "\n" || peek(1) == "\r" || peek(1) == " " || peek(1) == "\t" {
                    // A backslash at the end of a line joins it to the next, without the whitespace.
                    advance()
                    while let next = current, " \t\r\n".unicodeScalars.contains(next) { advance() }
                } else {
                    result.unicodeScalars.append(try escape())
                }
                continue
            }
            result.unicodeScalars.append(character)
            advance()
        }
        throw error("the string is not closed")
    }

    private mutating func multilineLiteralString() throws(TOMLSyntaxError) -> String {
        advance(); advance(); advance()
        skipNewlineAfterOpeningQuotes()
        var result = ""
        while let character = current {
            if character == "'", peek(1) == "'", peek(2) == "'" {
                advance(); advance(); advance()
                return result
            }
            result.unicodeScalars.append(character)
            advance()
        }
        throw error("the string is not closed")
    }

    private mutating func skipNewlineAfterOpeningQuotes() {
        if current == "\r", peek(1) == "\n" { advance() }
        if current == "\n" { advance() }
    }

    private mutating func escape() throws(TOMLSyntaxError) -> Unicode.Scalar {
        advance()
        guard let character = current else { throw error("the string is not closed") }
        advance()
        switch character {
        case "b": return "\u{8}"
        case "t": return "\t"
        case "n": return "\n"
        case "f": return "\u{C}"
        case "r": return "\r"
        case "\"": return "\""
        case "\\": return "\\"
        case "e": return "\u{1B}"
        case "u", "U":
            var hex = ""
            for _ in 0..<(character == "u" ? 4 : 8) {
                guard let digit = current else { throw error("incomplete \\\(character) escape") }
                hex.unicodeScalars.append(digit)
                advance()
            }
            guard let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else { throw error("invalid \\\(character) escape") }
            return scalar
        default:
            throw error("unknown escape '\\\(character)'")
        }
    }
}

import Foundation
