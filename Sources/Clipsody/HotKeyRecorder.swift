import AppKit
import Carbon
import ClipsodyCore

/// Button that records the next key combination pressed while it is focused.
final class HotKeyRecorder: NSButton {
    var hotkey: String {
        didSet { updateTitle() }
    }
    var onChange: ((String) -> Void)?
    /// true when recording starts, false when it ends without a new key. A recorded key arrives
    /// through `onChange` only, so the owner registers once instead of restoring the old key first.
    var onRecordingChange: ((Bool) -> Void)?
    private var isRecording = false

    init(hotkey: String) {
        self.hotkey = hotkey
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(startRecording)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        isRecording = true
        title = String(localized: "Press shortcut…")
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
        announce(String(localized: "Press a key combination; Escape cancels"))
    }

    /// Ends a recording without changing the hotkey (window closed or left).
    func cancelRecording() {
        stopRecording()
    }

    private func stopRecording(recorded: Bool = false) {
        guard isRecording else { return }
        isRecording = false
        updateTitle()
        if !recorded { onRecordingChange?(false) }
        announce(String(localized: "Shortcut \(title)"))
    }

    // ⌘-combinations arrive here instead of keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { // Esc cancels
            stopRecording()
            return
        }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= HotKeySpec.control }
        if event.modifierFlags.contains(.option) { modifiers |= HotKeySpec.option }
        if event.modifierFlags.contains(.shift) { modifiers |= HotKeySpec.shift }
        if event.modifierFlags.contains(.command) { modifiers |= HotKeySpec.command }
        // Unknown keys and combinations without ⌘ or ⌃ (refused by macOS 15+) keep recording.
        guard let spec = HotKeySpec(keyCode: event.keyCode, modifiers: modifiers) else {
            NSSound.beep()
            return
        }
        hotkey = spec.configString
        stopRecording(recorded: true)
        onChange?(hotkey)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func updateTitle() {
        title = HotKeySpec(hotkey).map(KeyLabel.display) ?? hotkey
    }
}
