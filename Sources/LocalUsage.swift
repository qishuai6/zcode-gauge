import Foundation
import SQLite3

// 本地用量兜底：只读查询 ZCode 的请求流水库
enum LocalUsage {
    private static let provider = "account:bigmodel-individual-coding-plan"

    static func tokens(sinceEpochMs ms: Int64) -> Int64? {
        let path = NSString(string: "~/.zcode/cli/db/db.sqlite").expandingTildeInPath
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT COALESCE(SUM(computed_total_tokens),0) FROM model_usage " +
                  "WHERE provider_id = ? AND started_at >= ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, provider, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, ms)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }
}
