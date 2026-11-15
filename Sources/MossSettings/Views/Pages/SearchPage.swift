import MossConfig
import MossCore
import SwiftUI

/// Everything matching the sidebar search: pages to open, options to change right here, and
/// shortcuts.
struct SearchPage: View {
    let query: String
    let open: (SettingsPage) -> Void
    @Environment(SettingsStore.self) private var store

    var body: some View {
        let pages = SettingsPage.allCases.filter { matches($0.title, $0.keywords) }
        let options = OptionRegistry.all.filter { matches(OptionTitles.title(for: $0), $0.path, $0.summary) }
        let shortcuts = store.shortcutRows.compactMap { row -> (ShortcutRow, KeyBinding)? in
            guard let binding = row.binding else { return nil }
            return matches(binding.summary ?? Describe.command(binding.command), row.keys, binding.action?.description ?? "") ? (row, binding) : nil
        }
        Page {
            if pages.isEmpty && options.isEmpty && shortcuts.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            if !pages.isEmpty {
                Card(title: "Pages", symbol: "sidebar.left") {
                    ForEach(pages) { page in
                        Button { open(page) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol)
                                    .foregroundStyle(Design.accent)
                                    .frame(width: 20)
                                Text(page.title)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
            if !options.isEmpty {
                Card(title: "Options", symbol: "slider.horizontal.3") {
                    ForEach(Array(options.enumerated()), id: \.element.path) { index, option in
                        if index > 0 { Divider() }
                        OptionRow(path: option.path)
                    }
                }
            }
            if !shortcuts.isEmpty {
                Card(title: "Shortcuts", symbol: "keyboard") {
                    ForEach(Array(shortcuts.enumerated()), id: \.element.0.id) { index, item in
                        if index > 0 { Divider() }
                        Button { open(.keybindings) } label: {
                            HStack(spacing: 12) {
                                KeyComboView(modifiers: item.1.modifiers, trigger: item.1.trigger)
                                    .frame(width: 150, alignment: .leading)
                                Text(item.1.summary ?? Describe.command(item.1.command))
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    /// Every word of the query appears in one of the fields.
    private func matches(_ fields: String...) -> Bool {
        let text = fields.joined(separator: " ").lowercased()
        return query.lowercased().split(separator: " ").allSatisfy { text.contains($0) }
    }
}
