public import MossCore
public import MossConfig
import MossIPC
public import Foundation
import os

/// Runs the window manager: feeds platform and input events into the `World`, executes
/// actions, and reconciles windows, focus and decorations with the resulting state.
@EngineActor
public final class WindowManager {
    public internal(set) var world = World()
    public internal(set) var configuration = EvaluatedConfig()

    let windowSystem: any WindowSystem
    let input: any InputSystem
    let decorations: any DecorationSystem
    let notices: any NoticeSystem
    let store: ConfigurationStore
    let commands: any CommandRunner
    let publish: @Sendable ([Event]) -> Void
    /// Where window placements are kept between runs, if anywhere.
    let sessionFile: URL?
    var sessionSaveGeneration = 0

    /// Called when an action asks Moss to quit.
    public var onExit: (@Sendable () -> Void)?
    /// Opens one of the interfaces the application draws, such as the palette.
    public var onShow: (@Sendable (Action.Surface) -> Void)?
    /// Called when a tiled window took focus, so Moss's own windows can stay in front of it.
    public var onTileFocused: (@Sendable () -> Void)?

    // Reconciliation bookkeeping.
    /// The frames last requested from the window system.
    var appliedFrames: [WindowID: Rect] = [:]
    /// The frames last reported by the window system.
    var observedFrames: [WindowID: Rect] = [:]
    /// Windows their applications keep at another size than their tiles, and where they go instead.
    var fittedFrames: [WindowID: FittedFrame] = [:]
    /// Tiles offered once more to windows that reported another size, before they are fitted.
    var fitOffers: [WindowID: Rect] = [:]
    var appliedFocus: WindowID?
    /// The workspaces and scratchpads last shown.
    var appliedWorkspaces: Set<WorkspaceID> = []
    /// Windows out of sight whose focus is followed after waiting to see whether the window
    /// that had focus closed.
    var followedFocus: Set<WindowID> = []
    /// Windows of hidden workspaces waiting to be parked again.
    var pendingReparks: Set<WindowID> = []
    /// Windows Moss recently asked the system to focus, also only to bring them forward,
    /// with when: a late report of one taking focus is not to be followed.
    var focusRequests: [WindowID: ContinuousClock.Instant] = [:]
    /// Windows last focused only to bring them forward, with when.
    var broughtForward: [WindowID: ContinuousClock.Instant] = [:]
    /// When the primary button last went down.
    var lastClick: ContinuousClock.Instant?
    var appliedMode: String?
    var pendingFocus: (window: WindowID, since: ContinuousClock.Instant)?
    /// Windows that opened without focus, which their applications are about to focus anyway,
    /// with when they opened.
    var declinedFocus: [WindowID: ContinuousClock.Instant] = [:]
    var appliedDecorations: [WindowDecoration] = []
    var lastArrangement: Arrangement?
    lazy var animator = FrameAnimator { [weak self] frames in self?.animationStep(frames) }

    /// Windows set aside while minimized, in native fullscreen or while their application is hidden.
    var dormant: [WindowID: DormantWindow] = [:]
    /// Windows that made themselves cover a whole display, as video players do for fullscreen.
    var coveringWindows: Set<WindowID> = []
    /// Windows their application closed for a fullscreen window of its own, kept for the
    /// window it opens in their place when fullscreen ends.
    var replacedByFullscreen: [WindowID: DormantWindow] = [:]
    /// A tiled window being dragged by its title bar or resized by its edges.
    var userDrag: (window: WindowID, resized: Bool)?
    /// A floating window the user is moving by its title bar.
    var floatingDrag: WindowID?
    /// Counts windows set aside, so they can come back in the order they left.
    var dormantOrder = 0
    /// Options changed with `moss set`, until the configuration is reloaded.
    var optionOverrides: [(option: OptionDescriptor, value: String)] = []
    /// When a window last went away. macOS activates some other application right after,
    /// which must not drag the user to that application's workspace.
    var lastDeparture: ContinuousClock.Instant?
    var lastScrollBinding: ContinuousClock.Instant?
    /// A workspace switch that followed an application's activation. If that application opens
    /// a new window right after, the user was launching something, not switching to it.
    var activationSwitch: (pid: Int32, from: WorkspaceID, at: ContinuousClock.Instant)?
    var hasStarted = false
    /// Set once shutdown begins; platform and input events are ignored from then on.
    var isStopping = false
    /// While paused, Moss keeps track of windows but leaves them where they are.
    public internal(set) var isPaused = false
    /// A message set with `moss error`, shown instead of configuration errors until a reload.
    var customError: ErrorBar?
    var appliedErrorBar: (bar: ErrorBar, area: Rect)?
    var appliedDropTarget: Rect?
    /// Windows whose frame is checked against their tile once it settles.
    var pendingSettleChecks: Set<WindowID> = []
    /// How far a window's own frame may differ from its tile while still counting as filling it,
    /// as when a terminal rounds its size to whole lines.
    static let fillTolerance: Double = 40

