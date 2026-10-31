import Foundation
import SQLite3

/// Adding and changing entries.
extension Store {
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

    /// Stores the pin time (seconds since 1970) in `pinned`, so the pinned list shows the latest pin
    /// first; entries pinned before that hold 1 and follow. Returns false if the change could not be stored.
    @discardableResult
    public func setPinned(_ pinned: Bool, for item: ClipItem, at date: Date = Date()) -> Bool {
        run("UPDATE items SET pinned = ? WHERE id = ?") { stmt in
            sqlite3_bind_int64(stmt, 1, pinned ? max(1, Int64(date.timeIntervalSince1970)) : 0)
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

    private struct Row {
        var kind: ClipItem.Kind
        var text: String
        var hash: String
        var rich: RichText?
        var imageFile: String?
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
}
