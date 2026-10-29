import AppKit
import ApplicationServices
import ClippboardCore

/// Supplies the TIFF version of a pasted image only if the receiving app asks for it;
/// a 5K screenshot is about 30 MB as TIFF.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .tiff, let tiff = ImageIngest.tiff(fromPNG: png) {
            item.setData(tiff, forType: .tiff)
        }
    }
}

@MainActor
enum Paster {
    /// Kept alive until the next paste; the pasteboard item does not own its data provider.
    private static var tiffProvider: TIFFProvider?

    static func isTrusted(prompt: Bool) -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt, which Swift 6 treats as unsafe global state.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Puts the item on the pasteboard; returns false if there is nothing left to paste
    /// (image file or all copied files gone). `rich` is added for text when given.
    static func write(_ item: ClipItem, imageURL: URL?, rich: RichText?) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
            if let rich {
                pasteboard.setData(rich.data, forType: NSPasteboard.PasteboardType(rich.type))
            }
        case .image:
            guard let imageURL, let png = try? Data(contentsOf: imageURL) else { return false }
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            // Some older apps only accept TIFF.
            let provider = TIFFProvider(png: png)
            item.setDataProvider(provider, forTypes: [.tiff])
            tiffProvider = provider
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
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