    public init(
        windowSystem: any WindowSystem,
        input: any InputSystem,
        decorations: any DecorationSystem,
        notices: any NoticeSystem,
        store: ConfigurationStore,
        commands: any CommandRunner = ShellCommandRunner(),
        sessionFile: URL? = nil,
        publish: @escaping @Sendable ([Event]) -> Void = { _ in }
    ) {
        self.windowSystem = windowSystem
        self.input = input
        self.decorations = decorations
        self.notices = notices
        self.store = store
        self.commands = commands
        self.sessionFile = sessionFile
        self.publish = publish
    }

    // MARK: - Lifecycle

    /// Loads the configuration, adopts existing windows and starts listening for events.
    public func start() async {
        try? store.createDefaultIfMissing()
        // Read before anything happens that would save over it.
        let session = loadSession()
        let before = world
        world.updateDisplays(windowSystem.displays())
        applyConfiguration(store.load(overrides: optionOverrides))

        windowSystem.start { [weak self] event in
            EngineActor.enqueue { self?.handle(event) }
        }
        do {
            try input.start { [weak self] event in
                EngineActor.enqueue { self?.handle(event) }
            }
        } catch {
            appendDiagnostic("input monitoring could not start: \(error)")
        }

        // Behind a locked screen no window can be found, and the session would be restored,
        // and then saved, without any.
        await windowSystem.waitUntilUnlocked()
        for snapshot in await windowSystem.discoverWindows() { adoptExisting(snapshot) }
        if let session { world.restore(session) }
        // Windows of hidden applications wait outside the layout until they are shown.
        let hidden = windowSystem.hiddenApplications()
        for window in world.windows.values where hidden.contains(window.properties.pid) { setAside(window.id) }
        world.cursor = windowSystem.cursorLocation()
        hasStarted = true
        commit(from: before)

        // Started last, so the windows they open arrive as new windows and get their rules.
        for command in configuration.startup { runConfigured(command) }
    }

    /// Manages a window that was already open when Moss started.
    func adoptExisting(_ snapshot: WindowSnapshot) {
        observedFrames[snapshot.id] = snapshot.frame
        var frame = snapshot.frame
        if HiddenPlacement.isParked(frame, in: world.monitors.map(\.frame)), let monitor = world.focusedMonitor {
            // Left in a corner by a previous session: bring it back.
            frame = monitor.usableFrame.centered(snapshot.frame.size)
        }
        world.addWindow(snapshot.id, properties: snapshot.properties, frame: frame, origin: .existing)
        if snapshot.isFullscreen { enterFullscreen(snapshot.id, ownSpace: true) }
    }

    /// Restores every window to a visible position and stops managing them.
    public func shutdown() async {
        // Events from here on describe the restoration below, not anything to react to.
        isStopping = true
        for command in configuration.shutdown { commands.run(command, environment: environment) }
        animator.cancelAll()
        saveSession()
        input.stop()
        store.stopWatching()
        decorations.update([])
        notices.dismiss(oldest: nil)
        notices.showErrorBar(nil, within: .zero)

        var frames = unparkedFrames()
        for window in world.windows.values where window.fullscreen == .fullscreen && frames[window.id] == nil {
            // Fullscreen covers bars Moss makes room for; without Moss, it would hide them.
            if let monitor = world.monitor(of: window.id) { frames[window.id] = monitor.usableFrame }
        }
        windowSystem.setFrames(frames)
        await windowSystem.drain()
        windowSystem.stop()
    }

