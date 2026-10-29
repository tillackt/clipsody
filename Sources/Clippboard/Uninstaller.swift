import AppKit
import ClippboardCore
import ServiceManagement

/// Removes Clippboard from this Mac: history, settings, login item, privacy permissions, the
/// contents of the decoder service's sandbox container, and finally the app itself (to the Trash).
/// macOS does not tell an app that it is dragged to the Trash, so this is the only way to leave
/// nothing behind.
@MainActor
enum Uninstaller {
    /// Paths that could not be removed; the caller shows them, the app quits either way.
    static func run(dataDirectory: URL) -> [String] {
        let fileManager = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "local.thorsten.clippboard"
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var failed: [String] = []

        try? SMAppService.mainApp.unregister()
        // Accessibility and any other permission granted to the app.
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "All", bundleID]
        try? tcc.run()
        tcc.waitUntilExit()

        // The preferences daemon writes an emptied domain back to disk; wait for that before the
        // file is deleted, or an empty plist reappears.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        // Since macOS 14 only the container manager may delete a container itself; its contents
        // go, the empty, protected shell stays and holds no user data. Not reported as a failure.
        let container = library.appendingPathComponent("Containers/\(bundleID).decoder")
        try? fileManager.removeItem(at: container)

        let leftovers = [
            dataDirectory,
            library.appendingPathComponent("Preferences/\(bundleID).plist"),
            library.appendingPathComponent("Application Scripts/\(bundleID).decoder"),
            library.appendingPathComponent("Caches/\(bundleID)"),
            library.appendingPathComponent("HTTPStorages/\(bundleID)"),
            library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
        ]
        for url in leftovers where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failed.append((url.path as NSString).abbreviatingWithTildeInPath)
            }
        }

        do {
            try fileManager.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            failed.append(Bundle.main.bundlePath)
        }
        return failed
    }
}
