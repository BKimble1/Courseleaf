import Foundation
import CSQLite
import DocumentCore

/// A bound parameter or column value.
public enum SQLiteValue: Hashable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Bool) { self = .integer(value ? 1 : 0) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }
    /// Dates are stored as seconds since the reference date (exact round trip of `Date`'s storage).
    public init(_ value: Date) { self = .real(value.timeIntervalSinceReferenceDate) }
    public init<ID: EntityIdentifier>(_ id: ID) { self = .text(id.description) }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Date?) { self = value.map { SQLiteValue($0) } ?? .null }
    public init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    public init<ID: EntityIdentifier>(_ id: ID?) { self = id.map { .text($0.description) } ?? .null }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A prepared statement owned by `SQLiteDatabase`'s cache. Not thread-safe;
/// the owning database (and therefore the `CatalogDatabase` actor) serializes use.
public final class SQLiteStatement {
    fileprivate let handle: OpaquePointer
    fileprivate unowned let database: SQLiteDatabase
    public let sql: String

    fileprivate init(handle: OpaquePointer, database: SQLiteDatabase, sql: String) {
        self.handle = handle; self.database = database; self.sql = sql
    }
    deinit { sqlite3_finalize(handle) }

    public var columnCount: Int { Int(sqlite3_column_count(handle)) }

    func bind(_ values: [SQLiteValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(handle, index)
            case .integer(let v): rc = sqlite3_bind_int64(handle, index, v)
            case .real(let v): rc = sqlite3_bind_double(handle, index, v)
            case .text(let s): rc = sqlite3_bind_text(handle, index, s, -1, sqliteTransient)
            case .blob(let d):
                rc = d.withUnsafeBytes { buffer -> Int32 in
                    if buffer.isEmpty { return sqlite3_bind_zeroblob(handle, index, 0) }
                    return sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
            }
            if rc != SQLITE_OK { throw database.error(rc) }
        }
    }

    /// Advances to the next row. Returns false when the statement is done.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw database.error(rc)
        }
    }

    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }

    // MARK: Column access

    public func isNull(_ column: Int) -> Bool { sqlite3_column_type(handle, Int32(column)) == SQLITE_NULL }
    public func int64(_ column: Int) -> Int64 { sqlite3_column_int64(handle, Int32(column)) }
    public func int(_ column: Int) -> Int { Int(sqlite3_column_int64(handle, Int32(column))) }
    public func bool(_ column: Int) -> Bool { sqlite3_column_int64(handle, Int32(column)) != 0 }
    public func double(_ column: Int) -> Double { sqlite3_column_double(handle, Int32(column)) }
    public func string(_ column: Int) -> String {
        guard let p = sqlite3_column_text(handle, Int32(column)) else { return "" }
        return String(cString: p)
    }
    public func optionalString(_ column: Int) -> String? { isNull(column) ? nil : string(column) }
    public func optionalDouble(_ column: Int) -> Double? { isNull(column) ? nil : double(column) }
    public func date(_ column: Int) -> Date { Date(timeIntervalSinceReferenceDate: double(column)) }
    public func optionalDate(_ column: Int) -> Date? { isNull(column) ? nil : date(column) }
    public func data(_ column: Int) -> Data {
        let count = Int(sqlite3_column_bytes(handle, Int32(column)))
        guard count > 0, let p = sqlite3_column_blob(handle, Int32(column)) else { return Data() }
        return Data(bytes: p, count: count)
    }
    public func identifier<ID: EntityIdentifier>(_ column: Int, as type: ID.Type = ID.self) -> ID? {
        ID(uuidString: string(column))
    }
    public func value(_ column: Int) -> SQLiteValue {
        switch sqlite3_column_type(handle, Int32(column)) {
        case SQLITE_INTEGER: return .integer(int64(column))
        case SQLITE_FLOAT: return .real(double(column))
        case SQLITE_TEXT: return .text(string(column))
        case SQLITE_BLOB: return .blob(data(column))
        default: return .null
        }
    }
}

/// Thin, synchronous wrapper around one `sqlite3*` connection: WAL for files,
/// busy timeout, a prepared-statement cache, typed bind/column helpers,
/// transactions that roll back on throw, and `CatalogError` mapping. Owned and
/// serialized by `CatalogDatabase`; not thread-safe on its own.
public final class SQLiteDatabase {
    public static let memoryPath = ":memory:"
    private var handle: OpaquePointer?
    private var statements: [String: SQLiteStatement] = [:]
    private var transactionDepth = 0
    public let path: String
    public var isInMemory: Bool { path == SQLiteDatabase.memoryPath }
    public var isOpen: Bool { handle != nil }

