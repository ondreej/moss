public import MossConfig
public import MossCore
public import Foundation
public import Observation

/// The configuration file being edited.
///
/// Edits go through `TOMLDocument`, which keeps the comments and formatting written by hand.
/// Changes are saved shortly after the last edit, and the running window manager picks them up
/// through its own file watcher.
@MainActor
@Observable
public final class SettingsStore {
    public let fileURL: URL
    public private(set) var document: TOMLDocument
    public private(set) var config: EvaluatedConfig
    public private(set) var saveError: String?
    public private(set) var lastSaved: Date?

    @ObservationIgnored private var savedText: String
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private let evaluator = ConfigEvaluator()

    public init(fileURL: URL = ConfigPaths.mainFile) {
        self.fileURL = fileURL
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? DefaultConfiguration.text
        document = TOMLDocument(text: text)
        savedText = text
        config = EvaluatedConfig()
        config = evaluate(document)
        watch()
    }

    public var settings: Settings { config.settings }
    public var errors: [Diagnostic] { config.diagnostics.filter { $0.severity == .error } }
    public var hasUnsavedChanges: Bool { document.text != savedText }

    private func evaluate(_ document: TOMLDocument) -> EvaluatedConfig {
        evaluator.evaluate(document, at: fileURL)
    }

    // MARK: - Options

    /// The effective value of an option, formatted as configuration text.
    public func value(of option: OptionDescriptor) -> String { option.value(in: config.settings) }

    /// Whether the configuration sets the option explicitly rather than relying on the default.
    public func isSet(_ option: OptionDescriptor) -> Bool { config.origins[option.path] != nil }

    public func set(_ option: OptionDescriptor, to text: String) {
        guard option.validate(text) == nil, value(of: option) != text || !isSet(option) else { return }
        edit { $0.setValue(option.tomlValue(fromText: text), at: option.keyPath) }
    }

    public func reset(_ option: OptionDescriptor) {
        edit { $0.removeValue(at: option.keyPath) }
    }

    /// The key every shortcut starts with, written `mod` in the file.
    public var mainKey: Modifiers { settings.keyboard.mainKey }

    // MARK: - Shortcuts, rules and workspaces

    /// Adds a shortcut, replacing `row` if given, or another shortcut with the same keys.
    public func saveShortcut(_ binding: KeyBinding, replacing row: ShortcutRow? = nil) {
        let keys = binding.chord.description(mainKey: mainKey)
        edit { document in
            if let row { document.removeValue(at: row.table + [row.keys]) }
            document.setValue(Declarations.value(for: binding), at: Declarations.table(for: binding) + [keys])
        }
    }

    public func removeShortcut(_ row: ShortcutRow) {
        edit { $0.removeValue(at: row.table + [row.keys]) }
    }

    /// Adds a rule, or replaces the rule at `index`.
    public func saveRule(_ entries: [(key: String, value: String)], replacing index: Int? = nil) {
        let toml = Declarations.tomlEntries(entries)
        edit { document in
            if let index {
                document.replaceArrayTable(["rules"], at: index, entries: toml)
            } else {
                document.appendArrayTable(["rules"], entries: toml)
            }
        }
    }

    public func removeRule(at index: Int) {
        edit { $0.removeArrayTable(["rules"], at: index) }
    }

    /// Writes a workspace's settings, removing the table of `previous` if it was another workspace.
    public func saveWorkspace(_ rule: WorkspaceRule, replacing previous: WorkspaceID? = nil) {
        let toml = Declarations.tomlEntries(rule.entries)
        edit { document in
            if let previous, previous != rule.workspace { document.removeTable(Self.table(for: previous)) }
            if toml.isEmpty {
                document.removeTable(Self.table(for: rule.workspace))
            } else {
                document.setTable(Self.table(for: rule.workspace), entries: toml)
            }
        }
    }

    public func removeWorkspace(_ workspace: WorkspaceID) {
        edit { $0.removeTable(Self.table(for: workspace)) }
    }

    /// The table a workspace's settings are written in: `[workspaces.3]`, `[scratchpads.notes]`.
    static func table(for workspace: WorkspaceID) -> [String] {
        switch workspace {
        case .numbered(let number): ["workspaces", String(number)]
        case .named(let name): ["workspaces", name]
        case .scratchpad(let name): ["scratchpads", name]
        }
    }

    /// The whole file as text, for the raw editor.
    public var text: String {
        get { document.text }
        set {
            guard newValue != document.text else { return }
            edit { $0 = TOMLDocument(text: newValue) }
        }
    }

    private func edit(_ body: (inout TOMLDocument) -> Void) {
        body(&document)
        config = evaluate(document)
        scheduleSave()
    }

    // MARK: - Saving and external changes

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    public func save() {
        saveTask?.cancel()
        let text = document.text
        guard text != savedText else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            savedText = text
            lastSaved = .now
            saveError = nil
            watch()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Re-reads the file after it changed on disk, unless there are edits waiting to be saved.
    public func reloadFromDisk() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8), text != savedText, !hasUnsavedChanges else { return }
        savedText = text
        document = TOMLDocument(text: text)
        config = evaluate(document)
    }

    private func watch() {
        watcher?.cancel()
        let descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Editors often save by replacing the file; follow the new one.
                if source.data.contains(.delete) || source.data.contains(.rename) { self.watch() }
                self.reloadFromDisk()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}
