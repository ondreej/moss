import os
import ApplicationServices
import AppKit
import MossCore
import MossRuntime
import Synchronization

/// Owns all accessibility communication with one application.
///
/// Accessibility requests are synchronous round trips to the target process, and a busy
/// or hung application can take seconds to answer. Each application therefore gets its
/// own thread: a slow app delays only its own windows, never the engine, other apps or
/// keyboard handling. Frame updates are coalesced so a fast stream of requests (a mouse
/// drag) never queues up stale work.
final class AppAgent: @unchecked Sendable {
    let pid: pid_t
    private let appID: String
    private let appName: String
    /// Menu bar applications have no Dock icon; their windows are panels and launchers that float.
    private let floatsWindows: Bool
    private let emit: @Sendable (PlatformEvent) -> Void
    private let isFrontmost: @Sendable () -> Bool
    private let application: AXElement

    private var runLoop: CFRunLoop!
    private let pendingFrames = Mutex<[WindowID: Rect]>([:])
    private let flushScheduled = Atomic<Bool>(false)
    private let waiters = Mutex(Waiters())

    // State below is only touched on the agent's thread.
    private var observer: AXObserver?
    private var windows: [WindowID: AXElement] = [:]
    private var knownFrames: [WindowID: Rect] = [:]
    private var kinds: [WindowID: WindowProperties.Kind] = [:]
    /// Windows that were minimized when first seen and have not been announced yet.
    private var unannounced: Set<WindowID> = []
    /// Windows currently in macOS's own fullscreen mode.
    private var nativeFullscreen: Set<WindowID> = []
    /// Windows given a new frame since their frames were last read back.
    private var unverified: Set<WindowID> = []
    private var verifyTimer: CFRunLoopTimer?
    private var isAttached = false
    /// The window last reported as focused.
    private var reportedFocus: WindowID?
    /// Fullscreen windows the application put up in place of a window it closed, as browsers
    /// do for video.
    private var standIns: [StandIn] = []
    /// The window whose stand-in just closed, to be replaced by the next window that opens.
    private var returning: StandIn?

    private struct StandIn {
        var element: AXElement
        var replaced: WindowID
        var kind: WindowProperties.Kind
    }

