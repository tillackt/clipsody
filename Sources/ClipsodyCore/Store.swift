import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sqlite(String)

    public var description: String {
        switch self {
        case .open(let message): String(localized: "The database could not be opened: \(message)")
        case .sqlite(let message): String(localized: "Database error: \(message)")
        }
    }
}

/// SQLite-backed clipboard history. Images live as PNG files next to the database.
/// Not thread-safe: use one instance from one thread (the app uses the main thread).
public final class Store {
    public let directory: URL
    public let imagesDirectory: URL
    private var db: OpaquePointer?
    /// Single deletes are wiped from disk in one go (see `flushDeletions`), not on every ⌘⌫.
    private var hasUnwipedDeletions = false

    /// Characters of a text loaded for the list; enough for title, preview and search.
    public static let listTextPrefix = CaptureLimits.searchableCharacters

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipsody")
    }

    /// Where the app kept its data before it was renamed from Clippboard to Clipsody.
    public static var legacyDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippboard")
    }

    /// Moves the data of the app's old name into `directory`, keeping history, images and
    /// settings. Only when nothing exists at `directory` yet, so newer data is never overwritten.
    /// Returns whether it moved anything.
    @discardableResult
    public static func adoptLegacyDirectory(_ legacy: URL = Store.legacyDirectory,
                                            into directory: URL = Store.defaultDirectory) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path), !fileManager.fileExists(atPath: directory.path) else { return false }
        do {
            // Same volume: a rename, so the folder keeps its 0700 mode and backup exclusion.
            try fileManager.moveItem(at: legacy, to: directory)
            return true
        } catch {
            logger.error("Could not move the old data folder: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public init(directory: URL = Store.defaultDirectory) throws {
        self.directory = directory
        imagesDirectory = directory.appendingPathComponent("images")
        // Private from the first byte: folders 0700 and the database file 0600 exist before SQLite
        // opens it (SQLite gives its -wal/-shm files the database file's mode).
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        FilePermissions.set(0o700, of: directory)
        FilePermissions.set(0o700, of: imagesDirectory)
        FilePermissions.excludeFromBackup(directory)

        let path = directory.appendingPathComponent("history.sqlite").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw StoreError.open(message)
        }
        // Deleted content is overwritten with zeros instead of lingering in free pages.
        try execute("PRAGMA secure_delete = ON")
        // WAL: fewer disk syncs per copied item. journal_size_limit 0 lets checkpoints shrink the WAL to
        // nothing instead of keeping old frames (with deleted content) around for reuse.
        try execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA journal_size_limit = 0")
        try migrate()
        try validateSchema()
        // Only an optimisation: a failure (e.g. disk full) must not keep the app from starting.
        do {
            try enableIncrementalVacuum()
        } catch {
            logger.error("Could not enable incremental vacuum: \(String(describing: error), privacy: .public)")
        }
        restrictPermissions()
        removeOrphanedImages()
        // Deletes not yet wiped when the app last ended (crash, power loss) are wiped now.
        wipeDeletedContent()
    }

    /// A database edited by hand or by a broken tool may claim the current version without the
    /// columns that go with it; then every query would silently return nothing.
    private func validateSchema() throws {
        var columns = Set<String>()
        query("PRAGMA table_info(items)") { stmt in
            if let name = Self.string(stmt, 1) { columns.insert(name) }
        }
        let required: Set = ["id", "kind", "text", "image_file", "hash", "app", "app_path", "ts", "pinned",
                             "ocr_text", "rich", "rich_type", "width", "height", "byte_size"]
        let missing = required.subtracting(columns)
        guard missing.isEmpty else {
            throw StoreError.sqlite("Unexpected database schema, missing: \(missing.sorted().joined(separator: ", "))")
        }
    }

    /// Image files no entry refers to: left by a crash between writing a file and storing its row,
    /// or between deleting a row and its file. Unknown files are left alone.
    private func removeOrphanedImages() {
        var referenced = Set<String>()
        let complete = query("SELECT image_file FROM items WHERE image_file IS NOT NULL") { stmt in
            if let file = Self.string(stmt, 0) { referenced.insert(file) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        Self.orphanedImageFiles(files, referenced: complete ? referenced : nil).forEach(removeImage)
    }

    /// Files to delete as orphans. Without a complete list of referenced files (the query failed)
    /// nothing is deleted: an incomplete list would make images still in use look orphaned.
    static func orphanedImageFiles(_ files: [String], referenced: Set<String>?) -> [String] {
        guard let referenced else { return [] }
        // A preview belongs to its image: it is an orphan exactly when the image is.
        return files.filter { name in
            imageFileName(of: name).map { !referenced.contains($0) } ?? isAtomicWriteLeftover(name)
        }
    }

    /// Temporary file of an atomic write (Data.write(options: .atomic)) that a crash left behind;
    /// it may hold a copied image.
    static func isAtomicWriteLeftover(_ name: String) -> Bool {
        name.hasPrefix(".dat.nosync")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    /// Ordered schema steps; `PRAGMA user_version` stores how many have been applied.
    /// Append new steps, never change released ones.
    private static let migrations: [@Sendable (Store) throws -> Void] = [
        { try $0.migrateToV1() },
        { try $0.migrateToV2() },
        { try $0.migrateToV3() },
    ]

    var schemaVersion: Int {
        var version = 0
        query("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
        return version
    }

    private func migrate() throws {
        let current = schemaVersion
        for (index, step) in Self.migrations.enumerated() where index >= current {
            try transaction {
                try step(self)
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
    }

    /// Initial schema. Also adopts databases created before versioning, which may lack later columns.
    private func migrateToV1() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS items(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                kind INTEGER NOT NULL,
                text TEXT NOT NULL,
                image_file TEXT,
                hash TEXT NOT NULL UNIQUE,
                app TEXT,
                app_path TEXT,
                ts REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS items_ts ON items(ts);
            """)
        var columns = Set<String>()
        query("PRAGMA table_info(items)") { stmt in
            if let name = Self.string(stmt, 1) { columns.insert(name) }
        }
        let added = [
            ("pinned", "INTEGER NOT NULL DEFAULT 0"),
            ("ocr_text", "TEXT"),
            ("rich", "BLOB"),
            ("rich_type", "TEXT"),
        ]
        for (column, definition) in added where !columns.contains(column) {
            try execute("ALTER TABLE items ADD COLUMN \(column) \(definition)")
        }
    }

    /// Image size as numbers instead of a German label in `text`, file lists as JSON
    /// (paths may contain newlines), and a key-value table for app state (unused since the Alfred
    /// import was removed; kept because released migrations never change).
    private func migrateToV2() throws {
        try execute("""
            ALTER TABLE items ADD COLUMN width INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE items ADD COLUMN height INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE items ADD COLUMN byte_size INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)

        var images: [(id: Int64, label: String, file: String?)] = []
        query("SELECT id, text, image_file FROM items WHERE kind = 1") { stmt in
            images.append((sqlite3_column_int64(stmt, 0), Self.string(stmt, 1) ?? "", Self.string(stmt, 2)))
        }
        for image in images {
            // Old label: "Bild 946×858"
            let numbers = image.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let size = image.file.flatMap { fileSize(of: imagesDirectory.appendingPathComponent($0)) } ?? 0
            try runOrThrow("UPDATE items SET text = '', width = ?, height = ?, byte_size = ? WHERE id = ?") { stmt in
                sqlite3_bind_int64(stmt, 1, Int64(numbers.count == 2 ? numbers[0] : 0))
                sqlite3_bind_int64(stmt, 2, Int64(numbers.count == 2 ? numbers[1] : 0))
                sqlite3_bind_int64(stmt, 3, size)
                sqlite3_bind_int64(stmt, 4, image.id)
            }
        }

        var fileRows: [(id: Int64, text: String)] = []
        query("SELECT id, text FROM items WHERE kind = 2") { stmt in
            fileRows.append((sqlite3_column_int64(stmt, 0), Self.string(stmt, 1) ?? ""))
        }
        for row in fileRows {
            let json = Self.encodePaths(row.text.split(separator: "\n").map(String.init))
            try runOrThrow("UPDATE items SET text = ?, hash = ? WHERE id = ?") { stmt in
                Self.bind(stmt, 1, json)
                Self.bind(stmt, 2, ImageIngest.sha256(Data(("f:" + json).utf8)))
                sqlite3_bind_int64(stmt, 3, row.id)
            }
        }
    }

    /// OCR lookups and the still-used check on delete query by image file; without an index each
    /// of them scans the whole table.
    private func migrateToV3() throws {
        try execute("CREATE INDEX IF NOT EXISTS items_image_file ON items(image_file)")
    }

    /// Lets the file shrink again after pruning (otherwise it stays at its largest size).
    /// Switching an existing database needs one VACUUM, which cannot run inside a transaction.
    private func enableIncrementalVacuum() throws {
        var mode = 0
        query("PRAGMA auto_vacuum") { mode = Int(sqlite3_column_int($0, 0)) }
        guard mode != 2 else { return }
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try execute("VACUUM")
    }

    // MARK: - Writing

    // The add methods return whether the entry was stored; failures are also logged.

    @discardableResult
    public func addText(_ text: String, rich: RichText? = nil, app: String?, appPath: String?, date: Date = Date()) -> Bool {
        upsert(Row(kind: .text, text: text, hash: ImageIngest.sha256(Data(("t:" + text).utf8)), rich: rich),
               app: app, appPath: appPath, date: date)
    }

    @discardableResult
    public func addFiles(_ paths: [String], app: String?, appPath: String?, date: Date = Date()) -> Bool {
        let json = Self.encodePaths(paths)
        return upsert(Row(kind: .files, text: json, hash: ImageIngest.sha256(Data(("f:" + json).utf8))),
                      app: app, appPath: appPath, date: date)
    }

    @discardableResult
    public func addImage(_ image: PreparedImage, app: String?, appPath: String?, date: Date = Date()) -> Bool {
        let fileName = image.hash + ".png"
        // The hash names a file; anything but "<sha256>.png" must never become a path.
        guard let url = imageURL(forFile: fileName) else {
            logger.error("Rejected image with invalid name")
            return false
        }
        let isNewFile = !FileManager.default.fileExists(atPath: url.path)
        if isNewFile {
            do {
                // Atomic: a crash mid-write must not leave a truncated file that later copies reuse.
                try image.png.write(to: url, options: .atomic)
                FilePermissions.set(0o600, of: url)
            } catch {
                logger.error("Could not write image: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        if let preview = image.preview, let previewURL = imageURL(forFile: Self.previewFileName(for: fileName)),
           !FileManager.default.fileExists(atPath: previewURL.path) {
            // Only an optimisation: without it the panel previews the full image.
            if (try? preview.write(to: previewURL, options: .atomic)) != nil { FilePermissions.set(0o600, of: previewURL) }
        }
        let stored = upsert(Row(kind: .image, text: "", hash: image.hash, imageFile: fileName,
                                width: image.width, height: image.height, byteSize: Int64(image.png.count)),
                            app: app, appPath: appPath, date: date)
        if !stored && isNewFile { removeImage(fileName) }
        return stored
    }

    /// Moves an item to the top of the history. Returns false if it could not be stored.
    @discardableResult
    public func touch(_ item: ClipItem) -> Bool {
        run("UPDATE items SET ts = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    /// Returns false if the change could not be stored.
    @discardableResult
    public func setPinned(_ pinned: Bool, for item: ClipItem) -> Bool {
        run("UPDATE items SET pinned = ? WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    /// Returns false if the text could not be stored.
    @discardableResult
    public func setRecognizedText(_ text: String, forImageFile fileName: String) -> Bool {
        run("UPDATE items SET ocr_text = ? WHERE image_file = ?") { stmt in
            Self.bind(stmt, 1, text)
            Self.bind(stmt, 2, fileName)
        }
    }

    /// Returns false if the entry could not be deleted.
    @discardableResult
    public func delete(_ item: ClipItem) -> Bool {
        guard deleteWhere("id = ?", bind: { sqlite3_bind_int64($0, 1, item.id) }) != nil else { return false }
        hasUnwipedDeletions = true
        return true
    }

    /// Removes what single deletes left in the WAL and free pages. The app calls it when the panel
    /// closes and when it quits, so holding ⌘⌫ does not run a checkpoint per entry.
    public func flushDeletions() {
        guard hasUnwipedDeletions else { return }
        wipeDeletedContent()
    }

    /// Deletes everything except pinned entries.
    public func clear() {
        if (deleteWhere("pinned = 0") { _ in } ?? 0) > 0 || hasUnwipedDeletions { wipeDeletedContent() }
    }

    /// Drops unpinned entries older than the retention period or beyond maxItems.
    public func prune(retentionDays: Int, maxItems: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
        let condition = """
            pinned = 0 AND (ts < ? OR id NOT IN (SELECT id FROM items WHERE pinned = 0 ORDER BY ts DESC LIMIT ?))
            """
        let deleted = deleteWhere(condition) { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int64(stmt, 2, Int64(maxItems))
        }
        // Most hourly runs delete nothing; then there is nothing to wipe.
        if (deleted ?? 0) > 0 || hasUnwipedDeletions { wipeDeletedContent() }
    }

    /// secure_delete zeroes freed pages, but in WAL mode the old page versions (with the deleted
    /// text) still sit in the -wal file. Copying everything into the main file and truncating the
    /// WAL to zero bytes removes them; incremental_vacuum hands freed pages back to the file system.
    /// The pending flag is only cleared when the checkpoint really truncated the WAL; a blocked or
    /// failed one is tried again at the next flush, prune or clear.
    private func wipeDeletedContent() {
        try? execute("PRAGMA incremental_vacuum")
        var busy = 1
        let ran = query("PRAGMA wal_checkpoint(TRUNCATE)") { busy = Int(sqlite3_column_int($0, 0)) }
        if ran && busy == 0 {
            hasUnwipedDeletions = false
        } else {
            hasUnwipedDeletions = true
            logger.error("WAL checkpoint was blocked; deleted content stays in the WAL until the next try")
        }
    }

    /// Whether deleted content may still be in the WAL (for tests).
    var hasPendingWipe: Bool { hasUnwipedDeletions }

    /// Runs `body` in one transaction; rolls back if it throws. Internal on purpose: image files
    /// deleted inside a transaction would not come back with a rollback.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Reading

    /// All entries, pinned first. Without a limit pinned entries cannot push others out of view;
    /// `prune` keeps the total bounded.
    public func items(limit: Int? = nil) -> [ClipItem] {
        var result: [ClipItem] = []
        // Texts are loaded only up to listTextPrefix: opening the panel must not read and decode
        // several multi-MB texts. Pasting fetches the whole text with fullText(for:).
        let sql = """
            SELECT id, kind,
                   CASE WHEN kind = 0 AND length(CAST(text AS BLOB)) > ? THEN substr(text, 1, ?) ELSE text END,
                   image_file, app, app_path,
                   ts, pinned, ocr_text, rich_type, width, height, byte_size, length(CAST(text AS BLOB))
            FROM items ORDER BY pinned DESC, ts DESC LIMIT ?
            """
        query(sql, bind: { stmt in
            // Only really large texts are cut: SQLite's substr() stops at a NUL character, so texts
            // below 4 bytes per prefix character are always loaded whole.
            sqlite3_bind_int64(stmt, 1, Int64(Self.listTextPrefix * 4))
            sqlite3_bind_int64(stmt, 2, Int64(Self.listTextPrefix))
            // LIMIT -1 means no limit in SQLite.
            sqlite3_bind_int64(stmt, 3, Int64(limit ?? -1))
        }) { stmt in
            let kind = ClipItem.Kind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text
            let raw = Self.string(stmt, 2) ?? ""
            let paths = kind == .files ? Self.decodePaths(raw) : []
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: kind,
                text: kind == .files ? paths.joined(separator: "\n") : raw,
                textByteCount: Int(sqlite3_column_int64(stmt, 13)),
                filePaths: paths,
                imageFile: Self.string(stmt, 3),
                imageWidth: Int(sqlite3_column_int64(stmt, 10)),
                imageHeight: Int(sqlite3_column_int64(stmt, 11)),
                byteSize: sqlite3_column_int64(stmt, 12),
                app: Self.string(stmt, 4),
                appPath: Self.string(stmt, 5),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                pinned: sqlite3_column_int(stmt, 7) != 0,
                recognizedText: Self.string(stmt, 8),
                hasRichText: Self.string(stmt, 9) != nil
            ))
        }
        return result
    }

    /// The complete text of a text entry (the list holds only its beginning).
    public func fullText(for item: ClipItem) -> String? {
        var text: String?
        query("SELECT text FROM items WHERE id = ? AND kind = 0", bind: { sqlite3_bind_int64($0, 1, item.id) }) {
            text = Self.string($0, 0)
        }
        return text
    }

    public func richText(for item: ClipItem) -> RichText? {
        var result: RichText?
        query("SELECT rich, rich_type FROM items WHERE id = ? AND rich IS NOT NULL",
              bind: { sqlite3_bind_int64($0, 1, item.id) }) { stmt in
            guard let bytes = sqlite3_column_blob(stmt, 0), let type = Self.string(stmt, 1) else { return }
            result = RichText(data: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))), type: type)
        }
        return result
    }

    /// Image files whose text has not been recognised yet.
    public func imageFilesWithoutRecognizedText() -> [String] {
        var files: [String] = []
        query("SELECT DISTINCT image_file FROM items WHERE kind = 1 AND ocr_text IS NULL AND image_file IS NOT NULL") { stmt in
            if let file = Self.string(stmt, 0) { files.append(file) }
        }
        return files
    }

    public func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.flatMap(imageURL(forFile:))
    }

    /// Only names the app itself generates ("<sha256>.png"); anything else (e.g. "../x" from a
    /// tampered database) never becomes a path.
    public func imageURL(forFile fileName: String) -> URL? {
        Self.isImageFileName(fileName) ? imagesDirectory.appendingPathComponent(fileName) : nil
    }

    static func isImageFileName(_ name: String) -> Bool {
        imageFileName(of: name) != nil
    }

    /// "<sha256>.png" for both the image and its "<sha256>-preview.png"; nil for any other name.
    static func imageFileName(of name: String) -> String? {
        let base = name.hasSuffix("-preview.png") ? String(name.dropLast(12)) : String(name.dropLast(4))
        guard name.hasSuffix(".png"), base.count == 64,
              base.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return base + ".png"
    }

    static func previewFileName(for imageFile: String) -> String {
        String(imageFile.dropLast(4)) + "-preview.png"
    }

    /// The small preview of an image entry if one was stored (large images only).
    public func previewURL(for item: ClipItem) -> URL? {
        guard let file = item.imageFile, let url = imageURL(forFile: Self.previewFileName(for: file)),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - SQLite helpers

    private struct Row {
        var kind: ClipItem.Kind
        var text: String
        var hash: String
        var rich: RichText? = nil
        var imageFile: String? = nil
        var width = 0
        var height = 0
        var byteSize: Int64 = 0
    }

    private func upsert(_ row: Row, app: String?, appPath: String?, date: Date) -> Bool {
        // On a duplicate keep the newest timestamp and the app (and formatting) of the latest copy.
        let sql = """
            INSERT INTO items(kind, text, image_file, hash, app, app_path, ts, rich, rich_type, width, height, byte_size)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                app = CASE WHEN excluded.ts > ts THEN excluded.app ELSE app END,
                app_path = CASE WHEN excluded.ts > ts THEN excluded.app_path ELSE app_path END,
                rich = CASE WHEN excluded.ts > ts THEN excluded.rich ELSE rich END,
                rich_type = CASE WHEN excluded.ts > ts THEN excluded.rich_type ELSE rich_type END,
                ts = MAX(ts, excluded.ts)
            """
        return run(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(row.kind.rawValue))
            Self.bind(stmt, 2, row.text)
            Self.bind(stmt, 3, row.imageFile)
            Self.bind(stmt, 4, row.hash)
            Self.bind(stmt, 5, app)
            Self.bind(stmt, 6, appPath)
            sqlite3_bind_double(stmt, 7, date.timeIntervalSince1970)
            if let rich = row.rich {
                _ = rich.data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt, 8, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
                Self.bind(stmt, 9, rich.type)
            } else {
                sqlite3_bind_null(stmt, 8)
                sqlite3_bind_null(stmt, 9)
            }
            sqlite3_bind_int64(stmt, 10, Int64(row.width))
            sqlite3_bind_int64(stmt, 11, Int64(row.height))
            sqlite3_bind_int64(stmt, 12, row.byteSize)
        }
    }

    /// Deletes matching rows and the image files no remaining row refers to.
    /// Number of deleted rows, nil if they could not be deleted.
    @discardableResult
    private func deleteWhere(_ condition: String, bind: (OpaquePointer?) -> Void) -> Int? {
        var files: [String] = []
        query("SELECT image_file FROM items WHERE image_file IS NOT NULL AND (\(condition))", bind: bind) { stmt in
            if let file = Self.string(stmt, 0) { files.append(file) }
        }
        guard run("DELETE FROM items WHERE \(condition)", bind: bind) else { return nil }
        let deletedRows = Int(sqlite3_changes(db))
        for file in files {
            var stillUsed = false
            let checked = query("SELECT 1 FROM items WHERE image_file = ? LIMIT 1",
                                bind: { Self.bind($0, 1, file) }) { _ in stillUsed = true }
            // Only delete a file when it is certain that no entry uses it any more.
            if checked && !stillUsed { removeImage(file) }
        }
        return deletedRows
    }

    /// Removes a file; for an image also its preview.
    private func removeImage(_ fileName: String) {
        let url = Self.isAtomicWriteLeftover(fileName) && fileName == (fileName as NSString).lastPathComponent
            ? imagesDirectory.appendingPathComponent(fileName)
            : imageURL(forFile: fileName)
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
        if !fileName.hasSuffix("-preview.png"), Self.isImageFileName(fileName),
           let preview = imageURL(forFile: Self.previewFileName(for: fileName)) {
            try? FileManager.default.removeItem(at: preview)
        }
    }

    /// History is private: folder only for the user (0700), files read/write for the user only (0600).
    private func restrictPermissions() {
        FilePermissions.set(0o700, of: directory)
        FilePermissions.set(0o700, of: imagesDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        let databaseFiles = ["history.sqlite", "history.sqlite-journal", "history.sqlite-wal", "history.sqlite-shm"]
            .map { directory.appendingPathComponent($0) }
        for url in files + databaseFiles + [Config.url(in: directory)]
        where FileManager.default.fileExists(atPath: url.path) {
            FilePermissions.set(0o600, of: url)
        }
    }


    private func fileSize(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    private var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError) }
    }

    private func runOrThrow(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard run(sql, bind: bind) else { throw StoreError.sqlite(lastError) }
    }

    /// Executes a statement; logs and returns false on any error.
    @discardableResult
    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        query(sql, bind: bind) { _ in }
    }

    /// Steps through all result rows; logs and returns false if preparing or stepping fails.
    @discardableResult
    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logger.error("SQLite prepare failed: \(self.lastError, privacy: .public)")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW:
                row(stmt)
            case SQLITE_DONE:
                return true
            default:
                logger.error("SQLite step failed: \(self.lastError, privacy: .public)")
                return false
            }
        }
    }

    /// Binds with the explicit UTF-8 length, so text containing NUL characters is stored completely.
    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            var value = value
            value.withUTF8 { buffer in
                _ = sqlite3_bind_text(stmt, index, UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self),
                                      Int32(buffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Reads the column by its byte length; a C string would stop at the first NUL character.
    static func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, column) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, column))
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF8.self)
    }

    private static func encodePaths(_ paths: [String]) -> String {
        (try? String(data: JSONEncoder().encode(paths), encoding: .utf8)) ?? "[]"
    }

    private static func decodePaths(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
