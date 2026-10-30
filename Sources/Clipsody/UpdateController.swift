import AppKit
import ClipsodyCore
import ClipsodyServices

/// The update check. Clipsody asks once whether it may check automatically (off unless the user
/// agrees), then checks once a day while that is on, and whenever the user asks. A new version is only
/// announced: the user downloads it from the release page, as on first install.
@MainActor
final class UpdateController {
    private static let lastCheckKey = "UpdateLastCheck"
    private static let announcedVersionKey = "UpdateAnnouncedVersion"

    private let checker: UpdateChecker
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    private var timer: Timer?
    private var isChecking = false

    init(checker: UpdateChecker = UpdateChecker()) {
        self.checker = checker
    }

    /// Asks whether to check automatically; the answer goes into the settings.
    static func askForConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Check for updates automatically?")
        alert.informativeText = String(localized: """
            Once a day Clipsody can ask GitHub whether a new version is available. Only the version number \
            is fetched; nothing from your clipboard is sent, but GitHub sees your IP address. You can change \
            this at any time in Settings → General.
            """)
        alert.addButton(withTitle: String(localized: "Check Automatically"))
        alert.addButton(withTitle: String(localized: "Don’t Check"))
        NSApp.bringToFront()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Starts or stops the daily check to match the settings.
    func apply(_ config: Config) {
        timer?.invalidate()
        timer = nil
        guard config.checkForUpdates == true else { return }
        // Looks hourly whether a day has passed since the last check: a sleeping Mac skips timer fires,
        // and the time of the last check survives restarts.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 300
        checkIfDue()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Checks right away and always reports the result.
    func checkNow() {
        check(userInitiated: true)
    }

    private func checkIfDue() {
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard UpdateCheck.isDue(lastCheck: lastCheck) else { return }
        check(userInitiated: false)
    }

    private func check(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        let checker = checker
        let currentVersion = currentVersion
        Task {
            do {
                let release = try await checker.latestRelease(currentVersion: currentVersion)
                finish(.success(release), userInitiated: userInitiated)
            } catch {
                finish(.failure(error), userInitiated: userInitiated)
            }
        }
    }

    private func finish(_ result: Result<UpdateCheck.Release, Error>, userInitiated: Bool) {
        isChecking = false
        switch result {
        case .success(let release):
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            if UpdateCheck.isNewer(release, than: currentVersion) {
                // The automatic check announces each version once; checking by hand always shows it.
                let version = release.version.description
                guard userInitiated || UserDefaults.standard.string(forKey: Self.announcedVersionKey) != version else { return }
                UserDefaults.standard.set(version, forKey: Self.announcedVersionKey)
                announce(release)
            } else if userInitiated {
                inform(String(localized: "Clipsody is up to date."),
                       String(localized: "Version \(currentVersion) is the latest version."))
            }
        case .failure(let error):
            // Not recorded as a check: an offline Mac tries again within the hour.
            logger.error("Update check failed: \(String(describing: error), privacy: .public)")
            if userInitiated {
                inform(String(localized: "Clipsody could not check for updates."),
                       String(localized: "Please check your internet connection and try again later."))
            }
        }
    }

    private func announce(_ release: UpdateCheck.Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clipsody \(release.version.description) is available")
        alert.informativeText = String(localized: """
            You have version \(currentVersion). The release page lists what is new and has the download.
            """)
        alert.addButton(withTitle: String(localized: "Open Release Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.bringToFront()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.bringToFront()
        alert.runModal()
    }
}
