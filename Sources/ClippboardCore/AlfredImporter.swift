import Foundation
import SQLite3

/// One-time import of the Alfred clipboard history (Alfred 3, 4 and 5 use the same schema).
public enum AlfredImporter {
    private static let doneKey = "alfredImportDone"

    public static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // Alfred stores timestamps relative to 2001-01-01; dataType 0 = text, 1 = image, 2 = file.
    @discardableResult
    public static func importIfNeeded(into store: Store, supportDirectory: URL = defaultSupportDirectory,
                                      force: Bool = false) -> Int {
        // Before the flag moved into the database it lived in UserDefaults.
        let alreadyDone = store.metadata(doneKey) == "1" || UserDefaults.standard.bool(forKey: doneKey)
        if !force && alreadyDone { return 0 }
        defer { store.setMetadata("1", for: doneKey) }

        let candidates = ["Alfred", "Alfred 3"].map {
            supportDirectory.appendingPathComponent($0).appendingPathComponent("Databases")
        }
        guard let databases = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("clipboard.alfdb").path)
        }) else { return 0 }

        var db: OpaquePointer?
        let path = databases.appendingPathComponent("clipboard.alfdb").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT item, ts, app, apppath, dataType, dataHash FROM clipboard ORDER BY ts ASC"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        let imageDirectory = databases.appendingPathComponent("clipboard.alfdb.data")
        var count = 0
        // One transaction instead of one commit per row keeps the import fast.
        try? store.transaction {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let item = Store.string(stmt, 0) ?? ""
                let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
                let app = Store.string(stmt, 2)
                let appPath = Store.string(stmt, 3)
                switch sqlite3_column_int(stmt, 4) {
                case 1:
                    guard let file = Store.string(stmt, 5),
                          file == (file as NSString).lastPathComponent, !file.hasPrefix("."),
                          let data = try? Data(contentsOf: imageDirectory.appendingPathComponent(file)),
                          let image = ImageIngest.prepare(data) else { continue }
                    store.addImage(image, app: app, appPath: appPath, date: date)
                case 2:
                    let paths = item.split(separator: "\n").map(String.init)
                    guard !paths.isEmpty else { continue }
                    store.addFiles(paths, app: app, appPath: appPath, date: date)
                default:
                    guard !item.isEmpty else { continue }
                    store.addText(item, app: app, appPath: appPath, date: date)
                }
                count += 1
            }
        }
        return count
    }
}
