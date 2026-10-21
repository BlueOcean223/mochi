import Foundation
import SQLite3

/// 系统 libsqlite3 的薄封装，只包这里用得到的几样。不是线程安全的，只在 `ClipStore` 这个 actor 里用。
final class Database {
    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "错误码 \(rc)"
            sqlite3_close(db)
            throw DatabaseError(message: "打开 \(path) 失败：\(message)")
        }
        handle = db
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    /// 跑一段不需要参数、不取结果的 SQL，可以有多条语句。
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? lastError
            sqlite3_free(error)
            throw DatabaseError(message: message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError(message: "\(lastError)：\(sql)")
        }
        return Statement(handle: statement, database: self)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastError: String { String(cString: sqlite3_errmsg(handle)) }
}

struct DatabaseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

/// 准备好的语句：`bind` → 循环 `step()` 读列；不取结果的用 `run()`。
final class Statement {
    private let handle: OpaquePointer
    private let database: Database

    fileprivate init(handle: OpaquePointer, database: Database) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    /// 按顺序绑定 `?1`、`?2`……，先清掉上一次的。
    @discardableResult
    func bind(_ values: SQLValue...) throws -> Statement {
        try bind(values)
    }

    @discardableResult
    func bind(_ values: [SQLValue]) throws -> Statement {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32 = switch value {
            case .null: sqlite3_bind_null(handle, index)
            case .int(let v): sqlite3_bind_int64(handle, index, v)
            case .double(let v): sqlite3_bind_double(handle, index, v)
            case .text(let v): sqlite3_bind_text(handle, index, v, -1, transient)
            case .blob(let v) where v.isEmpty: sqlite3_bind_zeroblob(handle, index, 0)
            case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard rc == SQLITE_OK else { throw DatabaseError(message: database.lastError) }
        }
        return self
    }

    /// 走一步：有一行返回 true，走完返回 false。
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DatabaseError(message: database.lastError)
        }
    }

    func run() throws {
        while try step() {}
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func text(_ column: Int32) -> String? {
        sqlite3_column_text(handle, column).map { String(cString: $0) }
    }

    func blob(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

/// 让 SQLite 自己拷一份绑定的数据（`SQLITE_TRANSIENT`）。C 宏在 Swift 里用不了，只能这么写。
private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