    init(pid: pid_t, appID: String, appName: String, floatsWindows: Bool, isFrontmost: @escaping @Sendable () -> Bool, emit: @escaping @Sendable (PlatformEvent) -> Void) {
        self.pid = pid
        self.appID = appID
        self.appName = appName
        self.floatsWindows = floatsWindows
        self.emit = emit
        self.isFrontmost = isFrontmost
        self.application = .application(pid)
        application.setMessagingTimeout(1)

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            runLoop = CFRunLoopGetCurrent()
            // Keeps the run loop alive until the observer adds its source.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "moss.app.\(pid)"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    // MARK: - Scheduling

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    /// Callers waiting for a result from the agent's thread. Once the thread has been told to
    /// stop, queued blocks may never run, so their callers are answered with a fallback instead.
    private struct Waiters {
        struct Waiter {
            let giveUp: @Sendable () -> Void
        }

        var isStopped = false
        var nextToken = 0
        var pending: [Int: Waiter] = [:]
    }

    /// Runs `block` on the agent's thread and returns its result, or `fallback` if the agent
    /// stops first.
    private func perform<T: Sendable>(returning block: @escaping () -> T, otherwise fallback: T) async -> T {
        await withCheckedContinuation { continuation in
            let token: Int? = waiters.withLock { waiters in
                guard !waiters.isStopped else { return nil }
                let token = waiters.nextToken
                waiters.nextToken += 1
                waiters.pending[token] = Waiters.Waiter { continuation.resume(returning: fallback) }
                return token
            }
            guard let token else {
                continuation.resume(returning: fallback)
                return
            }
            perform { [self] in
                // Whoever removes the waiter answers it: this block or `stop()`.
                guard waiters.withLock({ $0.pending.removeValue(forKey: token) }) != nil else { return }
                continuation.resume(returning: block())
            }
        }
    }

    /// Waits until every previously scheduled operation has run.
    func barrier() async {
        await perform(returning: {}, otherwise: ())
    }

    func stop() {
        let abandoned = waiters.withLock { waiters in
            waiters.isStopped = true
            defer { waiters.pending.removeAll() }
            return Array(waiters.pending.values)
        }
        abandoned.forEach { $0.giveUp() }
        perform { [self] in
            if let observer {
                CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            if let verifyTimer { CFRunLoopTimerInvalidate(verifyTimer) }
            windows.removeAll()
            CFRunLoopStop(runLoop)
        }
    }

    // MARK: - Attaching

    /// Starts observing the application and returns its manageable windows.
    /// With `announce`, the windows are also reported as newly appeared.
    func attach(announce: Bool) async -> [WindowSnapshot] {
        await perform(returning: { [self] in
            ensureAttached()
            let snapshots = scan()
            if announce { snapshots.forEach { emit(.windowAppeared($0)) } }
            return snapshots
        }, otherwise: [])
    }

    private func ensureAttached() {
        if !isAttached { isAttached = attachObserver() }
    }

    /// Creates the observer, retrying while a freshly launched application is not ready yet.
    private func attachObserver() -> Bool {
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let agent = Unmanaged<AppAgent>.fromOpaque(refcon).takeUnretainedValue()
            agent.handle(notification as String, element: AXElement(element))
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return false }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for attempt in 0..<20 {
            let result = AXObserverAddNotification(created, application.ref, kAXWindowCreatedNotification as CFString, refcon)
            if result == .success || result == .notificationAlreadyRegistered { break }
            guard result == .cannotComplete || result == .apiDisabled, attempt < 19 else { return false }
            usleep(50_000)
        }
        AXObserverAddNotification(created, application.ref, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        return true
    }

    // MARK: - Window tracking

    /// Finds windows not tracked yet and returns snapshots of the ones that should be managed.
    private func scan() -> [WindowSnapshot] {
        var snapshots: [WindowSnapshot] = []
        for element in application.windows {
            if let snapshot = track(element) { snapshots.append(snapshot) }
        }
        // Return already tracked windows too, so repeated discovery is complete.
        for (id, element) in windows where !snapshots.contains(where: { $0.id == id }) && !unannounced.contains(id) {
            if let frame = element.frame, let kind = kinds[id] {
                snapshots.append(WindowSnapshot(id: id, properties: properties(of: element, kind: kind), frame: frame))
            }
        }
        return snapshots
    }

    private static func kind(of element: AXElement) -> WindowProperties.Kind? {
        guard element.role == kAXWindowRole else { return nil }
        switch element.subrole {
        // A window that cannot go fullscreen is an inspector or the like, such as Finder's Get
        // Info, a sticky note or System Settings, and floats.
        case kAXStandardWindowSubrole: return element.hasFullScreenButton ? .standard : .panel
        case kAXDialogSubrole, kAXSystemDialogSubrole: return .dialog
        case kAXFloatingWindowSubrole: return element.hasCloseButton ? .panel : nil
        default: return nil
        }
    }

    /// Starts tracking `element` if it is a manageable window. Returns its snapshot when it
    /// should be announced now (it is not minimized). With `canWait`, a window that may be a
    /// notice over other windows is looked at again shortly and announced then.
    private func track(_ element: AXElement, canWait: Bool = true) -> WindowSnapshot? {
        guard let id = element.windowID, windows[id] == nil, var kind = Self.kind(of: element),
              let frame = element.frame, frame.width >= 40, frame.height >= 40,
              let observer else { return nil }
        if Self.mayBeNotice(element, kind: kind) {
            if canWait {
                trackShortly(element)
                return nil
            }
            if Self.isNotice(element) { return nil }
        }

        if floatsWindows && kind == .standard { kind = .panel }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, element.ref, kAXUIElementDestroyedNotification as CFString, refcon) == .success else {
            return nil
        }
        for notification in [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(observer, element.ref, notification as CFString, refcon)
        }
        windows[id] = element
        kinds[id] = kind
        knownFrames[id] = frame
        if element.isMinimized {
            unannounced.insert(id)
            return nil
        }
        if element.isFullscreen {
            // In fullscreen in a Space of its own: it joins the layout once it leaves fullscreen.
            nativeFullscreen.insert(id)
            unannounced.insert(id)
            return nil
        }
        return WindowSnapshot(id: id, properties: properties(of: element, kind: kind), frame: frame)
    }

    private func properties(of element: AXElement, kind: WindowProperties.Kind) -> WindowProperties {
        WindowProperties(
            appID: appID,
            appName: appName,
            title: element.title ?? "",
            pid: pid,
            kind: kind,
            isResizable: element.isSettable(kAXSizeAttribute)
        )
    }

    private func id(of element: AXElement) -> WindowID? {
        if let id = element.windowID, windows[id] != nil { return id }
        return windows.first { $0.value == element }?.key
    }

    // MARK: - Notices over other windows

    // Some untitled dialogs are notices shown over other windows rather than dialogs: the
    // bubble macOS puts beside the text cursor while Caps Lock is on or after the input source
    // changes, or a keyboard utility's "Caps Lock On". They sit above the normal level, and the
    // bubble one above the window it belongs to, while real dialogs sit at the normal level or,
    // when modal, the modal panel level. They reach their level a moment after they appear.
    // Focusing one takes focus from the window being typed in; for the bubble, that hides it,
    // and focusing the text again brings it back, over and over.

    /// Whether `window` may be a notice, which only its level tells for sure.
    private static func mayBeNotice(_ window: AXElement, kind: WindowProperties.Kind) -> Bool {
        kind == .dialog && (window.title?.isEmpty ?? true) && !window.hasCloseButton
    }

    private static func isNotice(_ window: AXElement) -> Bool {
        guard let level = window.windowLevel else { return false }
        return level > Int(CGWindowLevelForKey(.normalWindow)) && level != Int(CGWindowLevelForKey(.modalPanelWindow))
    }

    /// How long a window that may be a notice is given to reach its level.
    private static let noticeDelay: CFTimeInterval = 0.1

    /// Tracks `window` once it has had time to reach its level.
    private func trackShortly(_ window: AXElement) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Self.noticeDelay, 0, 0, 0) { [weak self] _ in
            guard let self, let snapshot = track(window, canWait: false) else { return }
            announce(snapshot)
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    // MARK: - Notifications

    private func handle(_ notification: String, element: AXElement) {
        switch notification {
        case kAXWindowCreatedNotification:
            if let snapshot = track(element) { announce(snapshot) }

        case kAXFocusedWindowChangedNotification:
            reportFocus(of: element)

        case kAXUIElementDestroyedNotification:
            if let index = standIns.firstIndex(where: { $0.element == element }) {
                standInClosed(standIns.remove(at: index))
                return
            }
            guard let id = id(of: element) else { return }
            let kind = kinds[id]
            windows[id] = nil
            knownFrames[id] = nil
            kinds[id] = nil
            nativeFullscreen.remove(id)
            guard unannounced.remove(id) == nil else { return }
            if id == reportedFocus, let kind, let standIn = fullscreenStandIn() {
                // The application put a window of its own over the whole display in place of
                // this one, as browsers do for video, and opens another when it leaves.
                standIns.append(StandIn(element: standIn, replaced: id, kind: kind))
                emit(.windowReplacedByFullscreen(id))
            } else {
                emit(.windowDisappeared(id))
            }

        case kAXMovedNotification, kAXResizedNotification:
            guard let id = id(of: element), let frame = element.frame else { return }
            if unannounced.contains(id) {
                // A window that appeared in fullscreen is announced when it leaves fullscreen.
                guard nativeFullscreen.contains(id), !element.isFullscreen, let kind = kinds[id] else { return }
                nativeFullscreen.remove(id)
                unannounced.remove(id)
                knownFrames[id] = frame
                emit(.windowAppeared(WindowSnapshot(id: id, properties: properties(of: element, kind: kind), frame: frame)))
                return
            }
            knownFrames[id] = frame
            let isFullscreen = element.isFullscreen
            if isFullscreen != nativeFullscreen.contains(id) {
                if isFullscreen { nativeFullscreen.insert(id) } else { nativeFullscreen.remove(id) }
                emit(.windowNativeFullscreen(id, isFullscreen))
                return
            }
            if !isFullscreen { emit(.windowFrameChanged(id, frame)) }

        case kAXTitleChangedNotification:
            guard let id = id(of: element), let kind = kinds[id], !unannounced.contains(id) else { return }
            emit(.windowPropertiesChanged(id, properties(of: element, kind: kind)))

        case kAXWindowMiniaturizedNotification:
            guard let id = id(of: element), !unannounced.contains(id) else { return }
            emit(.windowMinimized(id, true))

        case kAXWindowDeminiaturizedNotification:
            guard let id = id(of: element) else { return }
            if unannounced.remove(id) != nil, let kind = kinds[id], let frame = element.frame {
                emit(.windowAppeared(WindowSnapshot(id: id, properties: properties(of: element, kind: kind), frame: frame)))
            } else {
                emit(.windowMinimized(id, false))
            }

        default:
            break
        }
    }

    private func reportFocus(of element: AXElement?) {
        guard isFrontmost() else {
            Log.platform.debug("\(self.appID, privacy: .public): focus change ignored, not frontmost")
            return
        }
        guard let element, let windowID = element.windowID else {
            reportedFocus = nil
            emit(.focusChanged(nil))
            confirmFocusShortly()
            return
        }
        // Notices never take focus, so a focused window is never one.
        if windows[windowID] == nil, let snapshot = track(element, canWait: false) {
            announce(snapshot)
        }
        // A sheet has focus in place of its window, which still counts as focused.
        let focused = windows[windowID] != nil ? windowID : trackedWindow(holding: element)
        Log.platform.debug("\(self.appID, privacy: .public): focused window \(windowID.address, privacy: .public), counted as \(focused?.address ?? "none", privacy: .public)")
        reportedFocus = focused
        emit(.focusChanged(focused))
        if focused == nil { confirmFocusShortly() }
    }

    /// The tracked window an element such as a sheet belongs to.
    private func trackedWindow(holding element: AXElement) -> WindowID? {
        var parent = element.element(kAXParentAttribute)
        for _ in 0..<4 {
            guard let current = parent else { return nil }
            if let id = current.windowID, windows[id] != nil { return id }
            parent = current.element(kAXParentAttribute)
        }
        return nil
    }

    /// Focus reported on something that is not a window may be a step on its way to one, as
    /// when Finder's first window opens over the desktop: look again in a moment.
    private func confirmFocusShortly() {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0, 0, 0) { [weak self] _ in
            guard let self, isFrontmost(), let element = application.focusedWindow, let id = element.windowID,
                  let focused = windows[id] != nil ? id : trackedWindow(holding: element) else { return }
            Log.platform.debug("\(self.appID, privacy: .public): focus settled on \(focused.address, privacy: .public)")
            reportedFocus = focused
            emit(.focusChanged(focused))
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    /// Reports the application's focused window, e.g. after the application was activated.
    func reportFocusedWindow() {
        perform { [self] in
            let known = Set(windows.keys)
            ensureAttached()
            for snapshot in scan() where !known.contains(snapshot.id) {
                announce(snapshot)
            }
            reportFocus(of: application.focusedWindow)
        }
    }

    // MARK: - Fullscreen stand-ins

    /// Announces a window that just opened: as the one returning from fullscreen if that is
    /// awaited, otherwise as a new window.
    private func announce(_ snapshot: WindowSnapshot) {
        if let standIn = returning, standIn.kind == snapshot.properties.kind {
            returning = nil
            emit(.windowReturnedFromFullscreen(standIn.replaced, snapshot))
        } else {
            emit(.windowAppeared(snapshot))
        }
    }

    /// The focused window if it is one Moss does not arrange spread over a whole display:
    /// a fullscreen window the application put up of its own, watched until it closes.
    private func fullscreenStandIn() -> AXElement? {
        guard let element = application.focusedWindow, let id = element.windowID, windows[id] == nil,
              let frame = element.frame, Displays.isWholeDisplay(frame), let observer else { return nil }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, element.ref, kAXUIElementDestroyedNotification as CFString, refcon) == .success else {
            return nil
        }
        return element
    }

    /// The fullscreen ended: the window the application opens next takes the place of the one
    /// the stand-in replaced. If none opens, that one is gone for good.
    private func standInClosed(_ standIn: StandIn) {
        if let previous = returning { emit(.windowDisappeared(previous.replaced)) }
        returning = standIn
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 1, 0, 0, 0) { [weak self] _ in
            guard let self, returning?.replaced == standIn.replaced else { return }
            returning = nil
            emit(.windowDisappeared(standIn.replaced))
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    // MARK: - Commands

    func setFrames(_ frames: [WindowID: Rect]) {
        pendingFrames.withLock { $0.merge(frames) { _, new in new } }
        if !flushScheduled.exchange(true, ordering: .acquiringAndReleasing) {
            perform { [self] in flushFrames() }
        }
    }

    private func flushFrames() {
        flushScheduled.store(false, ordering: .releasing)
        let frames = pendingFrames.withLock { pending -> [WindowID: Rect] in
            defer { pending.removeAll() }
            return pending
        }
        guard !frames.isEmpty else { return }

        // With enhanced user interface on (set by assistive apps), applications animate every
        // frame change themselves, which makes tiling slow and jumpy.
        let enhanced = application.bool("AXEnhancedUserInterface") ?? false
        if enhanced { application.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { application.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

        for (id, frame) in frames {
            guard let element = windows[id] else { continue }
            apply(frame, to: element, known: knownFrames[id])
            knownFrames[id] = frame
            unverified.insert(id)
        }
        scheduleVerification()
    }

    /// Reads the frames back once the windows have stopped moving. An application that refuses
    /// a size it already has, as fixed-size and fixed-aspect windows do, reports no change at all.
    private func scheduleVerification() {
        if verifyTimer == nil {
            let timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, .greatestFiniteMagnitude, 0, 0) { [unowned self] _ in
                verifyFrames()
            }
            CFRunLoopAddTimer(runLoop, timer, .defaultMode)
            verifyTimer = timer
        }
        // Every new frame pushes the check back, so an animation is checked once, at its end.
        CFRunLoopTimerSetNextFireDate(verifyTimer, CFAbsoluteTimeGetCurrent() + 0.2)
    }

    private func verifyFrames() {
        let ids = unverified
        unverified.removeAll()
        for id in ids where !unannounced.contains(id) && !nativeFullscreen.contains(id) {
            guard let requested = knownFrames[id], let actual = windows[id]?.frame,
                  !actual.isApproximatelyEqual(to: requested, tolerance: 1) else { continue }
            knownFrames[id] = actual
            emit(.windowFrameChanged(id, actual))
        }
    }

    private func apply(_ frame: Rect, to element: AXElement, known: Rect?) {
        let moves = known.map { abs($0.minX - frame.minX) >= 0.5 || abs($0.minY - frame.minY) >= 0.5 } ?? true
        let resizes = known.map { abs($0.width - frame.width) >= 0.5 || abs($0.height - frame.height) >= 0.5 } ?? true
        if moves { element.setPosition(frame.origin) }
        if resizes {
            element.setSize(frame.size)
            // Growing near a screen edge can make the system nudge the window; put it back.
            if moves { element.setPosition(frame.origin) }
        }
    }

    /// Focuses a window, unless by the time the application gets to it the request has
    /// `expired`.
    func focus(_ id: WindowID, unless expired: @escaping @Sendable () -> Bool = { false }) {
        perform { [self] in
            guard !expired(), let element = windows[id] else { return }
            if !PrivateAPI.focus(window: CGWindowID(id.rawValue), pid: pid) {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
            element.perform(kAXRaiseAction)
        }
    }

    func close(_ id: WindowID) {
        perform { [self] in
            guard let element = windows[id] else { return }
            if let button = element.element(kAXCloseButtonAttribute) {
                button.perform(kAXPressAction)
            }
        }
    }
}
