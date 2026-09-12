import XCTest
import DocumentCore
@testable import Catalog

final class SQLiteDatabaseTests: XCTestCase {
    func testInMemoryRoundTripsEveryValueType() throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.memoryPath)
        try db.execute("CREATE TABLE t(i INTEGER, r REAL, s TEXT, b BLOB, n)")
        let date = Date(timeIntervalSinceReferenceDate: 123_456.789_012)
        try db.run("INSERT INTO t VALUES(?, ?, ?, ?, ?)", [.init(42), .init(date), .init("héllo \"quoted\""), .init(Data([0, 1, 2, 255])), .null])
        let rows = try db.query("SELECT i, r, s, b, n FROM t") { ($0.int($0.isNull(0) ? 4 : 0), $0.date(1), $0.string(2), $0.data(3), $0.isNull(4)) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].0, 42)
        XCTAssertEqual(rows[0].1, date)
        XCTAssertEqual(rows[0].2, "héllo \"quoted\"")
        XCTAssertEqual(rows[0].3, Data([0, 1, 2, 255]))
        XCTAssertTrue(rows[0].4)
    }

    func testFileDatabaseUsesWALAndPersists() throws {
        let dir = TemporaryDirectory()
        let path = dir.file("db.sqlite").path
        do {
            let db = try SQLiteDatabase(path: path)
            XCTAssertEqual(try db.scalar("PRAGMA journal_mode"), .text("wal"))
            try db.execute("CREATE TABLE t(x TEXT)")
            try db.run("INSERT INTO t VALUES(?)", [.init("persisted")])
            db.close()
            XCTAssertFalse(db.isOpen)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let reopened = try SQLiteDatabase(path: path)
        XCTAssertEqual(try reopened.query("SELECT x FROM t") { $0.string(0) }, ["persisted"])
        XCTAssertGreaterThan(try reopened.storageSizeInBytes(), 0)
        withExtendedLifetime(dir) {}
    }

    func testTransactionRollsBackOnThrow() throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.memoryPath)
        try db.execute("CREATE TABLE t(x INTEGER)")
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t VALUES(1)")
            try db.transaction { try db.run("INSERT INTO t VALUES(2)") } // nested joins the outer transaction
            throw Boom()
        })
        XCTAssertFalse(db.isInTransaction)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM t"), .integer(0))
        let result = try db.transaction { () -> Int in try db.run("INSERT INTO t VALUES(3)"); return 7 }
        XCTAssertEqual(result, 7)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM t"), .integer(1))
    }

    func testPreparedStatementsAreCachedAndRebound() throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.memoryPath)
        try db.execute("CREATE TABLE t(x INTEGER)")
        let a = try db.prepare("INSERT INTO t VALUES(?)")
        let b = try db.prepare("INSERT INTO t VALUES(?)")
        XCTAssertTrue(a === b)
        for i in 1...3 { try db.run("INSERT INTO t VALUES(?)", [.init(i)]) }
        XCTAssertEqual(try db.query("SELECT x FROM t ORDER BY x") { $0.int(0) }, [1, 2, 3])
        // A second run of the same SELECT with a different binding must not see the old one.
        XCTAssertEqual(try db.query("SELECT x FROM t WHERE x > ?", [.init(1)]) { $0.int(0) }, [2, 3])
        XCTAssertEqual(try db.query("SELECT x FROM t WHERE x > ?", [.init(2)]) { $0.int(0) }, [3])
    }

    func testErrorsMapToCatalogError() throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.memoryPath)
        XCTAssertThrowsError(try db.execute("SELEKT nonsense")) { error in
            guard case CatalogError.sqlite(let code, let message)? = error as? CatalogError else { return XCTFail("\(error)") }
            XCTAssertNotEqual(code, 0)
            XCTAssertFalse(message.isEmpty)
        }
        try db.execute("CREATE TABLE u(x INTEGER PRIMARY KEY)")
        try db.run("INSERT INTO u VALUES(1)")
        XCTAssertThrowsError(try db.run("INSERT INTO u VALUES(1)")) { error in
            guard case CatalogError.sqlite(let code, _)? = error as? CatalogError else { return XCTFail("\(error)") }
            XCTAssertEqual(code & 0xff, 19, "SQLITE_CONSTRAINT")
        }
        db.close()
        XCTAssertThrowsError(try db.execute("SELECT 1")) { XCTAssertEqual($0 as? CatalogError, .closed) }
        XCTAssertThrowsError(try db.prepare("SELECT 1")) { XCTAssertEqual($0 as? CatalogError, .closed) }
    }

    func testFTS5IsAvailableAndIntegrityCheckPasses() throws {
        let db = try SQLiteDatabase(path: SQLiteDatabase.memoryPath)
        try db.execute("CREATE VIRTUAL TABLE f USING fts5(t)")
        try db.run("INSERT INTO f(t) VALUES(?)", [.init("gradient descent")])
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM f WHERE f MATCH ?", [.init("\"grad\"*")]), .integer(1))
        XCTAssertEqual(try db.integrityCheck(), [])
    }

    func testUserVersionAndSchemaMismatch() throws {
        let dir = TemporaryDirectory()
        let url = dir.file("catalog.sqlite")
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.setUserVersion(CatalogSchema.version + 1)
            XCTAssertEqual(db.userVersion, CatalogSchema.version + 1)
        }
        XCTAssertThrowsError(try CatalogDatabase.open(at: url)) {
            XCTAssertEqual($0 as? CatalogError, .schemaMismatch(found: CatalogSchema.version + 1, expected: CatalogSchema.version))
        }
        let recreated = try CatalogDatabase.open(at: url, recreateOnSchemaMismatch: true)
        let db = try SQLiteDatabase(path: url.path)
        XCTAssertEqual(db.userVersion, CatalogSchema.version)
        withExtendedLifetime((dir, recreated)) {}
    }
}
