import ClipsodyDecoderKit
import Foundation
import Testing
@testable import ClipsodyCore

@Suite struct StoreTests {
    let directory: TemporaryDirectory
    let store: Store

    init() throws {
        directory = try TemporaryDirectory()
        store = try Store(directory: directory.url)
    }

    @Test func newDatabaseIsAtLatestSchemaVersion() {
        #expect(store.schemaVersion == 3)
    }

    @Test func imageFileLookupsUseAnIndex() {
        let path = directory.url.appendingPathComponent("history.sqlite").path
        #expect(sqliteValue(path, "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'items_image_file'")
                == "items_image_file")
    }

    @Test func databaseUsesWALAndIncrementalVacuum() {
        let path = directory.url.appendingPathComponent("history.sqlite").path
        #expect(sqliteValue(path, "PRAGMA journal_mode") == "wal")
        #expect(sqliteValue(path, "PRAGMA auto_vacuum") == "2") // 2 = incremental
    }

    @Test func duplicateTextKeepsOneEntryWithNewestTimeAndApp() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        store.addText("hello", app: "Notes", appPath: nil, date: new)
        store.addText("hello", app: "Mail", appPath: nil, date: old)

        let items = store.items(limit: 10)
        #expect(items.count == 1)
        #expect(items[0].date == new)
        #expect(items[0].app == "Notes")
    }

    @Test func richTextIsStoredAndReturned() throws {
        let rich = RichText(data: Data("{\\rtf1 bold}".utf8), type: "public.rtf")
        store.addText("bold", rich: rich, app: nil, appPath: nil)
        let item = try #require(store.items(limit: 1).first)
        #expect(item.hasRichText)
        #expect(store.richText(for: item) == rich)
    }

    @Test func filePathsSurviveNewlinesInNames() throws {
        let paths = ["/tmp/a.txt", "/tmp/line\nbreak.txt"]
        store.addFiles(paths, app: "Finder", appPath: nil)
        let item = try #require(store.items(limit: 1).first)
        #expect(item.kind == .files)
        #expect(item.filePaths == paths)
    }

    @Test func imageIsWrittenAsFileWithSize() throws {
        let image = try #require(ImageCodec.prepare(makeImage(width: 30, height: 20)))
        store.addImage(image, app: "Monosnap", appPath: nil)
        let item = try #require(store.items(limit: 1).first)
        #expect(item.kind == .image)
        #expect(item.imageWidth == 30 && item.imageHeight == 20)
        #expect(item.byteSize == Int64(image.png.count))
        let url = try #require(store.imageURL(for: item))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func previewIsStoredAndRemovedWithItsImage() throws {
        let image = try #require(ImageCodec.prepare(makeImage(width: 2_000, height: 1_000)))
        store.addImage(image, app: nil, appPath: nil)
        let item = try #require(store.items().first)
        let preview = try #require(store.previewURL(for: item))
        #expect(preview.lastPathComponent == image.hash + "-preview.png")

        store.delete(item)
        #expect(!FileManager.default.fileExists(atPath: preview.path))
    }

    @Test func previewsOfKeptImagesAreNoOrphans() {
        let image = String(repeating: "ab", count: 32) + ".png"
        let preview = String(repeating: "ab", count: 32) + "-preview.png"
        let orphanPreview = String(repeating: "cd", count: 32) + "-preview.png"
        #expect(Store.orphanedImageFiles([image, preview, orphanPreview], referenced: [image]) == [orphanPreview])
    }

    @Test func pruneRemovesOldAndSurplusEntriesButKeepsPinned() throws {
        let now = Date()
        store.addText("ancient", app: nil, appPath: nil, date: now.addingTimeInterval(-30 * 86_400))
        store.addText("ancient pinned", app: nil, appPath: nil, date: now.addingTimeInterval(-30 * 86_400))
        for index in 0..<5 {
            store.addText("recent \(index)", app: nil, appPath: nil, date: now.addingTimeInterval(Double(-index)))
        }
        let pinned = try #require(store.items(limit: 100).first { $0.text == "ancient pinned" })
        store.setPinned(true, for: pinned)

        store.prune(retentionDays: 7, maxItems: 3)

        let texts = store.items(limit: 100).map(\.text)
        #expect(texts == ["ancient pinned", "recent 0", "recent 1", "recent 2"])
    }

    @Test func clearKeepsPinnedAndRemovesUnusedImageFiles() throws {
        let image = try #require(ImageCodec.prepare(makeImage()))
        store.addImage(image, app: nil, appPath: nil)
        store.addText("keep me", app: nil, appPath: nil)
        let keep = try #require(store.items(limit: 10).first { $0.kind == .text })
        store.setPinned(true, for: keep)
        let imageURL = try #require(store.items(limit: 10).first { $0.kind == .image }.flatMap(store.imageURL(for:)))

        store.clear()

        #expect(store.items(limit: 10).map(\.text) == ["keep me"])
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test func recognizedTextIsSearchable() throws {
        let image = try #require(ImageCodec.prepare(makeImage()))
        store.addImage(image, app: nil, appPath: nil)
        #expect(store.imageFilesWithoutRecognizedText() == [image.hash + ".png"])

        store.setRecognizedText("Fehlermeldung 404", forImageFile: image.hash + ".png")

        #expect(store.imageFilesWithoutRecognizedText().isEmpty)
        let item = try #require(store.items(limit: 1).first)
        #expect(SearchQuery("fehlermeldung").matches(item))
    }

    @Test func pinnedEntriesDoNotHideOthers() throws {
        for index in 0..<4 {
            store.addText("entry \(index)", app: nil, appPath: nil, date: Date(timeIntervalSince1970: Double(index)))
        }
        let oldest = try #require(store.items().last)
        store.setPinned(true, for: oldest)
        store.prune(retentionDays: 365_000, maxItems: 3)

        #expect(store.items().count == 4)
        #expect(store.items().first?.text == "entry 0")
    }

    @Test func listHoldsTheBeginningOfLongTextsAndPasteGetsAll() throws {
        let long = String(repeating: "ä", count: Store.listTextPrefix * 2 + 10) // > 4 bytes per prefix character
        store.addText(long, app: nil, appPath: nil)
        let item = try #require(store.items().first)
        #expect(item.text.count == Store.listTextPrefix)
        #expect(item.textByteCount == long.utf8.count)
        #expect(store.fullText(for: item) == long)
    }

}

