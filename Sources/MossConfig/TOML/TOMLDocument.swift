/// A TOML file kept line by line, so it can be edited by the settings window or
/// `moss set` without disturbing the comments, order or formatting written by hand.
public struct TOMLDocument: Hashable, Sendable {
    public private(set) var lines: [String]
    private var endsWithNewline: Bool
    public private(set) var sections: [Section] = []
    public private(set) var syntaxErrors: [TOMLSyntaxError] = []

    /// A table header and the keys under it. Keys before the first header belong to the root
    /// section, whose path is empty.
    public struct Section: Hashable, Sendable {
        public var path: [String]
        /// Whether the section is an element of an array of tables, `[[path]]`.
        public var isArrayElement: Bool
        /// The element's position in its array, counting from zero.
        public var arrayIndex: Int?
        public var headerLine: Int?
        public var entries: [Entry]
        /// The last line of the header or of an entry.
        public var lastLine: Int?
    }

    /// A key and its value, as written.
    public struct Entry: Hashable, Sendable {
        /// The key split at its dots, relative to its section.
        public var key: [String]
        public var value: TOMLValue
        public var lines: ClosedRange<Int>
    }

    public init(text: String) {
        var raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        endsWithNewline = text.hasSuffix("\n")
        if endsWithNewline { raw.removeLast() }
        lines = raw.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        reparse()
    }

    public var text: String {
        lines.joined(separator: "\n") + (endsWithNewline || lines.isEmpty ? "\n" : "")
    }

    private mutating func reparse() {
        let (statements, errors) = TOMLParser.parse(lines.joined(separator: "\n"))
        syntaxErrors = errors
        var sections = [Section(path: [], isArrayElement: false, headerLine: nil, entries: [], lastLine: nil)]
        var arrayCounts: [[String]: Int] = [:]
        for statement in statements {
            switch statement.kind {
            case .table(let path):
                sections.append(Section(path: path, isArrayElement: false, headerLine: statement.lines.lowerBound, entries: [], lastLine: statement.lines.upperBound))
            case .arrayTable(let path):
                let index = arrayCounts[path, default: 0]
                arrayCounts[path] = index + 1
                sections.append(Section(path: path, isArrayElement: true, arrayIndex: index, headerLine: statement.lines.lowerBound, entries: [], lastLine: statement.lines.upperBound))
            case .keyValue(let key, let value):
                sections[sections.count - 1].entries.append(Entry(key: key, value: value, lines: statement.lines))
                sections[sections.count - 1].lastLine = statement.lines.upperBound
            }
        }
        self.sections = sections
    }

    // MARK: - Reading

    /// The value at `path`, outside arrays of tables.
    public func value(at path: [String]) -> TOMLValue? {
        locate(path).map { sections[$0.section].entries[$0.entry].value }
    }

    /// The elements of the array of tables at `path`, in order.
    public func arrayTables(_ path: [String]) -> [Section] {
        sections.filter { $0.isArrayElement && $0.path == path }
    }

    /// The table at `path`, if it has a header of its own.
    public func table(_ path: [String]) -> Section? {
        sections.first { !$0.isArrayElement && $0.path == path && $0.headerLine != nil }
    }

    private func locate(_ path: [String]) -> (section: Int, entry: Int)? {
        for (sectionIndex, section) in sections.enumerated().reversed() where !section.isArrayElement && path.starts(with: section.path) {
            let key = Array(path.dropFirst(section.path.count))
            if let entryIndex = section.entries.lastIndex(where: { $0.key == key }) { return (sectionIndex, entryIndex) }
        }
        return nil
    }

    // MARK: - Editing values

    /// Sets the value at `path`, editing it in place or adding it to the table it belongs in.
    public mutating func setValue(_ value: TOMLValue, at path: [String]) {
        precondition(!path.isEmpty)
        if let (sectionIndex, entryIndex) = locate(path) {
            let section = sections[sectionIndex], entry = section.entries[entryIndex]
            let first = lines[entry.lines.lowerBound]
            let indent = String(first.prefix { $0 == " " || $0 == "\t" })
            let comment = entry.lines.count == 1 ? Self.trailingComment(of: first) : nil
            let line = indent + Self.keyText(entry.key) + " = " + value.text + (comment.map { " " + $0 } ?? "")
            replace(entry.lines, with: [line])
            return
        }
        let tablePath = Array(path.dropLast())
        let line = Self.keyText([path[path.count - 1]]) + " = " + value.text
        if tablePath.isEmpty {
            insertRootLines([line])
        } else if let section = sections.last(where: { !$0.isArrayElement && $0.path == tablePath && $0.headerLine != nil }), let last = section.lastLine {
            insert([line], at: last + 1)
        } else {
            insertTable(tablePath, lines: [line])
        }
    }

