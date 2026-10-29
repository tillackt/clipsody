import AppKit
import Carbon
import ClippboardCore

/// Button that records the next key combination pressed while it is focused.
final class HotKeyRecorder: NSButton {
    var hotkey: String {
        didSet { updateTitle() }
    }
    var onChange: ((String) -> Void)?
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

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func startRecording() {
        isRecording = true
        title = "Tastenkombination drücken …"
        window?.makeFirstResponder(self)
        onRecordingChange?(true)
    }

    /// Ends a recording without changing the hotkey (window closed or left).
    func cancelRecording() {
        stopRecording()
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        updateTitle()
        onRecordingChange?(false)
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
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        // macOS 15+ refuses hotkeys without ⌘ or ⌃.
        guard !flags.isDisjoint(with: [.command, .control]), let key = HotKeySpec.keyName(for: event.keyCode) else {
            NSSound.beep()
            return
        }
        var parts: [String] = []
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        parts.append(key)
        hotkey = parts.joined(separator: "+")
        stopRecording()
        onChange?(hotkey)
    }

    private func updateTitle() {
        title = HotKeySpec(hotkey).map(KeyLabel.display) ?? hotkey
    }
}
