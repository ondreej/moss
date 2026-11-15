public import AppKit
import MossIPC
import os
import SwiftUI

/// Owns the settings window and the menu bar panel's content.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public let store: SettingsStore
    public let live: LiveState
    private let services: SettingsServices
    private var window: NSWindow?
    private var welcome: NSWindow?
    private var overview: NSPanel?
    private var overviewSelection = OverviewSelection()
    /// The overview's shortcut was pressed again while it was open.
    private var hasStepped = false
    private var heldKeysMonitors: [Any] = []
    private var selection = SelectionBox()
    /// The workspace the settings window belongs to, as written in actions: the one in use when
    /// it was last opened. Moss does not arrange its own windows, so the window follows
    /// workspaces itself, hiding while its workspace is not shown like any other window.
    private var home: String?
    /// The window is hidden because its workspace is not shown.
    private var isAway = false

    public init(store: SettingsStore = SettingsStore(), live: LiveState = LiveState(), services: SettingsServices) {
        self.store = store
        self.live = live
        self.services = services
    }

    /// Shows the settings window, optionally on a specific page, on the workspace in use.
    public func show(_ page: SettingsPage? = nil) {
        if let page { selection.page = page }
        if window == nil { window = makeWindow() }
        live.start()
        live.onUpdate = { [weak self] in self?.workspacesChanged() }
        // The live state can lag behind a workspace switch: ask afresh where the user is.
        home = nil
        isAway = false
        Task {
            await live.refresh()
            if home == nil, window?.isVisible == true { home = live.focusedWorkspace }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Keeps the settings window above the tiles, as a floating window, after a tile took focus.
    /// The tile keeps the keyboard; a click brings it to the settings window.
    public func keepInFront() {
        guard let window, window.isVisible, !isAway else { return }
        window.orderFrontRegardless()
    }

    /// Moss became active without being opened again, as some launchers do: a settings
    /// window hidden with its workspace comes to the workspace in use. Nothing happens when
    /// one of Moss's panels, such as the palette, is what became active.
    public func applicationDidBecomeActive() {
        guard isAway else { return }
        DispatchQueue.main.async { [self] in
            guard isAway, NSApp.keyWindow == nil else { return }
            show()
        }
    }

    /// Hides the settings window while its workspace is not shown, and shows it again after.
    private func workspacesChanged() {
        guard let window, let home else { return }
        let isHomeShown = live.workspaces.contains { $0.workspace == home && $0.isVisible }
        if !isHomeShown, window.isVisible {
            isAway = true
            window.orderOut(nil)
        } else if isHomeShown, isAway {
            isAway = false
            window.orderFront(nil)
        }
    }

    /// Shows every workspace over the screen with the cursor. `finished` learns whether the
    /// user chose somewhere to go.
    ///
    /// Shown again while it is open, as when its shortcut is pressed again with its keys still
    /// held, it highlights the workspace `step` away; letting go of the keys then goes there, as
    /// Command-Tab does.
    public func showOverview(step: Int = 1, finished: @escaping (_ chose: Bool) -> Void) {
        if overview != nil {
            overviewSelection.step(step)
            hasStepped = true
            return
        }
        live.start()
        Task { await live.refresh() }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let selection = OverviewSelection()
        overviewSelection = selection
        hasStepped = false
        let panel = KeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = NSHostingController(rootView: WorkspaceOverview(selected: selection) { [weak self, weak panel] chose in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel?.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { panel?.orderOut(nil) }
            }
            self?.overview = nil
            self?.stopWatchingHeldKeys()
            finished(chose)
        }.environment(live))
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        overview = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        watchHeldKeys()
    }

    /// The modifier keys held as the overview opened. Letting go of them after stepping goes to
    /// the highlighted workspace; letting go without stepping leaves the overview open.
    private func watchHeldKeys() {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let held = NSEvent.modifierFlags.intersection(relevant)
        Self.log.debug("overview opened holding \(held.rawValue, privacy: .public)")
        guard !held.isEmpty else { return }
        let released = { [weak self] (flags: NSEvent.ModifierFlags) in
            guard let self, flags.intersection(held).isEmpty else { return }
            Self.log.debug("overview keys released, stepped: \(self.hasStepped, privacy: .public)")
            stopWatchingHeldKeys()
            if hasStepped { overviewSelection.goToSelection() }
        }
        // The overview takes keys without making Moss the active application, so the keys
        // may be let go while another application is active: watch both.
        heldKeysMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                released(event.modifierFlags)
                return event
            },
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                MainActor.assumeIsolated { released(event.modifierFlags) }
            },
        ].compactMap { $0 }
    }

    private func stopWatchingHeldKeys() {
        heldKeysMonitors.forEach(NSEvent.removeMonitor)
        heldKeysMonitors = []
    }

    private static let log = Logger(subsystem: "app.moss", category: "overview")

    /// Shows the first-launch tour.
    public func showWelcome() {
        if welcome == nil {
            let view = WelcomeView { [weak self] openSettings in
                self?.welcome?.close()
                if openSettings { self?.show(.overview) }
            }
            .environment(store)
            .environment(\.services, services)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // Starting the window manager focuses a window; the tour stays in front of it.
            window.level = .floating
            window.setContentSize(window.contentViewController?.view.fittingSize ?? NSSize(width: 640, height: 560))
            window.center()
            welcome = window
        }
        NSApp.activate()
        welcome?.makeKeyAndOrderFront(nil)
    }

    /// The palette. In a popover it sits on the popover's material; `floating` on its own, for
    /// a `PalettePanel`.
    public func makeMenuBarPanel(floating: Bool = false, close: @escaping () -> Void, quit: @escaping () -> Void) -> NSViewController {
        let panel = MenuBarPanel(
            live: live,
            store: store,
            openSettings: { [weak self] page in self?.show(page) },
            close: close,
            quit: quit
        )
        let controller: NSViewController
        if floating {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            let hosting = NSHostingController(rootView: panel
                .background(.thickMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
                .clipShape(shape))
            hosting.sizingOptions = .preferredContentSize
            controller = hosting
        } else {
            let hosting = NSHostingController(rootView: panel)
            hosting.sizingOptions = .preferredContentSize
            controller = hosting
        }
        return controller
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRoot(store: store, live: live, selection: selection, services: services, showWelcome: { [weak self] in self?.showWelcome() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Moss"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 980, height: 700))
        window.minSize = NSSize(width: 820, height: 560)
        window.setFrameAutosaveName("MossSettings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    public func windowWillClose(_ notification: Notification) {
        store.save()
        home = nil
        isAway = false
    }
}

@MainActor
@Observable
final class SelectionBox {
    var page: SettingsPage = .overview
}

private struct SettingsRoot: View {
    let store: SettingsStore
    let live: LiveState
    @Bindable var selection: SelectionBox
    let services: SettingsServices
    let showWelcome: @MainActor () -> Void

    var body: some View {
        SettingsView(store: store, live: live, page: $selection.page, services: services)
            .environment(\.showWelcome, ShowWelcomeAction(action: showWelcome))
    }
}

/// A borderless panel that can take keyboard focus.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
