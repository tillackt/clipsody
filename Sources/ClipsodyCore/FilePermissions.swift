import Foundation

/// Keeps the history private on disk; used by Store and Config alike.
enum FilePermissions {
    /// Changes the mode only when it differs: every change updates the file's ctime and sends
    /// file system events, which a launch-time pass over all images would do for nothing.
    static func set(_ mode: Int, of url: URL) {
        let current = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        guard current != mode else { return }
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
