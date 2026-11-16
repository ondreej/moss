import Foundation
import Synchronization
@testable public import MossCore
@testable public import MossRuntime

/// An in-memory window system that applies frames instantly and records requests.
final class FakeWindowSystem: WindowSystem, @unchecked Sendable {
    struct State {
        var windows: [WindowID: WindowSnapshot] = [:]
        var frameRequests: [[WindowID: Rect]] = []
        var focused: [WindowID] = []
        /// Windows focused without being raised, left where they are in the stacking order.
        var focusedInPlace: Set<WindowID> = []
        var broughtForward: [[WindowID]] = []
        var desktopFocused = 0
        var closed: [WindowID] = []
        var cursor = Point(x: 0, y: 0)
        var primaryButtonDown = false
        var isStopped = false
        var signals: [(pid: Int32, signal: Int32)] = []
        var hiddenApplications: Set<Int32> = []
    }

    let state = Mutex(State())
    let sink = EventSink<PlatformEvent>()
    var displayList: [DisplayDescription]

    init(displays: Int = 1, windows: [WindowSnapshot] = []) {
        displayList = (0..<displays).map { index in
            DisplayDescription(
                id: MonitorID(UInt32(index + 1)),
                name: "Display \(index + 1)",
                frame: Rect(x: Double(index) * 1000, y: 0, width: 1000, height: 600),
                visibleFrame: Rect(x: Double(index) * 1000, y: 0, width: 1000, height: 600),
                isMain: index == 0
            )
        }
        state.withLock { state in
            for window in windows { state.windows[window.id] = window }
        }
    }

    var isTrusted: Bool { true }
    func start(sink: @escaping @Sendable (PlatformEvent) -> Void) { self.sink.connect(sink) }

    /// Like the real window system, a stopped one moves no windows.
    func stop() {
        sink.disconnect()
        state.withLock { $0.isStopped = true }
    }

    func displays() -> [DisplayDescription] { displayList }
    func discoverWindows() async -> [WindowSnapshot] { state.withLock { Array($0.windows.values).sorted { $0.id < $1.id } } }
    func hiddenApplications() -> Set<Int32> { state.withLock(\.hiddenApplications) }

    func setFrames(_ frames: [WindowID: Rect]) {
        state.withLock { state in
            guard !state.isStopped else { return }
            state.frameRequests.append(frames)
            for (id, frame) in frames { state.windows[id]?.frame = frame }
        }
    }

    func drain() async {}
    func focus(_ window: WindowID, raise: Bool) { state.withLock { $0.recordFocus(window, raise: raise) } }
    func focusDesktop() { state.withLock { $0.desktopFocused += 1 } }
    func focus(_ window: WindowID, raise: Bool, after others: [WindowID]) {
        state.withLock { state in
            state.broughtForward.append(others)
            state.recordFocus(window, raise: raise)
        }
    }
    func close(_ window: WindowID) { state.withLock { $0.closed.append(window) } }
    func terminate(pid: Int32) {}
    func signal(pid: Int32, _ signal: Int32) { state.withLock { $0.signals.append((pid, signal)) } }
    func cursorLocation() -> Point { state.withLock(\.cursor) }
    func warpCursor(to point: Point) { state.withLock { $0.cursor = point } }
    func isPrimaryButtonDown() -> Bool { state.withLock(\.primaryButtonDown) }

    func topmostWindow(at point: Point) -> WindowID? {
        state.withLock { state in state.windows.values.first { $0.frame.contains(point) }?.id }
    }

    func frame(of id: WindowID) -> Rect? { state.withLock { $0.windows[id]?.frame } }
    var lastFocused: WindowID? { state.withLock(\.focused.last) }
    /// Whether the last focus request left the window where it was in the stacking order.
    var lastFocusLeftInPlace: Bool { state.withLock { $0.focused.last.map($0.focusedInPlace.contains) ?? false } }
    var focusRequests: [WindowID] { state.withLock(\.focused) }
    var broughtForward: [[WindowID]] { state.withLock(\.broughtForward) }
    var desktopFocusCount: Int { state.withLock(\.desktopFocused) }
    var frameRequestCount: Int { state.withLock(\.frameRequests.count) }

    /// Simulates the user moving or resizing a window: the system frame changes, then the event arrives.
    func userChanged(_ id: WindowID, to frame: Rect) -> PlatformEvent {
        state.withLock { $0.windows[id]?.frame = frame }
        return .windowFrameChanged(id, frame)
    }

    /// Simulates a window opening: the system knows about it before the event is delivered.
    func open(_ window: WindowSnapshot) -> PlatformEvent {
        state.withLock { $0.windows[window.id] = window }
        return .windowAppeared(window)
    }
    func setPrimaryButton(down: Bool) { state.withLock { $0.primaryButtonDown = down } }
}

final class FakeInputSystem: InputSystem, @unchecked Sendable {
    let bindings = Mutex<[KeyBinding]>([])
    let mode = Mutex<String?>(nil)

