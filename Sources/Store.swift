import AppKit
import CryptoKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ClipItem {
    enum Kind: Int {
        case text = 0
        case image = 1
        case files = 2
    }

    let id: Int64
    let kind: Kind
    /// Plain text for text items, a short description ("Bild 287×523") for images,
    /// newline-separated paths for files.
    let text: String
    let imageFile: String?
    let app: String?
    let appPath: String?
    let date: Date
    let pinned: Bool
    /// Text recognised in an image; nil until recognition ran.
    let recognizedText: String?
    /// Whether formatted text (RTF/HTML) was stored alongside the plain text.
    let hasRichText: Bool

    var filePaths: [String] {
        kind == .files ? text.split(separator: "\n").map(String.init) : []
    }
}

enum StoreError: Error {
    case open(String)
}

/// SQLite-backed clipboard history. Images live as PNG files next to the database.
final class Store {
    let directory: URL
    let imagesDirectory: URL
    private var db: OpaquePointer?

    init() throws {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clippboard")
        imagesDirectory = directory.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("history.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        exec("""
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
        migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    /// Adds columns introduced after the first release to existing databases.
    private func migrate() {
        var columns = Set<String>()
        query("PRAGMA table_info(items)") { stmt in
            if let name = Self.string(stmt, 1) { columns.insert(name) }
        }
        let added = [
            "pinned": "INTEGER NOT NULL DEFAULT 0",
            "ocr_text": "TEXT",
            "rich": "BLOB",
            "rich_type": "TEXT",
        ]
        for (column, definition) in added where !columns.contains(column) {
            exec("ALTER TABLE items ADD COLUMN \(column) \(definition)")
        }
    }

    var isEmpty: Bool {
        var empty = true
        query("SELECT 1 FROM items LIMIT 1") { _ in empty = false }
        return empty
    }

    // MARK: - Writing

    /// `rich` is optional formatted text (RTF or HTML) pasted with ⌥⏎.
    func addText(_ text: String, rich: (data: Data, type: NSPasteboard.PasteboardType)? = nil,
                 app: String?, appPath: String?, date: Date = Date()) {
        upsert(kind: .text, text: text, imageFile: nil, hash: Self.sha256("t:" + text), rich: rich,
               app: app, appPath: appPath, date: date)
    }

    func addFiles(_ paths: [String], app: String?, appPath: String?, date: Date = Date()) {
        let text = paths.joined(separator: "\n")
        upsert(kind: .files, text: text, imageFile: nil, hash: Self.sha256("f:" + text), rich: nil,
               app: app, appPath: appPath, date: date)
    }

    /// Accepts any image data NSBitmapImageRep can read (PNG, TIFF, …) and stores it as PNG.
    func addImage(_ data: Data, app: String?, appPath: String?, date: Date = Date()) {
        guard let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let hash = Self.sha256(png)
        let fileName = hash + ".png"
        let url = imagesDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? png.write(to: url)
        }
        let label = "Bild \(rep.pixelsWide)×\(rep.pixelsHigh)"
        upsert(kind: .image, text: label, imageFile: fileName, hash: hash, rich: nil, app: app, appPath: appPath, date: date)
    }

    /// Moves an item to the top of the history.
    func touch(_ item: ClipItem) {
        run("UPDATE items SET ts = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    func setPinned(_ pinned: Bool, for item: ClipItem) {
        run("UPDATE items SET pinned = ? WHERE id = ?") { stmt in
            sqlite3_bind_int(stmt, 1, pinned ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    func setRecognizedText(_ text: String, forImageFile fileName: String) {
        run("UPDATE items SET ocr_text = ? WHERE image_file = ?") { stmt in
            Self.bind(stmt, 1, text)
            Self.bind(stmt, 2, fileName)
        }
    }

    func delete(_ item: ClipItem) {
        run("DELETE FROM items WHERE id = ?") { stmt in sqlite3_bind_int64(stmt, 1, item.id) }
        removeImage(item.imageFile)
    }

    /// Deletes everything except pinned entries.
    func clear() {
        deleteWhere("pinned = 0") { _ in }
    }

    /// Drops unpinned entries older than the retention period or beyond maxItems.
    func prune(retentionDays: Int, maxItems: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
        let condition = """
            pinned = 0 AND (ts < ? OR id NOT IN (SELECT id FROM items WHERE pinned = 0 ORDER BY ts DESC LIMIT ?))
            """
        deleteWhere(condition) { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int64(stmt, 2, Int64(maxItems))
        }
    }

    // MARK: - Reading

    func items(limit: Int) -> [ClipItem] {
        var result: [ClipItem] = []
        let sql = """
            SELECT id, kind, text, image_file, app, app_path, ts, pinned, ocr_text, rich_type
            FROM items ORDER BY pinned DESC, ts DESC LIMIT ?
            """
        query(sql, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: ClipItem.Kind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text,
                text: Self.string(stmt, 2) ?? "",
                imageFile: Self.string(stmt, 3),
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

    func richText(for item: ClipItem) -> (data: Data, type: NSPasteboard.PasteboardType)? {
        var result: (Data, NSPasteboard.PasteboardType)?
        query("SELECT rich, rich_type FROM items WHERE id = ? AND rich IS NOT NULL",
              bind: { sqlite3_bind_int64($0, 1, item.id) }) { stmt in
            guard let bytes = sqlite3_column_blob(stmt, 0), let type = Self.string(stmt, 1) else { return }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            result = (data, NSPasteboard.PasteboardType(type))
        }
        return result
    }

    /// Image files whose text has not been recognised yet.
    func imageFilesWithoutRecognizedText() -> [String] {
        var files: [String] = []
        query("SELECT DISTINCT image_file FROM items WHERE kind = 1 AND ocr_text IS NULL AND image_file IS NOT NULL") { stmt in
            if let file = Self.string(stmt, 0) { files.append(file) }
        }
        return files
    }

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDirectory.appendingPathComponent($0) }
    }

    // MARK: - SQLite helpers

    private func upsert(kind: ClipItem.Kind, text: String, imageFile: String?, hash: String,
                        rich: (data: Data, type: NSPasteboard.PasteboardType)?,
                        app: String?, appPath: String?, date: Date) {
        // On a duplicate keep the newest timestamp and the app (and formatting) of the latest copy.
        let sql = """
            INSERT INTO items(kind, text, image_file, hash, app, app_path, ts, rich, rich_type)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                app = CASE WHEN excluded.ts > ts THEN excluded.app ELSE app END,
                app_path = CASE WHEN excluded.ts > ts THEN excluded.app_path ELSE app_path END,
                rich = CASE WHEN excluded.ts > ts THEN excluded.rich ELSE rich END,
                rich_type = CASE WHEN excluded.ts > ts THEN excluded.rich_type ELSE rich_type END,
                ts = MAX(ts, excluded.ts)
            """
        run(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(kind.rawValue))
            Self.bind(stmt, 2, text)
            Self.bind(stmt, 3, imageFile)
            Self.bind(stmt, 4, hash)
            Self.bind(stmt, 5, app)
            Self.bind(stmt, 6, appPath)
            sqlite3_bind_double(stmt, 7, date.timeIntervalSince1970)
            if let rich {
                _ = rich.data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt, 8, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
                Self.bind(stmt, 9, rich.type.rawValue)
            } else {
                sqlite3_bind_null(stmt, 8)
                sqlite3_bind_null(stmt, 9)
            }
        }
    }

    /// Deletes matching rows and the image files no remaining row refers to.
    private func deleteWhere(_ condition: String, bind: (OpaquePointer?) -> Void) {
        var files: [String] = []
        query("SELECT image_file FROM items WHERE image_file IS NOT NULL AND (\(condition))", bind: bind) { stmt in
            if let file = Self.string(stmt, 0) { files.append(file) }
        }
        run("DELETE FROM items WHERE \(condition)", bind: bind)
        for file in files {
            var stillUsed = false
            query("SELECT 1 FROM items WHERE image_file = ? LIMIT 1", bind: { Self.bind($0, 1, file) }) { _ in stillUsed = true }
            if !stillUsed { removeImage(file) }
        }
    }

    private func removeImage(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(fileName))
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            log.error("SQLite error: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) {
        query(sql, bind: bind) { _ in }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("SQLite error: \(String(cString: sqlite3_errmsg(self.db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
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

    private static func sha256(_ string: String) -> String {
        sha256(Data(string.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
