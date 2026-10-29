import AppKit
import ApplicationServices

enum Paster {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func write(_ item: ClipItem, store: Store) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) else { return }
            pasteboard.setData(png, forType: .png)
            // Some older apps only accept TIFF.
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
    }

    /// Simulates ⌘V in the frontmost app. Requires Accessibility permission.
    static func sendPasteKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keep keys the user is still holding (e.g. ⏎ from selecting the entry) out of the synthetic event.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let vKey: CGKeyCode = 9
        // 0x08 is the device flag for the left ⌘ key; some apps (Electron, Java) check it.
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
