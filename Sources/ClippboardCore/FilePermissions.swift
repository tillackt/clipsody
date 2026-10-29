import Foundation

/// Keeps the history private on disk; used by Store and Config alike.
enum FilePermissions {
    static func set(_ mode: Int, of url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Time Machine and other backups would keep entries that "clear" and retention already removed.
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
