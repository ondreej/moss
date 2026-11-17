import AppKit
import MossConfig
import MossCore
import MossPlatform
import MossRuntime
import MossSettings

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = AppController()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let palettePanel = PalettePanel()
    private var permissionTimer: Timer?
    private var terminationSignals: [any DispatchSourceSignal] = []
    /// What the menu bar shows: the active workspace, or that tiling is paused.
    private var workspaceName = "1"
    private var isTilingPaused = false
    private lazy var settings = SettingsWindowController(
        services: SettingsServices(
            setBindingsPaused: { [weak self] paused in self?.controller.setBindingsPaused(paused) },
            isAccessibilityGranted: { AccessibilityPermission.isGranted },
            requestAccessibility: {
                AccessibilityPermission.request()
                AccessibilityPermission.openSettings()
            },
            startsAtLogin: { LoginItem.isEnabled },
            setStartsAtLogin: { LoginItem.isEnabled = $0 }
        )
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let isFirstLaunch = !FileManager.default.fileExists(atPath: controller.store.mainFile.path)
        try? controller.store.createDefaultIfMissing()

        installStatusItem()
        quitOnTerminationSignals()
        controller.onEvents = { [weak self] events in
            Task { @MainActor in self?.handle(events) }
        }
        controller.onTileFocused = { [weak self] in self?.settings.keepInFront() }
        controller.onStartAtLogin = { change in LoginItem.isEnabled = change.apply(to: LoginItem.isEnabled) }
        controller.onShow = { [weak self] surface in
            switch surface {
            case .palette: self?.showPaletteFromKeyboard()
            case .overview: self?.showOverview(step: 1)
            case .overviewPrevious: self?.showOverview(step: -1)
            }
        }

        if AccessibilityPermission.isGranted {
            Task { await controller.start() }
        } else {
            AccessibilityPermission.request()
            waitForPermission()
        }
        if isFirstLaunch {
            settings.showWelcome()
        } else if !AccessibilityPermission.isGranted {
            settings.show(.overview)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settings.store.save()
        guard controller.isRunning else { return .terminateNow }
        Task {
            await controller.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Moss also becomes active for a moment to pass focus between windows of another app.
        guard !FocusRelay.isPassing else { return }
        settings.applicationDidBecomeActive()
    }

    /// Asked to stop by `kill` or at logout, Moss quits as usual, bringing back the windows
    /// of hidden workspaces.
    private func quitOnTerminationSignals() {
        terminationSignals = [SIGTERM, SIGINT, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { AppController.terminate() }
            source.resume()
            return source
        }
    }

    /// Starts the window manager as soon as Accessibility access is granted.
    private func waitForPermission() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard AccessibilityPermission.isGranted, let self else { return }
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                Task { await self.controller.start() }
            }
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true

        statusItem = item
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        if isTilingPaused {
            button.title = ""
            button.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Tiling paused")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.toolTip = "Tiling is paused"
        } else {
            button.title = workspaceName
            button.image = nil
            button.toolTip = "Workspace \(workspaceName)"
        }
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPalette()
        }
    }

    private func showPalette() {
        guard let button = statusItem?.button else { return }
        // A fresh palette each time, starting with an empty search.
        popover.contentViewController = settings.makeMenuBarPanel(
            close: { [weak self] in self?.popover.performClose(nil) },
            quit: { AppController.terminate() }
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Opens the palette for typing in the middle of the screen; pressed again, closes it.
    private func showPaletteFromKeyboard() {
        if popover.isShown || palettePanel.isShown {
            popover.performClose(nil)
            palettePanel.close()
            return
        }
        let content = settings.makeMenuBarPanel(
            floating: true,
            close: { [weak self] in self?.palettePanel.close() },
            quit: { AppController.terminate() }
        )
        palettePanel.show(content)
    }

    /// Shows every workspace; dismissed without choosing, focus goes back where it was.
    private func showOverview(step: Int) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let previous = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        settings.showOverview(step: step) { chose in
            if !chose { previous?.activate() }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r").target = self
        menu.addItem(withTitle: isTilingPaused ? "Resume Tiling" : "Pause Tiling", action: #selector(togglePause), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Configuration File", action: #selector(openConfiguration), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Moss", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func handle(_ events: [Event]) {
        for event in events {
            switch event {
            case .workspaceShown(_, let name, _): workspaceName = name
            case .tilingPaused(let paused): isTilingPaused = paused
            default: continue
            }
            updateStatusButton()
        }
    }

    @objc private func openSettings() { settings.show() }
    @objc private func reload() { controller.reload() }
    @objc private func togglePause() { controller.togglePause() }

    @objc private func openConfiguration() {
        NSWorkspace.shared.open(controller.store.mainFile)
    }
}
