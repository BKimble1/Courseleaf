import Foundation
import XCTest
import DocumentCore
@testable import Archive

/// Every rejection rule of docs/FORMAT.md section 4, one hand-built archive each.
final class ArchiveRejectionTests: XCTestCase {
    private var fixture = Fixture.make()
    private var dir: URL!
    private var url: URL!
    private var docDir: String { "documents/\(fixture.snapshot.document.id)" }

    override func setUpWithError() throws {
        dir = try makeTempDir()
        url = dir.appendingPathComponent("suspect.courseleaf")
        try writeFixtureArchive(fixture, to: url, includeHistory: true)
        XCTAssertNoThrow(try ArchiveReader.open(url: url), "fixture archive must be valid before it is corrupted")
    }

    private func assertOpenFails(_ expected: ArchiveError, limits: ArchiveLimits = .default, file: StaticString = #filePath, line: UInt = #line) {
        assertArchiveError(try ArchiveReader.open(url: url, limits: limits), expected, file: file, line: line)
    }

    private func assertOpenFails(limits: ArchiveLimits = .default, file: StaticString = #filePath, line: UInt = #line, _ matches: (ArchiveError) -> Bool) {
        assertArchiveError(try ArchiveReader.open(url: url, limits: limits), file: file, line: line, matches)
    }

    private func writeRaw(_ entries: [RawZip.Entry], listed: Bool = true) throws {
        try RawZip.archive(with: entries, listed: listed).write(to: url)
    }

    // MARK: Paths

    func testRejectsParentDirectoryTraversal() throws {
        try writeRaw([RawZip.Entry(name: "../x", data: Data("evil".utf8))])
        assertOpenFails(.pathTraversal("../x"))
    }

    func testRejectsNestedParentDirectoryTraversal() throws {
        try writeRaw([RawZip.Entry(name: "\(docDir)/../../x", data: Data("evil".utf8))])
        assertOpenFails(.pathTraversal("\(docDir)/../../x"))
    }

    func testRejectsAbsolutePath() throws {
        try writeRaw([RawZip.Entry(name: "/etc/passwd", data: Data("root".utf8))])
        assertOpenFails(.pathTraversal("/etc/passwd"))
    }

    func testRejectsDriveLetterPath() throws {
        try writeRaw([RawZip.Entry(name: "C:Windows/x", data: Data("x".utf8))])
        assertOpenFails(.pathTraversal("C:Windows/x"))
    }

    func testRejectsBackslashPath() throws {
        try writeRaw([RawZip.Entry(name: "documents\\..\\x", data: Data("x".utf8))])
        assertOpenFails(.pathTraversal("documents\\..\\x"))
    }

    func testRejectsNULInPath() throws {
        let name = "\(docDir)/manifest.json\u{0}.png"
        try writeRaw([RawZip.Entry(name: name, data: Data("x".utf8))])
        assertOpenFails(.pathTraversal(name))
    }

    func testRejectsControlCharacterInPath() throws {
        let name = "\(docDir)/pages/a\u{1B}[2Jb.json"
        try writeRaw([RawZip.Entry(name: name, data: Data("x".utf8))])
        assertOpenFails(.invalidPath(name))
    }

    func testRejectsTraversalListedOnlyInManifest() throws {
        // A well-formed ZIP whose archive.json advertises a traversal path.
        try ArchiveRewriter.replaceManifest(at: url) { m in
            m.entries.append(ArchiveEntryRecord(path: "../x", size: 0, sha256: String(repeating: "0", count: 64)))
        }
        assertOpenFails(.pathTraversal("../x"))
    }

    // MARK: Listing and sizes

    func testRejectsUnlistedEntry() throws {
        try ArchiveRewriter.rewrite(url, regenerateManifest: false) { list in
            list.insert(("\(self.docDir)/pages/extra.json", Data("{}".utf8)), at: 0)
        }
        assertOpenFails(.unlistedEntry("\(docDir)/pages/extra.json"))
    }

