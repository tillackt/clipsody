import ClipsodyCore
import Foundation

/// Carries data over from the app's old name, Clippboard (bundle ID local.thorsten.clippboard):
/// the history folder, and the language and settings tab chosen in the app. Runs at every launch
/// and does nothing once the old data is gone.
enum LegacyMigration {
    static let legacyBundleID = "local.thorsten.clippboard"
    /// Keys the app itself wrote into its preferences; everything else there was macOS' own.
    private static let preferenceKeys = ["AppleLanguages", "SettingsSelectedTab"]

    static func run() {
        if Store.adoptLegacyDirectory() {
            logger.notice("Moved the data folder from Clippboard to Clipsody")
        }
        let defaults = UserDefaults.standard
        guard let legacy = defaults.persistentDomain(forName: legacyBundleID) else { return }
        let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in preferenceKeys where current[key] == nil {
            if let value = legacy[key] { defaults.set(value, forKey: key) }
        }
        // Emptied first and synced, or the preferences daemon writes an empty plist back.
        defaults.removePersistentDomain(forName: legacyBundleID)
        defaults.synchronize()
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(legacyBundleID).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
