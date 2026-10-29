import AppKit
import ApplicationServices

enum Paster {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Puts the item on the pasteboard; returns false if there is nothing left to paste
    /// (image file or all copied files gone).
    static func write(_ item: ClipItem, store: Store, withFormatting: Bool) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
            if withFormatting, let rich = store.richText(for: item) {
                pasteboard.setData(rich.data, forType: rich.type)
            }
        case .image:
            guard let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) else { return false }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            // Some older apps only accept TIFF.
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        case .files:
            let urls = item.filePaths
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { NSURL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls)
        }
        return true
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
