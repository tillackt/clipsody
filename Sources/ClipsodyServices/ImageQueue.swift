import ClipsodyCore
import Foundation

/// Stores copied images after converting them (in the decoder service): one at a time, in copy
/// order, with bounded memory. Each entry gets the time of the copy, not of the end of the
/// conversion, so a text copied meanwhile stays on top.
@MainActor
public final class ImageQueue {
    private let store: Store
    private let prepare: (Data) async -> PreparedImage?
    private let onStored: () -> Void
    private let accepts: (_ appBundleID: String?) -> Bool
    private let maxPending: Int
    /// Bumped by `discardPending()`; conversions started earlier are not stored.
    private var generation = 0
    /// The last queued conversion; each one waits for its predecessor.
    private var chain: Task<Void, Never>?
    public private(set) var pendingCount = 0

    /// `accepts` is asked again when a conversion has finished: if images were switched off or the
    /// source app was added to the ignored apps meanwhile, the image is dropped.
    public init(store: Store, maxPending: Int = 3, accepts: @escaping (_ appBundleID: String?) -> Bool = { _ in true },
                prepare: @escaping (Data) async -> PreparedImage?, onStored: @escaping () -> Void) {
        self.store = store
        self.maxPending = maxPending
        self.accepts = accepts
        self.prepare = prepare
        self.onStored = onStored
    }

    /// Returns false if the image was dropped because too many conversions are pending.
    @discardableResult
    public func enqueue(_ data: Data, app: String?, appPath: String?, appBundleID: String? = nil,
                        copiedAt: Date = Date()) -> Bool {
        guard pendingCount < maxPending else {
            logger.notice("Skipped image: \(self.pendingCount) conversions already pending")
            return false
        }
        let generation = generation
        let previous = chain
        pendingCount += 1
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let image = await prepare(data)
            pendingCount -= 1
            guard let image, generation == self.generation, accepts(appBundleID) else { return }
            store.addImage(image, app: app, appPath: appPath, date: copiedAt)
            onStored()
        }
        return true
    }

    /// Call when the history is cleared: images still being converted must not reappear.
    public func discardPending() {
        generation += 1
    }

    /// Waits until every queued conversion has finished (for tests).
    public func waitUntilIdle() async {
        await chain?.value
    }
}
