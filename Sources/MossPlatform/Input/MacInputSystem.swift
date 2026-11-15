import os
import AppKit
public import MossCore
public import MossRuntime
import MossKeyboard
import Synchronization

/// Global keyboard and mouse handling through a Quartz event tap.
///
/// The tap callback runs on its own thread and only looks bindings up in a prebuilt table;
/// everything else is handed to the engine asynchronously. macOS disables taps that answer
/// slowly, which would freeze input system-wide, so the callback never waits for anything.
public final class MacInputSystem: InputSystem, @unchecked Sendable {
    private let table = Mutex(BindingTable())
    private let bindings = Mutex<[KeyBinding]>([])
    private let mode = Mutex<String?>(nil)
    private let paused = Atomic<Bool>(false)
    private let pauseGeneration = Atomic<Int>(0)
    private let sink = EventSink<InputEvent>()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    @MainActor private var layoutObserver: (any NSObjectProtocol)?
    @MainActor private var wakeObservers: [any NSObjectProtocol] = []
    /// What Caps Lock, remapped to F18, does: a `CapsLockRole` raw value.
    private let capsLockRole = Atomic<Int>(CapsLockRole.unchanged.rawValue)
    /// Whether Hyper's modifiers are pressed on behalf of Caps Lock, for releasing them on stop.
    private let hyperPressed = Atomic<Bool>(false)

    // State below is confined to the tap thread.
    private var consumedKeys: Set<UInt16> = []
    private var releaseBindings: [UInt16: [KeyBinding]] = [:]
    private var activeMouseButton: Int64?
    /// Caps Lock, remapped to F18, is held down as the `caps` modifier.
    private var isCapsLockHeld = false
    /// Caps Lock is held down as Hyper: since when, and whether anything was pressed with it.
    private var hyperPress: (since: ContinuousClock.Instant, isUsed: Bool)?
    /// Modifiers the user really holds while Caps Lock is Hyper.
    private var realModifiers = RealModifiers()
    /// Held alone for this long or more, Caps Lock does not lock capitals when released.
    private static let tapLimit = Duration.seconds(1)
    private var scrollGesture = ScrollGesture()
    private var lastPointerReport = ContinuousClock.now
    private static let pointerInterval = Duration.milliseconds(8)