    /// Frames that bring every window parked in a corner back into the middle of its monitor,
    /// within the space left by menu and status bars.
    func unparkedFrames() -> [WindowID: Rect] {
        var frames: [WindowID: Rect] = [:]
        for (id, monitorID) in world.arrangement().hidden {
            guard let monitor = world.monitor(monitorID) else { continue }
            let area = monitor.usableFrame
            let size = observedFrames[id]?.size ?? appliedFrames[id]?.size ?? Size(width: 800, height: 600)
            frames[id] = area.centered(Size(width: min(size.width, area.width), height: min(size.height, area.height))).integral
        }
        return frames
    }

    /// Stops arranging windows, bringing every one into view where it is, or resumes.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        animator.cancelAll()
        if paused {
            windowSystem.setFrames(unparkedFrames())
            decorations.update([])
            decorations.showDropTarget(nil, below: nil)
            appliedDecorations = []
            appliedDropTarget = nil
            userDrag = nil
            post(Notice(icon: .info, message: "Tiling paused", milliseconds: 2000))
        } else {
            // Every window may have moved since: send all frames again.
            appliedFrames.removeAll()
            post(Notice(icon: .ok, message: "Tiling resumed", milliseconds: 2000))
        }
        publish([.tilingPaused(paused)])
    }

    // MARK: - Configuration

    public func reloadConfiguration() {
        optionOverrides.removeAll()
        // A reload also clears a message shown with `moss error`.
        customError = nil
        let before = world
        applyConfiguration(store.load())
        commit(from: before, extraEvents: [.configReloaded])
    }

    /// As Hyper, Caps Lock also carries Moss's own `caps` shortcuts. Otherwise it is
    /// Moss's alone while a shortcut uses it, and left alone when none does.
    static func capsLockRole(for config: EvaluatedConfig) -> CapsLockRole {
        if config.settings.keyboard.capsLock == .hyper { return .hyper }
        return config.bindings.contains(where: { $0.modifiers.contains(.capsLock) }) ? .modifier : .unchanged
    }

    func applyConfiguration(_ config: EvaluatedConfig) {
        configuration = config
        world.configure(
            settings: config.settings,
            windowRules: config.windowRules,
            workspaceRules: config.workspaceRules,
            monitorReservations: config.displayReservations,
            modes: config.modes
        )
        input.setBindings(config.bindings)
        // Caps Lock becomes a modifier of its own only while a shortcut uses it.
        input.setCapsLock(Self.capsLockRole(for: config))

        store.watch(config.files, patterns: config.filePatterns) { [weak self] in
            EngineActor.enqueue { self?.reloadConfiguration() }
        }
        appliedDecorations = []
        updateErrorBar()
    }

    // MARK: - Session

    private func loadSession() -> SessionState? {
        guard let sessionFile, let data = try? Data(contentsOf: sessionFile) else { return nil }
        do {
            return try JSONDecoder().decode(SessionState.self, from: data)
        } catch {
            Log.engine.error("could not restore the previous session: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func saveSession() {
        // Until the previous session is restored, there is nothing to save but a partial one.
        guard hasStarted, let sessionFile, let data = try? JSONEncoder().encode(world.sessionState()) else { return }
        try? data.write(to: sessionFile, options: .atomic)
    }

    /// Saves the session shortly after the last change, so a crash loses little.
    func scheduleSessionSave() {
        guard sessionFile != nil else { return }
        sessionSaveGeneration += 1
        let generation = sessionSaveGeneration
        Task { @EngineActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.sessionSaveGeneration == generation else { return }
            self.saveSession()
        }
    }

    var environment: [String: String] {
        Dictionary(configuration.environment.map { ($0.name, $0.value) }, uniquingKeysWith: { _, new in new })
    }

    /// Runs a startup command like the `run` action, so `[rules]` apply.
    private func runConfigured(_ command: String) {
        do {
            try perform(.run(command))
        } catch {
            appendDiagnostic("startup command \(command): \(error)")
        }
    }

    func appendDiagnostic(_ message: String) {
        configuration.diagnostics.append(Diagnostic(.error, message, at: SourceLocation(file: nil, line: 0)))
        updateErrorBar()
    }

    public func perform(_ action: Action) throws(ActionError) {
        if isPaused, action.arrangesWindows { throw .tilingPaused }
        let before = world
        let effects = try world.perform(action)
        commit(from: before, effects: effects)
    }
}
