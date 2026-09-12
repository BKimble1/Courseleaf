import XCTest
import DocumentCore
@testable import Persistence
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class FileSystemTests: XCTestCase {
    func testErrnoMappingAndRetryability() {
        XCTAssertEqual(PersistenceError.fromErrno(ENOSPC, path: "/x"), .diskFull)
        XCTAssertEqual(PersistenceError.fromErrno(EDQUOT, path: "/x"), .diskFull)
        XCTAssertEqual(PersistenceError.fromErrno(ENOENT, path: "/x"), .packageNotFound(path: "/x"))
        XCTAssertEqual(PersistenceError.fromErrno(EEXIST, path: "/x"), .alreadyExists(path: "/x"))
        if case .writeFailed(let path, let underlying) = PersistenceError.fromErrno(EIO, path: "/y") {
            XCTAssertEqual(path, "/y")
            XCTAssertTrue(underlying.contains("errno \(EIO)"))
        } else { XCTFail("EIO must map to writeFailed") }
        XCTAssertTrue(PersistenceError.diskFull.isRetryable)
        XCTAssertFalse(PersistenceError.unsupportedSchema(version: 2).isRetryable)
        XCTAssertFalse(PersistenceError.corruptManifest(reason: "x").isRetryable)
    }

    func testLocalFileSystemWritesReplacesLinksAndLists() throws {
        let dir = try tempDirectory("FS")
        let fs = LocalFileSystem()
        let nested = dir.appendingPathComponent("a/b")
        try fs.createDirectory(at: nested)
        try fs.createDirectory(at: nested)   // idempotent
        XCTAssertTrue(fs.directoryExists(at: nested))
        XCTAssertFalse(fs.fileExists(at: nested))

        let file = nested.appendingPathComponent("one.txt")
        try fs.write(Data("hello".utf8), to: file)
        try fs.syncFile(at: file)
        try fs.syncDirectory(at: nested)
        XCTAssertTrue(fs.fileExists(at: file))
        XCTAssertEqual(try fs.fileSize(at: file), 5)
        XCTAssertEqual(try fs.read(at: file), Data("hello".utf8))

        // Atomic replace: the destination carries the new bytes and the source is gone.
        let staged = nested.appendingPathComponent("one.txt.tmp")
        try fs.write(Data("replaced".utf8), to: staged)
        try fs.replaceItem(at: file, withItemAt: staged)
        XCTAssertEqual(try fs.read(at: file), Data("replaced".utf8))
        XCTAssertFalse(fs.fileExists(at: staged))

        // copyOrLink shares content, refuses to clobber, and reports a missing source specifically.
        let linked = nested.appendingPathComponent("two.txt")
        try fs.copyOrLink(from: file, to: linked)
        XCTAssertEqual(try fs.read(at: linked), Data("replaced".utf8))
        XCTAssertThrowsError(try fs.copyOrLink(from: file, to: linked)) { error in
            XCTAssertEqual(error as? PersistenceError, .alreadyExists(path: linked.path))
        }
        XCTAssertThrowsError(try fs.copyOrLink(from: nested.appendingPathComponent("missing"), to: nested.appendingPathComponent("three"))) { error in
            if case .packageNotFound? = error as? PersistenceError {} else { XCTFail("\(error)") }
        }

        // Listing is sorted, a missing directory lists as empty, moves refuse to overwrite, removes are idempotent.
        XCTAssertEqual(try fs.contentsOfDirectory(at: nested).map(\.lastPathComponent), ["one.txt", "two.txt"])
        XCTAssertEqual(try fs.contentsOfDirectory(at: dir.appendingPathComponent("nope")), [])
        XCTAssertThrowsError(try fs.moveItem(at: file, to: linked))
        try fs.moveItem(at: file, to: nested.appendingPathComponent("moved.txt"))
        XCTAssertFalse(fs.fileExists(at: file))
        try fs.removeItem(at: nested.appendingPathComponent("moved.txt"))
        try fs.removeItem(at: nested.appendingPathComponent("moved.txt"))
        XCTAssertEqual(fs.totalSize(at: dir), 8)
        XCTAssertNotNil(fs.freeSpace(at: dir))

        // A write into a missing directory is a specific error, not a generic one.
        XCTAssertThrowsError(try fs.write(Data(), to: dir.appendingPathComponent("missing/x"))) { error in
            if case .packageNotFound? = error as? PersistenceError {} else { XCTFail("\(error)") }
        }
    }

    func testFaultInjectionNumbersMutatingOperationsAndBlocksAfterCrash() throws {
        let dir = try tempDirectory("Fault")
        let fs = FaultInjectingFileSystem(logsReads: true)
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b"), c = dir.appendingPathComponent("c")
        try fs.write(Data("1".utf8), to: a)          // #0
        fs.failStep(1, with: PersistenceError.diskFull)
        XCTAssertThrowsError(try fs.write(Data("2".utf8), to: b)) { XCTAssertEqual($0 as? PersistenceError, .diskFull) }   // #1 blocked
        XCTAssertFalse(fs.fileExists(at: b))
        try fs.write(Data("2".utf8), to: b)          // #2 applies: a single failure does not persist
        XCTAssertEqual(try fs.read(at: b), Data("2".utf8))
        fs.crash(atStep: 3)
        XCTAssertThrowsError(try fs.write(Data("3".utf8), to: c)) { XCTAssertEqual($0 as? SimulatedCrash, SimulatedCrash(step: 3)) }
        XCTAssertThrowsError(try fs.removeItem(at: a)) { XCTAssertEqual($0 as? SimulatedCrash, SimulatedCrash(step: 4)) }
        XCTAssertTrue(fs.hasCrashed)
        XCTAssertTrue(fs.fileExists(at: a), "nothing is applied after the crash point")
        XCTAssertFalse(fs.fileExists(at: c))
        XCTAssertEqual(fs.mutatingOperations.map(\.mutatingIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(fs.mutatingOperations.map(\.applied), [true, false, true, false, false])
        XCTAssertTrue(fs.log.contains { $0.kind == .read && $0.mutatingIndex == nil }, "reads are logged but never numbered")
        fs.clearFaults()
        try fs.write(Data("3".utf8), to: c)
        XCTAssertTrue(fs.fileExists(at: c))
    }
}