    @MainActor
    public init() {
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildTable() }
        }
        // Waking up, unlocking or switching users back can reset the key mapping list.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.screensDidWakeNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, role != .unchanged else { return }
                DispatchQueue.global(qos: .userInitiated).async { CapsLockRemap.apply(true) }
            })
        }
    }

    public func start(sink: @escaping @Sendable (InputEvent) -> Void) throws {
        self.sink.connect(sink)
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
            .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let system = Unmanaged<MacInputSystem>.fromOpaque(refcon).takeUnretainedValue()
            return system.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw InputError.tapUnavailable
        }
        self.tap = tap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            guard let tap = self.tap else { return }
            runLoop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "moss.input"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    public func stop() {
        // Give Caps Lock back before quitting, and let go of Hyper if it is held.
        if capsLockRole.exchange(CapsLockRole.unchanged.rawValue, ordering: .acquiringAndReleasing) != CapsLockRole.unchanged.rawValue {
            CapsLockRemap.apply(false)
        }
        if hyperPressed.exchange(false, ordering: .acquiringAndReleasing) { Self.postHyperModifiers(down: false) }
        sink.disconnect()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    public func setBindings(_ bindings: [KeyBinding]) {
        self.bindings.withLock { $0 = bindings }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.rebuildTable() } }
    }

    public func setMode(_ name: String?) {
        mode.withLock { $0 = name }
    }

    public func setCapsLock(_ role: CapsLockRole) {
        let old = CapsLockRole(rawValue: capsLockRole.exchange(role.rawValue, ordering: .acquiringAndReleasing)) ?? .unchanged
        guard (old == .unchanged) != (role == .unchanged) else { return }
        DispatchQueue.global(qos: .userInitiated).async { CapsLockRemap.apply(role != .unchanged) }
    }

    private var role: CapsLockRole {
        CapsLockRole(rawValue: capsLockRole.load(ordering: .relaxed)) ?? .unchanged
    }

    /// Marks keys Moss sends itself, so the tap lets them through without matching bindings.
    private static let sentKeyMarker: Int64 = 0x7375_6B6B_6972

    public func send(_ chord: KeyChord, to pid: Int32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let code: UInt16? = switch chord.key {
                case .key(let name): KeyboardLayout.current().keyCode(for: name)
                case .keyCode(let code): code
                default: nil
                }
                guard let code else {
                    Log.input.error("cannot send '\(chord.key.description, privacy: .public)': no such key on this keyboard layout")
                    return
                }
                let source = CGEventSource(stateID: .privateState)
                let flags = Self.flags(for: chord.modifiers)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
                    event.flags = flags
                    event.setIntegerValueField(.eventSourceUserData, value: Self.sentKeyMarker)
                    if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
                }
            }
        }
    }

    private static func flags(for modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        return flags
    }

    /// Lets every event through untouched, e.g. while a shortcut is being recorded.
    /// A pause lifts itself after a while, so bindings can never stay disabled by accident.
    public func setPaused(_ isPaused: Bool) {
        paused.store(isPaused, ordering: .releasing)
        let generation = pauseGeneration.add(1, ordering: .acquiringAndReleasing).newValue
        guard isPaused else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, pauseGeneration.load(ordering: .acquiring) == generation else { return }
            paused.store(false, ordering: .releasing)
        }
    }

    @MainActor
    private func rebuildTable() {
        let bindings = bindings.withLock { $0 }
        let built = BindingTable(bindings: bindings, layout: .current())
        table.withLock { $0 = built }
        Log.input.info("bindings rebuilt: \(bindings.count) binds")
    }

    // MARK: - Event handling

    private func send(_ event: InputEvent) {
        sink.send(event)
    }

    /// Modifiers held for `event`, with Caps Lock counted while it works as a modifier.
    private func modifiers(of event: CGEvent) -> Modifiers {
        let flags = event.flags
        var result: Modifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        if isCapsLockHeld { result.insert(.capsLock) }
        return result
    }

    private static func location(of event: CGEvent) -> Point {
        Point(x: event.location.x, y: event.location.y)
    }

    /// Returns `nil` to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if event.getIntegerValueField(.eventSourceUserData) == Self.sentKeyMarker {
            return pass
        }
        if type == .keyDown || type == .keyUp,
           UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == CapsLockRemap.f18KeyCode {
            switch role {
            case .modifier:
                // Caps Lock, remapped to F18, is a modifier: track it and keep it from applications.
                isCapsLockHeld = type == .keyDown
                return paused.load(ordering: .acquiring) ? pass : nil
            case .hyper:
                hyperKey(isDown: type == .keyDown)
                return nil
            case .unchanged:
                break
            }
        }
        if type == .flagsChanged {
            // Only real modifier keys arrive here; Hyper's own presses carry the sent-key marker.
            if hyperPress != nil { trackModifierKey(event) }
            return pass
        }
        if hyperPress != nil { applyHyper(to: event, type) }
        if paused.load(ordering: .acquiring), type != .tapDisabledByTimeout, type != .tapDisabledByUserInput {
            // Released buttons pass by unseen while paused.
            abandonMouseBinding()
            return pass
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Log.input.info("event tap was disabled by the system; re-enabling")
            // A button may have been released while the tap was off.
            abandonMouseBinding()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            return keyDown(event) ? nil : pass
        case .keyUp:
            return keyUp(event) ? nil : pass
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return mouseDown(event) ? nil : pass
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return mouseDragged(event) ? nil : pass
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return mouseUp(event) ? nil : pass
        case .mouseMoved:
            reportPointer { .cursorMoved(to: Self.location(of: event)) }
            return pass
        case .scrollWheel:
            return scroll(event) ? nil : pass
        default:
            return pass
        }
    }

    // MARK: - Hyper

    private static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    /// The modifier keys Hyper presses, in order: Control, Option, Shift, Command.
    private static let hyperKeys: [(code: CGKeyCode, flag: CGEventFlags)] = [
        (59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand),
    ]

    /// Caps Lock went down or up while it works as Hyper.
    private func hyperKey(isDown: Bool) {
        if isDown {
            // Holding the key repeats it; only the first press counts.
            guard hyperPress == nil else { return }
            hyperPress = (.now, false)
            realModifiers.begin(holding: Self.modifiers(of: CGEventSource.flagsState(.hidSystemState)))
            hyperPressed.store(true, ordering: .releasing)
            Self.postHyperModifiers(down: true)
        } else {
            guard let press = hyperPress else { return }
            hyperPress = nil
            realModifiers.end()
            hyperPressed.store(false, ordering: .releasing)
            Self.postHyperModifiers(down: false)
            // Tapped alone, it still locks capitals.
            if !press.isUsed, ContinuousClock.now - press.since < Self.tapLimit {
                DispatchQueue.global(qos: .userInteractive).async { CapsLockRemap.toggleLock() }
            }
        }
    }

    /// A real modifier key went down or up while Caps Lock is held.
    private func trackModifierKey(_ event: CGEvent) {
        if realModifiers.keyChanged(UInt16(event.getIntegerValueField(.keyboardEventKeycode))) {
            hyperPress?.isUsed = true
        }
    }

    /// What Caps Lock and the modifiers really held make, for Moss's `caps` shortcuts.
    private var capsLayer: Modifiers { realModifiers.modifiers.union(.capsLock) }

    private static func modifiers(of flags: CGEventFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskSecondaryFn) { result.insert(.function) }
        return result
    }

    /// The shortcuts for `event`, with the modifiers they were found with. With Caps Lock held
    /// as Hyper, its own shortcuts (`caps-shift-h`) come first, then Hyper's (`hyper-h`).
    private func firstMatch(
        for event: CGEvent,
        _ lookup: (BindingTable, Modifiers, String?) -> [KeyBinding]
    ) -> (modifiers: Modifiers, matches: [KeyBinding]) {
        let table = table.withLock { $0 }
        let mode = mode.withLock { $0 }
        let candidates = hyperPress != nil ? [capsLayer, modifiers(of: event)] : [modifiers(of: event)]
        for modifiers in candidates {
            let matches = lookup(table, modifiers, mode)
            if !matches.isEmpty { return (modifiers, matches) }
        }
        return (candidates[candidates.count - 1], [])
    }

    /// Keys, clicks and scrolling while Hyper is held carry its modifiers.
    private func applyHyper(to event: CGEvent, _ type: CGEventType) {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            hyperPress?.isUsed = true
        case .keyUp, .leftMouseUp, .rightMouseUp, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break
        default:
            return
        }
        event.flags.formUnion(Self.hyperFlags)
    }

    /// Presses or releases Hyper's modifier keys for the whole system, so applications and
    /// their global shortcuts see them as if they were held.
    private static func postHyperModifiers(down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = down ? [] : hyperFlags
        for (code, flag) in down ? hyperKeys : hyperKeys.reversed() {
            if down { flags.insert(flag) } else { flags.remove(flag) }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.type = .flagsChanged
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: sentKeyMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Keys

    private func keyDown(_ event: CGEvent) -> Bool {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let (modifiers, matches) = firstMatch(for: event) { $0.bindings(forKey: code, modifiers: $1, mode: $2) }
        guard !matches.isEmpty else {
            if !modifiers.subtracting([.shift, .capsLock, .function]).isEmpty {
                Log.input.debug("no binding for key code \(code) with \(modifiers.description, privacy: .public)")
            }
            return false
        }
        Log.input.debug("key code \(code) with \(modifiers.description, privacy: .public) matched \(matches.count) binding(s)")

        var consume = false
        for binding in matches {
            if !binding.options.contains(.passesThrough) { consume = true }
            if binding.options.contains(.onRelease) {
                if !isRepeat { releaseBindings[code, default: []].append(binding) }
            } else if !isRepeat || binding.options.contains(.repeats) {
                send(.binding(binding))
            }
        }
        if consume { consumedKeys.insert(code) }
        return consume
    }

    private func keyUp(_ event: CGEvent) -> Bool {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if let pending = releaseBindings.removeValue(forKey: code) {
            pending.forEach { send(.binding($0)) }
        }
        return consumedKeys.remove(code) != nil
    }

    /// The button's number: 0 left, 1 right, 2 middle, then extra buttons.
    private static func button(of event: CGEvent) -> Int64 {
        event.getIntegerValueField(.mouseEventButtonNumber)
    }

    private func mouseDown(_ event: CGEvent) -> Bool {
        let button = Self.button(of: event)
        if activeMouseButton == button {
            // The button went down again, so its release was missed.
            abandonMouseBinding()
        }
        let location = Self.location(of: event)
        if let mouseButton = MouseButton(rawValue: Int(button)), activeMouseButton == nil {
            let (_, matches) = firstMatch(for: event) { $0.bindings(for: .drag(mouseButton), modifiers: $1, mode: $2) }
            if let binding = matches.first, case .drag(let action) = binding.command {
                activeMouseButton = button
                send(.mouseBindingBegan(action, at: location))
                return true
            }
        }
        if button == 0 { send(.primaryButton(isDown: true, at: location)) }
        return false
    }

    private func mouseDragged(_ event: CGEvent) -> Bool {
        guard activeMouseButton != nil else { return false }
        reportPointer { .mouseBindingMoved(to: Self.location(of: event)) }
        return true
    }

    private func mouseUp(_ event: CGEvent) -> Bool {
        let button = Self.button(of: event)
        if activeMouseButton == button {
            activeMouseButton = nil
            send(.mouseBindingEnded(at: Self.location(of: event)))
            return true
        }
        if button == 0 { send(.primaryButton(isDown: false, at: Self.location(of: event))) }
        return false
    }

    /// Ends a mouse binding whose button release may never arrive.
    private func abandonMouseBinding() {
        guard activeMouseButton != nil else { return }
        activeMouseButton = nil
        let location = CGEvent(source: nil)?.location ?? .zero
        send(.mouseBindingEnded(at: Point(x: location.x, y: location.y)))
    }

    private func scroll(_ event: CGEvent) -> Bool {
        let isBound = { (direction: Direction) in
            !self.firstMatch(for: event) { $0.bindings(for: .scroll(direction), modifiers: $1, mode: $2) }.matches.isEmpty
        }
        switch scrollGesture.handle(Self.scrollInput(of: event), isBound: isBound) {
        case .pass:
            return false
        case .consume:
            return true
        case .run(let direction):
            firstMatch(for: event) { $0.bindings(for: .scroll(direction), modifiers: $1, mode: $2) }.matches.forEach { send(.binding($0)) }
            return true
        }
    }

    /// What a scroll event says: a wheel notch, or part of a swipe on a trackpad.
    private static func scrollInput(of event: CGEvent) -> ScrollGesture.Input {
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if momentum != 0 { return .coasting(isLast: momentum == 3) }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        if isContinuous, phase != 0 {
            switch phase {
            case 1, 128: return .began
            case 4, 8: return .ended
            default:
                return .moved(dx: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2),
                              dy: event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            }
        }
        let vertical = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let horizontal = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if vertical != 0 { return .notch(vertical > 0 ? .up : .down) }
        if horizontal != 0 { return .notch(horizontal > 0 ? .left : .right) }
        return .moved(dx: 0, dy: 0)
    }

    /// Rate-limits high-frequency pointer reports; the engine only needs the latest position.
    private func reportPointer(_ event: () -> InputEvent) {
        let now = ContinuousClock.now
        guard now - lastPointerReport >= Self.pointerInterval else { return }
        lastPointerReport = now
        send(event())
    }
}

public enum InputError: Error, CustomStringConvertible {
    case tapUnavailable

    public var description: String {
        "the event tap could not be created; grant Moss Accessibility access in System Settings"
    }
}
