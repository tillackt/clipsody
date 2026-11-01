import AppKit
import ClipsodyServices

/// A small window that shows what the installer is doing while an update downloads and installs.
@MainActor
final class UpdateProgressWindow {
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let indicator = NSProgressIndicator()
    private var closed = false

    init(version: String) {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 110),
                         styleMask: [.titled], backing: .buffered, defer: false)
        window.title = String(localized: "Updating Clipsody to \(version)")
        window.isReleasedWhenClosed = false
        window.level = .floating

        indicator.style = .bar
        indicator.isIndeterminate = true
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [label, indicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack
        indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
    }

    func show(_ step: UpdateInstaller.Step) {
        guard !closed else { return }
        label.stringValue = switch step {
        case .downloading: String(localized: "Downloading…")
        case .verifying: String(localized: "Checking the signature…")
        case .installing: String(localized: "Installing…")
        }
        guard !window.isVisible else { return }
        window.center()
        NSApp.bringToFront()
        window.makeKeyAndOrderFront(nil)
        indicator.startAnimation(nil)
    }

    func close() {
        closed = true
        indicator.stopAnimation(nil)
        window.orderOut(nil)
    }
}