    /// Removes the value at `path`, returning the option to its default.
    public mutating func removeValue(at path: [String]) {
        while let (sectionIndex, entryIndex) = locate(path) {
            remove(sections[sectionIndex].entries[entryIndex].lines)
        }
    }

    // MARK: - Editing tables

    /// Appends an element to the array of tables at `path`.
    public mutating func appendArrayTable(_ path: [String], entries: [(key: [String], value: TOMLValue)]) {
        appendBlock(["[[\(Self.keyText(path))]]"] + Self.entryLines(entries))
    }

    /// Replaces the keys of an element of the array of tables at `path`.
    public mutating func replaceArrayTable(_ path: [String], at index: Int, entries: [(key: [String], value: TOMLValue)]) {
        guard let section = arrayTables(path).first(where: { $0.arrayIndex == index }), let header = section.headerLine, let last = section.lastLine else { return }
        replace(header...last, with: [lines[header]] + Self.entryLines(entries))
    }

    /// Removes an element of the array of tables at `path`.
    public mutating func removeArrayTable(_ path: [String], at index: Int) {
        guard let section = arrayTables(path).first(where: { $0.arrayIndex == index }), let header = section.headerLine, let last = section.lastLine else { return }
        removeBlock(header...last)
    }

    /// Sets the keys of the table at `path`, replacing those it had, or adds the table.
    public mutating func setTable(_ path: [String], entries: [(key: [String], value: TOMLValue)]) {
        if let section = table(path), let header = section.headerLine, let last = section.lastLine {
            replace(header...last, with: [lines[header]] + Self.entryLines(entries))
        } else {
            insertTable(path, lines: Self.entryLines(entries))
        }
    }

    /// Removes the table at `path` with its keys.
    public mutating func removeTable(_ path: [String]) {
        guard let section = table(path), let header = section.headerLine, let last = section.lastLine else { return }
        removeBlock(header...last)
    }

    // MARK: - Lines

    private mutating func replace(_ range: ClosedRange<Int>, with newLines: [String]) {
        lines.replaceSubrange(range, with: newLines)
        reparse()
    }

    private mutating func remove(_ range: ClosedRange<Int>) {
        lines.removeSubrange(range)
        reparse()
    }

    private mutating func insert(_ newLines: [String], at index: Int) {
        lines.insert(contentsOf: newLines, at: min(max(0, index), lines.count))
        reparse()
    }

    /// Removes a table with the blank line that separated it from the next one.
    private mutating func removeBlock(_ range: ClosedRange<Int>) {
        var range = range
        if range.upperBound + 1 < lines.count, lines[range.upperBound + 1].allSatisfy(\.isWhitespace) {
            range = range.lowerBound...(range.upperBound + 1)
        } else if range.lowerBound > 0, lines[range.lowerBound - 1].allSatisfy(\.isWhitespace) {
            range = (range.lowerBound - 1)...range.upperBound
        }
        remove(range)
    }

    /// Adds lines at the end of the file, after a blank line.
    private mutating func appendBlock(_ block: [String]) {
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        endsWithNewline = true
        insert((lines.isEmpty ? [] : [""]) + block, at: lines.count)
    }

    /// Adds a table: after its parent table when the file has one, at the end otherwise.
    private mutating func insertTable(_ path: [String], lines tableLines: [String]) {
        let block = ["[\(Self.keyText(path))]"] + tableLines
        let parent = sections.last { !$0.isArrayElement && !$0.path.isEmpty && path.starts(with: $0.path) && $0.headerLine != nil }
        if let parent, let last = parent.lastLine {
            // After the parent and any of its sub-tables that follow it.
            let following = sections.filter { $0.headerLine.map { $0 > last } ?? false }
            let end = following.prefix { $0.path.starts(with: parent.path) && $0.path != parent.path }.last?.lastLine ?? last
            insert([""] + block, at: end + 1)
        } else {
            appendBlock(block)
        }
    }

    /// Adds keys before the first table header, where keys outside any table belong.
    private mutating func insertRootLines(_ newLines: [String]) {
        if let last = sections[0].lastLine {
            insert(newLines, at: last + 1)
        } else if let firstHeader = sections.dropFirst().compactMap(\.headerLine).first {
            insert(newLines + [""], at: firstHeader)
        } else {
            appendBlock(newLines)
        }
    }

    // MARK: - Writing

    static func keyText(_ key: [String]) -> String {
        key.map(TOMLValue.key).joined(separator: ".")
    }

    static func entryLines(_ entries: [(key: [String], value: TOMLValue)]) -> [String] {
        entries.map { keyText($0.key) + " = " + $0.value.text }
    }

