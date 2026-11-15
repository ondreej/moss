import AppKit
import MossConfig
import MossCore
import Foundation
import SwiftUI
import Testing
@testable import MossIPC
@testable import MossSettings

/// Renders every page and the menu bar panel against a running window manager's state. A view
/// that reads an environment object nobody provided crashes here instead of in the app.
@MainActor
@Suite("Rendering")
struct RenderingTests {
    let store: SettingsStore
    let live: LiveState

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moss-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(fileURL: directory.appendingPathComponent("moss.conf"))
        live = LiveState()
        live.apply(Self.connectedSnapshot())
    }

    /// What `moss --json` answers for a desktop with two windows.
    static func connectedSnapshot() -> LiveState.Snapshot {
        var world = World()
        world.updateDisplays([DisplayDescription(id: MonitorID(1), name: "Display", frame: Rect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: Rect(x: 0, y: 30, width: 1440, height: 870), isMain: true)])
        world.addWindow(WindowID(1), properties: WindowProperties(appID: "com.example.editor", appName: "Editor", title: "notes.txt", pid: 1), frame: Rect(x: 0, y: 0, width: 600, height: 400))
        world.addWindow(WindowID(2), properties: WindowProperties(appID: "com.example.browser", appName: "Browser", title: "Start", pid: 2), frame: Rect(x: 0, y: 0, width: 600, height: 400))
        let context = QueryContext(world: world)
        func query<T: Decodable>(_ command: ControlCommand, as type: T.Type) -> T {
            let json = QueryResponder.respond(to: command, json: true, context: context)
            return try! JSONDecoder().decode(T.self, from: Data(json.utf8))
        }
        return LiveState.Snapshot(
            displays: query(.displays, as: [DisplayInfo].self),
            workspaces: query(.workspaces, as: [WorkspaceInfo].self),
            windows: query(.windows, as: [WindowInfo].self),
            focusedWindow: query(.focused, as: WindowInfo.self),
            status: query(.status, as: StatusInfo.self)
        )
    }

    /// Lays the view out in an offscreen window and draws it, scroll views included.
    func render(_ view: some View, name: String? = nil, size: CGSize = CGSize(width: 980, height: 700)) -> NSImage? {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        // One appearance throughout, so text and backgrounds match.
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // With MOSS_SNAPSHOTS set to a directory, the rendered views are saved there for review.
        if let name, let directory = ProcessInfo.processInfo.environment["MOSS_SNAPSHOTS"],
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    @Test func menuBarPanel() {
        #expect(live.isConnected)
        #expect(render(MenuBarPanel(live: live, store: store, openSettings: { _ in }, quit: {}), name: "palette", size: CGSize(width: 420, height: 480)) != nil)
    }

    @Test(arguments: SettingsPage.allCases)
    func page(_ page: SettingsPage) {
        let view = SettingsView(store: store, live: live, page: .constant(page), services: SettingsServices())
        #expect(render(view, name: "page-\(page.rawValue)") != nil)
    }

    @Test(arguments: LayoutKind.allCases)
    func layoutsPage(_ layout: LayoutKind) throws {
        let option = try #require(OptionRegistry.option("layout.style"))
        store.set(option, to: layout.rawValue)
        let view = SettingsView(store: store, live: live, page: .constant(.layouts), services: SettingsServices())
        #expect(render(view, name: "layouts-\(layout.rawValue)", size: CGSize(width: 980, height: 1400)) != nil)
    }

    @Test(arguments: ["border", "margins", "workspace", "nothing matches this"])
    func search(_ query: String) {
        let view = SearchPage(query: query, open: { _ in }).environment(store).environment(live)
        #expect(render(view, name: "search-\(query.replacing(" ", with: "-"))") != nil)
    }

    @Test(arguments: [WelcomeView.Step.permission, .mainKey, .keys])
    func welcome(_ step: WelcomeView.Step) {
        let view = WelcomeView(startingAt: step) { _ in }.environment(store).environment(live)
        #expect(render(view, name: "welcome-\(step.rawValue)", size: CGSize(width: 640, height: 520)) != nil)
    }

    @Test func overview() {
        #expect(WorkspaceOverview.cards(from: live).map(\.workspace.workspace) == ["1"])
        let view = WorkspaceOverview(selected: OverviewSelection()) { _ in }.environment(live)
        #expect(render(view, name: "overview", size: CGSize(width: 1440, height: 900)) != nil)
    }
}