    func testRejectsEntryListedButMissingFromZip() throws {
        try ArchiveRewriter.replaceManifest(at: url) { m in
            m.entries.append(ArchiveEntryRecord(path: "\(self.docDir)/pages/ghost.json", size: 0, sha256: SHA256.hexDigest(Data())))
        }
        assertOpenFails(.missingEntry("\(docDir)/pages/ghost.json"))
    }

    func testRejectsDeclaredSizeMismatch() throws {
        let path = docDir + "/manifest.json"
        try ArchiveRewriter.replaceManifest(at: url) { m in
            let i = m.entries.firstIndex { $0.path == path }!
            m.entries[i].size += 1
            m.totalSize += 1
        }
        assertOpenFails(.sizeMismatch(path))
    }

    func testRejectsTotalSizeNotMatchingEntrySizes() throws {
        try ArchiveRewriter.replaceManifest(at: url) { m in m.totalSize += 7 }
        assertOpenFails(.sizeMismatch("archive.json"))
    }

    func testRejectsExpansionRatioBomb() throws {
        // A tiny file whose manifest claims many megabytes of content: within the
        // total limit, but far above 200x the archive's own size.
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64
        try ArchiveRewriter.replaceManifest(at: url) { m in
            for i in m.entries.indices { m.entries[i].size = 2_000_000 }
            m.totalSize = m.entries.reduce(0) { $0 + $1.size }
            XCTAssertLessThan(m.totalSize, ArchiveLimits.default.totalBytes)
            XCTAssertGreaterThan(Double(m.totalSize) / Double(fileSize), ArchiveLimits.default.expansionRatio)
        }
        assertOpenFails(.expansionRatioExceeded)
    }

    func testRejectsExpansionRatioBombWithManyEntries() throws {
        // Dozens of entries each declared just under the single-entry limit.
        var entries: [RawZip.Entry] = []
        for i in 0..<40 { entries.append(RawZip.Entry(name: "\(docDir)/pages/p\(i).json", data: Data("{\"n\":\(i)}".utf8))) }
        let manifest = ArchiveManifest(kind: .document, createdAt: fixtureDate(0), producer: "t",
                                       entries: entries.map { ArchiveEntryRecord(path: $0.name, size: 100 << 20, sha256: SHA256.hexDigest($0.data)) })
        XCTAssertEqual(manifest.totalSize, manifest.entries.reduce(0) { $0 + $1.size })
        XCTAssertLessThan(manifest.totalSize, ArchiveLimits.default.totalBytes)
        let data = RawZip.build(entries + [RawZip.Entry(name: "archive.json", data: try DocumentJSON.encoder().encode(manifest))])
        try data.write(to: url)
        assertOpenFails(.expansionRatioExceeded)
    }

    func testRejectsTotalSizeOverLimit() throws {
        let limits = ArchiveLimits(totalBytes: 1000)
        assertOpenFails(.totalSizeExceeded, limits: limits)
    }

    func testRejectsDeclaredTotalSizeOverLimitEvenWhenZipIsSmall() throws {
        try ArchiveRewriter.replaceManifest(at: url) { m in
            m.entries[0].size = ArchiveLimits.default.totalBytes
            m.totalSize = m.entries.reduce(0) { $0 + $1.size }
        }
        assertOpenFails(.totalSizeExceeded)
    }

    func testRejectsEntryOverSingleEntryLimit() throws {
        let biggest = try ArchiveRewriter.manifest(of: url).entries.max { $0.size < $1.size }!
        assertOpenFails(.entryTooLarge(biggest.path), limits: ArchiveLimits(maxEntryBytes: biggest.size - 1))
    }

    func testRejectsTooManyEntriesWithCustomLimit() throws {
        assertOpenFails(.tooManyEntries, limits: ArchiveLimits(maxEntries: 4))
    }

