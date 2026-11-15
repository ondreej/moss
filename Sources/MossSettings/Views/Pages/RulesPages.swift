import MossConfig
import MossCore
import MossIPC
import SwiftUI

// MARK: - Window rules

struct WindowRulesPage: View {
    @Environment(SettingsStore.self) private var store
    @State private var editing: RuleEditorTarget?

    var body: some View {
        Page {
            PageHeader(title: "Window Rules", subtitle: "Float, place and size windows automatically when they open.", symbol: "macwindow.badge.plus")
            HStack {
                Text("Rules match the application's bundle identifier or name, and the window title, with regular expressions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Rule", systemImage: "plus") { editing = .new }
                    .buttonStyle(.borderedProminent)
            }
            let rows = store.ruleRows
            if rows.isEmpty {
                ContentUnavailableView("No Window Rules", systemImage: "macwindow.badge.plus", description: Text("Dialogs, panels and windows that cannot be resized float on their own. Add a rule to treat other windows differently."))
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            RuleRowView(row: row, edit: { editing = .existing(row) }, delete: { store.removeRule(at: row.index) })
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { RuleEditor(target: $0) }
    }
}

enum RuleEditorTarget: Identifiable, Hashable {
    case new
    case existing(RuleRow)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let row): "rule-\(row.index)"
        }
    }
}

private struct RuleRowView: View {
    let row: RuleRow
    let edit: () -> Void
    let delete: () -> Void
    @Environment(LiveState.self) private var live
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if let rule = row.rules.first {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(row.rules.map { RuleDraft.title(of: $0.effect) }, id: \.self) { Tag(text: $0, color: Design.accent) }
                    }
                    Text(rule.conditions.map { "\($0.key) \($0.value)" }.joined(separator: "  ·  ")).font(.callout.monospaced())
                    if live.isConnected {
                        let matching = live.windows.filter { RuleDraft.matches(rule, $0) }.count
                        Text(matching == 0 ? "No open windows match" : "Matches \(matching) open window\(matching == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text(row.entries.map { "\($0.key) = \($0.value)" }.joined(separator: ", ")).font(.callout.monospaced())
                    Text(row.error ?? "Does nothing").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                Button("Edit", systemImage: "pencil", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: edit)
    }
}

/// An editable `[[rules]]` table: which windows it matches and what it does to them.
struct RuleDraft: Equatable {
    enum EffectKind: String, CaseIterable, Identifiable {
        case float, tile, workspace, display, size, position, center, keepSize, pin, fullscreen, maximize
        case noFocusOnOpen, notFocusable, keepFocus, noBorder, borderWidth, borderColor, noDim, cornerRadius
        case minSize, maxSize, ownTabs, noTabs, tag

        var id: String { rawValue }

        var title: String {
            switch self {
            case .float: "Float above the tiles"
            case .tile: "Tile"
            case .workspace: "Open on workspace"
            case .display: "Open on display"
            case .size: "Size"
            case .position: "Position"
            case .center: "Center"
            case .keepSize: "Keep its own size"
            case .pin: "Pin to all workspaces"
            case .fullscreen: "Fullscreen"
            case .maximize: "Maximize"
            case .noFocusOnOpen: "Don't focus when it opens"
            case .notFocusable: "Never focus"
            case .keepFocus: "Keep focus while visible"
            case .noBorder: "No border"
            case .borderWidth: "Border width"
            case .borderColor: "Border color"
            case .noDim: "Don't dim"
            case .cornerRadius: "Corner radius"
            case .minSize: "Minimum floating size"
            case .maxSize: "Maximum floating size"
            case .ownTabs: "Open as a tab group"
            case .noTabs: "Never join tabs"
            case .tag: "Tag"
            }
        }

        /// What the effect needs typed in, if anything.
        var input: String? {
            switch self {
            case .workspace: "2, mail or scratchpad"
            case .display: "built-in, external or a name"
            case .size, .minSize, .maxSize: "800 600, or 60% 70%"
            case .position: "100 100, or 10% 10%"
            case .borderWidth, .cornerRadius: "Points"
            case .borderColor: "#ff8800, or focused and unfocused colors"
            case .tag: "Name"
            default: nil
            }
        }

