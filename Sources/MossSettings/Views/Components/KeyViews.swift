import AppKit
import MossCore
import MossKeyboard
import SwiftUI

/// A single key cap.
struct KeyCap: View {
    let text: String
    /// The small variant used in lists and footers.
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
            .foregroundStyle(compact ? .secondary : .primary)
            .padding(.horizontal, compact ? 4 : 6)
            .frame(minWidth: compact ? 18 : 22, minHeight: compact ? 18 : 21)
            .background(compact ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.background), in: .rect(cornerRadius: compact ? 4 : 5))
            .overlay {
                if !compact { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator) }
            }
            .shadow(color: .black.opacity(compact ? 0 : 0.12), radius: 0, y: 1)
    }
}

/// A shortcut drawn as key caps, e.g. ⌥ ⇧ Q.
struct KeyComboView: View {
    let modifiers: Modifiers
    let trigger: Trigger?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 2 : 3) {
            ForEach(Self.symbols(for: modifiers), id: \.self) { KeyCap(text: $0, compact: compact) }
            if let trigger { KeyCap(text: Self.name(of: trigger), compact: compact) }
        }
    }

    static func symbols(for modifiers: Modifiers) -> [String] {
        var symbols: [String] = []
        if modifiers.contains(.function) { symbols.append("fn") }
        if modifiers.contains(.capsLock) { symbols.append("⇪") }
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    static func name(of trigger: Trigger) -> String {
        switch trigger {
        case .key(let name): KeyNames.displayName(for: name)
        case .keyCode(let code): "Key \(code)"
        case .drag(.left): "Left Drag"
        case .drag(.right): "Right Drag"
        case .drag(.middle): "Middle Drag"
        case .scroll(.up): "Scroll ↑"
        case .scroll(.down): "Scroll ↓"
        case .scroll(.left): "Scroll ←"
        case .scroll(.right): "Scroll →"
        }
    }
}

/// Records a shortcut from the keyboard. Moss's own shortcuts are paused while recording,
/// so shortcuts that are already bound can be recorded too.
struct KeyRecorder: View {
    @Binding var modifiers: Modifiers
    @Binding var key: String?
    @Environment(\.services) private var services
    @State private var isRecording = false
    @State private var liveModifiers: Modifiers = []
    @State private var monitor: Any?
    /// Captured when recording starts: environment values are not available to event callbacks.
    @State private var resumeBindings: (@MainActor () -> Void)?

    var body: some View {
        Button {
            isRecording ? stop() : start()
        } label: {
            HStack(spacing: 8) {
                if isRecording {
                    if liveModifiers.isEmpty {
                        Text("Type a shortcut…").foregroundStyle(.secondary)
                    } else {
                        KeyComboView(modifiers: liveModifiers, trigger: nil)
                    }
                } else if let key {
                    KeyComboView(modifiers: modifiers, trigger: .key(key))
                } else {
                    Text("Click to record").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                    .foregroundStyle(isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .symbolEffect(.pulse, isActive: isRecording)
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 32)
            .background(.background, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isRecording ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.separator), lineWidth: isRecording ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .focusRing(.rect(cornerRadius: 8))
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        liveModifiers = []
        let setPaused = services.setBindingsPaused
        setPaused(true)
        resumeBindings = { setPaused(false) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        resumeBindings?()
        resumeBindings = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = Self.modifiers(of: event.modifierFlags)
        // Caps Lock working as a modifier arrives as F18 going down and up.
        if event.keyCode == Self.capsLockKeyCode {
            if event.type == .keyDown { liveModifiers.insert(.capsLock) }
            if event.type == .keyUp { liveModifiers.remove(.capsLock) }
            return
        }
        if event.type == .keyUp { return }
        if event.type == .flagsChanged {
            liveModifiers = flags.union(liveModifiers.intersection(.capsLock))
            return
        }
        if event.keyCode == 53 && flags.isEmpty {
            stop()
            return
        }
        if let name = KeyboardLayout.current().name(for: event.keyCode) {
            // Some event sources (remote control, automation) report modifiers only through
            // flag changes, so combine both.
            modifiers = flags.union(liveModifiers)
            key = name
        }
        stop()
    }

    /// F18, which Caps Lock is remapped to while it works as a modifier.
    static let capsLockKeyCode: UInt16 = 79

    static func modifiers(of flags: NSEvent.ModifierFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}

/// Toggles for picking a set of modifiers.
struct ModifierPicker: View {
    @Binding var modifiers: Modifiers
    /// Offers Caps Lock, which works as a modifier only when Moss remaps it.
    var offersCapsLock = false

    var body: some View {
        HStack(spacing: 4) {
            if offersCapsLock { toggle(.capsLock, "⇪", "Caps Lock") }
            toggle(.control, "⌃", "Control")
            toggle(.option, "⌥", "Option")
            toggle(.shift, "⇧", "Shift")
            toggle(.command, "⌘", "Command")
        }
    }

    private func toggle(_ modifier: Modifiers, _ symbol: String, _ name: String) -> some View {
        let isOn = modifiers.contains(modifier)
        return Button {
            if isOn { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        } label: {
            Text(symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 28)
                .background(isOn ? AnyShapeStyle(Design.accent) : AnyShapeStyle(.background), in: .rect(cornerRadius: 7))
                .foregroundStyle(isOn ? Design.onAccent : .primary)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator) }
        }
        .buttonStyle(.plain)
        .focusRing(.rect(cornerRadius: 7))
        .help(name)
    }
}
