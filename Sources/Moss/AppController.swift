import AppKit
import MossConfig
import MossCore
import MossIPC
import MossPlatform
import MossRuntime

/// Owns the running window manager and its sockets.
@MainActor
final class AppController {
    private(set) var manager: WindowManager?
    private var input: MacInputSystem?
    private var controlServer: ControlServer?
    private var eventServer: EventBroadcaster?
    private let paths = SocketPaths.standard
    let store = ConfigurationStore()
    var onEvents: (@Sendable ([Event]) -> Void)?
    /// Called when a binding asks for one of Moss's interfaces.
    var onShow: ((Action.Surface) -> Void)?
    /// Called when an action turns opening at login on or off.
    var onStartAtLogin: ((Action.Switch) -> Void)?
    /// Called when a tiled window took focus.
    var onTileFocused: (() -> Void)?

    var isRunning: Bool { manager != nil }

    /// Starts managing windows. Requires the Accessibility permission.
    func start() async {
        guard manager == nil else { return }
        let broadcaster = EventBroadcaster(url: paths.events)
        let observer = onEvents
        let windowSystem = MacWindowSystem()
        let input = MacInputSystem()
        self.input = input
        let decorations = BorderOverlays()
        try? paths.prepare()
        let manager = await WindowManager(
            windowSystem: windowSystem,
            input: input,
            decorations: decorations,
            notices: NoticeOverlays(),
            store: store,
            sessionFile: paths.directory.appendingPathComponent("session.json"),
            publish: { events in
                broadcaster.publish(events)
                observer?(events)
            }
        )
        self.manager = manager
        let show: @Sendable (Action.Surface) -> Void = { [weak self] surface in Task { @MainActor in self?.onShow?(surface) } }
        let tileFocused: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.onTileFocused?() } }
        let startAtLogin: @Sendable (Action.Switch) -> Void = { [weak self] change in Task { @MainActor in self?.onStartAtLogin?(change) } }
        await EngineActor.run {
            manager.onExit = { AppController.terminate() }
            manager.onShow = show
            manager.onStartAtLogin = startAtLogin
            manager.onTileFocused = tileFocused
        }

        do {
            try paths.prepare()
            let server = ControlServer(url: paths.control) { line in
                await manager.respond(to: line)
            }
            try server.start()
            try broadcaster.start()
            controlServer = server
            eventServer = broadcaster
        } catch {
            NSLog("Moss: could not open sockets: \(error)")
        }
        await manager.start()
    }

    func stop() async {
        controlServer?.stop()
        eventServer?.stop()
        await manager?.shutdown()
        manager = nil
    }

    /// Quits from anywhere. Termination waits in a loop of its own for the window manager to
    /// stop on the main actor, so it must not start inside a main-actor job, which would keep
    /// that work from ever running. A block run by the run loop is not such a job.
    nonisolated static func terminate() {
        RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// Lets keyboard shortcuts through untouched, e.g. while one is being recorded.
    func setBindingsPaused(_ paused: Bool) {
        input?.setPaused(paused)
    }

    func reload() {
        guard let manager else { return }
        Task { await manager.reloadConfiguration() }
    }

    /// Pauses tiling, or resumes it.
    func togglePause() {
        guard let manager else { return }
        Task { _ = await manager.respond(to: "pause") }
    }
}

extension EngineActor {
    /// Runs `body` on the engine and returns its result.
    static func run<T: Sendable>(_ body: @escaping @Sendable @EngineActor () -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: body()) }
        }
    }
}