        var key: String {
            switch self {
            case .float, .tile: "float"
            case .workspace: "workspace"
            case .display: "display"
            case .size: "size"
            case .position: "position"
            case .center: "center"
            case .keepSize: "keep-size"
            case .pin: "pin"
            case .fullscreen: "fullscreen"
            case .maximize: "maximize"
            case .noFocusOnOpen: "focus-on-open"
            case .notFocusable: "focusable"
            case .keepFocus: "keep-focus"
            case .noBorder: "border"
            case .borderWidth: "border-width"
            case .borderColor: "border-color"
            case .noDim: "dim"
            case .cornerRadius: "corner-radius"
            case .minSize: "min-size"
            case .maxSize: "max-size"
            case .ownTabs, .noTabs: "tabs"
            case .tag: "tag"
            }
        }

        /// The value written for effects that take no input.
        var fixedValue: String? {
            switch self {
            case .float, .center, .keepSize, .pin, .fullscreen, .maximize, .keepFocus: "true"
            case .tile, .noFocusOnOpen, .notFocusable, .noBorder, .noDim: "false"
            case .ownTabs: "own"
            case .noTabs: "never"
            default: nil
            }
        }
    }

    struct Effect: Equatable, Identifiable {
        let id = UUID()
        var kind: EffectKind
        var value = ""
        /// For `workspace`: stay on the current workspace while the window opens on the other.
        var silent = true

        static func == (lhs: Effect, rhs: Effect) -> Bool { lhs.kind == rhs.kind && lhs.value == rhs.value && lhs.silent == rhs.silent }
    }

    var app = ""
    var title = ""
    var effects: [Effect] = [Effect(kind: .float)]
    /// Conditions and keys the editor does not show, kept as written.
    var otherEntries: [RuleRow.Entry] = []

    init() {}

    init(entries: [RuleRow.Entry]) {
        effects = []
        let silent = entries.contains { $0.key == "silent" && $0.value == "true" }
        for entry in entries {
            switch entry.key {
            case "if.app" where app.isEmpty: app = entry.value
            case "if.title" where title.isEmpty: title = entry.value
            case "silent": continue
            default:
                if let kind = EffectKind.allCases.first(where: { $0.key == entry.key && ($0.fixedValue == nil || $0.fixedValue == entry.value) }) {
                    effects.append(Effect(kind: kind, value: kind.fixedValue == nil ? entry.value : "", silent: silent))
                } else {
                    otherEntries.append(entry)
                }
            }
        }
    }

    var entries: [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        if !app.isEmpty { result.append(("if.app", app)) }
        if !title.isEmpty { result.append(("if.title", title)) }
        result += otherEntries.map { ($0.key, $0.value) }
        for effect in effects {
            result.append((effect.kind.key, effect.kind.fixedValue ?? effect.value.trimmingCharacters(in: .whitespaces)))
            if effect.kind == .workspace && effect.silent { result.append(("silent", "true")) }
        }
        return result
    }

    var rules: Result<[WindowRule], ActionError> {
        Result { () throws(ActionError) in try WindowRule.rules(from: entries) }
    }

    static func title(of effect: WindowRule.Effect) -> String {
        switch effect {
        case .workspace(let selector, let silent): "On \(Describe.workspace(selector))" + (silent ? ", in the background" : "")
        case .display(let selector): "On display \(selector)"
        case .size(let width, let height): "Size \(width) × \(height)"
        case .position(let x, let y): "At \(x), \(y)"
        case .borderWidth(let width): "Border \(width.formatted()) pt"
        case .cornerRadius(let radius): "Corners \(radius.formatted()) pt"
        case .tag(let name): "Tag “\(name)”"
        default: EffectKind.allCases.first { kind in effect.entries.first.map { $0.key == kind.key && ($0.value == kind.fixedValue || kind.fixedValue == nil) } ?? false }?.title ?? "\(effect.entries.first?.key ?? "")"
        }
    }

