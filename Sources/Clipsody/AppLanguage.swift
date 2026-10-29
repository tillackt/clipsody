import AppKit

/// Language of the app's interface. Stored like the per-app language in System Settings
/// (AppleLanguages in the app's own defaults), so both stay in sync. Takes effect at launch.
@MainActor
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// Languages the app is translated into, as language codes ("de", "pt-BR").
    static var available: [String] {
        // Listed twice: once from CFBundleLocalizations, once from the .lproj folders.
        Set(Bundle.main.localizations).subtracting(["Base"])
            .sorted { displayName($0).localizedStandardCompare(displayName($1)) == .orderedAscending }
    }

    /// The chosen language, or nil to follow the system.
    static var selected: String? {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        return (domain?[key] as? [String])?.first
    }

    static func select(_ language: String?) {
        if let language {
            UserDefaults.standard.set([language], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The language the app shows when it follows the system.
    static var systemLanguage: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let preferred = global?[key] as? [String] ?? []
        return Bundle.preferredLocalizations(from: available, forPreferences: preferred).first ?? "en"
    }

    /// Name of the language in that language ("Deutsch", "Français"), so it can be found
    /// whatever language is currently shown.
    static func displayName(_ language: String) -> String {
        let locale = Locale(identifier: language)
        let name = locale.localizedString(forIdentifier: language) ?? language
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Starts a new instance once this one has quit; two instances would fight over the hotkey.
    static func relaunch() {
        // Right after the process is gone, LaunchServices may still refuse to open the app (-600);
        // retried for a few seconds, or the user would be left without a running Clipsody.
        let script = """
            while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
            for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 0.5; /usr/bin/open "$0" && exit 0; done
            exit 1
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
