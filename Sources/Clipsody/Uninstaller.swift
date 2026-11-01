import AppKit
import ClipsodyCore
import ServiceManagement

/// Removes Clipsody from this Mac: history, snippets, settings, login item, privacy permissions, the
/// contents of the decoder service's sandbox container, and finally the app itself (to the Trash).
/// macOS does not tell an app that it is dragged to the Trash, so this is the only way to leave
/// nothing behind.
@MainActor
enum Uninstaller {
    /// The app's bundle ID, but only when running from a real Clipsody.app. Run from the build
    /// folder (`swift run`), the "bundle" is the folder holding the executable, which must never be
    /// trashed; an empty or odd ID would turn the paths below into whole Library folders.
    static var bundleID: String? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.executableURL?.lastPathComponent == "Clipsody",
              let id = bundle.bundleIdentifier,
              id.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/) != nil else { return nil }
        return id
    }

    /// Paths that could not be removed; the caller shows them, the app quits either way.
    /// Does nothing outside a real app bundle (see `bundleID`).
    static func run(dataDirectory: URL, snippetsDirectory: URL) -> [String] {
        guard let bundleID else { return [] }
        let fileManager = FileManager.default
        let library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        var failed: [String] = []

        try? SMAppService.mainApp.unregister()
        // Accessibility and any other permission granted to the app.
        let tcc = Process()
        tcc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tcc.arguments = ["reset", "All", bundleID]
        // waitUntilExit on a task that never launched raises an exception.
        if (try? tcc.run()) != nil { tcc.waitUntilExit() }

        // The preferences daemon writes an emptied domain back to disk; wait for that before the
        // file is deleted, or an empty plist reappears.
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        // Since macOS 14 only the container manager may delete a container itself; its contents
        // go, the empty, protected shell with the manager's metadata stays and holds no user data.
        // Anything else that remains (or cannot be listed) is reported.
        let container = library.appendingPathComponent("Containers/\(bundleID).decoder")
        if fileManager.fileExists(atPath: container.path) {
            try? fileManager.removeItem(at: container)
            if fileManager.fileExists(atPath: container.path) {
                let remaining = try? fileManager.contentsOfDirectory(atPath: container.path)
                if remaining.map({ !Set($0).isSubset(of: [".com.apple.containermanagerd.metadata.plist"]) }) ?? true {
                    failed.append((container.path as NSString).abbreviatingWithTildeInPath)
                }
            }
        }

        let leftovers = [
            dataDirectory,
            snippetsDirectory,
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
