import Foundation
import SQLite3

/// 只读 SQLite 访问层（对齐 FFSQLiteService 的浏览能力）。
/// 连接固定用 SQLITE_OPEN_READONLY 打开（默认 serialized 模式，不开 NOMUTEX），
/// 再用串行队列保证同一时刻只有一个语句在跑；大表按页读取，不整表进内存。
enum SQLiteServiceError: LocalizedError {
    case openFailed(String)
    case notOpen
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message), .queryFailed(let message):
            return message
        case .notOpen:
            return "数据库连接已关闭"
        }
    }
}

struct SQLiteQueryResult {
    let columns: [String]
    let rows: [[String]]
}

final class SQLiteService {
    let path: String

    private let queue = DispatchQueue(label: "ff.sqlite")
    private var db: OpaquePointer?

    /// 只读打开。加密（SQLCipher）或损坏文件在这里通常能打开，
    /// 第一次查询才会报「文件不是有效的 SQLite 数据库或已损坏」。
    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite 错误 \(rc)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteServiceError.openFailed(Self.friendlyMessage(rc, message))
        }
        self.db = opened
        // WAL 数据库以只读打开时依赖 -wal/-shm 可访问；同容器内通常成立。
    }

    deinit {
        queue.sync {
            if let handle = self.db { sqlite3_close(handle) }
        }
    }

    func close() {
        queue.sync {
            if let handle = self.db {
                sqlite3_close(handle)
                self.db = nil
            }
        }
    }

    // MARK: - 元信息

    /// 「页大小 X 字节 · 编码 · user_version N\nN 张表 · M 个视图」。
    func databaseSummary() throws -> String {
        try withDatabase { db in
            let pageSize = try self.scalarInt("PRAGMA page_size", db: db)
            let encoding = try self.scalarText("PRAGMA encoding", db: db) ?? "未知编码"
            let userVersion = try self.scalarInt("PRAGMA user_version", db: db)
            let tables = try self.objectNames(type: "table", db: db)
            let views = try self.objectNames(type: "view", db: db)
            return "页大小 \(pageSize) 字节 · \(encoding) · user_version \(userVersion)\n"
                + "\(tables.count) 张表 · \(views.count) 个视图"
        }
    }

    func tableNames() throws -> [String] {
        try withDatabase { db in try self.objectNames(type: "table", db: db) }
    }

    func viewNames() throws -> [String] {
        try withDatabase { db in try self.objectNames(type: "view", db: db) }
    }

    /// 表/视图的列名（PRAGMA table_info 顺序）。
    func columnNames(forObject name: String) throws -> [String] {
        try withDatabase { db in
            let statement = try self.prepare("PRAGMA table_info(\(Self.quoted(name)))", db: db)
            defer { sqlite3_finalize(statement) }
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                names.append(self.text(statement, 1))
            }
            return names
        }
    }

    /// 行数；表不存在或读取失败会抛错。视图同样支持。
    func rowCount(forObject name: String) throws -> Int64 {
        try withDatabase { db in
            let statement = try self.prepare("SELECT COUNT(*) FROM \(Self.quoted(name))", db: db)
            defer { sqlite3_finalize(statement) }
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW else { throw self.queryError(rc, db: db) }
            return sqlite3_column_int64(statement, 0)
        }
    }

    func schema(forObject name: String) throws -> String {
        try withDatabase { db in
            let safe = name.replacingOccurrences(of: "'", with: "''")
            return try self.scalarText(
                "SELECT sql FROM sqlite_master WHERE name = '\(safe)'", db: db) ?? ""
        }
    }

    func indexNames(forTable name: String) throws -> [String] {
        try withDatabase { db in
            let statement = try self.prepare("PRAGMA index_list(\(Self.quoted(name)))", db: db)
            defer { sqlite3_finalize(statement) }
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let index = self.text(statement, 1)
                if !index.isEmpty { names.append(index) }
            }
            return names
        }
    }

    // MARK: - 查询

    /// 通用分页查询（limit/offset），NULL 显示为空串。
    func query(_ sql: String, limit: Int = 200, offset: Int = 0) throws -> SQLiteQueryResult {
        try withDatabase { db in
            try self.queryResult(sql: sql, limit: limit, offset: offset, db: db)
        }
    }

    /// 按页读取表/视图数据。
    func rows(inObject name: String, limit: Int = 200, offset: Int = 0) throws -> SQLiteQueryResult {
        try query("SELECT * FROM \(Self.quoted(name))", limit: limit, offset: offset)
    }

    // MARK: - CSV

    /// CSV 文本（最多 maxRows 行，不含表头）；列名与值都加引号并转义内部引号。
    func csvString(forObject name: String, maxRows: Int = 50_000) throws -> String {
        try withDatabase { db in
            var output = ""
            _ = try self.enumerateCSV(forObject: name, db: db, maxRows: maxRows) {
                output += $0
            }
            return output
        }
    }

    /// 流式导出 CSV 到文件（不整表进内存），返回写入行数（不含表头）。
    @discardableResult
    func exportCSV(forObject name: String, to url: URL, maxRows: Int = 50_000) throws -> Int {
        try withDatabase { db in
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw SQLiteServiceError.queryFailed("无法创建导出文件")
            }
            guard let handle = try? FileHandle(forWritingTo: url) else {
                throw SQLiteServiceError.queryFailed("无法写入导出文件")
            }
            defer { try? handle.close() }
            do {
                var buffer = ""
                let written = try self.enumerateCSV(forObject: name, db: db, maxRows: maxRows) { line in
                    buffer += line
                    if buffer.utf8.count >= 256 * 1024 {
                        try handle.write(contentsOf: Data(buffer.utf8))
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: Data(buffer.utf8))
                }
                return written
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    static func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - 内部（调用方必须已在 queue 上）

    private func enumerateCSV(forObject name: String,
                              db: OpaquePointer,
                              maxRows: Int,
                              _ consume: (String) throws -> Void) throws -> Int {
        let statement = try prepare("SELECT * FROM \(Self.quoted(name))", db: db)
        defer { sqlite3_finalize(statement) }
        let columnCount = sqlite3_column_count(statement)
        var columns: [String] = []
        columns.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            columns.append(sqlite3_column_name(statement, index).map { String(cString: $0) }
                ?? "列\(index)")
        }
        try consume(columns.map(Self.csvField).joined(separator: ",") + "\n")

        var written = 0
        let cap = max(maxRows, 1)
        while written < cap {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw queryError(rc, db: db) }
            var fields: [String] = []
            fields.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                fields.append(Self.csvField(text(statement, index)))
            }
            try consume(fields.joined(separator: ",") + "\n")
            written += 1
        }
        return written
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let db = self.db else { throw SQLiteServiceError.notOpen }
            return try body(db)
        }
    }

    private func objectNames(type: String, db: OpaquePointer) throws -> [String] {
        let statement = try prepare(
            "SELECT name FROM sqlite_master WHERE type = '\(type)'"
                + " AND name NOT LIKE 'sqlite_%' ORDER BY name",
            db: db)
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            names.append(text(statement, 0))
        }
        return names
    }

    private func queryResult(sql: String, limit: Int, offset: Int,
                             db: OpaquePointer) throws -> SQLiteQueryResult {
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        let columnCount = sqlite3_column_count(statement)
        var columns: [String] = []
        columns.reserveCapacity(Int(columnCount))
        for index in 0..<columnCount {
            columns.append(sqlite3_column_name(statement, index).map { String(cString: $0) }
                ?? "列\(index)")
        }

        var skipped = 0
        while skipped < offset {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                skipped += 1
                continue
            }
            if rc == SQLITE_DONE {
                return SQLiteQueryResult(columns: columns, rows: [])
            }
            throw queryError(rc, db: db)
        }

        var rows: [[String]] = []
        let pageLimit = max(limit, 1)
        while rows.count < pageLimit {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                var row: [String] = []
                row.reserveCapacity(Int(columnCount))
                for index in 0..<columnCount {
                    row.append(text(statement, index))
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw queryError(rc, db: db)
            }
        }
        return SQLiteQueryResult(columns: columns, rows: rows)
    }

    private func prepare(_ sql: String, db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw queryError(rc, db: db)
        }
        return statement
    }

    private func scalarInt(_ sql: String, db: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ sql: String, db: OpaquePointer) throws -> String? {
        let statement = try prepare(sql, db: db)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }

    private func queryError(_ code: Int32, db: OpaquePointer) -> SQLiteServiceError {
        .queryFailed(Self.friendlyMessage(code, String(cString: sqlite3_errmsg(db))))
    }

    private static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func friendlyMessage(_ code: Int32, _ message: String) -> String {
        switch code {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return "\(message)（数据库被占用，稍后重试）"
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return "文件不是有效的 SQLite 数据库或已损坏"
        case SQLITE_CANTOPEN:
            return "无法打开数据库文件"
        default:
            return message.isEmpty ? "SQLite 错误 \(code)" : message
        }
    }
}
