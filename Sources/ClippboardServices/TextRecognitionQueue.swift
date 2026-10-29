import ClippboardCore
import Foundation

/// Recognises text in stored images one at a time, so screenshots become searchable.
@MainActor
public final class TextRecognitionQueue {
    private let store: Store
    private let recognize: (Data) async -> RecognitionResult
    private let onRecognized: (_ file: String, _ text: String) -> Void
    private var running: Task<Void, Never>?
    /// Invalid file names; never processed.
    private var invalid = Set<String>()
    /// Files that were missing; retried as soon as the file exists again (the image copied anew).
    private var missing = Set<String>()
    /// The service did not answer for these; retried with the next `start()`, not in a tight loop.
    private var failed = Set<String>()
    /// Set before the store goes away (uninstall); nothing is started or written afterwards.
    private var isStopped = false

    /// `recognize` gets the PNG bytes (never a path); `onRecognized` receives the image file name
    /// and the stored text.
    public init(store: Store, recognize: @escaping (Data) async -> RecognitionResult,
                onRecognized: @escaping (_ file: String, _ text: String) -> Void) {
        self.store = store
        self.recognize = recognize
        self.onRecognized = onRecognized
    }

    /// Starts working through pending images unless that is already happening. Images whose
    /// recognition failed earlier are tried again.
    public func start() {
        guard running == nil, !isStopped else { return }
        failed.removeAll()
        running = Task { [weak self] in
            await self?.processPending()
            self?.running = nil
        }
    }

    /// Stops for good: a recognition still in flight is not stored.
    public func stop() {
        isStopped = true
        running?.cancel()
    }

    /// Waits until the current run has finished (for tests).
    public func waitUntilIdle() async {
        await running?.value
    }

    private func nextFile() -> (file: String, url: URL)? {
        for file in store.imageFilesWithoutRecognizedText() where !invalid.contains(file) && !failed.contains(file) {
            // Validated path only: a tampered database must not make Vision read files elsewhere.
            guard let url = store.imageURL(forFile: file) else {
                invalid.insert(file)
                continue
            }
            if missing.contains(file) && !FileManager.default.fileExists(atPath: url.path) { continue }
            missing.remove(file)
            return (file, url)
        }
        return nil
    }

    private func processPending() async {
        while !isStopped, let (file, url) = nextFile() {
            // Reading a multi-MB file must not block the main thread; the service gets the bytes, not the path.
            let png = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let png else {
                // Gone: retried once the image is copied again. Present but unreadable (permissions,
                // I/O error): not again in this run, or the loop would read it forever.
                if FileManager.default.fileExists(atPath: url.path) {
                    failed.insert(file)
                } else {
                    missing.insert(file)
                }
                continue
            }
            let result = await recognize(png)
            if isStopped { return }
            guard FileManager.default.fileExists(atPath: url.path) else {
                // Deleted meanwhile: writing "" could hit a new entry for the same image copied again.
                missing.insert(file)
                continue
            }
            switch result {
            case .text(let text):
                // A failed write (database locked, disk full) is retried later, not in a tight loop.
                if store.setRecognizedText(text, forImageFile: file) {
                    onRecognized(file, text)
                } else {
                    failed.insert(file)
                }
            case .unreadable:
                // Final: stored as empty so the image is not processed again.
                if !store.setRecognizedText("", forImageFile: file) { failed.insert(file) }
            case .failed:
                failed.insert(file)
            }
        }
    }
}
