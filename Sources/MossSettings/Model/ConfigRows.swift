import MossConfig
public import MossCore

/// A shortcut as written in `[shortcuts]`, `[modes.NAME]` or `[mouse]`.
public struct ShortcutRow: Identifiable, Hashable, Sendable {
    public var id: String { (table + [keys]).joined(separator: ".") }
    /// The table it is written in, e.g. `["modes", "resize"]`.
    public let table: [String]
    /// The keys as written, e.g. `mod-shift-left`.
    public let keys: String
    public let binding: KeyBinding?
    public let error: String?

    public var mode: String? { table.first == "modes" && table.count > 1 ? table[1] : nil }
    public var isMouse: Bool { table == ["mouse"] }
}

/// A `[[rules]]` table.
public struct RuleRow: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    /// The rule's position among the `[[rules]]` tables of the file.
    public let index: Int
    public let entries: [Entry]
    /// The rules the table declares, one per effect.
    public let rules: [WindowRule]
    public let error: String?

    public struct Entry: Hashable, Sendable {
        public var key: String
        public var value: String
    }

    /// The table's rule, when it declares exactly one and the rule editor can rewrite it.
    public var rule: WindowRule? { rules.count == 1 ? rules[0] : nil }
}

/// A `[workspaces.N]` or `[scratchpads.NAME]` table.
public struct WorkspaceRow: Identifiable, Hashable, Sendable {
    public var id: WorkspaceID { workspace }
    public let workspace: WorkspaceID
    public let rule: WorkspaceRule?
    public let error: String?
}

extension SettingsStore {
    /// Every shortcut in the file, in order.
    public var shortcutRows: [ShortcutRow] {
        var rows: [ShortcutRow] = []
        for section in document.sections where !section.isArrayElement {
            for entry in section.entries {
                let path = section.path + entry.key
                guard let keys = path.last else { continue }
                let table = Array(path.dropLast())
                let isShortcutTable = table == ["shortcuts"] || table == ["mouse"] || (table.count == 2 && table[0] == "modes")
                guard isShortcutTable else { continue }
                do throws(ConfigError) {
                    let binding = table == ["mouse"]
                        ? try Declarations.mouseBinding(keys: keys, value: entry.value, mainKey: mainKey)
                        : try Declarations.binding(keys: keys, value: entry.value, mode: table.count == 2 ? table[1] : nil, mainKey: mainKey)
                    rows.append(ShortcutRow(table: table, keys: keys, binding: binding, error: nil))
                } catch {
                    rows.append(ShortcutRow(table: table, keys: keys, binding: nil, error: error.description))
                }
            }
        }
        return rows
    }

    /// The modes the file declares shortcuts for, in order.
    public var modes: [String] {
        shortcutRows.compactMap(\.mode).reduce(into: [String]()) { modes, mode in
            if !modes.contains(mode) { modes.append(mode) }
        }
    }

    public var ruleRows: [RuleRow] {
        document.arrayTables(["rules"]).compactMap { section -> RuleRow? in
            guard let index = section.arrayIndex else { return nil }
            let entries = Declarations.entries(of: section)
            let rowEntries = entries.map { RuleRow.Entry(key: $0.key, value: $0.value) }
            do {
                return RuleRow(index: index, entries: rowEntries, rules: try WindowRule.rules(from: entries), error: nil)
            } catch {
                return RuleRow(index: index, entries: rowEntries, rules: [], error: "\(error)")
            }
        }
    }

    public var workspaceRows: [WorkspaceRow] {
        document.sections.compactMap { section -> WorkspaceRow? in
            guard !section.isArrayElement, section.path.count == 2, section.headerLine != nil else { return nil }
            let workspace: WorkspaceID
            switch section.path[0] {
            case "workspaces": workspace = Int(section.path[1]).map(WorkspaceID.numbered) ?? .named(section.path[1])
            case "scratchpads": workspace = .scratchpad(section.path[1])
            default: return nil
            }
            do {
                return WorkspaceRow(workspace: workspace, rule: try WorkspaceRule(workspace: workspace, entries: Declarations.entries(of: section)), error: nil)
            } catch {
                return WorkspaceRow(workspace: workspace, rule: nil, error: "\(error)")
            }
        }
    }
}
