public import SwiftUI

/// Hooks into the hosting application that the settings interface needs.
public struct SettingsServices {
    /// Suspends key bindings, e.g. while the user records a new shortcut.
    public var setBindingsPaused: @MainActor (Bool) -> Void
    public var isAccessibilityGranted: @MainActor () -> Bool
    public var requestAccessibility: @MainActor () -> Void
    public var startsAtLogin: @MainActor () -> Bool
    public var setStartsAtLogin: @MainActor (Bool) -> Void

    public init(
        setBindingsPaused: @escaping @MainActor (Bool) -> Void = { _ in },
        isAccessibilityGranted: @escaping @MainActor () -> Bool = { true },
        requestAccessibility: @escaping @MainActor () -> Void = {},
        startsAtLogin: @escaping @MainActor () -> Bool = { false },
        setStartsAtLogin: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.setBindingsPaused = setBindingsPaused
        self.isAccessibilityGranted = isAccessibilityGranted
        self.requestAccessibility = requestAccessibility
        self.startsAtLogin = startsAtLogin
        self.setStartsAtLogin = setStartsAtLogin
    }
}

extension EnvironmentValues {
    @Entry var services = SettingsServices()
    /// Opens the first-launch tour again.
    @Entry var showWelcome = ShowWelcomeAction()
}

struct ShowWelcomeAction {
    var action: @MainActor () -> Void = {}

    @MainActor func callAsFunction() { action() }
}

public enum SettingsPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview, general, appearance, layouts, input, keybindings, windowRules, workspaces, configuration, about

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .general: "General"
        case .appearance: "Appearance"
        case .layouts: "Layouts"
        case .input: "Focus & Input"
        case .keybindings: "Shortcuts"
        case .windowRules: "Window Rules"
        case .workspaces: "Workspaces"
        case .configuration: "Configuration File"
        case .about: "About"
        }
    }

    /// Extra words the search finds the page by.
    var keywords: String {
        switch self {
        case .overview: "status desktop displays monitors windows"
        case .general: "gaps spacing layout startup login floating snap"
        case .appearance: "borders colors colours accent rounding corners dimming animations"
        case .layouts: "split stack scrolling columns main ratio side tabs"
        case .input: "mouse cursor follow focus scratchpads fullscreen displays"
        case .keybindings: "shortcuts keys hotkeys keybindings main key mod modes mouse"
        case .windowRules: "rules float workspace app application title"
        case .workspaces: "displays persistent names scratchpads"
        case .configuration: "file errors source text raw options"
        case .about: "version permissions accessibility"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .general: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .layouts: "rectangle.split.3x1"
        case .input: "cursorarrow.motionlines"
        case .keybindings: "keyboard"
        case .windowRules: "macwindow.badge.plus"
        case .workspaces: "square.stack.3d.up"
        case .configuration: "doc.text"
        case .about: "info.circle"
        }
    }
}

/// The settings window.
public struct SettingsView: View {
    @State private var store: SettingsStore
    @State private var live: LiveState
    @Binding private var page: SettingsPage
    @State private var search = ""
    private let services: SettingsServices

    public init(store: SettingsStore, live: LiveState, page: Binding<SettingsPage>, services: SettingsServices) {
        _store = State(initialValue: store)
        _live = State(initialValue: live)
        _page = page
        self.services = services
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsPage?>(get: { page }, set: { if let value = $0 { page = value } })) {
                Section {
                    row(.overview)
                }
                Section("Tiling") {
                    row(.general)
                    row(.appearance)
                    row(.layouts)
                }
                Section("Control") {
                    row(.input)
                    row(.keybindings)
                }
                Section("Rules") {
                    row(.windowRules)
                    row(.workspaces)
                }
                Section {
                    row(.configuration)
                    row(.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                detail
                    .navigationTitle(page.title)
            } else {
                SearchPage(query: search) { found in
                    page = found
                    search = ""
                }
                .navigationTitle("Search")
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Search settings")
        .environment(store)
        .environment(live)
        .environment(\.services, services)
        .onAppear { live.start() }
    }

    private func row(_ page: SettingsPage) -> some View {
        Label {
            HStack {
                Text(page.title)
                Spacer()
                if page == .configuration, !store.errors.isEmpty {
                    Text("\(store.errors.count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.red, in: .capsule)
                        .foregroundStyle(.white)
                }
            }
        } icon: {
            Image(systemName: page.symbol)
        }
        .tag(page)
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .overview: OverviewPage(page: $page)
        case .general: GeneralPage()
        case .appearance: AppearancePage()
        case .layouts: LayoutsPage()
        case .input: InputPage()
        case .keybindings: KeybindingsPage()
        case .windowRules: WindowRulesPage()
        case .workspaces: WorkspacesPage()
        case .configuration: ConfigurationPage()
        case .about: AboutPage()
        }
    }
}
