import Foundation
import SQLite3

/// Deleting entries and wiping what deletes leave behind on disk.
extension Store {
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
    func wipeDeletedContent() {
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
    func removeImage(_ fileName: String) {
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
}
