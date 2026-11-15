import MossConfig
import MossCore
import SwiftUI

struct KeybindingsPage: View {
    @Environment(SettingsStore.self) private var store
    @State private var search = ""
    @State private var editing: ShortcutEditorTarget?

    var body: some View {
        let rows = store.shortcutRows.filter(matches)
        Page {
            PageHeader(title: "Shortcuts", subtitle: "Keys that run actions, and the mouse.", symbol: "keyboard")
            MainKeyCard()
            HStack {
                TextField("Search shortcuts", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Add Shortcut", systemImage: "plus") { editing = .new }
                    .buttonStyle(.borderedProminent)
            }
            let defaultRows = rows.filter { $0.mode == nil }
            ForEach(Describe.Category.allCases) { category in
                let items = defaultRows.filter { row in row.binding.map { Describe.category(of: $0.command) == category } ?? (category == .system) }
                if !items.isEmpty {
                    Card(title: category.rawValue, symbol: category.symbol) {
                        ShortcutList(rows: items) { editing = .existing($0) }
                    }
                }
            }
            ForEach(store.modes, id: \.self) { mode in
                let items = rows.filter { $0.mode == mode }
                if !items.isEmpty {
                    Card(title: "“\(mode)” mode", symbol: "rectangle.on.rectangle.angled") {
                        Text("These shortcuts take over after one runs `mode \(mode)`, until one runs `mode default`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ShortcutList(rows: items) { editing = .existing($0) }
                    }
                }
            }
            if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .sheet(item: $editing) { target in
            ShortcutEditor(target: target)
        }
    }

    private func matches(_ row: ShortcutRow) -> Bool {
        guard !search.isEmpty else { return true }
        let haystack = [row.keys, row.binding.map { Describe.command($0.command) } ?? "", row.binding?.action?.description ?? ""].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(search)
    }
}

/// The main key, which every shortcut written with `mod` starts with.
private struct MainKeyCard: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let mainKey = store.mainKey
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Main key")
                    Text("Shortcuts written with mod start with it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ModifierPicker(modifiers: Binding(get: { mainKey }, set: { new in
                    guard !new.isEmpty, let option = OptionRegistry.option("keyboard.main-key") else { return }
                    store.set(option, to: new.description)
                }), offersCapsLock: true)
            }
            Divider()
            OptionRow(path: "keyboard.caps-lock", summary: capsLockSummary(mainKey: mainKey))
            if mainKey.contains(.capsLock) || store.settings.keyboard.capsLock == .hyper {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Caps Lock not responding? Check that it is set to “⇪ Caps Lock” in System Settings › Keyboard › Keyboard Shortcuts › Modifier Keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Keyboard Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func capsLockSummary(mainKey: Modifiers) -> String {
        if store.settings.keyboard.capsLock == .hyper {
            return "Hold for shortcuts, tap to lock capitals. Other apps see it as Hyper (⌃⌥⇧⌘)."
        }
        return mainKey.contains(.capsLock) ? "Moss's alone: it does not lock capitals." : "Locks capitals, as usual."
    }
}

private struct ShortcutList: View {
    let rows: [ShortcutRow]
    let edit: (ShortcutRow) -> Void
    @Environment(SettingsStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                ShortcutRowView(row: row, edit: { edit(row) }, delete: { store.removeShortcut(row) })
            }
        }
    }
}

private struct ShortcutRowView: View {
    let row: ShortcutRow
    let edit: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            if let binding = row.binding {
                KeyComboView(modifiers: binding.modifiers, trigger: binding.trigger)
                    .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(binding.summary ?? Describe.command(binding.command))
                    let options = optionNames(binding.options)
                    if !options.isEmpty {
                        Text(options).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.keys).font(.body.monospaced())
                    Text(row.error ?? "").font(.caption).foregroundStyle(.red)
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
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: edit)
        .contextMenu {
            Button("Edit…", action: edit)
            Button("Delete", role: .destructive, action: delete)
        }
    }

    private func optionNames(_ options: KeyBinding.Options) -> String {
        var names: [String] = []
        if options.contains(.repeats) { names.append("repeats while held") }
        if options.contains(.onRelease) { names.append("on release") }
        if options.contains(.passesThrough) { names.append("also reaches the app") }
        return names.joined(separator: " · ")
    }
}
