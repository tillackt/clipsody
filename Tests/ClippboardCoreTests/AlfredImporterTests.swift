import Foundation
import Testing
@testable import ClippboardCore

@Suite struct AlfredImporterTests {
    /// Fake Alfred 3 support folder with one text, one image and one file entry.
    func makeAlfred(in root: URL) throws {
        let databases = root.appendingPathComponent("Alfred 3/Databases")
        let images = databases.appendingPathComponent("clipboard.alfdb.data")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try makeImage(width: 5, height: 4).write(to: images.appendingPathComponent("img.tiff"))
        sqlite(databases.appendingPathComponent("clipboard.alfdb").path, """
            CREATE TABLE clipboard(item, ts decimal, app, apppath, dataType integer, dataHash);
            INSERT INTO clipboard VALUES ('hello from alfred', 800000000, 'Notes', '/Applications/Notes.app', 0, 'h1');
            INSERT INTO clipboard VALUES ('Image: 5x4', 800000001, 'Monosnap', NULL, 1, 'img.tiff');
            INSERT INTO clipboard VALUES ('/tmp/report.pdf', 800000002, 'Finder', NULL, 2, 'h3');
            """)
    }

    @Test func importsTextImagesAndFilesOnce() throws {
        let alfred = try TemporaryDirectory()
        let data = try TemporaryDirectory()
        try makeAlfred(in: alfred.url)
        let store = try Store(directory: data.url)

        #expect(AlfredImporter.importIfNeeded(into: store, supportDirectory: alfred.url) == 3)
        #expect(AlfredImporter.importIfNeeded(into: store, supportDirectory: alfred.url) == 0)

        let items = store.items(limit: 10)
        #expect(items.map(\.kind) == [.files, .image, .text])
        #expect(items[0].filePaths == ["/tmp/report.pdf"])
        #expect(items[1].imageWidth == 5 && items[1].imageHeight == 4)
        #expect(items[2].text == "hello from alfred")
        #expect(items[2].date == Date(timeIntervalSinceReferenceDate: 800_000_000))
    }

    @Test func missingAlfredImportsNothing() throws {
        let empty = try TemporaryDirectory()
        let data = try TemporaryDirectory()
        let store = try Store(directory: data.url)
        #expect(AlfredImporter.importIfNeeded(into: store, supportDirectory: empty.url, force: true) == 0)
    }
}
