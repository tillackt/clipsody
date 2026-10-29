import Carbon
import Foundation

/// User settings, read from ~/Library/Application Support/Clippboard/config.json.
struct Config: Codable {
    var hotkey = "cmd+option+c"
    var retentionDays = 7
    var maxItems = 1000
    var keepImages = true
    /// Bundle IDs whose copies are never recorded (password managers etc.).
    var ignoredApps = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
    ]

    init() {}

    // Missing keys fall back to the defaults so the file may list only what differs.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
        keepImages = try c.decodeIfPresent(Bool.self, forKey: .keepImages) ?? d.keepImages
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? d.ignoredApps
    }

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("config.json")
    }

    static func load(from directory: URL) -> Config {
        if let data = try? Data(contentsOf: url(in: directory)) {
            do {
                return try JSONDecoder().decode(Config.self, from: data)
            } catch {
                log.error("Invalid config.json, using defaults: \(error, privacy: .public)")
                return Config()
            }
        }
        let config = Config()
        config.save(to: directory)
        return config
    }

    func save(to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(self).write(to: Self.url(in: directory))
    }
}

/// Parses strings like "cmd+option+c" into a Carbon key code and modifier mask.
struct HotKeySpec {
    let keyCode: UInt32
    let modifiers: UInt32
    let display: String

    private static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "space": 49,
    ]

    /// Config name of a key code ("c", "5", "space"), nil for keys the hotkey cannot use.
    static func keyName(for keyCode: UInt16) -> String? {
        keyCodes.first { $0.value == UInt32(keyCode) }?.key
    }

    init?(_ string: String) {
        var modifiers: UInt32 = 0
        var symbols = ""
        var key: (code: UInt32, name: String)?
        for part in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            default:
                guard let code = Self.keyCodes[part] else { return nil }
                key = (code, part == "space" ? "Space" : part.uppercased())
            }
        }
        guard let key, modifiers != 0 else { return nil }
        // Same order macOS uses in menus: ⌃⌥⇧⌘
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        self.keyCode = key.code
        self.modifiers = modifiers
        self.display = symbols + key.name
    }
}
