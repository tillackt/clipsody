import AppKit
import ClippboardCore
import ClippboardServices

/// Polls the general pasteboard; macOS offers no change notification for it.
@MainActor
final class ClipboardMonitor {
    private let store: Store
    private let images: ImageQueue
    private let config: () -> Config
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    var onChange: (() -> Void)?

    init(store: Store, images: ImageQueue, config: @escaping () -> Config) {
        self.store = store
        self.images = images
        self.config = config
    }

    func start() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Lets macOS bundle wake-ups with other timers; reading changeCount is cheap anyway.
        timer.tolerance = 0.1
        // Common modes: keep polling while the status menu or an alert is open, otherwise copies get lost.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Call after writing to the pasteboard ourselves so that write is not recorded again.
    func ignoreCurrentContents() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private enum Content {
        case files([String])
        case text(String, RichText?)
        case image(Data)
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let config = config()
        let app = NSWorkspace.shared.frontmostApplication
        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard CapturePolicy.shouldRecord(pasteboardTypes: types, frontmostApp: app?.bundleIdentifier, config: config)
        else { return }
        guard let content = read(pasteboard, keepImages: config.keepImages) else { return }
        // Another write in the meantime (possibly a concealed password) would mix two contents;
        // the next poll picks up the new one and checks it again.
        guard pasteboard.changeCount == changeCount else { return }

        let appName = app?.localizedName
        let appPath = app?.bundleURL?.path
        switch content {
        case .files(let paths):
            store.addFiles(paths, app: appName, appPath: appPath)
        case .text(let text, let rich):
            store.addText(text, rich: rich, app: appName, appPath: appPath)
        case .image(let data):
            // Untrusted image data is converted in the sandboxed decoder service; the queue
            // stores it and calls back when done.
            images.enqueue(data, app: appName, appPath: appPath)
            return
        }
        onChange?()
    }

    private func read(_ pasteboard: NSPasteboard, keepImages: Bool) -> Content? {
        // Files copied in Finder are pasted back as files, not as path text.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls.map(\.path))
        }
        if let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard CapturePolicy.acceptsText(text) else {
                logger.notice("Skipped text of \(text.utf8.count) bytes (limit \(CaptureLimits.maxTextBytes))")
                return nil
            }
            return .text(text, Self.richText(from: pasteboard))
        }
        if keepImages {
            if let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return .image(image) }
        }
        return nil
    }

    /// Formatting pasted with ⏎: RTF from Office/Pages/TextEdit, otherwise HTML from browsers.
    private static func richText(from pasteboard: NSPasteboard) -> RichText? {
        for type in [NSPasteboard.PasteboardType.rtf, .html] {
            if let data = pasteboard.data(forType: type), CapturePolicy.acceptsRichText(byteCount: data.count) {
                return RichText(data: data, type: type.rawValue)
            }
        }
        return nil
    }
}
