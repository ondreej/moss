import os
import AppKit
public import MossCore
public import MossRuntime
import Synchronization

/// The macOS window system, driven through the accessibility API.
public final class MacWindowSystem: WindowSystem, @unchecked Sendable {
    private let agents = Mutex<[pid_t: AppAgent]>([:])
    private let owners = Mutex<[WindowID: pid_t]>([:])
    private let frontmost = Atomic<Int32>(0)
    /// Counts focus requests, so a newer one stops a sequence still under way.
    private let focusRequests = Atomic<Int>(0)
    private let displayCache = Mutex<[DisplayDescription]>([])
    private let sink = EventSink<PlatformEvent>()
    @MainActor private var observers: [any NSObjectProtocol] = []
    @MainActor private var reaper: Timer?
    @MainActor private lazy var desktopAnchor = DesktopAnchor()

    @MainActor
    public init() {
        displayCache.withLock { $0 = Self.currentDisplays() }
    }

    public var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: - Lifecycle

    public func start(sink: @escaping @Sendable (PlatformEvent) -> Void) {
        self.sink.connect(sink)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.observeWorkspace() } }
    }

    public func stop() {
        sink.disconnect()
        let all = agents.withLock { agents -> [AppAgent] in
            defer { agents.removeAll() }
            return Array(agents.values)
        }
        all.forEach { $0.stop() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let center = NSWorkspace.shared.notificationCenter
                self.observers.forEach { center.removeObserver($0); NotificationCenter.default.removeObserver($0) }
                self.observers.removeAll()
                self.reaper?.invalidate()
                self.reaper = nil
            }
        }
    }

    private func send(_ event: PlatformEvent) {
        sink.send(event)
    }

    private func log(_ message: String) {
        Log.platform.debug("\(message, privacy: .public)")
    }

    // MARK: - Applications

    /// The process identifier of the application a workspace notification is about.
    private static func pid(of note: Notification) -> pid_t? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
    }

    @MainActor
    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (pid_t) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let pid = Self.pid(of: note) else { return }
                MainActor.assumeIsolated { body(pid) }
            })
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] pid in
            // An application updated in place is often closed without notice and launched again.
            self?.reapEndedApplications()
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            self?.adopt(app, announce: true)
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] pid in
            self?.terminated(pid)
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
            self?.activated(app)
        }
        observe(NSWorkspace.didHideApplicationNotification) { [weak self] pid in
            self?.send(.applicationHidden(pid: pid, true))
        }
        observe(NSWorkspace.didUnhideApplicationNotification) { [weak self] pid in
            self?.send(.applicationHidden(pid: pid, false))
            self?.agent(for: pid)?.reportFocusedWindow()
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        })

        reaper = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reapEndedApplications()
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            activated(app)
        }
    }

    /// macOS posts screen-parameter changes for many reasons (applications activating, the Dock
    /// resizing); only actual changes to the displays are passed on.
    @MainActor
    private func displaysChanged() {
        let displays = Self.currentDisplays()
        let changed = displayCache.withLock { cache -> Bool in
            defer { cache = displays }
            return cache != displays
        }
        if changed { send(.displaysChanged(displays)) }
    }

    /// Applications can end without macOS saying so, as when one is closed to be updated, and
    /// their windows would keep their places in the layout. Checking that each managed
    /// application's process still runs lets them go.
    private func reapEndedApplications() {
        let pids = agents.withLock { Array($0.keys) }
        for pid in pids where kill(pid, 0) == -1 && errno == ESRCH {
            Log.platform.info("application \(pid) ended without notice")
            terminated(pid)
        }
    }

    private func terminated(_ pid: pid_t) {
        agents.withLock { $0.removeValue(forKey: pid) }?.stop()
        owners.withLock { $0 = $0.filter { $0.value != pid } }
        send(.applicationTerminated(pid: pid))
    }

    @MainActor
    private func activated(_ app: NSRunningApplication) {
        log("activated \(app.bundleIdentifier ?? "?") (\(app.processIdentifier))")
        frontmost.store(app.processIdentifier, ordering: .releasing)
        let agent = agent(for: app.processIdentifier) ?? adopt(app, announce: true)
        agent?.reportFocusedWindow()
    }

    private func agent(for pid: pid_t) -> AppAgent? { agents.withLock { $0[pid] } }

    /// System processes whose windows are part of the operating system's interface.
    private static let systemApplications: Set<String> = [
        "com.apple.notificationcenterui", "com.apple.controlcenter", "com.apple.dock", "com.apple.Spotlight",
        "com.apple.WindowManager", "com.apple.systemuiserver", "com.apple.loginwindow", "com.apple.screencaptureui",
        "com.apple.TextInputMenuAgent", "com.apple.TextInputSwitcher", "com.apple.wallpaper.agent", "com.apple.UserNotificationCenter",
        "com.apple.screensharing.agent", "com.apple.ScreenSharing.menuextra", "com.apple.AirPlayUIAgent", "com.apple.coreservices.uiagent",
    ]

    /// Starts managing an application's windows.
    @MainActor
    @discardableResult
    private func adopt(_ app: NSRunningApplication, announce: Bool) -> AppAgent? {
        let pid = app.processIdentifier
        guard app.activationPolicy != .prohibited, pid != getpid(), pid > 0,
              !Self.systemApplications.contains(app.bundleIdentifier ?? "") else { return nil }
        if let existing = agent(for: pid) { return existing }
        let agent = AppAgent(
            pid: pid,
            appID: app.bundleIdentifier ?? app.localizedName ?? "pid-\(pid)",
            appName: app.localizedName ?? app.bundleIdentifier ?? "",
            floatsWindows: app.activationPolicy == .accessory,
            isFrontmost: { [weak self] in self?.frontmost.load(ordering: .acquiring) == pid },
            emit: { [weak self] event in self?.route(event, from: pid) }
        )
        agents.withLock { $0[pid] = agent }
        if announce {
            Task { _ = await agent.attach(announce: true) }
        }
        return agent
    }

    private func route(_ event: PlatformEvent, from pid: pid_t) {
        switch event {
        case .windowAppeared(let snapshot), .windowDiscovered(let snapshot): owners.withLock { $0[snapshot.id] = pid }
        case .windowDisappeared(let id), .windowReplacedByFullscreen(let id): owners.withLock { $0[id] = nil }
        case .windowReturnedFromFullscreen(let replaced, let snapshot):
            owners.withLock {
                $0[replaced] = nil
                $0[snapshot.id] = pid
            }
        default: break
        }
        send(event)
    }

    /// How long starting up waits for applications to list their windows. A frozen
    /// application must not hold up the rest; its windows are reported when it answers.
    private static let discoveryDeadline = Duration.seconds(2)

    /// How often a locked screen is looked at again.
    private static let lockCheckInterval = Duration.milliseconds(500)

    public func waitUntilUnlocked() async {
        guard Self.isScreenLocked else { return }
        Log.platform.info("the screen is locked: windows are listed once it is unlocked")
        while Self.isScreenLocked { try? await Task.sleep(for: Self.lockCheckInterval) }
    }

    /// Whether the screen is locked, which hides every window from the accessibility API.
    private static var isScreenLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    public func discoverWindows() async -> [WindowSnapshot] {
        let adopted = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { self.adopt($0, announce: false) }
        }
        let discovery = Discovery(expecting: adopted.count)
        for agent in adopted {
            Task {
                let windows = await agent.attach(announce: false)
                owners.withLock { owners in
                    for window in windows { owners[window.id] = agent.pid }
                }
                let late = discovery.deliver(windows)
                late.forEach { send(.windowDiscovered($0)) }
            }
        }
        Task {
            try? await Task.sleep(for: Self.discoveryDeadline)
            discovery.finish()
        }
        return await discovery.result().sorted { $0.id < $1.id }
    }

    public func hiddenApplications() -> Set<Int32> {
        let agents = agents.withLock { Set($0.keys) }
        return Set(NSWorkspace.shared.runningApplications.filter { $0.isHidden && agents.contains($0.processIdentifier) }.map(\.processIdentifier))
    }

    // MARK: - Window operations

    private func owner(of window: WindowID) -> AppAgent? {
        guard let pid = owners.withLock({ $0[window] }) else { return nil }
        return agent(for: pid)
    }

    public func setFrames(_ frames: [WindowID: Rect]) {
        var byOwner: [pid_t: [WindowID: Rect]] = [:]
        owners.withLock { owners in
            for (id, frame) in frames {
                if let pid = owners[id] { byOwner[pid, default: [:]][id] = frame }
            }
        }
        for (pid, frames) in byOwner {
            agent(for: pid)?.setFrames(frames)
        }
    }

    public func drain() async {
        let all = agents.withLock { Array($0.values) }
        await withTaskGroup(of: Void.self) { group in
            for agent in all { group.addTask { await agent.barrier() } }
        }
    }

    public func focus(_ window: WindowID, raise: Bool) {
        focusRequests.add(1, ordering: .relaxed)
        owner(of: window)?.focus(window, raise: raise)
    }

    public func focus(_ window: WindowID, raise: Bool, after others: [WindowID]) {
        let request = focusRequests.add(1, ordering: .relaxed).newValue
        Task {
            // Each waits for the one before, which may be another application's, but not for
            // long: an application that does not answer holds nothing up.
            for other in others {
                guard focusRequests.load(ordering: .relaxed) == request else { return }
                guard let agent = owner(of: other) else { continue }
                // A busy application that gets to it later must not take focus then.
                let step = Expiry()
                agent.focus(other, raise: true, unless: { step.isExpired })
                await Self.waitBriefly(for: agent)
                step.expire()
            }
            guard focusRequests.load(ordering: .relaxed) == request else { return }
            owner(of: window)?.focus(window, raise: raise)
        }
    }

    public func focusDesktop(fromFullscreenSpace: Bool) {
        let request = focusRequests.add(1, ordering: .relaxed).newValue
        // While macOS brings a fullscreen Space up, the desktop still counts as on screen, but
        // focusing it would not stop the Space from coming.
        guard let finder = Self.finder, fromFullscreenSpace || !Self.focusDesktop(of: finder) else { return }
        // A fullscreen Space is shown, or coming, which macOS leaves only for a window on the
        // desktop.
        Task { @MainActor [self] in
            await desktopAnchor.showDesktop()
            guard focusRequests.load(ordering: .relaxed) == request, let finder = Self.finder else { return }
            if !Self.focusDesktop(of: finder) { finder.activate() }
        }
    }

    private static var finder: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    /// Focuses Finder's desktop window, as a click on the desktop does. Returns `false` when no
    /// desktop is on screen.
    private static func focusDesktop(of finder: NSRunningApplication) -> Bool {
        let pid = finder.processIdentifier
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let desktop = list.first {
            $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == desktopLevel
        }
        guard let number = desktop?[kCGWindowNumber as String] as? UInt32 else { return false }
        if !PrivateAPI.focus(window: CGWindowID(number), pid: pid, raise: true) { finder.activate() }
        return true
    }

    /// Marks a request that should not be carried out any more.
    private final class Expiry: Sendable {
        private let expired = Atomic(false)
        var isExpired: Bool { expired.load(ordering: .acquiring) }
        func expire() { expired.store(true, ordering: .releasing) }
    }

    /// Waits until `agent` has done what it was asked, or a quarter of a second.
    private static func waitBriefly(for agent: AppAgent) async {
        let resumed = Atomic(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume: @Sendable () -> Void = {
                if !resumed.exchange(true, ordering: .acquiringAndReleasing) { continuation.resume() }
            }
            Task { await agent.barrier(); resume() }
            Task { try? await Task.sleep(for: .milliseconds(250)); resume() }
        }
    }

    public func close(_ window: WindowID) {
        owner(of: window)?.close(window)
    }

    public func terminate(pid: Int32) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    public func signal(pid: Int32, _ signal: Int32) {
        guard pid > 0, pid != getpid() else { return }
        kill(pid, signal)
    }

    // MARK: - Displays

    public func displays() -> [DisplayDescription] { displayCache.withLock { $0 } }

    /// Converts AppKit's bottom-left screen coordinates into the top-left space used everywhere else.
    @MainActor
    static func currentDisplays() -> [DisplayDescription] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let height = primary.frame.height
        func flip(_ rect: NSRect) -> Rect {
            Rect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            return DisplayDescription(
                id: MonitorID(id),
                name: screen.localizedName,
                frame: flip(screen.frame),
                visibleFrame: flip(screen.visibleFrame),
                scale: screen.backingScaleFactor,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isMain: screen == primary
            )
        }
    }

    // MARK: - Pointer

    public func cursorLocation() -> Point {
        let location = CGEvent(source: nil)?.location ?? .zero
        return Point(x: location.x, y: location.y)
    }

    public func warpCursor(to point: Point) {
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: point.y))
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func isPrimaryButtonDown() -> Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// System processes whose screen-sized, mostly transparent windows sit above applications
    /// and must not count as covering them.
    private static let transparentOwners: Set<String> = ["Dock", "Window Server", "WindowManager"]

    /// Whether a window under the pointer lets it through to the windows below: the system's
    /// transparent overlays, and anything above normal windows that spreads over a whole
    /// display, as Notification Center's does. Menus and popovers are smaller and still count.
    static func letsPointerThrough(owner: String, layer: Int, bounds: CGRect, displays: [CGRect]) -> Bool {
        if transparentOwners.contains(owner) { return true }
        return layer > 0 && displays.contains { bounds.insetBy(dx: -1, dy: -1).contains($0) }
    }

    public func topmostWindow(at point: Point) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        // While a menu is open, the pointer is on its way to it, or it leaves to close the menu
        // with a click; focus moving underneath would close the menu instead.
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if list.contains(where: { $0[kCGWindowLayer as String] as? Int == menuLevel && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }) {
            log("a menu is open; hovering focuses nothing")
            return nil
        }
        let ownPID = getpid()
        let displays = Displays.bounds
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.contains(CGPoint(x: point.x, y: point.y)),
                  let number = info[kCGWindowNumber as String] as? UInt32 else { continue }
            // Moss's borders and notices let the mouse through; its settings window does not.
            if pid == ownPID && ClickThroughPanel.contains(Int(number)) { continue }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if Self.letsPointerThrough(owner: owner, layer: layer, bounds: bounds, displays: displays) { continue }
            log("topmost window at \(Int(point.x)),\(Int(point.y)): \(owner) \(number), layer \(layer)")
            return WindowID(number)
        }
        return nil
    }
}

