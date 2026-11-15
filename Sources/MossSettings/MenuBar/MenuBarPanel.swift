import AppKit
import MossConfig
import MossCore
import MossIPC
public import SwiftUI

/// The panel shown from the menu bar item: a keyboard-first palette for workspaces, windows and
/// actions. Type to filter, ↑ ↓ to choose, ↩ to run.
public struct MenuBarPanel: View {
    @State private var live: LiveState
    private let store: SettingsStore
    private let openSettings: (SettingsPage) -> Void
    private let close: () -> Void
    private let quit: () -> Void

    @State private var query = ""
    @State private var selection = 0

    public init(
        live: LiveState,
        store: SettingsStore,
        openSettings: @escaping (SettingsPage) -> Void,
        close: @escaping () -> Void = {},
        quit: @escaping () -> Void
    ) {
        _live = State(initialValue: live)
        self.store = store
        self.openSettings = openSettings
        self.close = close
        self.quit = quit
    }

    public var body: some View {
        let items = visibleItems
        VStack(spacing: 0) {
            searchField(items)
            Divider()
            if live.isConnected && query.isEmpty {
                WorkspaceStrip()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                Divider()
            }
            list(items)
            Divider()
            footer
        }
        .frame(width: 420)
        .environment(live)
        .environment(store)
        .onAppear { live.start() }
        .onChange(of: query) { selection = 0 }
    }

    // MARK: - Search

