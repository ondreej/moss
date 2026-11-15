import MossCore
import MossKeyboard

/// Shortcuts indexed for constant-time lookup from the event tap.
struct BindingTable: Sendable {
    private struct KeyCombo: Hashable {
        var mode: String?
        var keyCode: UInt16
        var modifiers: Modifiers
    }

    private struct PointerCombo: Hashable {
        var mode: String?
        var trigger: Trigger
        var modifiers: Modifiers
    }

    private var keys: [KeyCombo: [KeyBinding]] = [:]
    private var pointer: [PointerCombo: [KeyBinding]] = [:]

    init() {}

    init(bindings: [KeyBinding], layout: KeyboardLayout) {
        for binding in bindings {
            switch binding.trigger {
            case .key(let name):
                guard let code = layout.keyCode(for: name) else { continue }
                keys[KeyCombo(mode: binding.mode, keyCode: code, modifiers: binding.modifiers), default: []].append(binding)
            case .keyCode(let code):
                keys[KeyCombo(mode: binding.mode, keyCode: code, modifiers: binding.modifiers), default: []].append(binding)
            case .drag, .scroll:
                pointer[PointerCombo(mode: binding.mode, trigger: binding.trigger, modifiers: binding.modifiers), default: []].append(binding)
            }
        }
    }

    var isEmpty: Bool { keys.isEmpty && pointer.isEmpty }

    /// Shortcuts for a key press. Fn only takes part when a shortcut asks for it: macOS sets the
    /// function flag on arrow and function keys by itself.
    func bindings(forKey code: UInt16, modifiers: Modifiers, mode: String?) -> [KeyBinding] {
        for candidate in Self.candidates(modifiers) {
            if let found = keys[KeyCombo(mode: mode, keyCode: code, modifiers: candidate)] { return found }
        }
        return []
    }

    func bindings(for trigger: Trigger, modifiers: Modifiers, mode: String?) -> [KeyBinding] {
        for candidate in Self.candidates(modifiers) {
            if let found = pointer[PointerCombo(mode: mode, trigger: trigger, modifiers: candidate)] { return found }
        }
        return []
    }

    /// Modifier sets to look a key up with: as held, then without Fn, which macOS sets on its
    /// own for arrow keys, function keys and keys pressed while one is down.
    private static func candidates(_ modifiers: Modifiers) -> [Modifiers] {
        modifiers.contains(.function) ? [modifiers, modifiers.subtracting(.function)] : [modifiers]
    }
}
