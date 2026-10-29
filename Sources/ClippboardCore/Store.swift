import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sqlite(String)

    public var description: String {
        switch self {
        case .open(let message): "Datenbank konnte nicht geöffnet werden: \(message)"
        case .sqlite(let message): "SQLite-Fehler: \(message)"
        }
    }
}

/// SQLite-backed clipboard history. Images live as PNG files next to the database.
/// Not thread-safe: use one instance from one thread (the app uses the main thread).
public final class Store {
    public let directory: URL
    public let imagesDirectory: URL
    private var db: OpaquePointer?

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippboard")
    }

    public init(directory: URL = Store.defaultDirectory) throws {
        self.directory = directory
        imagesDirectory = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw StoreError.open(message)
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    /// Ordered schema steps; `PRAGMA user_version` stores how many have been applied.
    /// Append new steps, never change released ones.
    private static let migrations: [(Store) throws -> Void] = [
        { try $0.migrateToV1() },
        { try $0.migrateToV2() },
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
    /// (paths may contain newlines), and a key-value table for app state.
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

    // MARK: - Writing

    public func addText(_ text: String, rich: RichText? = nil, app: String?, appPath: String?, date: Date = Date()) {
        upsert(Row(kind: .text, text: text, hash: ImageIngest.sha256(Data(("t:" + text).utf8)), rich: rich),
               app: app, appPath: appPath, date: date)
    }

    public func addFiles(_ paths: [String], app: String?, appPath: String?, date: Date = Date()) {
        let json = Self.encodePaths(paths)
        upsert(Row(kind: .files, text: json, hash: ImageIngest.sha256(Data(("f:" + json).utf8))),
               app: app, appPath: appPath, date: date)
    }

    public func addImage(_ image: PreparedImage, app: String?, appPath: String?, date: Date = Date()) {
        let fileName = image.hash + ".png"
        let url = imagesDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try image.png.write(to: url)
            } catch {
                logger.error("Could not write image: \(String(describing: error), privacy: .public)")
                return
            }
        }
        upsert(Row(kind: .image, text: "", hash: image.hash, imageFile: fileName,
                   width: image.width, height: image.height, byteSize: Int64(image.png.count)),
               app: app, appPath: appPath, date: date)
    }

    /// Moves an item to the top of the history.
    public func touch(_ item: ClipItem) {
        run("UPDATE items SET ts = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    public func setPinned(_ pinned: Bool, for item: ClipItem) {
        run("UPDATE items SET pinned = ? WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    public func setRecognizedText(_ text: String, forImageFile fileName: String) {
        run("UPDATE items SET ocr_text = ? WHERE image_file = ?") { stmt in
            Self.bind(stmt, 1, text)
            Self.bind(stmt, 2, fileName)
        }
    }

    public func delete(_ item: ClipItem) {
        deleteWhere("id = ?") { sqlite3_bind_int64($0, 1, item.id) }
    }

    /// Deletes everything except pinned entries.
    public func clear() {
        deleteWhere("pinned = 0") { _ in }
    }

    /// Drops unpinned entries older than the retention period or beyond maxItems.
    public func prune(retentionDays: Int, maxItems: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
        let condition = """
            pinned = 0 AND (ts < ? OR id NOT IN (SELECT id FROM items WHERE pinned = 0 ORDER BY ts DESC LIMIT ?))
            """
        deleteWhere(condition) { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int64(stmt, 2, Int64(maxItems))
        }
    }

    public func metadata(_ key: String) -> String? {
        var value: String?
        query("SELECT value FROM meta WHERE key = ?", bind: { Self.bind($0, 1, key) }) { value = Self.string($0, 0) }
        return value
    }

    public func setMetadata(_ value: String, for key: String) {
        run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value") { stmt in
            Self.bind(stmt, 1, key)
            Self.bind(stmt, 2, value)
        }
    }

    /// Runs `body` in one transaction (e.g. a bulk import); rolls back if it throws.
    public func transaction(_ body: () throws -> Void) throws {
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

    public func items(limit: Int) -> [ClipItem] {
        var result: [ClipItem] = []
        let sql = """
            SELECT id, kind, text, image_file, app, app_path, ts, pinned, ocr_text, rich_type, width, height, byte_size
            FROM items ORDER BY pinned DESC, ts DESC LIMIT ?
            """
        query(sql, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            let kind = ClipItem.Kind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text
            let raw = Self.string(stmt, 2) ?? ""
            let paths = kind == .files ? Self.decodePaths(raw) : []
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: kind,
                text: kind == .files ? paths.joined(separator: "\n") : raw,
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
        item.imageFile.map { imagesDirectory.appendingPathComponent($0) }
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

    private func upsert(_ row: Row, app: String?, appPath: String?, date: Date) {
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
        run(sql) { stmt in
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
    private func deleteWhere(_ condition: String, bind: (OpaquePointer?) -> Void) {
        var files: [String] = []
        query("SELECT image_file FROM items WHERE image_file IS NOT NULL AND (\(condition))", bind: bind) { stmt in
            if let file = Self.string(stmt, 0) { files.append(file) }
        }
        guard run("DELETE FROM items WHERE \(condition)", bind: bind) else { return }
        for file in files {
            var stillUsed = false
            query("SELECT 1 FROM items WHERE image_file = ? LIMIT 1", bind: { Self.bind($0, 1, file) }) { _ in stillUsed = true }
            if !stillUsed { removeImage(file) }
        }
    }

    private func removeImage(_ fileName: String) {
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(fileName))
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

    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    static func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    private static func encodePaths(_ paths: [String]) -> String {
        (try? String(data: JSONEncoder().encode(paths), encoding: .utf8)) ?? "[]"
    }

    private static func decodePaths(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
