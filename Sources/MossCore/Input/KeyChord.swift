/// Modifiers and a trigger written together, such as `cmd-shift-t` or `mod-left-drag`.
///
/// `mod` stands for the main key chosen in the configuration, so a shortcut keeps working
/// when the main key changes.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public var modifiers: Modifiers
    public var key: Trigger

    /// How the main key is written in shortcuts.
    public static let mainKeyName = "mod"

    public init(modifiers: Modifiers, key: Trigger) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses a chord. `mod` is replaced by `mainKey`, and is an error without one.
    public init(parsing text: String, mainKey: Modifiers? = nil) throws(KeyBindingError) {
        let parts = text.trimmingWhitespace.lowercased().split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var modifiers: Modifiers = []
        var index = 0
        // Modifiers come first; whatever follows is the trigger, which may itself contain dashes.
        while index < parts.count - 1 {
            if parts[index] == Self.mainKeyName {
                guard let mainKey else { throw .mainKeyUnavailable }
                modifiers.formUnion(mainKey)
            } else if let modifier = Modifiers(name: parts[index]) {
                modifiers.formUnion(modifier)
            } else {
                break
            }
            index += 1
        }
        self.init(modifiers: modifiers, key: try Trigger(parsing: parts[index...].joined(separator: "-")))
    }

    /// The chord as written, with the main key, if given and held, written `mod`.
    public func description(mainKey: Modifiers?) -> String {
        var modifiers = self.modifiers
        var parts: [String] = []
        // Hyper reads better than the main key plus the rest of it, as in `hyper-h`.
        let isHyperWithin = modifiers.isSuperset(of: .hyper) && mainKey != .hyper && mainKey.map(Modifiers.hyper.isSuperset(of:)) == true
        if let mainKey, !mainKey.isEmpty, modifiers.isSuperset(of: mainKey), !isHyperWithin {
            parts.append(Self.mainKeyName)
            modifiers.subtract(mainKey)
        }
        if !modifiers.isEmpty { parts.append(modifiers.description) }
        parts.append(key.description)
        return parts.joined(separator: "-")
    }

    public var description: String { description(mainKey: nil) }
}
