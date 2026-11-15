/// Names of keys. Internally, a printable key is identified by the character it types on the
/// active keyboard layout and other keys by a canonical name such as `return` or `page_up`;
/// shortcuts write them as `q`, `return`, `page-up` or `comma`.
public enum KeyNames {
    /// Keys written by name, with their canonical names. The first name of a key is the one written back.
    static let named: [(name: String, canonical: String)] = [
        ("return", "return"), ("enter", "return"), ("tab", "tab"), ("space", "space"), ("backspace", "backspace"),
        ("delete", "delete"), ("escape", "escape"), ("esc", "escape"),
        ("left", "left"), ("right", "right"), ("up", "up"), ("down", "down"), ("home", "home"), ("end", "end"),
        ("page-up", "page_up"), ("page-down", "page_down"), ("help", "help"),
        ("keypad-enter", "kp_enter"), ("keypad-plus", "kp_add"), ("keypad-minus", "kp_subtract"), ("keypad-multiply", "kp_multiply"),
        ("keypad-divide", "kp_divide"), ("keypad-decimal", "kp_decimal"), ("keypad-equals", "kp_equal"), ("keypad-clear", "kp_clear"),
    ] + (0...9).map { ("keypad-\($0)", "kp_\($0)") } + (1...20).map { ("f\($0)", "f\($0)") }

    /// Punctuation written by name, since some of it cannot be written in a chord.
    static let punctuation: [(name: String, character: String)] = [
        ("minus", "-"), ("equal", "="), ("plus", "+"), ("left-bracket", "["), ("right-bracket", "]"), ("backslash", "\\"),
        ("semicolon", ";"), ("quote", "'"), ("backtick", "`"), ("comma", ","), ("period", "."), ("slash", "/"), ("section", "§"),
    ]

    /// The canonical name of a key as written in a shortcut, or `nil` when no key has that name.
    public static func canonical(_ name: String) -> String? {
        let lower = name.lowercased()
        if let match = named.first(where: { $0.name == lower }) { return match.canonical }
        if let match = punctuation.first(where: { $0.name == lower }) { return match.character }
        // Any other single character is looked up on the keyboard layout.
        return lower.count == 1 ? lower : nil
    }

    /// How a key is written in a shortcut.
    public static func configName(for canonical: String) -> String {
        if let match = named.first(where: { $0.canonical == canonical }) { return match.name }
        if let match = punctuation.first(where: { $0.character == canonical }) { return match.name }
        return canonical.lowercased()
    }

    /// A compact symbol for display in user interfaces.
    public static func displayName(for canonical: String) -> String {
        switch canonical {
        case "return": "↩"
        case "tab": "⇥"
        case "space": "Space"
        case "backspace": "⌫"
        case "delete": "⌦"
        case "escape": "⎋"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "home": "↖"
        case "end": "↘"
        case "page_up": "⇞"
        case "page_down": "⇟"
        case "kp_enter": "⌤"
        default: canonical.uppercased()
        }
    }
}
