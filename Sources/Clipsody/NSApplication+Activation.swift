import AppKit

extension NSApplication {
    /// Brings Clipsody's own windows (settings, alerts) to the front.
    func bringToFront() {
        if #available(macOS 14.0, *) {
            activate()
        } else {
            activate(ignoringOtherApps: true)
        }
    }
}
