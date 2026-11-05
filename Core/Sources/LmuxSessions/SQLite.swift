import Foundation
import SQLite3

/// Minimal wrapper over the system SQLite C API (no third-party dependencies).
final class SQLiteDB {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        /// SQLite's result code, when it came from a statement.
        var code: Int32 = 0
        var description: String { "sqlite: \(message)" }
        /// The file is not a (readable) database: garbage, truncated, a torn write.
        var isCorrupt: Bool { code == SQLITE_CORRUPT || code == SQLITE_NOTADB }
    }

    let handle: OpaquePointer

    init(path: String) throws {
        // The index holds prompt text: private, and SQLite gives -wal / -shm the same mode.
        if path != ":memory:", !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) { chmod(path + suffix, 0o600) }
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(h)
            throw Failure(message: msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
    }

    deinit { sqlite3_close_v2(handle) }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw Failure(message: "\(msg) in: \(sql.prefix(120))", code: sqlite3_errcode(handle))
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw Failure(message: "\(errorMessage) in: \(sql.prefix(120))")
        }
        return Statement(stmt, db: self)
    }

    /// Runs a statement to completion with the given bindings.
    func run(_ sql: String, _ values: [Any?] = []) throws {
        let s = try prepare(sql)
        try s.bind(values)
        while try s.step() {}
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}

final class Statement {
    private let stmt: OpaquePointer
    private let db: SQLiteDB
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit { sqlite3_finalize(stmt) }

    func bind(_ values: [Any?]) throws {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case nil: rc = sqlite3_bind_null(stmt, idx)
            case let s as String: rc = sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case let n as Int: rc = sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: rc = sqlite3_bind_int64(stmt, idx, n)
            case let b as Bool: rc = sqlite3_bind_int64(stmt, idx, b ? 1 : 0)
            case let d as Double: rc = sqlite3_bind_double(stmt, idx, d)
            case let d as Data:
                rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), Self.transient) }
            default: throw SQLiteDB.Failure(message: "unsupported bind type \(type(of: v!))")
            }
            if rc != SQLITE_OK { throw SQLiteDB.Failure(message: db.errorMessage) }
        }
    }

    /// Returns true when a row is available.
    func step() throws -> Bool {
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteDB.Failure(message: db.errorMessage)
        }
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    func string(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func optDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
    func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}
