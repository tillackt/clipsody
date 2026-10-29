import ClippboardCore
import ClippboardDecoderKit
import Foundation
import Testing
@testable import ClippboardServices

/// Converts like the service, with an optional delay per call.
private func preparing(delays: [Duration] = []) -> (Data) async -> PreparedImage? {
    var remaining = delays
    return { data in
        if !remaining.isEmpty { try? await Task.sleep(for: remaining.removeFirst()) }
        return ImageCodec.prepare(data)
    }
}

@MainActor
@Suite struct ImageQueueTests {
    let directory: TemporaryDirectory
    let store: Store

    init() throws {
        directory = try TemporaryDirectory()
        store = try Store(directory: directory.url)
    }

    @Test func imagesAreStoredInCopyOrderWithCopyTime() async {
        // The first conversion is slower, but it still lands first and keeps its copy time.
        let queue = ImageQueue(store: store, prepare: preparing(delays: [.milliseconds(150), .zero])) {}
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        queue.enqueue(makeImage(width: 10, height: 10), app: "A", appPath: nil, copiedAt: first)
        queue.enqueue(makeImage(width: 20, height: 20), app: "B", appPath: nil, copiedAt: second)
        await queue.waitUntilIdle()

        let items = store.items()
        #expect(items.map(\.app) == ["B", "A"])
        #expect(items.map(\.date) == [second, first])
    }

    @Test func discardedConversionsAreNotStored() async {
        let queue = ImageQueue(store: store, prepare: preparing(delays: [.milliseconds(100)])) {}
        queue.enqueue(makeImage(), app: nil, appPath: nil)
        queue.discardPending()
        await queue.waitUntilIdle()
        #expect(store.items().isEmpty)
    }

    @Test func tooManyPendingImagesAreDropped() async {
        let queue = ImageQueue(store: store, maxPending: 2,
                               prepare: preparing(delays: [.milliseconds(100), .milliseconds(100)])) {}
        #expect(queue.enqueue(makeImage(width: 1, height: 1), app: nil, appPath: nil))
        #expect(queue.enqueue(makeImage(width: 2, height: 2), app: nil, appPath: nil))
        #expect(!queue.enqueue(makeImage(width: 3, height: 3), app: nil, appPath: nil))
        await queue.waitUntilIdle()
        #expect(store.items().count == 2)
        #expect(queue.pendingCount == 0)
    }

    @Test func imagesRejectedMeanwhileAreNotStored() async {
        // E.g. images switched off while the conversion was running.
        var accept = true
        let queue = ImageQueue(store: store, accepts: { _ in accept },
                               prepare: preparing(delays: [.milliseconds(100)])) {}
        queue.enqueue(makeImage(), app: nil, appPath: nil, appBundleID: "com.example.app")
        accept = false
        await queue.waitUntilIdle()
        #expect(store.items().isEmpty)
    }

    @Test func failedConversionsAreSkipped() async {
        var stored = 0
        let queue = ImageQueue(store: store, prepare: { _ in nil }) { stored += 1 }
        queue.enqueue(makeImage(), app: nil, appPath: nil)
        await queue.waitUntilIdle()
        #expect(stored == 0)
        #expect(store.items().isEmpty)
    }
}

@MainActor
@Suite struct TextRecognitionQueueTests {
    let directory: TemporaryDirectory
    let store: Store

    init() throws {
        directory = try TemporaryDirectory()
        store = try Store(directory: directory.url)
    }

    func addImage(width: Int) throws {
        let image = try #require(ImageCodec.prepare(makeImage(width: width, height: 5)))
        store.addImage(image, app: nil, appPath: nil)
    }

    @Test func allPendingImagesAreRecognised() async throws {
        try addImage(width: 5)
        try addImage(width: 6)
        var recognised: [String] = []
        let queue = TextRecognitionQueue(store: store, recognize: { png in .text("bytes \(png.count)") }) {
            recognised.append($0)
        }

        queue.start()
        await queue.waitUntilIdle()

        #expect(recognised.count == 2)
        #expect(store.items().allSatisfy { $0.recognizedText?.hasPrefix("bytes ") == true })
        #expect(store.imageFilesWithoutRecognizedText().isEmpty)
    }

    @Test func imagesWhoseFileVanishedAreSkipped() async throws {
        try addImage(width: 5)
        let item = try #require(store.items().first)
        try FileManager.default.removeItem(at: #require(store.imageURL(for: item)))
        let queue = TextRecognitionQueue(store: store, recognize: { _ in .text("never") }) { _ in }

        queue.start()
        await queue.waitUntilIdle()

        #expect(store.items().first?.recognizedText == nil)
    }

    @Test func serviceFailureIsRetriedNotStoredAsNoText() async throws {
        try addImage(width: 5)
        var answer = RecognitionResult.failed
        let queue = TextRecognitionQueue(store: store, recognize: { _ in answer }) { _ in }

        queue.start()
        await queue.waitUntilIdle()
        #expect(store.items().first?.recognizedText == nil)
        #expect(store.imageFilesWithoutRecognizedText().count == 1)

        answer = .text("found later")
        queue.start()
        await queue.waitUntilIdle()
        #expect(store.items().first?.recognizedText == "found later")
    }

    @Test func existingButUnreadableFileDoesNotLoopForever() async throws {
        try addImage(width: 5)
        let url = try #require(store.items().first.flatMap(store.imageURL(for:)))
        // Replace the file by a directory of the same name: it exists, but cannot be read as data.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        var calls = 0
        let queue = TextRecognitionQueue(store: store, recognize: { _ in calls += 1; return .text("x") }) { _ in }

        queue.start()
        await queue.waitUntilIdle()

        #expect(calls == 0)
        #expect(store.items().first?.recognizedText == nil)
    }

    @Test func unreadableImageIsMarkedDone() async throws {
        try addImage(width: 5)
        let queue = TextRecognitionQueue(store: store, recognize: { _ in .unreadable }) { _ in }
        queue.start()
        await queue.waitUntilIdle()
        #expect(store.items().first?.recognizedText == "")
    }

    @Test func imageCopiedAgainAfterItsFileVanishedIsRecognised() async throws {
        let image = try #require(ImageCodec.prepare(makeImage(width: 7, height: 5)))
        store.addImage(image, app: nil, appPath: nil)
        let url = try #require(store.items().first.flatMap(store.imageURL(for:)))
        try FileManager.default.removeItem(at: url)
        let queue = TextRecognitionQueue(store: store, recognize: { _ in .text("back") }) { _ in }
        queue.start()
        await queue.waitUntilIdle()

        // Same image copied again: the file is back, so it must not stay skipped.
        try image.png.write(to: url)
        queue.start()
        await queue.waitUntilIdle()
        #expect(store.items().first?.recognizedText == "back")
    }
}
