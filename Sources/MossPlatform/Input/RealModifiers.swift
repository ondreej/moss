import MossCore

/// The modifiers the user really holds while Caps Lock is Hyper, apart from those Hyper presses
/// itself. Hyper keeps every modifier down, so an event cannot say whether a modifier key went
/// down or up: each key alternates between the two instead.
struct RealModifiers {
    /// The modifier each modifier key stands for, left and right.
    static let keys: [UInt16: Modifiers] = [
        56: .shift, 60: .shift, 59: .control, 62: .control, 58: .option, 61: .option, 55: .command, 54: .command, 63: .function,
    ]

    /// Held since before Caps Lock went down.
    private var heldBefore: Modifiers = []
    /// Modifier keys pressed since.
    private var keysDown: Set<UInt16> = []

    /// Caps Lock went down while `held` were already down.
    mutating func begin(holding held: Modifiers) {
        heldBefore = held
        keysDown = []
    }

    mutating func end() {
        heldBefore = []
        keysDown = []
    }

    /// A modifier key went down or up. Returns `false` for other keys.
    @discardableResult
    mutating func keyChanged(_ code: UInt16) -> Bool {
        guard let modifier = Self.keys[code] else { return false }
        if keysDown.remove(code) == nil {
            if heldBefore.contains(modifier) {
                heldBefore.remove(modifier)
            } else {
                keysDown.insert(code)
            }
        }
        return true
    }

    var modifiers: Modifiers {
        keysDown.reduce(heldBefore) { $0.union(Self.keys[$1] ?? []) }
    }
}
