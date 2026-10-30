import AppKit

/// Whether macOS lets Clipsody read what other apps copy. Since macOS 15.4 the system can ask before
/// an app reads the general pasteboard in the background (pasteboard privacy), and the user can set
/// the app to Ask, Allow or Deny in System Settings → Privacy & Security. Clipsody lives on those
/// background reads, so it shows the state and stops reading while access is denied.
@MainActor
enum PasteboardAccess {
    enum State {
        /// macOS before 15.4: no pasteboard privacy, reading always works.
        case unrestricted
        /// The system may show its alert on the next read (also the state before the first alert).
        case ask
        case allowed
        case denied
    }

    static var state: State {
        guard #available(macOS 15.4, *) else { return .unrestricted }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        case .default, .ask: return .ask
        @unknown default: return .ask
        }
    }

    /// Privacy & Security in System Settings; the user picks the pasteboard setting there.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