    private func searchField(_ items: [PaletteItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            PaletteSearchField(
                text: $query,
                placeholder: "Search windows, actions and shortcuts",
                onMove: { down in
                    selection = down ? min(selection + 1, max(0, items.count - 1)) : max(selection - 1, 0)
                },
                onSubmit: {
                    if items.indices.contains(selection) { run(items[selection]) }
                },
                onCancel: close
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Results

    private func list(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || items[index - 1].section != item.section {
                            Text(item.section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 10)
                                .padding(.bottom, 3)
                        }
                        PaletteRow(item: item, isSelected: index == selection)
                            .id(item.id)
                            .onTapGesture { run(item) }
                            .onHover { if $0 { selection = index } }
                    }
                    if items.isEmpty {
                        Text(live.isConnected ? "No results" : "Moss is not running")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    }
                }
                .padding(6)
            }
            .frame(height: 320)
            .onChange(of: selection) {
                if items.indices.contains(selection) { proxy.scrollTo(items[selection].id) }
            }
        }
    }

    private var visibleItems: [PaletteItem] {
        let all = windowItems + (query.isEmpty ? [] : workspaceItems) + actionItems + (query.isEmpty ? [] : shortcutItems)
        guard !query.isEmpty else { return all }
        let words = query.lowercased().split(separator: " ")
        return all.filter { item in
            let text = [item.title, item.subtitle ?? "", item.tag ?? "", item.keywords].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private var windowItems: [PaletteItem] {
        guard live.isConnected else { return [] }
        return live.windows
            .sorted { ($0.focusOrder ?? .max) < ($1.focusOrder ?? .max) }
            .map { window in
                PaletteItem(
                    id: "window-\(window.id)",
                    section: .windows,
                    icon: .application(pid: window.pid),
                    title: window.app.isEmpty ? window.bundleID : window.app,
                    subtitle: window.title,
                    tag: window.workspace,
                    isCurrent: window.id == live.focusedWindow?.id,
                    command: "focus-window id:\(window.id)"
                )
            }
    }

    private var workspaceItems: [PaletteItem] {
        live.workspaces.map { workspace in
            PaletteItem(
                id: "workspace-\(workspace.workspace)",
                section: .workspaces,
                icon: .symbol(workspace.isScratchpad ? "square.dashed" : "square.stack.3d.up"),
                title: workspace.isScratchpad ? (workspace.workspace == "scratchpad" ? "Scratchpad" : "Scratchpad \(workspace.workspace.replacing("scratchpad:", with: ""))") : "Workspace \(workspace.name)",
                subtitle: "\(workspace.windows) window\(workspace.windows == 1 ? "" : "s")",
                isCurrent: workspace.isFocused,
                command: workspace.isScratchpad ? "scratchpad \(workspace.workspace.replacing("scratchpad:", with: "").replacing("scratchpad", with: ""))" : "workspace \(workspace.workspace)"
            )
        }
    }

    private var actionItems: [PaletteItem] {
        var items: [PaletteItem] = []
        if live.isConnected {
            func action(_ title: String, _ symbol: String, _ text: String, keywords: String = "") {
                let shortcut = (try? Action(parsing: text)).flatMap(binding(for:))
                items.append(PaletteItem(
                    id: "action-\(text)", section: .actions, icon: .symbol(symbol), title: title,
                    shortcut: shortcut, keywords: keywords, command: text
                ))
            }
            if live.focusedWindow != nil {
                action("Float or Tile", "rectangle.on.rectangle", "float", keywords: "floating tile")
                action("Fullscreen", "arrow.up.left.and.arrow.down.right", "fullscreen")
                action("Maximize", "macwindow", "maximize")
                action("Pin to All Workspaces", "pin", "pin", keywords: "sticky")
                action("Tabs", "rectangle.stack", "tabs", keywords: "group")
                action("Close Window", "xmark", "close", keywords: "quit")
            }
            action("Show All Workspaces", "square.grid.2x2", "overview", keywords: "mission control expose")
            action("Show or Hide the Scratchpad", "square.dashed", "scratchpad")
            if live.isPaused {
                action("Resume Tiling", "play.circle", "pause off", keywords: "start continue unpause")
            } else {
                action("Pause Tiling", "pause.circle", "pause on", keywords: "stop suspend")
            }
            for layout in LayoutKind.allCases where layout != store.settings.layout.style {
                let (title, symbol) = switch layout {
                case .bsp: ("BSP", "square.split.bottomrightquarter")
                case .stack: ("Stack", "rectangle.leadinghalf.inset.filled")
                case .scrolling: ("Scrolling", "rectangle.split.3x1")
                }
                items.append(PaletteItem(
                    id: "action-layout-\(layout.rawValue)", section: .actions, icon: .symbol(symbol),
                    title: "Switch to the \(title) Layout", keywords: "layout",
                    command: "set layout.style \(layout.rawValue)"
                ))
            }
            action("Reload Configuration", "arrow.clockwise", "reload")
        }
        items.append(PaletteItem(id: "action-settings", section: .actions, icon: .symbol("gearshape"), title: "Open Settings", keywords: "preferences", perform: { openSettings(.overview) }))
        items.append(PaletteItem(id: "action-quit", section: .actions, icon: .symbol("power"), title: "Quit Moss", perform: quit))
        return items
    }

    /// Every shortcut, so the palette doubles as a searchable cheat sheet.
    private var shortcutItems: [PaletteItem] {
        guard live.isConnected else { return [] }
        let shown = Set(actionItems.compactMap(\.command))
        return store.config.bindings.compactMap { binding -> PaletteItem? in
            guard binding.mode == nil, let action = binding.action else { return nil }
            let command = action.description
            guard !shown.contains(command) else { return nil }
            return PaletteItem(
                id: "shortcut-\(binding.chord.description)",
                section: .shortcuts,
                icon: .symbol("command"),
                title: binding.summary ?? Describe.action(action),
                shortcut: binding,
                keywords: "\(command) shortcut",
                command: command
            )
        }
    }

    /// The first default shortcut that runs `action`, to show its keys.
    private func binding(for action: Action) -> KeyBinding? {
        store.config.bindings.first { $0.mode == nil && $0.action == action }
    }

    private func run(_ item: PaletteItem) {
        close()
        if let perform = item.perform {
            perform()
        } else if let command = item.command {
            Task { await live.send(command) }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(live.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(live.isConnected ? "\(live.windows.count) window\(live.windows.count == 1 ? "" : "s") on \(live.displays.count) display\(live.displays.count == 1 ? "" : "s")" : "Not running")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                close()
                openSettings(.overview)
            } label: {
                HStack(spacing: 5) {
                    Text("Settings").font(.system(size: 12, weight: .medium))
                    KeyCap(text: "⌘", compact: true)
                    KeyCap(text: ",", compact: true)
                }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// One result in the palette.
struct PaletteItem: Identifiable {
    enum Section: Int {
        case windows, workspaces, actions, shortcuts

        var title: String {
            switch self {
            case .windows: "Windows"
            case .workspaces: "Workspaces"
            case .actions: "Actions"
            case .shortcuts: "Shortcuts"
            }
        }
    }

    enum Icon {
        case symbol(String)
        case application(pid: Int32)
    }

    let id: String
    let section: Section
    let icon: Icon
    let title: String
    var subtitle: String?
    var tag: String?
    var shortcut: KeyBinding?
    var isCurrent = false
    var keywords = ""
    /// A control request to send, or else a local action.
    var command: String?
    var perform: (() -> Void)?
}

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            Text(item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let subtitle = item.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let tag = item.tag {
                Text(tag)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .rect(cornerRadius: 4))
            }
            if let shortcut = item.shortcut {
                KeyComboView(modifiers: shortcut.modifiers, trigger: shortcut.trigger, compact: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
    }

    @ViewBuilder
    private var icon: some View {
        switch item.icon {
        case .application(let pid):
            if let image = NSRunningApplication(processIdentifier: pid)?.icon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "macwindow").foregroundStyle(.secondary)
            }
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(.quaternary, in: .rect(cornerRadius: 6, style: .continuous))
        }
    }
}
