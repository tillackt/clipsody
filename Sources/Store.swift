import AppKit
import CryptoKit
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ClipItem {
    enum Kind: Int {
        case text = 0
        case image = 1
    }

    let id: Int64
    let kind: Kind
    /// Plain text for text items, a short description ("Bild 287×523") for images.
    let text: String
    let imageFile: String?
    let app: String?
    let appPath: String?
    let date: Date
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
    }

    deinit {
        sqlite3_close(db)
    }

    var isEmpty: Bool {
        var empty = true
        query("SELECT 1 FROM items LIMIT 1") { _ in empty = false }
        return empty
    }

    // MARK: - Writing

    func addText(_ text: String, app: String?, appPath: String?, date: Date = Date()) {
        upsert(kind: .text, text: text, imageFile: nil, hash: Self.sha256("t:" + text), app: app, appPath: appPath, date: date)
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
        upsert(kind: .image, text: label, imageFile: fileName, hash: hash, app: app, appPath: appPath, date: date)
    }

    /// Moves an item to the top of the history.
    func touch(_ item: ClipItem) {
        run("UPDATE items SET ts = ? WHERE id = ?") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, item.id)
        }
    }

    func delete(_ item: ClipItem) {
        run("DELETE FROM items WHERE id = ?") { stmt in sqlite3_bind_int64(stmt, 1, item.id) }
        removeImage(item.imageFile)
    }

    func clear() {
        exec("DELETE FROM items")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path)) ?? []
        files.forEach(removeImage)
    }

    /// Drops everything older than the retention period and everything beyond maxItems.
    func prune(retentionDays: Int, maxItems: Int) {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400).timeIntervalSince1970
        let condition = "ts < ? OR id NOT IN (SELECT id FROM items ORDER BY ts DESC LIMIT ?)"
        let bind: (OpaquePointer?) -> Void = { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int64(stmt, 2, Int64(maxItems))
        }
        var files: [String] = []
        query("SELECT image_file FROM items WHERE image_file IS NOT NULL AND (\(condition))", bind: bind) { stmt in
            if let file = Self.string(stmt, 0) { files.append(file) }
        }
        run("DELETE FROM items WHERE \(condition)", bind: bind)
        files.forEach(removeImage)
    }

    // MARK: - Reading

    func items(limit: Int) -> [ClipItem] {
        var result: [ClipItem] = []
        let sql = "SELECT id, kind, text, image_file, app, app_path, ts FROM items ORDER BY ts DESC LIMIT ?"
        query(sql, bind: { sqlite3_bind_int64($0, 1, Int64(limit)) }) { stmt in
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: ClipItem.Kind(rawValue: Int(sqlite3_column_int(stmt, 1))) ?? .text,
                text: Self.string(stmt, 2) ?? "",
                imageFile: Self.string(stmt, 3),
                app: Self.string(stmt, 4),
                appPath: Self.string(stmt, 5),
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            ))
        }
        return result
    }

    func imageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDirectory.appendingPathComponent($0) }
    }

    // MARK: - SQLite helpers

    private func upsert(kind: ClipItem.Kind, text: String, imageFile: String?, hash: String, app: String?, appPath: String?, date: Date) {
        // On a duplicate keep the newest timestamp and the app that copied it last.
        let sql = """
            INSERT INTO items(kind, text, image_file, hash, app, app_path, ts) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET
                app = CASE WHEN excluded.ts > ts THEN excluded.app ELSE app END,
                app_path = CASE WHEN excluded.ts > ts THEN excluded.app_path ELSE app_path END,
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
        }
    }

    private func removeImage(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(fileName))
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Clippboard SQLite error: %@", String(cString: sqlite3_errmsg(db)))
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) {
        query(sql, bind: bind) { _ in }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("Clippboard SQLite error: %@", String(cString: sqlite3_errmsg(db)))
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
