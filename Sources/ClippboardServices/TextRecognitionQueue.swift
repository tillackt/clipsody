import ClippboardCore
import Foundation

/// Recognises text in stored images one at a time, so screenshots become searchable.
@MainActor
public final class TextRecognitionQueue {
    private let store: Store
    private let recognize: (Data) async -> String?
    private let onRecognized: (String) -> Void
    private var running: Task<Void, Never>?
    /// Images that could not be processed in this session (file gone or invalid name).
    private var skipped = Set<String>()

    /// `recognize` gets the PNG bytes (never a path); `onRecognized` receives the image file name.
    public init(store: Store, recognize: @escaping (Data) async -> String?, onRecognized: @escaping (String) -> Void) {
        self.store = store
        self.recognize = recognize
        self.onRecognized = onRecognized
    }

    /// Starts working through pending images unless that is already happening.
    public func start() {
        guard running == nil else { return }
        running = Task { [weak self] in
            await self?.processPending()
            self?.running = nil
        }
    }

    /// Waits until the current run has finished (for tests).
    public func waitUntilIdle() async {
        await running?.value
    }

    private func processPending() async {
        while let file = store.imageFilesWithoutRecognizedText().first(where: { !skipped.contains($0) }) {
            // Validated path only: a tampered database must not make Vision read files elsewhere.
            guard let url = store.imageURL(forFile: file) else {
                skipped.insert(file)
                continue
            }
            // The decoder service gets the bytes, not the path.
            let png = try? Data(contentsOf: url)
            let text = if let png { await recognize(png) } else { String?.none }
            if FileManager.default.fileExists(atPath: url.path) {
                // Stored even when empty so the image is not processed again.
                store.setRecognizedText(text ?? "", forImageFile: file)
                onRecognized(file)
            } else {
                // Deleted meanwhile: writing "" could hit a new entry for the same image copied again.
                skipped.insert(file)
            }
        }
    }
}
