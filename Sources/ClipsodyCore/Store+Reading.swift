import Foundation
import SQLite3

/// Reading entries and resolving image files.
extension Store {
    /// All entries: pinned ones first (latest pin first), then the rest by date. Without a limit pinned
    /// entries cannot push others out of view; `prune` keeps the total bounded.
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
                pinned: sqlite3_column_int64(stmt, 7) != 0,
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
}
