import Foundation
import SQLite3

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
/// The class holds the connection and the state; reading, writing, deleting, migrations and the
/// SQLite helpers live in extensions in the Store+*.swift files. Their internal (not public)
/// members, such as `db`, `query` or `execute`, exist for those extensions only: other code in
/// ClipsodyCore goes through the public API like the app does.
public final class Store {
    public let directory: URL
    public let imagesDirectory: URL
    private(set) var db: OpaquePointer?
    /// Single deletes are wiped from disk in one go (see `flushDeletions`), not on every ⌘⌫.
    var hasUnwipedDeletions = false

    /// Characters of a text loaded for the list; enough for title, preview and search.
    public static let listTextPrefix = CaptureLimits.searchableCharacters

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipsody")
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

    func fileSize(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }
}
