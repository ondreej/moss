public import MossCore
public import Foundation

/// The result of evaluating a configuration: typed settings and everything the tables declare.
public struct EvaluatedConfig: Sendable {
    public var settings = Settings()
    public var bindings: [KeyBinding] = []
    /// The modes declared under `[modes]`.
    public var modes: Set<String> = []
    public var windowRules: [WindowRule] = []
    public var workspaceRules: [WorkspaceRule] = []
    public var displayReservations: [MonitorReservation] = []
    /// Commands run when Moss starts.
    public var startup: [String] = []
    /// Commands run when Moss quits.
    public var shutdown: [String] = []
    public var environment: [(name: String, value: String)] = []
    public var diagnostics: [Diagnostic] = []
    /// Every file the configuration consists of, including ones that could not be read, for
    /// change monitoring.
    public var files: [URL] = []
    /// The patterns of included files, such as `/Users/me/.config/moss/themes/*.toml`, so
    /// files that come to match them are noticed.
    public var filePatterns: [String] = []
    /// Where each option was last set.
    public var origins: [String: SourceLocation] = [:]

    public init() {}

    public var errors: [Diagnostic] { diagnostics.filter { $0.severity == .error } }
    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

/// Evaluates configuration files: TOML with the tables and keys described in the documentation.
public struct ConfigEvaluator: Sendable {
    public var fileSystem: any ConfigFileSystem
    /// The maximum nesting of included files.
    public var maximumDepth = 16

    public init(fileSystem: any ConfigFileSystem = LocalFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Evaluates the configuration file at `url` and the files it includes.
    public func evaluate(fileAt url: URL) -> EvaluatedConfig {
        var state = State()
        guard let text = read(url, from: nil, state: &state) else { return state.result }
        load(TOMLDocument(text: text), at: url, state: &state)
        return state.finish()
    }

    /// Evaluates a document in memory; `url` is used in messages and for relative includes.
    public func evaluate(_ document: TOMLDocument, at url: URL? = nil) -> EvaluatedConfig {
        var state = State()
        if let url { state.result.files.append(url.standardizedFileURL) }
        load(document, at: url, state: &state)
        return state.finish()
    }

    // MARK: - State

    struct State {
        var result = EvaluatedConfig()
        /// Every file's tables, in the order they apply: included files before the file including them.
        var trees: [(root: TOMLTable, file: URL?)] = []
        var visited: Set<String> = []
        /// Shortcuts that switch to a mode, checked once every mode is known.
        var modeSwitches: [(mode: String, keys: String, file: URL?, line: Int)] = []

        mutating func report(_ severity: Diagnostic.Severity, _ message: String, file: URL?, line: Int?) {
            result.diagnostics.append(Diagnostic(severity, message, at: SourceLocation(file: file, line: line ?? 0)))
        }

        /// Applies every file: options first, so shortcuts read with the final main key.
        mutating func finish() -> EvaluatedConfig {
            for (root, file) in trees { applyOptions(root, prefix: [], file: file) }
            for (root, file) in trees { applyDeclarations(root, file: file) }
            for change in modeSwitches where !result.modes.contains(change.mode) {
                report(.error, "\(change.keys): there is no mode '\(change.mode)'; shortcuts for it go under [modes.\(change.mode)]", file: change.file, line: change.line)
            }
            return result
        }
    }

    private func read(_ url: URL, from location: SourceLocation?, state: inout State) -> String? {
        // Watched even when missing, so the file is read once it appears.
        state.result.files.append(url.standardizedFileURL)
        do {
            return try fileSystem.read(url)
        } catch {
            state.report(.error, "cannot read '\(url.path)'", file: location?.file ?? url, line: location?.line)
            return nil
        }
    }

    /// Reads a document and the files it includes, which apply before it.
    private func load(_ document: TOMLDocument, at url: URL?, state: inout State) {
        let key = url?.standardizedFileURL.path ?? ""
        guard !state.visited.contains(key) else {
            state.report(.error, "'\(url?.lastPathComponent ?? "")' includes itself", file: url, line: nil)
            return
        }
        guard state.visited.count < maximumDepth else {
            state.report(.error, "too many nested includes", file: url, line: nil)
            return
        }
        state.visited.insert(key)
        defer { state.visited.remove(key) }

        for error in document.syntaxErrors {
            state.report(.error, error.message, file: url, line: error.line)
        }
        let (root, problems) = document.tree()
        for problem in problems {
            state.report(.error, problem.message, file: url, line: problem.line)
        }
        if case .value(let value, let line)? = root["include"] {
            let paths: [String]
            switch value {
            case .string(let path): paths = [path]
            case .array(let items) where items.allSatisfy({ if case .string = $0 { true } else { false } }):
                paths = items.compactMap { if case .string(let path) = $0 { path } else { nil } }
            default:
                state.report(.error, "include expects a file name or a list of them", file: url, line: line)
                paths = []
            }
            for path in paths {
                let absolute = ConfigPaths.included(path, relativeTo: url?.deletingLastPathComponent())
                if ConfigPaths.isPattern(absolute) { state.result.filePatterns.append(absolute) }
                let matches = fileSystem.resolve(path, relativeTo: url?.deletingLastPathComponent())
                if matches.isEmpty { state.report(.error, "no files match '\(path)'", file: url, line: line) }
                for match in matches {
                    guard let text = read(match, from: SourceLocation(file: url, line: line), state: &state) else { continue }
                    load(TOMLDocument(text: text), at: match, state: &state)
                }
            }
        }
        state.trees.append((root, url))
    }
}

// MARK: - Options

/// Tables whose entries are declarations rather than options.
private let declarationTables: Set<String> = ["shortcuts", "modes", "mouse", "rules", "displays", "startup", "shutdown", "environment"]

extension ConfigEvaluator.State {
    mutating func applyOptions(_ table: TOMLTable, prefix: [String], file: URL?) {
        for (key, node) in table.entries {
            let path = prefix + [key]
            let dotted = path.joined(separator: ".")
            if prefix.isEmpty && (declarationTables.contains(key) || key == "include") { continue }
            switch node {
            case .value(let value, let line):
                guard let option = OptionRegistry.option(dotted) else {
                    report(.error, ConfigError.unknownOption(dotted, suggestion: OptionRegistry.suggestion(for: dotted)).description, file: file, line: line)
                    continue
                }
                do {
                    try option.apply(try option.text(from: value), to: &result.settings)
                    result.origins[option.path] = SourceLocation(file: file, line: line)
                } catch {
                    report(.error, "\(option.path): \(error)", file: file, line: line)
                }
            case .table(let child):
                // `[workspaces.3]` and `[scratchpads.notes]` describe a workspace each.
                if prefix.isEmpty && (key == "workspaces" || key == "scratchpads") { continue }
                guard OptionRegistry.isCategory(dotted) else {
                    report(.error, "unknown table [\(dotted)]", file: file, line: child.line)
                    continue
                }
                applyOptions(child, prefix: path, file: file)
            case .arrayOfTables(let elements):
                report(.error, "[[\(dotted)]] is not a list of tables", file: file, line: elements.first?.line)
            }
        }
        if prefix.isEmpty {
            for key in ["workspaces", "scratchpads"] {
                guard case .table(let child)? = table[key] else { continue }
                applyOptions(child.withoutTables, prefix: [key], file: file)
            }
        }
    }