    func testRejectsTooManyEntriesWithDefaultLimit() throws {
        // 50 001 tiny entries: refused by count before any entry is hashed.
        let writer = try ZipWriter(url: url, modificationDate: fixtureDate(0))
        var records: [ArchiveEntryRecord] = []
        let payload = Data("x".utf8), sha = SHA256.hexDigest(payload)
        for i in 0...ArchiveLimits.default.maxEntries {
            let name = "\(docDir)/pages/\(i).json"
            try writer.addEntry(name: name, data: payload)
            records.append(ArchiveEntryRecord(path: name, size: 1, sha256: sha))
        }
        let manifest = ArchiveManifest(kind: .document, createdAt: fixtureDate(0), producer: "t", entries: records)
        try writer.addEntry(name: "archive.json", data: try DocumentJSON.encoder().encode(manifest))
        try writer.finish()
        assertOpenFails(.tooManyEntries)
    }

    // MARK: Integrity

    func testRejectsCRCMismatch() throws {
        let path = docDir + "/manifest.json"
        let entry = try XCTUnwrap(ZipReader(url: url).entry(named: path))
        var bytes = try Data(contentsOf: url)
        bytes[Int(entry.dataOffset) + 5] ^= 0x20   // flips one byte of the document manifest
        try bytes.write(to: url)
        assertOpenFails(.checksumMismatch(path))
    }

    func testRejectsSHA256MismatchInArchiveManifest() throws {
        let path = docDir + "/manifest.json"
        try ArchiveRewriter.replaceManifest(at: url) { m in
            let i = m.entries.firstIndex { $0.path == path }!
            m.entries[i].sha256 = String(m.entries[i].sha256.reversed())
        }
        assertOpenFails(.checksumMismatch(path))
    }

