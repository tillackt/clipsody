import Foundation
import SQLite3

/// One-time import of the Alfred clipboard history (Alfred 3, 4 and 5 use the same schema).
public enum AlfredImporter {
    private static let doneKey = "alfredImportDone"

    private struct ImportError: Error, CustomStringConvertible {
        let description: String
    }

    public static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Imports once; the same rules as for live copies apply (ignored apps, images on/off, size
    /// limits). The import only counts as done when it was committed completely, so a failure is
    /// retried at the next launch instead of silently skipping entries for good.
    // Alfred stores timestamps relative to 2001-01-01; dataType 0 = text, 1 = image, 2 = file.
    @discardableResult
    public static func importIfNeeded(into store: Store, config: Config = Config(),
                                      supportDirectory: URL = defaultSupportDirectory, force: Bool = false) -> Int {
        if !force && store.metadata(doneKey) == "1" { return 0 }

        let candidates = ["Alfred", "Alfred 3"].map {
            supportDirectory.appendingPathComponent($0).appendingPathComponent("Databases")
        }
        guard let databases = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("clipboard.alfdb").path)
        }) else {
            // Nothing to import, now or later.
            store.setMetadata("1", for: doneKey)
            return 0
        }

        do {
            let count = try importEntries(from: databases, into: store, config: config)
            logger.info("Imported \(count) entries from Alfred")
            return count
        } catch {
            logger.error("Alfred import failed, will retry at next launch: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private static func importEntries(from databases: URL, into store: Store, config: Config) throws -> Int {
        var db: OpaquePointer?
        let path = databases.appendingPathComponent("clipboard.alfdb").path
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ImportError(description: "open: \(String(cString: sqlite3_errmsg(db)))")
        }
        var stmt: OpaquePointer?
        let sql = "SELECT item, ts, app, apppath, dataType, dataHash FROM clipboard ORDER BY ts ASC"
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ImportError(description: "read: \(String(cString: sqlite3_errmsg(db)))")
        }

        let imageDirectory = databases.appendingPathComponent("clipboard.alfdb.data")
        var count = 0
        // One transaction: fast, and all or nothing together with the "done" flag.
        try store.transaction {
            while true {
                let step = sqlite3_step(stmt)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw ImportError(description: "read: \(String(cString: sqlite3_errmsg(db)))")
                }
                let item = Store.string(stmt, 0) ?? ""
                let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
                let app = Store.string(stmt, 2)
                let appPath = Store.string(stmt, 3)
                if let appPath, let bundleId = Bundle(path: appPath)?.bundleIdentifier,
                   config.ignoredApps.contains(bundleId) { continue }

                let stored: Bool
                switch sqlite3_column_int(stmt, 4) {
                case 1:
                    guard config.keepImages,
                          let file = Store.string(stmt, 5),
                          file == (file as NSString).lastPathComponent, !file.hasPrefix("."),
                          let data = try? Data(contentsOf: imageDirectory.appendingPathComponent(file)),
                          let image = ImageIngest.prepare(data) else { continue }
                    stored = store.addImage(image, app: app, appPath: appPath, date: date)
                case 2:
                    let paths = item.split(separator: "\n").map(String.init)
                    guard !paths.isEmpty else { continue }
                    stored = store.addFiles(paths, app: app, appPath: appPath, date: date)
                default:
                    guard !item.isEmpty, item.utf8.count <= CaptureLimits.maxTextBytes else { continue }
                    stored = store.addText(item, app: app, appPath: appPath, date: date)
                }
                guard stored else { throw ImportError(description: "write failed") }
                count += 1
            }
            guard store.setMetadata("1", for: doneKey) else { throw ImportError(description: "write failed") }
        }
        return count
    }
}
