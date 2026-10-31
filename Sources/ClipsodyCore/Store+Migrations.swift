import Foundation
import SQLite3

/// Schema versions of the history database.
extension Store {
    /// Ordered schema steps; `PRAGMA user_version` stores how many have been applied.
    /// Append new steps, never change released ones.
    private static let migrations: [@Sendable (Store) throws -> Void] = [
        { try $0.migrateToV1() },
        { try $0.migrateToV2() },
        { try $0.migrateToV3() },
        { try $0.migrateToV4() },
    ]

    var schemaVersion: Int {
        var version = 0
        query("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
        return version
    }

    func migrate() throws {
        let current = schemaVersion
        for (index, step) in Self.migrations.enumerated() where index >= current {
            try transaction {
                try step(self)
                try execute("PRAGMA user_version = \(index + 1)")
            }
        }
        // Version 1.2.0 opens newer databases too and still pins with 1.
        try normalizePinTimes()
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

    /// `pinned` holds the pin time in milliseconds, compared with `ts` to tell whether a pinned entry
    /// was copied again since. Entries pinned before held 1: they get a pin time just after their last
    /// copy, which keeps them out of the history and in the order they had. Seconds from test builds
    /// of the pinned list become milliseconds.
    private func migrateToV4() throws {
        try normalizePinTimes()
    }

    func normalizePinTimes() throws {
        try execute("""
            UPDATE items SET pinned = (CAST(ts AS INTEGER) + 1) * 1000 WHERE pinned = 1;
            UPDATE items SET pinned = pinned * 1000 WHERE pinned > 1 AND pinned < 100000000000;
            """)
    }

    /// Lets the file shrink again after pruning (otherwise it stays at its largest size).
    /// Switching an existing database needs one VACUUM, which cannot run inside a transaction.
    func enableIncrementalVacuum() throws {
        var mode = 0
        query("PRAGMA auto_vacuum") { mode = Int(sqlite3_column_int($0, 0)) }
        guard mode != 2 else { return }
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try execute("VACUUM")
    }
}
