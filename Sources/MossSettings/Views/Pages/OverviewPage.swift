import MossConfig
import MossCore
import MossIPC
import SwiftUI

struct OverviewPage: View {
    @Binding var page: SettingsPage
    @Environment(SettingsStore.self) private var store
    @Environment(LiveState.self) private var live
    @Environment(\.services) private var services

    var body: some View {
        Page {
            hero
            if !services.isAccessibilityGranted() {
                Card {
                    HStack {
                        Image(systemName: "hand.raised.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text("Accessibility access is needed").font(.headline)
                            Text("Moss moves and resizes windows through the accessibility API. Allow it in System Settings › Privacy & Security › Accessibility.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open System Settings") { services.requestAccessibility() }
                    }
                }
            }
            if !store.errors.isEmpty {
                Card {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text("The configuration has \(store.errors.count) problem\(store.errors.count == 1 ? "" : "s").")
                        Spacer()
                        Button("Show") { page = .configuration }
                    }
                }
            }
            if live.isConnected {
                Card(title: "Desktop", symbol: "display") {
                    DesktopMap()
                    WorkspaceStrip()
                }
            }
            Card(title: "Layout", symbol: "rectangle.split.3x1") {
                LayoutKindPicker()
            }
            HStack(spacing: 14) {
                shortcut(.keybindings, "\(store.shortcutRows.count) shortcuts")
                shortcut(.windowRules, "\(store.ruleRows.count) rules")
                shortcut(.appearance, "Borders & dimming")
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text("Moss").font(.largeTitle.weight(.bold))
                StatusLabel(
                    text: live.isConnected ? "Managing \(live.windows.count) window\(live.windows.count == 1 ? "" : "s") on \(live.displays.count) display\(live.displays.count == 1 ? "" : "s")" : "Not running",
                    isOK: live.isConnected
                )
            }
            Spacer()
            Button("Reload", systemImage: "arrow.clockwise") {
                Task { await live.send("reload") }
            }
            .buttonStyle(.bordered)
            .disabled(!live.isConnected)
        }
        .padding(.bottom, 6)
    }

    private func shortcut(_ target: SettingsPage, _ detail: String) -> some View {
        Button {
            page = target
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: target.symbol).font(.title2).foregroundStyle(Design.accent)
                Text(target.title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary.opacity(0.6), in: .rect(cornerRadius: Design.cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: Design.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .focusRing(.rect(cornerRadius: Design.cornerRadius))
    }
}

/// A scaled map of every display with its visible windows; click a window to focus it.
struct DesktopMap: View {
    @Environment(LiveState.self) private var live

    var body: some View {
        let displays = live.displays
        let bounds = displays.reduce(CGRect.null) { $0.union(CGRect(x: $1.frame.x, y: $1.frame.y, width: $1.frame.width, height: $1.frame.height)) }
        GeometryReader { proxy in
            let scale = bounds.isNull ? 1 : min(proxy.size.width / bounds.width, proxy.size.height / bounds.height)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    Wallpaper()
                        .frame(width: display.frame.width * scale, height: display.frame.height * scale)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            Text(display.name).font(.caption2.weight(.medium)).foregroundStyle(.white).shadow(radius: 2).padding(6)
                        }
                        .offset(x: (display.frame.x - bounds.minX) * scale, y: (display.frame.y - bounds.minY) * scale)
                }
                ForEach(live.windows.filter { !$0.isHidden }) { window in
                    let isFocused = window.id == live.focusedWindow?.id
                    Button {
                        Task { await live.perform("focus-window id:\(window.id)") }
                    } label: {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(isFocused ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.separator), lineWidth: isFocused ? 2 : 0.5)
                            }
                            .overlay {
                                Text(window.app).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary).lineLimit(1).padding(4)
                            }
                    }
                    .buttonStyle(.plain)
                    .focusRing(.rect(cornerRadius: 5, style: .continuous))
                    .frame(width: window.frame.width * scale, height: window.frame.height * scale)
                    .offset(x: (window.frame.x - bounds.minX) * scale, y: (window.frame.y - bounds.minY) * scale)
                    .help("\(window.app) — \(window.title)")
                }
            }
            .animation(.spring(duration: 0.3), value: live.windows)
        }
        .aspectRatio(bounds.isNull ? 16 / 10 : bounds.width / bounds.height, contentMode: .fit)
        .frame(maxHeight: 280)
    }
}

struct ConfigurationPage: View {
    @Environment(SettingsStore.self) private var store
    @State private var text = ""
    @State private var showAllOptions = false
    @State private var filter = ""

    var body: some View {
        Page {
            PageHeader(title: "Configuration File", subtitle: store.fileURL.path.replacing(NSHomeDirectory(), with: "~"), symbol: "doc.text")
            HStack {
                Button("Open in Editor", systemImage: "square.and.pencil") { NSWorkspace.shared.open(store.fileURL) }
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL]) }
                Spacer()
                if let saved = store.lastSaved {
                    Text("Saved \(saved.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.config.diagnostics.isEmpty {
                Card(title: "Problems", symbol: "exclamationmark.triangle") {
                    ForEach(Array(store.config.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : diagnostic.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                                .foregroundStyle(diagnostic.severity == .error ? .red : diagnostic.severity == .warning ? .orange : .secondary)
                            Text(diagnostic.location.description).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(diagnostic.message).font(.callout)
                        }
                    }
                }
            }
            Card(title: "Error Bar", symbol: "exclamationmark.bubble") {
                OptionRow(path: "errors.show")
            }
            Card(title: "Source", symbol: "chevron.left.forwardslash.chevron.right") {
                TextEditor(text: $text)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 380)
                    .onAppear { text = store.text }
                    .onChange(of: store.document) { if store.text != text { text = store.text } }
                    .onChange(of: text) { store.text = text }
            }
            Card(title: "All Options", symbol: "list.bullet.rectangle") {
                DisclosureGroup("\(OptionRegistry.all.count) options", isExpanded: $showAllOptions) {
                    TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                    ForEach(OptionRegistry.all.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }) { option in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.path).font(.callout.monospaced())
                                Text(option.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(store.value(of: option)).font(.callout.monospaced()).foregroundStyle(store.isSet(option) ? .primary : .secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

struct AboutPage: View {
    @Environment(LiveState.self) private var live
    @Environment(\.services) private var services
    @Environment(\.showWelcome) private var showWelcome

    var body: some View {
        Page {
            PageHeader(title: "About", subtitle: "A dynamic tiling window manager for macOS.", symbol: "info.circle")
            Card {
                LabeledContent("Version", value: live.status?.version ?? "—")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Accessibility") {
                    if services.isAccessibilityGranted() {
                        StatusLabel(text: "Granted", isOK: true)
                    } else {
                        Button("Grant Access…") { services.requestAccessibility() }
                    }
                }
                LabeledContent("Configuration", value: live.status?.configFile.replacing(NSHomeDirectory(), with: "~") ?? ConfigPaths.mainFile.path)
                LabeledContent("Sockets", value: live.status?.socketDirectory ?? "—")
                Button("Show the Welcome Tour") { showWelcome() }
                    .buttonStyle(.link)
            }
            Card(title: "Command Line", symbol: "terminal") {
                Text("The moss command runs actions and answers questions, for scripts, launchers and status bars:")
                    .font(.callout)
                Text("moss workspace 2\nmoss --json windows\nmoss events")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
        }
    }
}

import Foundation
