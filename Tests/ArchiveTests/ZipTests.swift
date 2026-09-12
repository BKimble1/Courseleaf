import Foundation
import XCTest
import DocumentCore
@testable import Archive

final class ZipTests: XCTestCase {
    func testWriterProducesStoredEntriesTheReaderRestoresByteForByte() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("t.zip")
        let payloads: [(String, Data)] = [
            ("a.txt", Data("hello".utf8)),
            ("dir/empty.bin", Data()),
            ("dir/ünïcode ✓.json", Data(repeating: 0x42, count: 5000)),
            ("big/blob", Fixture.pngBytes(seed: 9, length: 3 << 20)),
        ]
        let writer = try ZipWriter(url: url, modificationDate: fixtureDate(0))
        for (name, data) in payloads { try writer.addEntry(name: name, data: data) }
        try writer.finish()

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual([UInt8](bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "starts with a local file header")
        XCTAssertEqual([UInt8](bytes.suffix(22).prefix(4)), [0x50, 0x4B, 0x05, 0x06], "ends with the end-of-central-directory record")
        let expectedSize = payloads.reduce(0) { $0 + 30 + $1.0.utf8.count + $1.1.count } + payloads.reduce(0) { $0 + 46 + $1.0.utf8.count } + 22
        XCTAssertEqual(bytes.count, expectedSize, "stored entries add no compression or extra fields")

        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.map(\.name), payloads.map(\.0))
        for (name, data) in payloads {
            let entry = try XCTUnwrap(reader.entry(named: name))
            XCTAssertEqual(entry.size, UInt64(data.count))
            XCTAssertEqual(entry.crc32, CRC32.checksum(data))
            XCTAssertEqual(try reader.data(for: entry), data)
            // The data really sits where the entry says it does.
            XCTAssertEqual(bytes.subdata(in: Int(entry.dataOffset)..<Int(entry.dataEnd)), data)
        }
        // Deterministic: the same input produces identical bytes.
        let url2 = dir.appendingPathComponent("t2.zip")
        let w2 = try ZipWriter(url: url2, modificationDate: fixtureDate(0))
        for (name, data) in payloads { try w2.addEntry(name: name, data: data) }
        try w2.finish()
        XCTAssertEqual(try Data(contentsOf: url2), bytes)
    }

    func testStreamedFileEntryMatchesInMemoryEntry() throws {
        let dir = try makeTempDir()
        let payload = Fixture.pngBytes(seed: 3, length: (2 << 20) + 12345)
        let src = dir.appendingPathComponent("src.bin")
        try payload.write(to: src)
        let a = dir.appendingPathComponent("a.zip"), b = dir.appendingPathComponent("b.zip")
        let wa = try ZipWriter(url: a, modificationDate: fixtureDate(0)); wa.chunkSize = 4096
        try wa.addEntry(name: "x", fileURL: src); try wa.finish()
        let wb = try ZipWriter(url: b, modificationDate: fixtureDate(0))
        try wb.addEntry(name: "x", data: payload); try wb.finish()
        XCTAssertEqual(try Data(contentsOf: a), try Data(contentsOf: b))
        let reader = try ZipReader(url: a); reader.chunkSize = 1000
        XCTAssertEqual(try reader.data(named: "x"), payload)
    }

    func testWriterRefusesDuplicateAndInvalidNames() throws {
        let dir = try makeTempDir()
        let writer = try ZipWriter(url: dir.appendingPathComponent("d.zip"))
        try writer.addEntry(name: "a", data: Data([1]))
        assertArchiveError(try writer.addEntry(name: "a", data: Data([2])), .duplicateEntry("a"))
        assertArchiveError(try writer.addEntry(name: "../a", data: Data()), .pathTraversal("../a"))
        assertArchiveError(try writer.addEntry(name: "/a", data: Data()), .pathTraversal("/a"))
        assertArchiveError(try writer.addEntry(name: "a\\b", data: Data()), .pathTraversal("a\\b"))
        assertArchiveError(try writer.addEntry(name: "", data: Data()), .invalidPath(""))
        try writer.addEntry(name: "b", data: Data([3]))
        try writer.finish()
        XCTAssertEqual(try ZipReader(url: dir.appendingPathComponent("d.zip")).entries.map(\.name), ["a", "b"])
    }

    func testReaderRejectsTruncatedFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("t.zip")
        let w = try ZipWriter(url: url); try w.addEntry(name: "a", data: Data(repeating: 7, count: 100)); try w.finish()
        let full = try Data(contentsOf: url)
        for cut in [1, 10, 21, 60, full.count - 20] {
            try full.prefix(full.count - cut).write(to: url)
            assertArchiveError(try ZipReader(url: url)) { if case .corruptZip = $0 { return true } else { return false } }
        }
        try Data().write(to: url)
        assertArchiveError(try ZipReader(url: url)) { if case .corruptZip = $0 { return true } else { return false } }
    }

    func testReaderRejectsOverlappingEntries() throws {
        // Entry "b"'s local header and data are embedded inside entry "a"'s data.
        let bData = Data("inner".utf8)
        let bLocal = RawZip.localHeader(name: "b", data: bData, crc: CRC32.checksum(bData)) + [UInt8](bData)
        let aData = Data(bLocal + [UInt8]("tail".utf8))
        let aLocal = RawZip.localHeader(name: "a", data: aData, crc: CRC32.checksum(aData)) + [UInt8](aData)
        var central: [UInt8] = []
        central += RawZip.centralHeader(name: "a", size: UInt32(aData.count), crc: CRC32.checksum(aData), offset: 0)
        central += RawZip.centralHeader(name: "b", size: UInt32(bData.count), crc: CRC32.checksum(bData), offset: UInt32(30 + 1))
        let bytes = Data(aLocal + central + RawZip.eocd(entryCount: 2, cdSize: UInt32(central.count), cdOffset: UInt32(aLocal.count)))
        let url = try makeTempDir().appendingPathComponent("overlap.zip")
        try bytes.write(to: url)
        assertArchiveError(try ZipReader(url: url)) { if case .corruptZip(let r) = $0 { return r.contains("overlap") } else { return false } }
    }

    func testReaderRejectsLocalHeaderDisagreeingWithCentralDirectory() throws {
        let url = try makeTempDir().appendingPathComponent("mismatch.zip")
        let data = Data("payload".utf8)
        try RawZip.build([RawZip.Entry(name: "a", data: data, localCRC: CRC32.checksum(data) ^ 1)]).write(to: url)
        assertArchiveError(try ZipReader(url: url)) { if case .corruptZip(let r) = $0 { return r.contains("disagrees") } else { return false } }
    }

    func testReaderRejectsOutOfBoundsLocalHeaderOffset() throws {
        let url = try makeTempDir().appendingPathComponent("oob.zip")
        try RawZip.build([RawZip.Entry(name: "a", data: Data("payload".utf8), localOffset: 0xFFFF_0000)]).write(to: url)
        assertArchiveError(try ZipReader(url: url)) { if case .corruptZip = $0 { return true } else { return false } }
    }

    func testReaderRejectsDuplicateNamesInCentralDirectory() throws {
        let url = try makeTempDir().appendingPathComponent("dup.zip")
        try RawZip.build([RawZip.Entry(name: "a", data: Data([1])), RawZip.Entry(name: "a", data: Data([2]))]).write(to: url)
        assertArchiveError(try ZipReader(url: url), .duplicateEntry("a"))
    }

    func testReaderRejectsCompressedEntries() throws {
        let url = try makeTempDir().appendingPathComponent("deflate.zip")
        try RawZip.build([RawZip.Entry(name: "a", data: Data([1, 2, 3]), method: 8)]).write(to: url)
        assertArchiveError(try ZipReader(url: url)) { if case .corruptZip(let r) = $0 { return r.contains("compressed") } else { return false } }
    }

    func testReaderRejectsZip64Markers() throws {
        let url = try makeTempDir().appendingPathComponent("z64.zip")
        try RawZip.build([RawZip.Entry(name: "a", data: Data([1]))], entryCountOverride: 0xFFFF).write(to: url)
        assertArchiveError(try ZipReader(url: url), .zip64Unsupported)
    }

    func testReaderDetectsCorruptedEntryDataThroughCRC() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("c.zip")
        let w = try ZipWriter(url: url)
        try w.addEntry(name: "a", data: Data(repeating: 0x11, count: 4000)); try w.addEntry(name: "b", data: Data([9])); try w.finish()
        let entry = try XCTUnwrap(ZipReader(url: url).entry(named: "a"))
        var bytes = try Data(contentsOf: url)
        bytes[Int(entry.dataOffset) + 2500] ^= 0xFF
        try bytes.write(to: url)
        let reader = try ZipReader(url: url)  // structure is still fine
        assertArchiveError(try reader.data(named: "a"), .checksumMismatch("a"))
        XCTAssertEqual(try reader.data(named: "b"), Data([9]))
    }
}
