import ClipsodyDecoderKit
import Foundation
import SQLite3
import Testing
@testable import ClipsodyCore

/// A second database connection holding a lock, like another process reading or writing.
final class LockHolder {
    private var db: OpaquePointer?

    init(path: String, sql: String) {
        sqlite3_open(path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func release() {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        sqlite3_close(db)
        db = nil
    }

    deinit {
        if db != nil { release() }
    }
}

@Suite struct LockTests {
    @Test func blockedWipeIsRetriedLater() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let secret = "secret-\(UUID().uuidString)"
        store.addText(secret, app: nil, appPath: nil)
        // A reader with an open snapshot keeps the WAL from being truncated.
        let reader = LockHolder(path: directory.url.appendingPathComponent("history.sqlite").path,
                                sql: "BEGIN; SELECT count(*) FROM items;")

        try store.delete(#require(store.items().first))
        store.flushDeletions()
        #expect(store.hasPendingWipe)

        reader.release()
        store.flushDeletions()
        #expect(!store.hasPendingWipe)
        let wal = FileManager.default.contents(atPath: directory.url.appendingPathComponent("history.sqlite-wal").path)
        #expect(wal.map { $0.range(of: Data(secret.utf8)) == nil } ?? true)
    }

    @Test func failedWriteOfRecognizedTextIsReported() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let image = try #require(ImageCodec.prepare(makeImage()))
        store.addImage(image, app: nil, appPath: nil)
        let writer = LockHolder(path: directory.url.appendingPathComponent("history.sqlite").path,
                                sql: "BEGIN IMMEDIATE;")

        #expect(!store.setRecognizedText("x", forImageFile: image.hash + ".png"))

        writer.release()
        #expect(store.setRecognizedText("x", forImageFile: image.hash + ".png"))
    }

    @Test func failedTouchAndPinAreReported() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        store.addText("entry", app: nil, appPath: nil)
        let item = try #require(store.items().first)
        let writer = LockHolder(path: directory.url.appendingPathComponent("history.sqlite").path,
                                sql: "BEGIN IMMEDIATE;")

        #expect(!store.touch(item))
        #expect(!store.setPinned(true, for: item))

        writer.release()
        #expect(store.touch(item))
        #expect(store.setPinned(true, for: item))
        #expect(store.items().first?.pinned == true)
    }

    @Test func pendingWipeFromACrashedRunIsDoneAtLaunch() throws {
        let running = try TemporaryDirectory()
        let afterCrash = try TemporaryDirectory()
        let secret = "secret-\(UUID().uuidString)"
        let store = try Store(directory: running.url)
        store.addText(secret, app: nil, appPath: nil)
        try store.delete(#require(store.items().first))
        // "Crash": take the files as they are while the store is still open, without its clean close.
        for name in ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"] {
            try FileManager.default.copyItem(at: running.url.appendingPathComponent(name),
                                             to: afterCrash.url.appendingPathComponent(name))
        }
        withExtendedLifetime(store) {}
        let crashedWAL = try Data(contentsOf: afterCrash.url.appendingPathComponent("history.sqlite-wal"))
        #expect(crashedWAL.range(of: Data(secret.utf8)) != nil)

        let relaunched = try Store(directory: afterCrash.url)

        for name in ["history.sqlite", "history.sqlite-wal"] {
            let data = FileManager.default.contents(atPath: afterCrash.url.appendingPathComponent(name).path) ?? Data()
            #expect(data.range(of: Data(secret.utf8)) == nil, "\(name)")
        }
        withExtendedLifetime(relaunched) {}
    }
}
