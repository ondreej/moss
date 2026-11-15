import Carbon.HIToolbox

/// Resolves key names from the configuration to the physical keys of the active keyboard layout.
///
/// Keys are named by the character they type (`q`, `1`, `-`), so shortcuts follow the user's
/// layout. A character that needs Shift on this layout (digits on AZERTY, for example)
/// resolves to the key that types it, and anything the layout cannot type falls back to the
/// key's position on a US keyboard.
public struct KeyboardLayout: Sendable {
    private var plain: [String: UInt16] = [:]
    private var shifted: [String: UInt16] = [:]
    private var characters: [UInt16: String] = [:]

    public init() {}

    public static let specialKeys: [String: UInt16] = [
        "return": 36, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "delete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119,
        "page_up": 116, "page_down": 121, "help": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86, "kp_5": 87, "kp_6": 88,
        "kp_7": 89, "kp_8": 91, "kp_9": 92, "kp_decimal": 65, "kp_multiply": 67, "kp_add": 69,
        "kp_clear": 71, "kp_divide": 75, "kp_enter": 76, "kp_subtract": 78, "kp_equal": 81,
    ]

    /// Key positions on an ANSI US keyboard.
    public static let usPositions: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "§": 10,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20,
        "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
        "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
    ]

    /// The layout of the current input source. Text Input Sources must be queried on the main thread.
    @MainActor
    public static func current() -> KeyboardLayout {
        var layout = KeyboardLayout()
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return layout }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in UInt16(0)..<128 where !specialKeys.values.contains(code) {
                if let character = translate(code, shift: false, layout: base) {
                    if layout.plain[character] == nil { layout.plain[character] = code }
                    layout.characters[code] = character
                }
                if let character = translate(code, shift: true, layout: base), layout.shifted[character] == nil {
                    layout.shifted[character] = code
                }
            }
        }
        return layout
    }

    private static func translate(_ code: UInt16, shift: Bool, layout: UnsafePointer<UCKeyboardLayout>) -> String? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = UCKeyTranslate(
            layout, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
        )
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length).lowercased()
        guard let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return text
    }

    /// The key code for a canonical key name.
    public func keyCode(for name: String) -> UInt16? {
        if let code = Self.specialKeys[name] { return code }
        return plain[name] ?? shifted[name] ?? Self.usPositions[name]
    }

    /// The canonical key name for a key code: a special key's name or the character it types.
    public func name(for keyCode: UInt16) -> String? {
        if let special = Self.specialKeys.first(where: { $0.value == keyCode })?.key { return special }
        return characters[keyCode] ?? Self.usPositions.first { $0.value == keyCode }?.key
    }
}
