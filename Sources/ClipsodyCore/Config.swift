import Foundation

/// User settings, read from ~/Library/Application Support/Clipsody/config.json.
public struct Config: Codable, Equatable, Sendable {
    public var hotkey = "cmd+option+c"
    public var retentionDays = 7
    public var maxItems = 1000
    public var keepImages = true
    /// Bundle IDs whose copies are never recorded (password managers etc.).
    public var ignoredApps = Self.defaultIgnoredApps.flatMap { $0 }
    /// How many generations of `defaultIgnoredApps` this configuration has seen.
    public var ignoredAppsDefaultsVersion = Self.defaultIgnoredApps.count
    /// Whether Clipsody looks for a new version once a day; nil until the user has been asked.
    /// Clipsody uses no network unless this is true or the user checks by hand.
    public var checkForUpdates: Bool?

    /// Default ignored apps by the release that introduced them. Append a new generation for new
    /// defaults: existing configurations receive it once, and apps the user removed stay removed.
    /// Display names for the defaults, shown when such an app is not installed.
    public static let defaultIgnoredAppNames = [
        // A bundle ID and an app name; the generic-password rule of the secret scanner mistakes it for a password.
        "com.1password.1password": "1Password 8", // betterleaks:allow
        "com.agilebits.onepassword7": "1Password 7",
        "com.apple.keychainaccess": String(localized: "Keychain Access"),
        "com.apple.Passwords": String(localized: "Passwords"),
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
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        hotkey = try container.decodeIfPresent(String.self, forKey: .hotkey) ?? defaults.hotkey
        retentionDays = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .retentionDays) ?? defaults.retentionDays,
                                   to: Self.retentionRange)
        maxItems = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .maxItems) ?? defaults.maxItems, to: Self.maxItemsRange)
        keepImages = try container.decodeIfPresent(Bool.self, forKey: .keepImages) ?? defaults.keepImages
        ignoredApps = try container.decodeIfPresent([String].self, forKey: .ignoredApps) ?? defaults.ignoredApps
        // Files written before versioning saw only the first generation.
        let seen = try container.decodeIfPresent(Int.self, forKey: .ignoredAppsDefaultsVersion) ?? 1
        for added in Self.defaultIgnoredApps.dropFirst(max(seen, 0)).joined() where !ignoredApps.contains(added) {
            ignoredApps.append(added)
        }
        ignoredAppsDefaultsVersion = Self.defaultIgnoredApps.count
        checkForUpdates = try container.decodeIfPresent(Bool.self, forKey: .checkForUpdates)
    }

    public static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("config.json")
    }

    /// `onInvalidFile` is called with the backup of an unreadable config.json, which is moved aside
    /// (config.json.bad) so the next save does not silently replace the user's settings.
    public static func load(from directory: URL, onInvalidFile: (URL) -> Void = { _ in }) -> Config {
        if let data = try? Data(contentsOf: url(in: directory)) {
            do {
                return try JSONDecoder().decode(Config.self, from: data)
            } catch {
                logger.error("Invalid config.json, using defaults: \(String(describing: error), privacy: .public)")
                let backup = directory.appendingPathComponent("config.json.bad")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.moveItem(at: url(in: directory), to: backup)
                onInvalidFile(backup)
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
            // Atomic: a crash while writing must not leave a half file that loads as "invalid".
            try encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
            FilePermissions.set(0o600, of: Self.url(in: directory))
        } catch {
            logger.error("Could not save config.json: \(String(describing: error), privacy: .public)")
        }
    }
}
