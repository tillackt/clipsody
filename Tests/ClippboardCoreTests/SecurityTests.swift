import Foundation
import SQLite3
import Testing
@testable import ClippboardCore

@Suite struct SecurityTests {
    func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func historyIsOnlyReadableByTheUser() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let image = try #require(ImageIngest.prepare(makeImage()))
        store.addImage(image, app: nil, appPath: nil)
        Config().save(to: directory.url)

        #expect(try permissions(of: directory.url) == 0o700)
        #expect(try permissions(of: store.imagesDirectory) == 0o700)
        #expect(try permissions(of: directory.url.appendingPathComponent("history.sqlite")) == 0o600)
        #expect(try permissions(of: store.imagesDirectory.appendingPathComponent(image.hash + ".png")) == 0o600)
        #expect(try permissions(of: Config.url(in: directory.url)) == 0o600)
    }

    /// Checks the main file and the WAL while the store is still open, as in the running app.
    func databaseFilesContain(_ secret: String, in directory: URL) -> Bool {
        ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm"].contains { name in
            let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path) ?? Data()
            return data.range(of: Data(secret.utf8)) != nil
        }
    }

    @Test func clearedTextIsGoneFromAllDatabaseFilesWhileOpen() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let secret = "correct-horse-battery-staple-\(UUID().uuidString)"
        for index in 0..<5 { store.addText("\(secret) \(index)", app: nil, appPath: nil) }
        #expect(databaseFilesContain(secret, in: directory.url))

        store.clear()

        #expect(!databaseFilesContain(secret, in: directory.url))
        withExtendedLifetime(store) {}
    }

    @Test func deletedAndPrunedTextIsGoneWhileOpen() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let deleted = "deleted-\(UUID().uuidString)"
        let pruned = "pruned-\(UUID().uuidString)"
        store.addText(deleted, app: nil, appPath: nil)
        store.addText(pruned, app: nil, appPath: nil, date: Date(timeIntervalSince1970: 0))

        try store.delete(#require(store.items().first { $0.text == deleted }))
        store.prune(retentionDays: 7, maxItems: 1_000)

        #expect(!databaseFilesContain(deleted, in: directory.url))
        #expect(!databaseFilesContain(pruned, in: directory.url))
        withExtendedLifetime(store) {}
    }

    @Test func historyIsExcludedFromBackups() throws {
        let directory = try TemporaryDirectory()
        _ = try Store(directory: directory.url)
        let values = try directory.url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test(arguments: ["../config.json", "/etc/passwd", "x.png", String(repeating: "A", count: 64) + ".png"])
    func foreignImageNamesNeverBecomePaths(_ name: String) throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        #expect(store.imageURL(forFile: name) == nil)
    }

    @Test func imagesWithForeignHashesAreNotWritten() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let real = try #require(ImageIngest.prepare(makeImage()))
        let forged = PreparedImage(png: real.png, width: real.width, height: real.height, hash: "../../escaped")

        #expect(!store.addImage(forged, app: nil, appPath: nil))
        #expect(!FileManager.default.fileExists(atPath: directory.url.deletingLastPathComponent()
            .appendingPathComponent("escaped.png").path))
        #expect(store.items().isEmpty)
    }

    @Test func generatedImageNamesAreAccepted() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let name = String(repeating: "a1", count: 32) + ".png"
        #expect(store.imageURL(forFile: name)?.lastPathComponent == name)
    }

    @Test func tamperedImageNameInDatabaseDoesNotDeleteOutsideFiles() throws {
        let directory = try TemporaryDirectory()
        let victim = directory.url.appendingPathComponent("victim.txt")
        try Data("keep".utf8).write(to: victim)
        do { _ = try Store(directory: directory.url) }
        try sqlite(directory.url.appendingPathComponent("history.sqlite").path, """
            INSERT INTO items(kind, text, image_file, hash, ts) VALUES (1, '', '../victim.txt', 'evil', 1);
            """)

        let store = try Store(directory: directory.url)
        store.clear()

        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func oversizedImagesAreRejectedBeforeDecoding() {
        let data = makeImage(width: 40, height: 40)
        #expect(ImageIngest.prepare(data, maxPixels: 1_599) == nil)
        #expect(ImageIngest.prepare(data, maxPixels: 1_600) != nil)
    }
}
