import Foundation

/// User settings, read from ~/Library/Application Support/Clippboard/config.json.
public struct Config: Codable, Equatable, Sendable {
    public var hotkey = "cmd+option+c"
    public var retentionDays = 7
    public var maxItems = 1000
    public var keepImages = true
    /// Bundle IDs whose copies are never recorded (password managers etc.).
    public var ignoredApps = Self.defaultIgnoredApps.flatMap { $0 }
    /// How many generations of `defaultIgnoredApps` this configuration has seen.
    public var ignoredAppsDefaultsVersion = Self.defaultIgnoredApps.count

    /// Default ignored apps by the release that introduced them. Append a new generation for new
    /// defaults: existing configurations receive it once, and apps the user removed stay removed.
    public static let defaultIgnoredApps: [[String]] = [
        ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
         "com.apple.Passwords", "com.bitwarden.desktop"],
        ["org.keepassxc.keepassxc", "com.markmcguill.strongbox.mac", "in.sinew.Enpass-Desktop"],
    ]

    public static let retentionRange = 1...365
    public static let maxItemsRange = 50...10_000

    public init() {}

    // Missing keys fall back to the defaults so the file may list only what differs.
    // Numbers are clamped: a hand-edited "maxItems": 0 must not wipe the history.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        retentionDays = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays,
                                   to: Self.retentionRange)
        maxItems = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems, to: Self.maxItemsRange)
        keepImages = try c.decodeIfPresent(Bool.self, forKey: .keepImages) ?? d.keepImages
        ignoredApps = try c.decodeIfPresent([String].self, forKey: .ignoredApps) ?? d.ignoredApps
        // Files written before versioning saw only the first generation.
        let seen = try c.decodeIfPresent(Int.self, forKey: .ignoredAppsDefaultsVersion) ?? 1
        for added in Self.defaultIgnoredApps.dropFirst(max(seen, 0)).joined() where !ignoredApps.contains(added) {
            ignoredApps.append(added)
        }
        ignoredAppsDefaultsVersion = Self.defaultIgnoredApps.count
    }

    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("config.json")
    }

    public static func load(from directory: URL) -> Config {
        if let data = try? Data(contentsOf: url(in: directory)) {
            do {
                return try JSONDecoder().decode(Config.self, from: data)
            } catch {
                logger.error("Invalid config.json, using defaults: \(String(describing: error), privacy: .public)")
                return Config()
            }
        }
        let config = Config()
        config.save(to: directory)
        return config
    }

    public func save(to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(self).write(to: Self.url(in: directory))
            FilePermissions.set(0o600, of: Self.url(in: directory))
        } catch {
            logger.error("Could not save config.json: \(String(describing: error), privacy: .public)")
        }
    }
}

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