    // MARK: - Declarations

    mutating func applyDeclarations(_ root: TOMLTable, file: URL?) {
        for (key, node) in root.entries {
            switch (key, node) {
            case ("shortcuts", .table(let table)):
                readShortcuts(table, mode: nil, file: file)
            case ("modes", .table(let table)):
                for (mode, node) in table.entries {
                    result.modes.insert(mode)
                    guard case .table(let shortcuts) = node else {
                        report(.error, "modes.\(mode) should be a table of shortcuts", file: file, line: line(of: node))
                        continue
                    }
                    readShortcuts(shortcuts, mode: mode, file: file)
                }
            case ("mouse", .table(let table)):
                readMouse(table, file: file)
            case ("rules", .arrayOfTables(let tables)):
                for table in tables { readRule(table, file: file) }
            case ("workspaces", .table(let table)), ("scratchpads", .table(let table)):
                for (name, node) in table.entries {
                    guard case .table(let settings) = node else { continue }
                    readWorkspace(name, scratchpad: key == "scratchpads", settings, file: file)
                }
            case ("displays", .table(let table)):
                readDisplays(table, file: file)
            case ("startup", .table(let table)), ("shutdown", .table(let table)):
                readCommands(table, startup: key == "startup", file: file)
            case ("environment", .table(let table)):
                for (name, node) in table.entries {
                    guard case .value(.string(let value), _) = node else {
                        report(.error, "environment.\(name) should be text in quotes", file: file, line: line(of: node))
                        continue
                    }
                    result.environment.removeAll { $0.name == name }
                    result.environment.append((name, value))
                }
            case (let key, _) where declarationTables.contains(key):
                report(.error, "\(key) has the wrong shape; see the configuration documentation", file: file, line: line(of: node))
            default:
                break
            }
        }
    }