    /// Opens (creating if needed) the database at `path`, or an in-memory
    /// database for `":memory:"`. Throws `CatalogError.fts5Unavailable` when
    /// the linked SQLite has no FTS5 module.
    public init(path: String, busyTimeoutMilliseconds: Int32 = 5_000) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close_v2(db) }
            throw CatalogError.sqlite(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
        do {
            try execute("PRAGMA foreign_keys = ON")
            if !isInMemory {
                try execute("PRAGMA journal_mode = WAL")
                try execute("PRAGMA synchronous = NORMAL")
            }
            try checkFTS5()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    /// Finalizes every cached statement and closes the connection. Idempotent.
    public func close() {
        statements.removeAll()
        if let handle { sqlite3_close_v2(handle); self.handle = nil }
    }

    // MARK: Errors

    fileprivate func error(_ rc: Int32) -> CatalogError {
        guard let handle else { return .closed }
        let extended = sqlite3_extended_errcode(handle)
        return .sqlite(code: extended != 0 ? extended : rc, message: String(cString: sqlite3_errmsg(handle)))
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let handle else { throw CatalogError.closed }
        return handle
    }

    // MARK: FTS5 availability

    private func checkFTS5() throws {
        let probe = "CREATE VIRTUAL TABLE temp.courseleaf_fts5_probe USING fts5(t)"
        let db = try requireHandle()
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, probe, nil, nil, &message)
        if let message { sqlite3_free(message) }
        guard rc == SQLITE_OK else { throw CatalogError.fts5Unavailable }
        try execute("DROP TABLE temp.courseleaf_fts5_probe")
    }

    // MARK: Statements

    /// Executes one or more semicolon-separated statements without bindings (DDL, pragmas).
    public func execute(_ sql: String) throws {
        let db = try requireHandle()
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let message { sqlite3_free(message) }
            throw CatalogError.sqlite(code: rc, message: text)
        }
    }

    /// Returns the cached prepared statement for `sql`, reset and with bindings cleared.
    public func prepare(_ sql: String) throws -> SQLiteStatement {
        let db = try requireHandle()
        if let cached = statements[sql] { cached.reset(); return cached }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        let statement = SQLiteStatement(handle: stmt, database: self, sql: sql)
        statements[sql] = statement
        return statement
    }

    /// Runs a statement that returns no rows (or whose rows are ignored).
    public func run(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        let stmt = try prepare(sql)
        try stmt.bind(bindings)
        while try stmt.step() {}
        stmt.reset()
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [], _ row: (SQLiteStatement) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(bindings)
        defer { stmt.reset() }
        var results: [T] = []
        while try stmt.step() { results.append(try row(stmt)) }
        return results
    }

    /// Runs a query and returns the first column of the first row, or `.null` when there is none.
    public func scalar(_ sql: String, _ bindings: [SQLiteValue] = []) throws -> SQLiteValue {
        try query(sql, bindings) { $0.value(0) }.first ?? .null
    }

    public var lastInsertRowID: Int64 { handle.map { sqlite3_last_insert_rowid($0) } ?? 0 }
    public var changes: Int { handle.map { Int(sqlite3_changes($0)) } ?? 0 }

    // MARK: Transactions

    /// Runs `body` inside a transaction (nested calls join the outer one).
    /// The transaction is rolled back when `body` throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        if transactionDepth > 0 {
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            return try body()
        }
        try execute("BEGIN IMMEDIATE")
        transactionDepth = 1
        do {
            let result = try body()
            transactionDepth = 0
            try execute("COMMIT")
            return result
        } catch {
            transactionDepth = 0
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var isInTransaction: Bool { transactionDepth > 0 }

    // MARK: Pragmas and maintenance

    public var userVersion: Int {
        get { (try? scalar("PRAGMA user_version")).flatMap { if case .integer(let v) = $0 { return Int(v) } else { return nil } } ?? 0 }
    }
    public func setUserVersion(_ version: Int) throws { try execute("PRAGMA user_version = \(version)") }

    /// Runs `PRAGMA integrity_check` and returns its complaints; empty means the file is sound.
    public func integrityCheck() throws -> [String] {
        let rows = try query("PRAGMA integrity_check") { $0.string(0) }
        if rows == ["ok"] { return [] }
        return rows
    }

    /// Bytes used by the database: file plus WAL/SHM on disk, page_count * page_size in memory.
    public func storageSizeInBytes() throws -> Int {
        if isInMemory {
            guard case .integer(let pages) = try scalar("PRAGMA page_count"),
                  case .integer(let size) = try scalar("PRAGMA page_size") else { return 0 }
            return Int(pages * size)
        }
        let fm = FileManager.default
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            if let attrs = try? fm.attributesOfItem(atPath: path + suffix), let size = attrs[.size] as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    /// Flushes the WAL into the main file so on-disk size reflects the content.
    public func checkpoint() throws {
        guard !isInMemory else { return }
        try execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }
}