    func testRejectsAssetWhoseNameIsNotItsContentDigest() throws {
        let asset = fixture.snapshot.assets.values.first { $0.mediaType == .png }!
        let path = docDir + "/" + asset.relativePath
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in
            let i = list.firstIndex { $0.name == path }!
            var d = list[i].data; d[d.count - 1] ^= 0xFF   // same length, different digest; archive.json is regenerated to match
            list[i].data = d
        }
        assertOpenFails(.assetNameMismatch(path))
    }

    func testRejectsAssetInWrongShardDirectory() throws {
        let asset = fixture.snapshot.assets.values.first { $0.mediaType == .pdf }!
        let path = docDir + "/" + asset.relativePath
        let wrong = docDir + "/assets/zz/\(asset.sha256).pdf"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in
            let i = list.firstIndex { $0.name == path }!
            list[i].name = wrong
        }
        assertOpenFails(.assetNameMismatch(wrong))
    }

    // MARK: Schema and documents

    func testRejectsUnsupportedArchiveFormatVersion() throws {
        try ArchiveRewriter.replaceManifest(at: url) { m in m.formatVersion = 99 }
        assertOpenFails(.unsupportedSchema(99))
    }

    func testRejectsUnsupportedDocumentManifestFormatVersion() throws {
        let path = docDir + "/manifest.json"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in
            let i = list.firstIndex { $0.name == path }!
            var m = try DocumentJSON.decoder().decode(ArchivedDocumentManifest.self, from: list[i].data)
            m.formatVersion = 99
            list[i].data = try DocumentJSON.encoder().encode(m)
        }
        assertOpenFails(.unsupportedSchema(99))
    }

    func testRejectsUndecodableArchiveManifest() throws {
        try ArchiveRewriter.rewrite(url, regenerateManifest: false) { list in
            let i = list.firstIndex { $0.name == "archive.json" }!
            list[i].data = Data("{\"formatVersion\": 1, \"kind\": \"picnic\"}".utf8)
        }
        assertOpenFails { if case .invalidManifest = $0 { return true } else { return false } }
    }

    func testRejectsMissingArchiveManifest() throws {
        try ArchiveRewriter.rewrite(url, regenerateManifest: false) { list in list.removeAll { $0.name == "archive.json" } }
        assertOpenFails(.missingEntry("archive.json"))
    }

    func testRejectsTruncatedFile() throws {
        let full = try Data(contentsOf: url)
        try full.prefix(full.count - 40).write(to: url)
        assertOpenFails { if case .corruptZip = $0 { return true } else { return false } }
        try full.prefix(full.count / 2).write(to: url)
        assertOpenFails { if case .corruptZip = $0 { return true } else { return false } }
    }

    func testRejectsOverlappingLocalHeaders() throws {
        let inner = Data("{}".utf8)
        let innerName = docDir + "/pages/b.json"
        let outerName = docDir + "/pages/a.json"
        let innerLocal = RawZip.localHeader(name: innerName, data: inner, crc: CRC32.checksum(inner)) + [UInt8](inner)
        let outer = Data(innerLocal + [UInt8]("tail".utf8))
        let outerLocal = RawZip.localHeader(name: outerName, data: outer, crc: CRC32.checksum(outer)) + [UInt8](outer)
        let manifest = try ArchiveRewriter.manifestData(listing: [(outerName, outer), (innerName, inner)])
        let manifestLocal = RawZip.localHeader(name: "archive.json", data: manifest, crc: CRC32.checksum(manifest)) + [UInt8](manifest)
        var central: [UInt8] = []
        central += RawZip.centralHeader(name: outerName, size: UInt32(outer.count), crc: CRC32.checksum(outer), offset: 0)
        central += RawZip.centralHeader(name: innerName, size: UInt32(inner.count), crc: CRC32.checksum(inner), offset: UInt32(30 + outerName.utf8.count))
        central += RawZip.centralHeader(name: "archive.json", size: UInt32(manifest.count), crc: CRC32.checksum(manifest), offset: UInt32(outerLocal.count))
        let body = outerLocal + manifestLocal
        try Data(body + central + RawZip.eocd(entryCount: 3, cdSize: UInt32(central.count), cdOffset: UInt32(body.count))).write(to: url)
        assertOpenFails { if case .corruptZip(let r) = $0 { return r.contains("overlap") } else { return false } }
    }

    func testRejectsMissingAssetReferencedByAPage() throws {
        let asset = fixture.snapshot.assets.values.first { $0.mediaType == .png }!
        let path = docDir + "/" + asset.relativePath
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in list.removeAll { $0.name == path } }
        assertOpenFails(.missingEntry(path))
    }

    func testRejectsMissingPageFile() throws {
        let pageID = fixture.snapshot.document.pageIDs[1]
        let path = docDir + "/pages/\(pageID)-\(fixture.snapshot.pages[pageID]!.revisionID).json"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in list.removeAll { $0.name == path } }
        assertOpenFails(.missingEntry(path))
    }

    func testRejectsMissingHeadRevision() throws {
        let path = docDir + "/revisions/\(fixture.snapshot.document.revisionHead).json"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in list.removeAll { $0.name == path } }
        assertOpenFails(.missingEntry(path))
    }

    func testRejectsUnexpectedFileInsideDocumentDirectory() throws {
        let path = docDir + "/notes.txt"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in list.append((path, Data("hi".utf8))) }
        assertOpenFails(.unexpectedEntry(path))
    }

    func testRejectsFileOutsideDocumentedLayout() throws {
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in list.append(("README.txt", Data("hi".utf8))) }
        assertOpenFails(.unexpectedEntry("README.txt"))
    }

    func testRejectsLibraryJSONInDocumentArchive() throws {
        let lib = try DocumentJSON.encoder().encode(LibraryManifest(modifiedAt: fixtureDate(0)))
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in list.append(("library.json", lib)) }
        assertOpenFails(.unexpectedEntry("library.json"))
    }

    func testRejectsLibraryArchiveWithoutLibraryJSON() throws {
        try ArchiveRewriter.replaceManifest(at: url) { m in m.kind = .library }
        assertOpenFails(.missingEntry("library.json"))
    }

    func testRejectsDocumentThatFailsSnapshotValidation() throws {
        let path = docDir + "/manifest.json"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in
            let i = list.firstIndex { $0.name == path }!
            var m = try DocumentJSON.decoder().decode(ArchivedDocumentManifest.self, from: list[i].data)
            m.document.reviewItems.append(ReviewItem(pageID: PageID(), createdAt: fixtureDate(0)))
            list[i].data = try DocumentJSON.encoder().encode(m)
        }
        assertOpenFails { if case .invalidDocument(let issues) = $0 { return issues.contains { $0.contains("review item") } } else { return false } }
    }

    func testRejectsUndecodablePageFile() throws {
        let pageID = fixture.snapshot.document.pageIDs[0]
        let path = docDir + "/pages/\(pageID)-\(fixture.snapshot.pages[pageID]!.revisionID).json"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in
            let i = list.firstIndex { $0.name == path }!
            list[i].data = Data("{\"id\": \"not a uuid\"}".utf8)
            // Keep the document manifest's recorded page digest consistent so only the decode fails.
            let mi = list.firstIndex { $0.name == self.docDir + "/manifest.json" }!
            var m = try DocumentJSON.decoder().decode(ArchivedDocumentManifest.self, from: list[mi].data)
            m.pageFiles[pageID.description]!.sha256 = SHA256.hexDigest(list[i].data)
            list[mi].data = try DocumentJSON.encoder().encode(m)
        }
        assertOpenFails { if case .invalidDocument(let issues) = $0 { return issues.first?.hasPrefix(path) == true } else { return false } }
    }

    func testRejectsDocumentDirectoryNotMatchingDocumentID() throws {
        let other = "documents/\(DocumentID())"
        try ArchiveRewriter.rewrite(url, regenerateManifest: true) { list in
            for i in list.indices where list[i].name.hasPrefix(self.docDir + "/") {
                list[i].name = other + list[i].name.dropFirst(self.docDir.count)
            }
        }
        assertOpenFails { if case .invalidDocument(let issues) = $0 { return issues.first?.contains("does not match its directory") == true } else { return false } }
    }

    // MARK: Read-only guarantee

    func testOpeningABadArchiveLeavesTheDirectoryUntouched() throws {
        // Corrupt the archive and surround it with sibling files.
        try ArchiveRewriter.replaceManifest(at: url) { m in m.entries[0].sha256 = String(m.entries[0].sha256.reversed()) }
        let sibling = dir.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: sibling)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Documents"), withIntermediateDirectories: true)

        func snapshotDirectory() throws -> [String: (size: UInt64, modified: Date, sha: String)] {
            var out: [String: (UInt64, Date, String)] = [:]
            let items = try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted()
            for item in items {
                let p = dir.appendingPathComponent(item)
                let attrs = try FileManager.default.attributesOfItem(atPath: p.path)
                let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
                let sha = isDir ? "dir" : SHA256.hexDigest(try Data(contentsOf: p))
                out[item] = (attrs[.size] as? UInt64 ?? 0, attrs[.modificationDate] as? Date ?? .distantPast, sha)
            }
            return out
        }
        let before = try snapshotDirectory()
        XCTAssertEqual(Set(before.keys), ["suspect.courseleaf", "notes.txt", "Documents"])

        assertOpenFails { if case .checksumMismatch = $0 { return true } else { return false } }
        // A second attempt with a different failure mode (limits) must also be read-only.
        assertOpenFails(.tooManyEntries, limits: ArchiveLimits(maxEntries: 2))

        let after = try snapshotDirectory()
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        for (k, v) in before {
            XCTAssertEqual(after[k]?.size, v.size, k)
            XCTAssertEqual(after[k]?.sha, v.sha, k)
            XCTAssertEqual(after[k]?.modified, v.modified, k)
        }
        // And the temporary directory tree gained nothing anywhere else under it either.
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: dir.path).count, 3)
    }
}
