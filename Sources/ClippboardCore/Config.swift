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
    /// Display names for the defaults, shown when such an app is not installed.
    public static let defaultIgnoredAppNames = [
        "com.1password.1password": "1Password 8",
        "com.agilebits.onepassword7": "1Password 7",
        "com.apple.keychainaccess": "Schlüsselbundverwaltung",
        "com.apple.Passwords": "Passwörter",
        "com.bitwarden.desktop": "Bitwarden",
        "org.keepassxc.keepassxc": "KeePassXC",
        "com.markmcguill.strongbox.mac": "Strongbox",
        "in.sinew.Enpass-Desktop": "Enpass",
    ]

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
