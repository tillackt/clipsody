import Foundation

/// Parses strings like "cmd+option+c" into a Carbon key code and modifier mask.
public struct HotKeySpec: Equatable, Sendable {
    // Carbon modifier masks (cmdKey, shiftKey, optionKey, controlKey), kept here so Core needs no Carbon.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    public let keyCode: UInt32
    public let modifiers: UInt32
    public let display: String

    // Virtual key codes of the ANSI layout (physical key positions).
    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49,
    ]

    /// ⌃⌥⇧⌘ symbols of the modifiers, in the order macOS uses in menus.
    public var modifierSymbols: String {
        Self.symbols(for: modifiers)
    }

    private static func symbols(for modifiers: UInt32) -> String {
        var symbols = ""
        if modifiers & control != 0 { symbols += "⌃" }
        if modifiers & option != 0 { symbols += "⌥" }
        if modifiers & shift != 0 { symbols += "⇧" }
        if modifiers & command != 0 { symbols += "⌘" }
        return symbols
    }

    /// Config name of a key code ("c", "5", "space"), nil for keys the hotkey cannot use.
    public static func keyName(for keyCode: UInt16) -> String? {
        keyCodes.first { $0.value == UInt32(keyCode) }?.key
    }

    /// Canonical config form ("ctrl+option+shift+cmd+c"), the format the settings recorder writes.
    public var configString: String {
        // Only parsed specs exist, so the key code always has a name.
        Self.configString(modifiers: modifiers, key: Self.keyName(for: UInt16(keyCode)) ?? "")
    }

    private static func configString(modifiers: UInt32, key: String) -> String {
        var parts: [String] = []
        if modifiers & control != 0 { parts.append("ctrl") }
        if modifiers & option != 0 { parts.append("option") }
        if modifiers & shift != 0 { parts.append("shift") }
        if modifiers & command != 0 { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// Spec of a pressed key with Carbon modifier masks; nil under the same rules as parsing.
    public init?(keyCode: UInt16, modifiers: UInt32) {
        guard let key = Self.keyName(for: keyCode) else { return nil }
        // Going through the parser keeps one place that decides which combinations are valid.
        self.init(Self.configString(modifiers: modifiers, key: key))
    }

    public init?(_ string: String) {
        var modifiers: UInt32 = 0
        var key: (code: UInt32, name: String)?
        for part in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers |= Self.control
            case "opt", "option", "alt": modifiers |= Self.option
            case "shift": modifiers |= Self.shift
            case "cmd", "command": modifiers |= Self.command
            default:
                guard let code = Self.keyCodes[part] else { return nil }
                key = (code, part == "space" ? "Space" : part.uppercased())
            }
        }
        // Since macOS 15 hotkeys need ⌘ or ⌃; ⌥ and ⇧ alone are refused by RegisterEventHotKey.
        guard let key, modifiers & (Self.command | Self.control) != 0 else { return nil }
        self.keyCode = key.code
        self.modifiers = modifiers
        self.display = Self.symbols(for: modifiers) + key.name
    }
}
