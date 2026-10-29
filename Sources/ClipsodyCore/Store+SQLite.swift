import Foundation
import SQLite3

// Named like the C constant it stands in for.
// swiftlint:disable:next identifier_name
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin helpers around the SQLite C API.
extension Store {
    /// Runs `body` in one transaction; rolls back if it throws. Internal on purpose: image files
    /// deleted inside a transaction would not come back with a rollback.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastError: String {
        String(cString: sqlite3_errmsg(db))
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(lastError) }
    }

    func runOrThrow(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        guard run(sql, bind: bind) else { throw StoreError.sqlite(lastError) }
    }

    /// Executes a statement; logs and returns false on any error.
    @discardableResult
    func run(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        query(sql, bind: bind) { _ in }
    }

    /// Steps through all result rows; logs and returns false if preparing or stepping fails.
    @discardableResult
    func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) -> Bool {
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

    /// Binds with the explicit UTF-8 length, so text containing NUL characters is stored completely.
    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            var value = value
            value.withUTF8 { buffer in
                _ = sqlite3_bind_text(stmt, index, UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: CChar.self),
                                      Int32(buffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Reads the column by its byte length; a C string would stop at the first NUL character.
    static func string(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, column) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, column))
        // Lenient on purpose: invalid UTF-8 in a stored text becomes U+FFFD instead of losing the entry.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: UnsafeBufferPointer(start: text, count: length), as: UTF8.self)
    }

    static func encodePaths(_ paths: [String]) -> String {
        (try? String(data: JSONEncoder().encode(paths), encoding: .utf8)) ?? "[]"
    }

    static func decodePaths(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
