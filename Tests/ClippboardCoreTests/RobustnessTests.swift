import Foundation
import Testing
@testable import ClippboardCore

@Suite struct RobustnessTests {
    @Test func textWithNulCharactersSurvivesCompletely() throws {
        let directory = try TemporaryDirectory()
        let store = try Store(directory: directory.url)
        let text = "before\u{0}after"
        #expect(store.addText(text, app: nil, appPath: nil))
        #expect(store.items().first?.text == text)
    }

    @Test func orphanedImageFilesAreRemovedAtLaunchButUnknownFilesStay() throws {
        let directory = try TemporaryDirectory()
        do { _ = try Store(directory: directory.url) }
        let images = directory.url.appendingPathComponent("images")
        let orphan = images.appendingPathComponent(String(repeating: "ab", count: 32) + ".png")
        let unknown = images.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: orphan)
        try Data("x".utf8).write(to: unknown)

        let store = try Store(directory: directory.url)

        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        withExtendedLifetime(store) {}
    }

    @Test func referencedImageFilesStay() throws {
        let directory = try TemporaryDirectory()
        let image = try #require(ImageIngest.prepare(makeImage()))
        do {
            let store = try Store(directory: directory.url)
            store.addImage(image, app: nil, appPath: nil)
        }
        let store = try Store(directory: directory.url)
        let url = try #require(store.items().first.flatMap(store.imageURL(for:)))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func databaseWithCurrentVersionButMissingColumnsIsRejected() throws {
        let directory = try TemporaryDirectory()
        try sqlite(directory.url.appendingPathComponent("history.sqlite").path, """
            CREATE TABLE items(id INTEGER PRIMARY KEY, kind INTEGER, text TEXT, hash TEXT UNIQUE, ts REAL);
            PRAGMA user_version = 2;
            """)
        #expect(throws: StoreError.self) { try Store(directory: directory.url) }
    }
}