    static func matches(_ rule: WindowRule, _ info: WindowInfo) -> Bool {
        let properties = WindowProperties(appID: info.bundleID, appName: info.app, title: info.title, pid: info.pid)
        let workspace: WorkspaceID = switch try? WorkspaceSelector(parsing: info.workspace) {
        case .id(let number)?: .numbered(number)
        case .scratchpad(let name)?: .scratchpad(name)
        default: .named(info.workspace)
        }
        let window = Window(id: WindowID(0), properties: properties, workspace: workspace, isFloating: info.isFloating, floatingFrame: .zero)
        return rule.matches(window, focused: false)
    }
}

private struct RuleEditor: View {
    let target: RuleEditorTarget
    @Environment(SettingsStore.self) private var store
    @Environment(LiveState.self) private var live
    @Environment(\.dismiss) private var dismiss
    @State private var draft = RuleDraft()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target == .new ? "New Window Rule" : "Edit Window Rule")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            Form {
                Section("Windows") {
                    TextField("Application", text: $draft.app, prompt: Text("^com\\.apple\\.calculator$"))
                    TextField("Title", text: $draft.title, prompt: Text("Optional regular expression"))
                    if !draft.otherEntries.isEmpty {
                        LabeledContent("Also", value: draft.otherEntries.map { "\($0.key) = \($0.value)" }.joined(separator: ", "))
                    }
                    if !live.windows.isEmpty {
                        Menu("Fill In From an Open Window") {
                            ForEach(live.windows) { window in
                                Button("\(window.app) — \(window.title)") {
                                    draft.app = "^\(NSRegularExpression.escapedPattern(for: window.bundleID))$"
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach($draft.effects) { $effect in
                        HStack {
                            Text(effect.kind.title)
                            Spacer()
                            if let prompt = effect.kind.input {
                                TextField("", text: $effect.value, prompt: Text(prompt))
                                    .frame(width: 210)
                            }
                            Button("Remove", systemImage: "minus.circle.fill", role: .destructive) {
                                draft.effects.removeAll { $0.id == effect.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        if effect.kind == .workspace {
                            Toggle("Stay on the current workspace", isOn: $effect.silent)
                        }
                    }
                    Menu("Add an Effect") {
                        ForEach(RuleDraft.EffectKind.allCases) { kind in
                            Button(kind.title) { draft.effects.append(RuleDraft.Effect(kind: kind)) }
                        }
                    }
                } header: {
                    Text("What happens to them")
                }
                Section {
                    if draft.app.isEmpty && draft.title.isEmpty {
                        Text("Enter an application or title to see which open windows the rule matches.")
                            .foregroundStyle(.secondary)
                    } else {
                        switch draft.rules {
                        case .success(let rules):
                            let matches = rules.first.map { rule in live.windows.filter { RuleDraft.matches(rule, $0) } } ?? []
                            if matches.isEmpty {
                                Text("No open windows match.").foregroundStyle(.secondary)
                            } else {
                                ForEach(matches) { window in
                                    Label("\(window.app) — \(window.title)", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                        case .failure(let error):
                            Label(error.description, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Open windows it matches")
                }
                Section("In the configuration file") {
                    Text(preview).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target == .new ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled((try? draft.rules.get()) == nil)
            }
            .padding(16)
        }
        .frame(width: 580, height: 660)
        .onAppear {
            if case .existing(let row) = target { draft = RuleDraft(entries: row.entries) }
        }
    }

    private var preview: String {
        (["[[rules]]"] + Declarations.tomlEntries(draft.entries).map { "\($0.key.joined(separator: ".")) = \($0.value.text)" }).joined(separator: "\n")
    }

    private func save() {
        if case .existing(let row) = target {
            store.saveRule(draft.entries, replacing: row.index)
        } else {
            store.saveRule(draft.entries)
        }
        dismiss()
    }
}

// MARK: - Workspaces

struct WorkspacesPage: View {
    @Environment(SettingsStore.self) private var store
    @Environment(LiveState.self) private var live
    @State private var editing: WorkspaceEditorTarget?

    var body: some View {
        Page {
            PageHeader(title: "Workspaces", subtitle: "Name workspaces, keep them on a display, and give them settings of their own.", symbol: "square.stack.3d.up")
            if live.isConnected {
                Card(title: "Now", symbol: "dot.radiowaves.left.and.right") {
                    WorkspaceStrip()
                }
            }
            HStack {
                Spacer()
                Button("Add Workspace", systemImage: "plus") { editing = .new }
                    .buttonStyle(.borderedProminent)
            }
            let rows = store.workspaceRows
            if rows.isEmpty {
                ContentUnavailableView("No Workspace Settings", systemImage: "square.stack.3d.up", description: Text("Workspaces open when you switch to them and close when they are empty."))
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Divider() }
                            HStack {
                                Text(Self.title(of: row.workspace)).font(.headline)
                                if let rule = row.rule {
                                    ForEach(Self.tags(for: rule), id: \.self) { Tag(text: $0, color: Design.accent) }
                                } else {
                                    Text(row.error ?? "").font(.caption).foregroundStyle(.red)
                                }
                                Spacer()
                                Button("Edit", systemImage: "pencil") { editing = .existing(row) }
                                Button("Delete", systemImage: "trash", role: .destructive) { store.removeWorkspace(row.workspace) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .sheet(item: $editing) { WorkspaceEditor(target: $0) }
    }

    static func title(of workspace: WorkspaceID) -> String {
        switch workspace {
        case .numbered(let number): "Workspace \(number)"
        case .named(let name): "Workspace “\(name)”"
        case .scratchpad(let name): name == WorkspaceID.defaultScratchpadName ? "Scratchpad" : "Scratchpad “\(name)”"
        }
    }

    static func tags(for rule: WorkspaceRule) -> [String] {
        var tags: [String] = []
        if let name = rule.name { tags.append("“\(name)”") }
        if let display = rule.display { tags.append("on \(display)") }
        if rule.isDefault { tags.append("shown first") }
        if rule.isPersistent { tags.append("kept when empty") }
        if let layout = rule.layout { tags.append(layout.rawValue) }
        if let gaps = rule.gaps { tags.append("gaps \(gaps)") }
        if let margins = rule.margins { tags.append("margins \(margins)") }
        if rule.decorations == false { tags.append("no borders") }
        if rule.whenEmpty != nil { tags.append("runs a command") }
        return tags
    }
}

/// Live workspaces as pills showing the applications on them; clicking one switches to it.
struct WorkspaceStrip: View {
    @Environment(LiveState.self) private var live
    private static let shownApps = 3

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(live.workspaces) { workspace in
                    let isFocused = workspace.isFocused
                    let apps = applications(on: workspace)
                    Button {
                        Task { await live.perform(workspace.isScratchpad ? "scratchpad \(workspace.workspace.replacing("scratchpad:", with: "").replacing("scratchpad", with: ""))" : "workspace \(workspace.workspace)") }
                    } label: {
                        HStack(spacing: 7) {
                            Text(workspace.name).font(.callout.weight(.semibold)).monospacedDigit()
                            if !apps.isEmpty {
                                HStack(spacing: 3) {
                                    ForEach(apps.prefix(Self.shownApps), id: \.bundleID) { app in
                                        AppIcon(pid: app.pid, bundleID: app.bundleID, size: 16)
                                    }
                                }
                                if apps.count > Self.shownApps {
                                    Text("+\(apps.count - Self.shownApps)")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(isFocused ? AnyShapeStyle(Design.onAccent.opacity(0.85)) : AnyShapeStyle(.secondary))
                                }
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, apps.isEmpty ? 12 : 8)
                        .padding(.vertical, 5)
                        .frame(minHeight: 28)
                        .background(isFocused ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.quaternary), in: .capsule)
                        .foregroundStyle(isFocused ? Design.onAccent : .primary)
                    }
                    .buttonStyle(.plain)
                    .focusRing(.capsule)
                    .help(summary(of: workspace, apps: apps))
                }
            }
        }
    }

    /// The applications with windows on `workspace`, most recently focused first.
    private func applications(on workspace: WorkspaceInfo) -> [(bundleID: String, pid: Int32, name: String)] {
        var seen: Set<String> = []
        return live.windows
            .filter { $0.workspace == workspace.workspace }
            .sorted { ($0.focusOrder ?? .max) < ($1.focusOrder ?? .max) }
            .compactMap { window in seen.insert(window.bundleID).inserted ? (window.bundleID, window.pid, window.app) : nil }
    }

    private func summary(of workspace: WorkspaceInfo, apps: [(bundleID: String, pid: Int32, name: String)]) -> String {
        let windows = "\(workspace.windows) window\(workspace.windows == 1 ? "" : "s") on \(workspace.display)"
        return apps.isEmpty ? windows : windows + ": " + apps.map(\.name).joined(separator: ", ")
    }
}

/// An application's icon, from its running process or else its bundle.
struct AppIcon: View {
    let pid: Int32
    let bundleID: String
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let image = Self.image(pid: pid, bundleID: bundleID) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    static func image(pid: Int32, bundleID: String) -> NSImage? {
        if let icon = NSRunningApplication(processIdentifier: pid)?.icon { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum WorkspaceEditorTarget: Identifiable, Hashable {
    case new
    case existing(WorkspaceRow)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let row): "workspace-\(row.workspace.name)"
        }
    }
}

private struct WorkspaceEditor: View {
    let target: WorkspaceEditorTarget
    @Environment(SettingsStore.self) private var store
    @Environment(LiveState.self) private var live
    @Environment(\.dismiss) private var dismiss

    @State private var workspace = "1"
    @State private var rule = WorkspaceRule(workspace: .numbered(1))
    @State private var gaps = ""
    @State private var margins = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target == .new ? "New Workspace" : "Edit Workspace")
                .font(.title3.weight(.semibold))
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 8)
            Form {
                TextField("Workspace", text: $workspace, prompt: Text("1, mail, or scratchpad:notes"))
                TextField("Name", text: Binding(get: { rule.name ?? "" }, set: { rule.name = $0.isEmpty ? nil : $0 }), prompt: Text("Shown instead of the number"))
                Picker("Display", selection: Binding(get: { rule.display?.description ?? "" }, set: { rule.display = $0.isEmpty ? nil : try? MonitorSelector(parsing: $0) })) {
                    Text("Any").tag("")
                    Text("Built-in display").tag("built-in")
                    Text("External display").tag("external")
                    ForEach(live.displays) { Text($0.name).tag($0.name) }
                }
                Toggle("Show it first on its display", isOn: $rule.isDefault)
                Toggle("Keep it when it is empty", isOn: $rule.isPersistent)
                Picker("Layout", selection: Binding(get: { rule.layout?.rawValue ?? "" }, set: { rule.layout = LayoutKind(rawValue: $0) })) {
                    Text("Default").tag("")
                    Text("BSP").tag("bsp")
                    Text("Stack").tag("stack")
                    Text("Scrolling").tag("scrolling")
                }
                TextField("Gaps", text: $gaps, prompt: Text("Default"))
                TextField("Margins", text: $margins, prompt: Text("Default"))
                Toggle("Borders and tab bars", isOn: Binding(get: { rule.decorations != false }, set: { rule.decorations = $0 ? nil : false }))
                TextField("When opened empty, run", text: Binding(get: { rule.whenEmpty ?? "" }, set: { rule.whenEmpty = $0.isEmpty ? nil : $0 }), prompt: Text("open -na Terminal"))
                Section("In the configuration file") {
                    Text(preview).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target == .new ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(edited == nil)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
        .onAppear(perform: load)
    }

    /// The workspace the field names, as a concrete workspace.
    private var workspaceID: WorkspaceID? {
        switch try? WorkspaceSelector(parsing: workspace) {
        case .id(let number): .numbered(number)
        case .named(let name): .named(name)
        case .scratchpad(let name): .scratchpad(name)
        default: nil
        }
    }

    /// The settings as edited, or `nil` while something is invalid.
    private var edited: WorkspaceRule? {
        guard let id = workspaceID else { return nil }
        var result = rule
        result.workspace = id
        if gaps.isEmpty { result.gaps = nil } else if let insets = Insets(cssNotation: gaps) { result.gaps = insets } else { return nil }
        if margins.isEmpty { result.margins = nil } else if let insets = Insets(cssNotation: margins) { result.margins = insets } else { return nil }
        return result
    }

    private var preview: String {
        guard let edited else { return "" }
        let table = SettingsStore.table(for: edited.workspace).map(TOMLValue.key).joined(separator: ".")
        return (["[\(table)]"] + Declarations.tomlEntries(edited.entries).map { "\($0.key.joined(separator: ".")) = \($0.value.text)" }).joined(separator: "\n")
    }

    private func load() {
        guard case .existing(let row) = target else { return }
        workspace = WorkspaceSelector.selector(for: row.workspace).description
        rule = row.rule ?? WorkspaceRule(workspace: row.workspace)
        gaps = rule.gaps?.description ?? ""
        margins = rule.margins?.description ?? ""
    }

    private func save() {
        guard let edited else { return }
        if case .existing(let row) = target {
            store.saveWorkspace(edited, replacing: row.workspace)
        } else {
            store.saveWorkspace(edited)
        }
        dismiss()
    }
}

import Foundation
