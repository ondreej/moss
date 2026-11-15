import AppKit
import MossIPC
import SwiftUI

/// The highlighted workspace of an open overview, which its shortcut can move from outside:
/// pressing the shortcut again while its keys are held steps to the next workspace, and letting
/// go goes there, as Command-Tab does for applications.
@MainActor
@Observable
final class OverviewSelection {
    var index = 0
    /// Asks the overview to go to the highlighted workspace.
    fileprivate(set) var goRequests = 0
    fileprivate var count = 0

    /// Moves the highlight, wrapping around at either end.
    func step(_ delta: Int) {
        guard count > 0 else { return }
        index = ((index + delta) % count + count) % count
    }

    func goToSelection() { goRequests += 1 }
}

/// Every workspace at a glance: each one a miniature of its monitor with its windows where they
/// are laid out. Arrow keys or a digit choose a workspace, Return goes there, Escape closes;
/// clicking a window focuses it.
struct WorkspaceOverview: View {
    let selected: OverviewSelection
    /// Closes the overview; `true` when the user chose where to go.
    let close: (_ chose: Bool) -> Void
    @Environment(LiveState.self) private var live
    @FocusState private var isFocused: Bool

    private var selection: Int {
        get { selected.index }
        nonmutating set { selected.index = newValue }
    }

    var body: some View {
        let cards = Self.cards(from: live)
        GeometryReader { proxy in
            let columns = max(1, min(cards.count, cards.count <= 4 ? cards.count : 3))
            let rows = CGFloat((cards.count + columns - 1) / columns)
            let aspect = cards.first.map { $0.display.frame.height / max(1, $0.display.frame.width) } ?? 0.625
            // Every row fits between the top, clear of menu and status bars, and the hints below.
            let byHeight = ((proxy.size.height - 220 - (rows - 1) * 30) / max(1, rows) - 32) / aspect
            let width = max(80, min(380, (proxy.size.width - 120 - CGFloat(columns - 1) * 28) / CGFloat(columns), byHeight))
            ZStack {
                // The desktop shows through, a little darker, so the cards stand out from it.
                Color.black.opacity(0.3)
                    .contentShape(.rect)
                    .onTapGesture { close(false) }
                VStack(spacing: 28) {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 28), count: columns), spacing: 30) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            WorkspaceCard(card: card, width: width, isSelected: index == selection, isCurrent: card.workspace.isFocused) {
                                go(to: card)
                            } focusWindow: { window in
                                choose("focus-window id:\(window.id)")
                            }
                            .onHover { if $0 { selection = index } }
                        }
                    }
                    HStack(spacing: 18) {
                        hint(["←", "→"], "Choose")
                        hint(["↩"], "Go")
                        hint(["esc"], "Close")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: .capsule)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            selected.count = cards.count
            selection = cards.firstIndex { $0.workspace.isFocused } ?? 0
        }
        .onChange(of: cards.count) { _, count in selected.count = count }
        .onChange(of: selected.goRequests) {
            if cards.indices.contains(selection) { go(to: cards[selection]) }
        }
        .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in
            selected.step(-1)
            return .handled
        }
        .onKeyPress(keys: [.rightArrow, .downArrow, .tab]) { _ in
            selected.step(1)
            return .handled
        }
        .onKeyPress(.return) {
            if cards.indices.contains(selection) { go(to: cards[selection]) }
            return .handled
        }
        .onKeyPress(.escape) {
            close(false)
            return .handled
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let number = Int(press.characters), let card = cards.first(where: { $0.workspace.number == (number == 0 ? 10 : number) }) else { return .ignored }
            go(to: card)
            return .handled
        }
    }

    private func hint(_ keys: [String], _ title: String) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { KeyCap(text: $0, compact: true) }
            Text(title).font(.callout)
        }
    }

    private func go(to card: OverviewCard) {
        choose("workspace \(card.workspace.workspace)")
    }

    private func choose(_ request: String) {
        close(true)
        Task { await live.send(request) }
    }

    /// One card per workspace, with the display it is on and its windows, front to back.
    static func cards(from live: LiveState) -> [OverviewCard] {
        live.workspaces
            .filter { !$0.isScratchpad }
            .compactMap { workspace -> OverviewCard? in
                guard let display = live.displays.first(where: { $0.name == workspace.display }) ?? live.displays.first else { return nil }
                var seen: Set<FrameInfo> = []
                // Tabs share their tile: show only the most recently focused.
                let windows = live.windows
                    .filter { $0.workspace == workspace.workspace }
                    .sorted { ($0.focusOrder ?? .max) < ($1.focusOrder ?? .max) }
                    .filter { seen.insert($0.frame).inserted }
                    .reversed()
                return OverviewCard(workspace: workspace, display: display, windows: Array(windows))
            }
            .sorted { ($0.display.frame.x, $0.workspace.number ?? .max, $0.workspace.workspace) < ($1.display.frame.x, $1.workspace.number ?? .max, $1.workspace.workspace) }
    }
}

struct OverviewCard: Identifiable {
    let workspace: WorkspaceInfo
    let display: DisplayInfo
    /// Back to front.
    let windows: [WindowInfo]

    var id: String { workspace.workspace }
}

private struct WorkspaceCard: View {
    let card: OverviewCard
    let width: CGFloat
    let isSelected: Bool
    let isCurrent: Bool
    let go: () -> Void
    let focusWindow: (WindowInfo) -> Void

    var body: some View {
        let display = card.display
        let scale = width / max(1, display.frame.width)
        let height = display.frame.height * scale
        VStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Wallpaper()
                    .frame(width: width, height: height)
                    .clipped()
                ForEach(card.windows) { window in
                    WindowTile(window: window)
                        .frame(width: max(8, window.frame.width * scale), height: max(8, window.frame.height * scale))
                        .offset(x: (window.frame.x - display.frame.x) * scale, y: (window.frame.y - display.frame.y) * scale)
                        .onTapGesture { focusWindow(window) }
                        .help("\(window.app) — \(window.title)")
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.white.opacity(0.3)), lineWidth: isSelected ? 3 : 1)
            }
            .shadow(color: .black.opacity(isSelected ? 0.35 : 0.2), radius: isSelected ? 18 : 10, y: 6)
            .contentShape(.rect)
            .onTapGesture(perform: go)

            HStack(spacing: 8) {
                if isCurrent {
                    Circle().fill(Design.accent).frame(width: 7, height: 7)
                }
                Text(card.workspace.name).font(.headline).monospacedDigit()
                let count = card.workspace.windows
                Text(count == 0 ? "Empty" : "\(count) window\(count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .scaleEffect(isSelected ? 1.04 : 1)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

/// A window in the overview: a frosted rectangle with its application's icon.
private struct WindowTile: View {
    let window: WindowInfo

    var body: some View {
        GeometryReader { proxy in
            let side = min(40, min(proxy.size.width, proxy.size.height) * 0.45)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                VStack(spacing: 4) {
                    if let icon = NSRunningApplication(processIdentifier: window.pid)?.icon {
                        Image(nsImage: icon).resizable().frame(width: side, height: side)
                    }
                    if proxy.size.height > side + 30 {
                        Text(window.app)
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
    }
}