/// Collects the windows applications report at startup, without waiting long for slow ones.
private final class Discovery: Sendable {
    private struct State {
        var remaining: Int
        var found: [WindowSnapshot] = []
        var isFinished = false
        var waiter: CheckedContinuation<[WindowSnapshot], Never>?
    }

    private let state: Mutex<State>

    init(expecting count: Int) {
        state = Mutex(State(remaining: count))
    }

    /// Adds one application's windows. Returns them back if discovery is already over.
    func deliver(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        let (late, completed) = state.withLock { state -> ([WindowSnapshot], Bool) in
            guard !state.isFinished else { return (windows, false) }
            state.found += windows
            state.remaining -= 1
            return ([], state.remaining == 0)
        }
        if completed { finish() }
        return late
    }

    /// Ends discovery with whatever has been found so far.
    func finish() {
        let (waiter, found) = state.withLock { state -> (CheckedContinuation<[WindowSnapshot], Never>?, [WindowSnapshot]) in
            guard !state.isFinished else { return (nil, []) }
            state.isFinished = true
            defer { state.waiter = nil }
            return (state.waiter, state.found)
        }
        waiter?.resume(returning: found)
    }

    func result() async -> [WindowSnapshot] {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> [WindowSnapshot]? in
                if state.isFinished || state.remaining == 0 {
                    state.isFinished = true
                    return state.found
                }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