    /// The `# comment` ending a line, outside any string.
    static func trailingComment(of line: String) -> String? {
        var quote: Character?
        var escaped = false
        for (offset, character) in line.enumerated() {
            if escaped {
                escaped = false
            } else if character == "\\" && quote == "\"" {
                escaped = true
            } else if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line.dropFirst(offset))
            }
        }
        return nil
    }
}

// MARK: - Tree

/// A TOML table read into keys and values, for evaluation.
public struct TOMLTable: Hashable, Sendable {
    public var entries: [(key: String, node: TOMLNode)] = []
    /// The line of the table's header, if it has one.
    public var line: Int?

    public init(line: Int? = nil) { self.line = line }

    public subscript(key: String) -> TOMLNode? {
        entries.first { $0.key == key }?.node
    }

    public static func == (lhs: TOMLTable, rhs: TOMLTable) -> Bool {
        lhs.line == rhs.line && lhs.entries.map(\.key) == rhs.entries.map(\.key) && lhs.entries.map(\.node) == rhs.entries.map(\.node)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(line)
        for entry in entries { hasher.combine(entry.key); hasher.combine(entry.node) }
    }
}

public indirect enum TOMLNode: Hashable, Sendable {
    case value(TOMLValue, line: Int)
    case table(TOMLTable)
    case arrayOfTables([TOMLTable])
}

extension TOMLDocument {
    /// The document read into nested tables, with the keys set twice or in conflict.
    public func tree() -> (root: TOMLTable, errors: [TOMLSyntaxError]) {
        var root = TOMLTable(line: nil)
        var errors: [TOMLSyntaxError] = []
        for section in sections {
            var current: [String] = []
            if !section.path.isEmpty, let line = section.headerLine {
                if let problem = Self.open(section.path, isArray: section.isArrayElement, line: line, in: &root) {
                    errors.append(TOMLSyntaxError(message: problem, line: line))
                    continue
                }
                current = section.path
            }
            for entry in section.entries {
                if let problem = Self.set(entry.value, at: current + entry.key, line: entry.lines.lowerBound, in: &root) {
                    errors.append(TOMLSyntaxError(message: problem, line: entry.lines.lowerBound))
                }
            }
        }
        return (root, errors)
    }

    /// Creates the table a header opens. Returns a problem, if any.
    private static func open(_ path: [String], isArray: Bool, line: Int, in table: inout TOMLTable) -> String? {
        let key = path[0]
        let index = table.entries.firstIndex { $0.key == key }
        if path.count == 1 {
            switch (index.map { table.entries[$0].node }, isArray) {
            case (nil, false): table.entries.append((key, .table(TOMLTable(line: line))))
            case (nil, true): table.entries.append((key, .arrayOfTables([TOMLTable(line: line)])))
            case (.arrayOfTables(var elements)?, true):
                elements.append(TOMLTable(line: line))
                table.entries[index!].node = .arrayOfTables(elements)
            case (.table(var existing)?, false) where existing.line == nil:
                existing.line = line
                table.entries[index!].node = .table(existing)
            default: return "'\(path.joined(separator: "."))' is defined twice"
            }
            return nil
        }
        return descend(into: key, at: index, line: line, in: &table) { child in open(Array(path.dropFirst()), isArray: isArray, line: line, in: &child) }
    }

    /// Sets a value, creating the tables its dotted key implies. Returns a problem, if any.
    private static func set(_ value: TOMLValue, at path: [String], line: Int, in table: inout TOMLTable) -> String? {
        let key = path[0]
        let index = table.entries.firstIndex { $0.key == key }
        if path.count == 1 {
            guard index == nil else { return "'\(key)' is set twice" }
            table.entries.append((key, .value(value, line: line)))
            return nil
        }
        return descend(into: key, at: index, line: line, in: &table) { child in set(value, at: Array(path.dropFirst()), line: line, in: &child) }
    }

    /// Runs `body` on the table at `key`, created if needed; arrays of tables continue in their last element.
    private static func descend(into key: String, at index: Int?, line: Int, in table: inout TOMLTable, _ body: (inout TOMLTable) -> String?) -> String? {
        guard let index else {
            var child = TOMLTable(line: nil)
            let problem = body(&child)
            table.entries.append((key, .table(child)))
            return problem
        }
        switch table.entries[index].node {
        case .table(var child):
            let problem = body(&child)
            table.entries[index].node = .table(child)
            return problem
        case .arrayOfTables(var elements):
            var last = elements.removeLast()
            let problem = body(&last)
            elements.append(last)
            table.entries[index].node = .arrayOfTables(elements)
            return problem
        case .value:
            return "'\(key)' is already a value, not a table"
        }
    }
}