    func start(sink: @escaping @Sendable (InputEvent) -> Void) throws {}
    func stop() {}
    func setBindings(_ bindings: [KeyBinding]) { self.bindings.withLock { $0 = bindings } }
    func setMode(_ name: String?) { mode.withLock { $0 = name } }
    let capsLock = Mutex(CapsLockRole.unchanged)
    func setCapsLock(_ role: CapsLockRole) { capsLock.withLock { $0 = role } }
    var capsLockRole: CapsLockRole { capsLock.withLock { $0 } }
    let sent = Mutex<[(chord: KeyChord, pid: Int32?)]>([])
    func send(_ chord: KeyChord, to pid: Int32?) { sent.withLock { $0.append((chord, pid)) } }
    var current: [KeyBinding] { bindings.withLock { $0 } }
}

final class FakeDecorations: DecorationSystem, @unchecked Sendable {
    let current = Mutex<[WindowDecoration]>([])
    func update(_ decorations: [WindowDecoration]) { current.withLock { $0 = decorations } }
    let dropTargets = Mutex<[Rect?]>([])
    func showDropTarget(_ frame: Rect?, below window: WindowID?) { dropTargets.withLock { $0.append(frame) } }
    let restacks = Mutex(0)
    func restack() { restacks.withLock { $0 += 1 } }
    var restackCount: Int { restacks.withLock { $0 } }
    var lastDropTarget: Rect?? { dropTargets.withLock(\.last) }
    var all: [WindowDecoration] { current.withLock { $0 } }
}

final class FakeNotices: NoticeSystem, @unchecked Sendable {
    struct State {
        var posted: [Notice] = []
        var areas: [Rect] = []
        var errorBar: ErrorBar?
        var dismissals: [Int?] = []
        var workspaceHUDs: [WorkspaceHUD] = []
    }

    let state = Mutex(State())
    func post(_ notice: Notice, within area: Rect) {
        state.withLock { state in
            state.posted.append(notice)
            state.areas.append(area)
        }
    }
    func dismiss(oldest count: Int?) { state.withLock { $0.dismissals.append(count) } }
    func showErrorBar(_ bar: ErrorBar?, within area: Rect) { state.withLock { $0.errorBar = bar } }
    func showWorkspaces(_ hud: WorkspaceHUD, within area: Rect) { state.withLock { $0.workspaceHUDs.append(hud) } }
    var workspaceHUDs: [WorkspaceHUD] { state.withLock(\.workspaceHUDs) }
    var errorBar: ErrorBar? { state.withLock(\.errorBar) }
    var posted: [Notice] { state.withLock(\.posted) }
    var areas: [Rect] { state.withLock(\.areas) }
}

final class RecordingRunner: CommandRunner, @unchecked Sendable {
    let commands = Mutex<[String]>([])
    func run(_ command: String, environment: [String: String]) { commands.withLock { $0.append(command) } }
    var all: [String] { commands.withLock { $0 } }
}

final class EventLog: @unchecked Sendable {
    let events = Mutex<[Event]>([])
    func record(_ new: [Event]) { events.withLock { $0.append(contentsOf: new) } }
    var all: [Event] { events.withLock { $0 } }
}

func snapshot(_ id: UInt32, app: String = "com.example.app", frame: Rect = Rect(x: 100, y: 100, width: 400, height: 300)) -> WindowSnapshot {
    WindowSnapshot(id: WindowID(id), properties: WindowProperties(appID: app, appName: "App", title: "Window \(id)", pid: Int32(id)), frame: frame)
}

/// A temporary configuration file.
func configurationFile(_ text: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moss-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("moss.toml")
    try text.write(to: file, atomically: true, encoding: .utf8)
    return file
}

/// A window manager wired to fakes.
@EngineActor
struct Harness {
    let manager: WindowManager
    let system: FakeWindowSystem
    let input: FakeInputSystem
    let decorations: FakeDecorations
    let notices: FakeNotices
    let runner: RecordingRunner
    let events: EventLog
    let file: URL

    init(
        config: String = "[layout]\ngaps = 0\nmargins = 0\n\n[borders]\nwidth = 0\n",
        animations: Bool = false,
        displays: Int = 1,
        windows: [WindowSnapshot] = [],
        hiddenApplications: Set<Int32> = []
    ) async throws {
        system = FakeWindowSystem(displays: displays, windows: windows)
        system.state.withLock { $0.hiddenApplications = hiddenApplications }
        input = FakeInputSystem()
        decorations = FakeDecorations()
        notices = FakeNotices()
        runner = RecordingRunner()
        events = EventLog()
        // Keys outside any table come first in a TOML file.
        file = try configurationFile((animations ? "" : "animation.enabled = false\n") + config)
        let log = events
        manager = WindowManager(
            windowSystem: system,
            input: input,
            decorations: decorations,
            notices: notices,
            store: ConfigurationStore(mainFile: file),
            commands: runner,
            publish: { log.record($0) }
        )
        await manager.start()
    }
}

extension FakeWindowSystem.State {
    mutating func recordFocus(_ window: WindowID, raise: Bool) {
        focused.append(window)
        if raise { focusedInPlace.remove(window) } else { focusedInPlace.insert(window) }
    }
}
