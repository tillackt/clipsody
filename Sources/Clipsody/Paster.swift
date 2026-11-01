import AppKit
import ApplicationServices
import ClipsodyCore
import ClipsodyServices

/// Supplies the TIFF version of a pasted image only if the receiving app asks for it;
/// a 5K screenshot is about 30 MB as TIFF.
private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data
    private let decoder: DecoderClient
    private let onFinished: @Sendable (ObjectIdentifier) -> Void

    init(png: Data, decoder: DecoderClient, onFinished: @escaping @Sendable (ObjectIdentifier) -> Void) {
        self.png = png
        self.decoder = decoder
        self.onFinished = onFinished
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        // The pasteboard asks on the main thread and waits; the conversion happens in the decoder
        // service, so the app does not decode the image itself.
        guard type == .tiff else { return }
        let png = png
        let decoder = decoder
        if let tiff = MainActor.assumeIsolated({ decoder.tiffBlocking(fromPNG: png) }) {
            item.setData(tiff, forType: .tiff)
        }
    }

    /// The pasteboard moved on (something else was copied): the image data is no longer needed.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        onFinished(ObjectIdentifier(self))
    }
}

/// Puts a history entry on the pasteboard and pastes it into the app the user came from.
@MainActor
final class Paster {
    private let decoder: DecoderClient

    init(decoder: DecoderClient) {
        self.decoder = decoder
    }

    /// The pasteboard item does not own its data provider, so it is kept here until released.
    private var tiffProvider: TIFFProvider?
    /// Pasteboard change count right after `tiffProvider` was written; tells whether our item is still there.
    private var tiffChangeCount: Int?
    /// Only the latest paste may send ⌘V; a quicker second one cancels the first.
    private var pasteTask: Task<Void, Never>?

    static func isTrusted(prompt: Bool) -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt, which Swift 6 treats as unsafe global state.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Writes the entry to the pasteboard and, when allowed and possible, sends ⌘V to `target`.
    /// Returns false if there was nothing to paste (image file or all copied files gone).
    func paste(_ item: ClipItem, imageURL: URL?, rich: RichText?, into target: NSRunningApplication?) -> Bool {
        pasteTask?.cancel()
        guard write(item, imageURL: imageURL, rich: rich) else { return false }

        guard Self.isTrusted(prompt: false) else {
            logger.error("Paste: no Accessibility permission, item only copied")
            NSSound.beep()
            _ = Self.isTrusted(prompt: true)
            return true
        }
        // Without a living target (Clipsody itself was in front, or the app quit) the entry is only copied.
        guard let target, !target.isTerminated else {
            logger.notice("Paste: no target app, item only copied")
            return true
        }
        // If Clipsody itself is active (e.g. the settings window was used), ⌘V would land here.
        if !target.isActive {
            if #available(macOS 14.0, *) { NSApp.yieldActivation(to: target) }
            target.activate(options: [])
        }
        let changeCount = NSPasteboard.general.changeCount
        pasteTask = Task {
            // Wait up to ~0.5 s for the target app to be frontmost, then let its window regain focus.
            for _ in 0..<20 where !Self.isFrontmost(target) {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if Self.isFrontmost(target) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Checked right before the keystroke: superseded by another paste, another app came to the
            // front (a chat, a notification), or the clipboard changed meanwhile. In each case ⌘V could
            // put something in the wrong place, so the entry just stays on the clipboard.
            guard !Task.isCancelled else { return }
            guard Self.isFrontmost(target), NSPasteboard.general.changeCount == changeCount else {
                logger.error("Paste: target not in front or clipboard changed, item only copied")
                NSSound.beep()
                return
            }
            logger.debug("Paste: ⌘V, kind \(item.kind.rawValue)")
            Self.sendPasteKeystroke()
        }
        return true
    }

    /// Pastes a plain text (a snippet) into `target`; Clipsody itself as target only copies it.
    /// True only if ⌘V goes out; without a target or the Accessibility permission the text is just copied.
    func pasteText(_ text: String, into target: NSRunningApplication?) -> Bool {
        let target = target?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : target
        let sendsKeystroke = Self.isTrusted(prompt: false) && target.map { !$0.isTerminated } == true
        let written = paste(ClipItem(id: 0, kind: .text, text: text, date: Date()), imageURL: nil, rich: nil, into: target)
        return written && sendsKeystroke
    }

    private static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// `rich` is added for text when given.
    private func write(_ item: ClipItem, imageURL: URL?, rich: RichText?) -> Bool {
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
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(png, forType: .png)
            // Some older apps only accept TIFF.
            let provider = TIFFProvider(png: png, decoder: decoder) { [weak self] finished in
                Task { @MainActor in
                    if let self, let current = self.tiffProvider, ObjectIdentifier(current) == finished {
                        self.tiffProvider = nil
                    }
                }
            }
            pasteboardItem.setDataProvider(provider, forTypes: [.tiff])
            // clearContents() tells the previous provider it is finished, so that provider must still
            // be alive then; it is only released afterwards.
            let previous = tiffProvider
            pasteboard.clearContents()
            pasteboard.writeObjects([pasteboardItem])
            tiffProvider = provider
            tiffChangeCount = pasteboard.changeCount
            withExtendedLifetime(previous) {}
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

    /// When the app quits, AppKit asks every data provider for its promised types; with a pasted
    /// image still on the pasteboard that is a synchronous TIFF conversion in the decoder service
    /// during quit. Writing the PNG again without the promise avoids it.
    func prepareForTermination() {
        let pasteboard = NSPasteboard.general
        guard let provider = tiffProvider, pasteboard.changeCount == tiffChangeCount else { return }
        let item = NSPasteboardItem()
        item.setData(provider.png, forType: .png)
        // clearContents() tells the provider it is finished; `provider` keeps it alive until then.
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        tiffProvider = nil
        tiffChangeCount = nil
        withExtendedLifetime(provider) {}
    }

    /// Simulates ⌘V in the frontmost app. Requires Accessibility permission.
    private static func sendPasteKeystroke() {
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
