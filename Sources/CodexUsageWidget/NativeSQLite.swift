import Foundation
import SQLite3

enum NativeSQLite {
    static func queryRows(dbPath: String, sql: String) -> [[String: String?]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [[String: String?]] = []
        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                if let cStr = sqlite3_column_text(stmt, i) {
                    row[name] = String(cString: cStr)
                } else if sqlite3_column_type(stmt, i) == SQLITE_INTEGER {
                    row[name] = String(sqlite3_column_int64(stmt, i))
                } else if sqlite3_column_type(stmt, i) == SQLITE_FLOAT {
                    row[name] = String(sqlite3_column_double(stmt, i))
                } else {
                    row[name] = nil
                }
            }
            rows.append(row)
        }
        return rows
    }

    static func querySingleRow(dbPath: String, sql: String) -> [String: String?]? {
        queryRows(dbPath: dbPath, sql: sql).first
    }

    static func queryRowsAny(dbPath: String, sql: String) -> [[String: Any]] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [[String: Any]] = []
        let colCount = sqlite3_column_count(stmt)

        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let type = sqlite3_column_type(stmt, i)
                switch type {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(stmt, i)
                case SQLITE_TEXT:
                    if let cStr = sqlite3_column_text(stmt, i) {
                        row[name] = String(cString: cStr)
                    }
                case SQLITE_BLOB:
                    if let blob = sqlite3_column_blob(stmt, i) {
                        let size = sqlite3_column_bytes(stmt, i)
                        row[name] = Data(bytes: blob, count: Int(size))
                    }
                default:
                    break
                }
            }
            rows.append(row)
        }
        return rows
    }
}
