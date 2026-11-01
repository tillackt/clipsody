import AppKit
import ClipsodyCore
import ClipsodyServices

/// The update check in the app. Clipsody asks once whether it may check automatically (off unless the
/// user agrees), then checks once a day while that is on, and whenever the user asks. A version found
/// in the background only marks the menu bar icon and adds a menu item, so no alert takes the focus
/// while the user types elsewhere. Only when the user clicks Install does Clipsody download the new
/// version, check its signature and replace itself (UpdateInstaller), then restart.
@MainActor
final class UpdateController {
    private let coordinator: UpdateCoordinator
    private let currentVersion: String
    private let installer = UpdateInstaller()
    private var timer: Timer?
    /// Set while an update installs, so a second click does not start another one.
    private var installing = false
    /// A newer version, found by any check; shown in the menu bar until Clipsody restarts.
    private(set) var available: UpdateCheck.Release?
    /// Called when `available` changes.
    var onAvailableChange: () -> Void = {}

    init(currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0") {
        self.currentVersion = currentVersion
        coordinator = UpdateCoordinator(currentVersion: currentVersion)
        coordinator.onOutcome = { [unowned self] outcome in show(outcome) }
    }

    /// Asks whether to check automatically; the answer goes into the settings. Return answers no.
    static func askForConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Check for updates automatically?")
        alert.informativeText = String(localized: """
            Once a day Clipsody can ask GitHub whether a new version is available. Nothing from your clipboard \
            is sent; GitHub sees your IP address and the Clipsody version. You can change this at any time in \
            Settings → General.
            """)
        let allow = alert.addButton(withTitle: String(localized: "Check Automatically"))
        let decline = alert.addButton(withTitle: String(localized: "Don’t Check"))
        // The default button must not opt in.
        allow.keyEquivalent = ""
        decline.keyEquivalent = "\r"
        NSApp.bringToFront()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Starts or stops the daily check to match the settings.
    func apply(_ config: Config) {
        timer?.invalidate()
        timer = nil
        guard config.checkForUpdates == true else {
            coordinator.cancelAutomatic()
            return
        }
        // Looks hourly whether a day has passed since the last check: a sleeping Mac skips timer fires,
        // and the time of the last check survives restarts.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator.checkIfDue() }
        }
        timer?.tolerance = 300
        coordinator.checkIfDue()
    }

    /// Nothing runs or reports afterwards (uninstall).
    func stop() {
        timer?.invalidate()
        timer = nil
        coordinator.stop()
    }

    /// Checks right away and always reports the result.
    func checkNow() {
        coordinator.checkNow()
    }

    /// The menu item of a version found in the background.
    func showAvailable() {
        if let available { announce(available) }
    }

    private func show(_ outcome: UpdateCoordinator.Outcome) {
        switch outcome {
        case .available(let release, let userInitiated):
            available = release
            onAvailableChange()
            if userInitiated { announce(release) }
        case .upToDate:
            inform(String(localized: "Clipsody is up to date."),
                   String(localized: "Version \(currentVersion) is the latest version."))
        case .noConnection:
            inform(String(localized: "Clipsody could not check for updates."),
                   String(localized: "Please check your internet connection and try again later."))
        case .unusableAnswer:
            inform(String(localized: "Clipsody could not check for updates."),
                   String(localized: "GitHub did not give a usable answer. Please try again later."))
        }
    }

    private func announce(_ release: UpdateCheck.Release) {
        guard !installing else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clipsody \(release.version.description) is available")
        alert.informativeText = String(localized: """
            You have version \(currentVersion). Clipsody downloads the new version from GitHub, checks that it \
            carries the Clipsody signature, replaces itself and restarts. Your history and settings stay.
            """)
        alert.addButton(withTitle: String(localized: "Install and Restart"))
        alert.addButton(withTitle: String(localized: "What’s New"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.bringToFront()
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.pageURL)
        default: break
        }
    }

    private func install(_ release: UpdateCheck.Release) {
        installing = true
        let window = UpdateProgressWindow(version: release.version.description)
        let appURL = Bundle.main.bundleURL
        let installer = installer
        let currentVersion = currentVersion
        Task {
            do {
                try await installer.install(release, currentVersion: currentVersion, replacing: appURL) { step in
                    Task { @MainActor in window.show(step) }
                }
                window.close()
                // Retries while LaunchServices still refuses the new app right after this one quit.
                if !AppLanguage.relaunch() {
                    // The new version is in place; only the restart failed. No further update offers.
                    available = nil
                    onAvailableChange()
                    inform(String(localized: "Clipsody \(release.version.description) is installed."),
                           String(localized: "Quit Clipsody and open it again to use the new version."))
                }
            } catch {
                window.close()
                installing = false
                report(error as? UpdateInstaller.Failure, release: release)
            }
        }
    }

    private func report(_ failure: UpdateInstaller.Failure?, release: UpdateCheck.Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clipsody could not install the update.")
        alert.informativeText = switch failure {
        case .notWritable:
            String(localized: """
                Clipsody cannot replace itself in this folder. Download the new version from the release page \
                and drag it to Applications.
                """)
        case .download:
            String(localized: "The download failed. Please check your internet connection and try again later.")
        case .checksumMismatch, .noAppInDiskImage, .untrustedSignature, .wrongVersion:
            String(localized: """
                The downloaded file did not pass the check and was not installed. Your version is unchanged.
                """)
        case .replaceFailed, nil:
            String(localized: "The installed app could not be replaced. Your version is unchanged.")
        }
        alert.addButton(withTitle: String(localized: "Open Release Page"))
        alert.addButton(withTitle: String(localized: "OK"))
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
