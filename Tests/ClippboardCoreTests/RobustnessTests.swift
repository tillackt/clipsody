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
        sqlite(directory.url.appendingPathComponent("history.sqlite").path, """
            CREATE TABLE items(id INTEGER PRIMARY KEY, kind INTEGER, text TEXT, hash TEXT UNIQUE, ts REAL);
            PRAGMA user_version = 2;
            """)
        #expect(throws: StoreError.self) { try Store(directory: directory.url) }
    }
}

@Suite struct AlfredImportRulesTests {
    let alfred: TemporaryDirectory
    let data: TemporaryDirectory
    let databases: URL

    init() throws {
        alfred = try TemporaryDirectory()
        data = try TemporaryDirectory()
        databases = alfred.url.appendingPathComponent("Alfred 3/Databases")
        try FileManager.default.createDirectory(at: databases.appendingPathComponent("clipboard.alfdb.data"),
                                                withIntermediateDirectories: true)
    }

    /// A fake .app bundle so the importer can read its bundle identifier.
    func makeApp(named name: String, bundleId: String) throws -> String {
        let contents = alfred.url.appendingPathComponent("\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": bundleId, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return alfred.url.appendingPathComponent("\(name).app").path
    }

    @Test func failedImportIsRetriedAtNextLaunch() throws {
        // Wrong schema: reading fails, nothing may be marked as done.
        sqlite(databases.appendingPathComponent("clipboard.alfdb").path, "CREATE TABLE clipboard(other);")
        let store = try Store(directory: data.url)
        #expect(AlfredImporter.importIfNeeded(into: store, supportDirectory: alfred.url) == 0)
        #expect(store.metadata("alfredImportDone") == nil)

        try FileManager.default.removeItem(at: databases.appendingPathComponent("clipboard.alfdb"))
        sqlite(databases.appendingPathComponent("clipboard.alfdb").path, """
            CREATE TABLE clipboard(item, ts decimal, app, apppath, dataType integer, dataHash);
            INSERT INTO clipboard VALUES ('second try', 1, NULL, NULL, 0, 'h');
            """)
        #expect(AlfredImporter.importIfNeeded(into: store, supportDirectory: alfred.url) == 1)
        #expect(store.metadata("alfredImportDone") == "1")
    }

    @Test func captureRulesApplyToImportedEntries() throws {
        let secretApp = try makeApp(named: "Vault", bundleId: "com.example.vault")
        try makeImage().write(to: databases.appendingPathComponent("clipboard.alfdb.data/img.tiff"))
        let huge = String(repeating: "x", count: CaptureLimits.maxTextBytes + 1)
        sqlite(databases.appendingPathComponent("clipboard.alfdb").path, """
            CREATE TABLE clipboard(item, ts decimal, app, apppath, dataType integer, dataHash);
            INSERT INTO clipboard VALUES ('password123', 1, 'Vault', '\(secretApp)', 0, 'h1');
            INSERT INTO clipboard VALUES ('Image', 2, NULL, NULL, 1, 'img.tiff');
            INSERT INTO clipboard VALUES ('\(huge)', 3, NULL, NULL, 0, 'h3');
            INSERT INTO clipboard VALUES ('kept', 4, NULL, NULL, 0, 'h4');
            """)
        var config = Config()
        config.ignoredApps = ["com.example.vault"]
        config.keepImages = false
        let store = try Store(directory: data.url)

        #expect(AlfredImporter.importIfNeeded(into: store, config: config, supportDirectory: alfred.url) == 1)
        #expect(store.items().map(\.text) == ["kept"])
    }
}