@Suite struct MigrationTests {
    /// Database as written by the first releases: no user_version, German image label in `text`,
    /// file lists joined by newlines.
    @Test func migratesUnversionedDatabase() throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("images"),
                                                withIntermediateDirectories: true)
        try sqlite(directory.url.appendingPathComponent("history.sqlite").path, """
            CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, text TEXT NOT NULL,
                image_file TEXT, hash TEXT NOT NULL UNIQUE, app TEXT, app_path TEXT, ts REAL NOT NULL);
            ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
            INSERT INTO items(kind, text, image_file, hash, ts, pinned) VALUES (1, 'Bild 946×858', 'abc.png', 'abc', 10, 1);
            INSERT INTO items(kind, text, hash, ts) VALUES (2, '/tmp/a' || char(10) || '/tmp/b', 'files', 20);
            INSERT INTO items(kind, text, hash, ts) VALUES (0, 'plain text', 'text', 30);
            """)

        let store = try Store(directory: directory.url)

        #expect(store.schemaVersion == 3)
        let items = store.items(limit: 10)
        let image = try #require(items.first { $0.kind == .image })
        #expect(image.text.isEmpty)
        #expect(image.imageWidth == 946 && image.imageHeight == 858)
        #expect(image.pinned)
        let files = try #require(items.first { $0.kind == .files })
        #expect(files.filePaths == ["/tmp/a", "/tmp/b"])
        #expect(items.first { $0.kind == .text }?.text == "plain text")
    }

    @Test func migratesV2DatabaseToV3() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("history.sqlite").path
        do {
            let store = try Store(directory: directory.url)
            store.addText("kept", app: nil, appPath: nil)
        }
        // Roll back to what a v2 build left behind.
        try sqlite(path, "DROP INDEX items_image_file; PRAGMA user_version = 2;")
        #expect(sqliteValue(path, "SELECT count(*) FROM sqlite_master WHERE name = 'items_image_file'") == "0")

        let store = try Store(directory: directory.url)

        #expect(store.schemaVersion == 3)
        #expect(sqliteValue(path, "SELECT count(*) FROM sqlite_master WHERE name = 'items_image_file'") == "1")
        #expect(store.items(limit: 10).first?.text == "kept")
    }

    @Test func reopeningDoesNotMigrateAgain() throws {
        let directory = try TemporaryDirectory()
        do {
            let store = try Store(directory: directory.url)
            store.addFiles(["/tmp/x"], app: nil, appPath: nil)
        }
        let reopened = try Store(directory: directory.url)
        #expect(reopened.items(limit: 10).first?.filePaths == ["/tmp/x"])
    }
}