    private func line(of node: TOMLNode) -> Int? {
        switch node {
        case .value(_, let line): line
        case .table(let table): table.line
        case .arrayOfTables(let tables): tables.first?.line
        }
    }

    private mutating func readShortcuts(_ table: TOMLTable, mode: String?, file: URL?) {
        for (keys, node) in table.entries {
            guard case .value(let value, let line) = node else {
                report(.error, "\(keys): a shortcut runs an action, written in quotes", file: file, line: self.line(of: node))
                continue
            }
            do {
                let binding = try Declarations.binding(keys: keys, value: value, mode: mode, mainKey: result.settings.keyboard.mainKey)
                if case .action(.mode(let target?)) = binding.command { modeSwitches.append((target, keys, file, line)) }
                add(binding)
            } catch {
                report(.error, "\(keys): \(error)", file: file, line: line)
            }
        }
    }

    private mutating func readMouse(_ table: TOMLTable, file: URL?) {
        for (keys, node) in table.entries {
            guard case .value(let value, let line) = node else { continue }
            do {
                add(try Declarations.mouseBinding(keys: keys, value: value, mainKey: result.settings.keyboard.mainKey))
            } catch {
                report(.error, "\(keys): \(error)", file: file, line: line)
            }
        }
    }

    /// Adds a shortcut, replacing one with the same keys from an earlier file.
    private mutating func add(_ binding: KeyBinding) {
        result.bindings.removeAll { $0.modifiers == binding.modifiers && $0.trigger == binding.trigger && $0.mode == binding.mode }
        result.bindings.append(binding)
    }

    private mutating func readRule(_ table: TOMLTable, file: URL?) {
        do {
            result.windowRules += try WindowRule.rules(from: try Declarations.entries(of: table))
        } catch {
            report(.error, "rule: \(error)", file: file, line: table.line)
        }
    }

    private mutating func readWorkspace(_ name: String, scratchpad: Bool, _ table: TOMLTable, file: URL?) {
        let id: WorkspaceID = scratchpad ? .scratchpad(name) : Int(name).map(WorkspaceID.numbered) ?? .named(name)
        do {
            result.workspaceRules.append(try WorkspaceRule(workspace: id, entries: try Declarations.entries(of: table)))
        } catch {
            report(.error, "\(scratchpad ? "scratchpads" : "workspaces").\(name): \(error)", file: file, line: table.line)
        }
    }

    private mutating func readDisplays(_ table: TOMLTable, file: URL?) {
        for (name, node) in table.entries {
            guard case .table(let settings) = node else { continue }
            for (key, setting) in settings.entries {
                guard case .value(let value, let line) = setting else { continue }
                guard key == "reserve" else {
                    report(.error, "unknown display setting '\(key)'; the only one is reserve", file: file, line: line)
                    continue
                }
                guard let insets = Insets(cssNotation: Declarations.text(of: value)) else {
                    report(.error, "displays.\(name).reserve expects a number, or a list of up to four numbers", file: file, line: line)
                    continue
                }
                let selector = name == "all" ? nil : try? MonitorSelector(parsing: name)
                result.displayReservations.append(MonitorReservation(monitor: selector, insets: insets))
            }
        }
    }

    private mutating func readCommands(_ table: TOMLTable, startup: Bool, file: URL?) {
        for (key, node) in table.entries {
            guard key == "run", case .value(let value, let line) = node else {
                report(.error, "\(startup ? "startup" : "shutdown") only takes run, a list of commands", file: file, line: self.line(of: node))
                continue
            }
            let commands: [String]
            switch value {
            case .string(let command): commands = [command]
            case .array(let items): commands = items.compactMap { if case .string(let command) = $0 { command } else { nil } }
            default:
                report(.error, "run expects a command or a list of commands", file: file, line: line)
                continue
            }
            if startup { result.startup += commands } else { result.shutdown += commands }
        }
    }
}

extension TOMLTable {
    /// The table with its sub-tables left out.
    var withoutTables: TOMLTable {
        var copy = self
        copy.entries = entries.filter { if case .value = $0.node { true } else { false } }
        return copy
    }
}
