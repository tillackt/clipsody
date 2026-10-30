import AppKit
import ClipsodyCore
import ClipsodyServices

/// The update check in the app. Clipsody asks once whether it may check automatically (off unless the
/// user agrees), then checks once a day while that is on, and whenever the user asks. A version found
/// in the background only marks the menu bar icon and adds a menu item, so no alert takes the focus
/// while the user types elsewhere. The user downloads a new version from the release page.
@MainActor
final class UpdateController {
    private let coordinator: UpdateCoordinator
    private let currentVersion: String
    private var timer: Timer?
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
