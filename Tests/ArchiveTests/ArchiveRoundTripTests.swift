import Foundation
import XCTest
import DocumentCore
@testable import Archive

final class ArchiveRoundTripTests: XCTestCase {
    func testDocumentRoundTripRestoresAnEqualSnapshotAndAssets() throws {
        let fixture = Fixture.make()
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("physics.courseleaf")
        let written = try writeFixtureArchive(fixture, to: url, includeHistory: true)

        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.inventory.kind, .document)
        XCTAssertEqual(reader.inventory.formatVersion, DocumentSchema.current)
        XCTAssertEqual(reader.inventory.documentIDs, [fixture.snapshot.document.id])
        XCTAssertEqual(reader.inventory.documents.first?.title, "Physics 101")
        XCTAssertEqual(reader.inventory.documents.first?.pageCount, 3)
        XCTAssertEqual(reader.inventory.producer, "Courseleaf Tests 1.0 (1)")
        XCTAssertEqual(reader.inventory.createdAt, fixtureDate(1000))
        XCTAssertEqual(reader.inventory.totalSize, written.totalSize)
        XCTAssertEqual(reader.inventory.archiveByteCount, Int(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64))
        XCTAssertNil(reader.library())

        let (snapshot, assetData) = try reader.document(fixture.snapshot.document.id)
        XCTAssertEqual(snapshot, fixture.snapshot)
        XCTAssertEqual(snapshot.validate(), [])
        for asset in snapshot.assets.values {
            XCTAssertEqual(try assetData(asset), fixture.assetBytes[asset.id])
        }
        // Ink survives byte-for-byte and decodes with the engine that produced it.
        let inkAsset = snapshot.pages[fixture.snapshot.document.pageIDs[0]]!.inkLayers[0].dataAssetID!
        let drawing = try ReferenceInkEngine().decode(try assetData(snapshot.assets[inkAsset]!))
        XCTAssertEqual(drawing.strokeCount, 5)
        XCTAssertNotNil(drawing.strokes[0].mask)
        let unknown = DocumentID()
        assertArchiveError(try reader.document(unknown), .documentNotFound(unknown))
    }

    func testArchiveJSONDescribesEveryEntryWithSizeAndDigest() throws {
        let fixture = Fixture.make()
        let url = try makeTempDir().appendingPathComponent("a.courseleaf")
        try writeFixtureArchive(fixture, to: url, includeHistory: true)
        let entries = try ArchiveRewriter.entries(of: url)
        XCTAssertEqual(entries.last?.name, "archive.json", "archive.json is written last")
        let manifest = try DocumentJSON.decoder().decode(ArchiveManifest.self, from: entries.last!.data)
        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.kind, .document)
        let listed = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
        XCTAssertEqual(Set(listed.keys), Set(entries.dropLast().map(\.name)))
        for e in entries.dropLast() {
            XCTAssertEqual(listed[e.name]?.size, e.data.count)
            XCTAssertEqual(listed[e.name]?.sha256, SHA256.hexDigest(e.data))
        }
        XCTAssertEqual(manifest.totalSize, entries.dropLast().reduce(0) { $0 + $1.data.count })
        let dir = "documents/\(fixture.snapshot.document.id)"
        XCTAssertTrue(listed.keys.contains(dir + "/manifest.json"))
        for asset in fixture.snapshot.assets.values { XCTAssertTrue(listed.keys.contains(dir + "/" + asset.relativePath), asset.relativePath) }
        for page in fixture.snapshot.pages.values { XCTAssertTrue(listed.keys.contains(dir + "/pages/\(page.id)-\(page.revisionID).json")) }
        for rev in fixture.snapshot.revisions.keys { XCTAssertTrue(listed.keys.contains(dir + "/revisions/\(rev).json")) }
        // The raw JSON uses the documented keys.
        let text = String(decoding: entries.last!.data, as: UTF8.self)
        for key in ["\"formatVersion\"", "\"kind\"", "\"createdAt\"", "\"producer\"", "\"entries\"", "\"totalSize\"", "\"path\"", "\"sha256\""] {
            XCTAssertTrue(text.contains(key), key)
        }
        let docManifestText = String(decoding: entries.first { $0.name == dir + "/manifest.json" }!.data, as: UTF8.self)
        for key in ["\"formatVersion\"", "\"document\"", "\"pageFiles\"", "\"assets\"", "\"committedAt\"", "\"file\""] {
            XCTAssertTrue(docManifestText.contains(key), key)
        }
    }

    func testHeadOnlyExportKeepsJustTheHeadRevision() throws {
        let fixture = Fixture.make()
        let url = try makeTempDir().appendingPathComponent("h.courseleaf")
        try writeFixtureArchive(fixture, to: url, includeHistory: false)
        let (snapshot, _) = try ArchiveReader.open(url: url).document(fixture.snapshot.document.id)
        XCTAssertEqual(Array(snapshot.revisions.keys), [fixture.snapshot.document.revisionHead])
        var expected = fixture.snapshot
        expected.revisions = [expected.document.revisionHead: expected.revisions[expected.document.revisionHead]!]
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(snapshot.validate(), [])
    }

    func testRestoreAsCopyIsEqualModuloIdentifiers() throws {
        let fixture = Fixture.make()
        let url = try makeTempDir().appendingPathComponent("c.courseleaf")
        try writeFixtureArchive(fixture, to: url, includeHistory: true)
        let (restored, _) = try ArchiveReader.open(url: url).document(fixture.snapshot.document.id)
        let copy = SnapshotReidentifier.copy(restored)
        XCTAssertEqual(copy.validate(), [])
        XCTAssertNotEqual(copy.document.id, restored.document.id)
        XCTAssertEqual(copy.assets, restored.assets, "assets are content-addressed and keep their ids")

        // No identifier survives, and references were remapped consistently.
        let original = restored
        XCTAssertTrue(Set(copy.pages.keys).isDisjoint(with: original.pages.keys))
        XCTAssertTrue(Set(copy.revisions.keys).isDisjoint(with: original.revisions.keys))
        XCTAssertEqual(copy.document.pageIDs.count, original.document.pageIDs.count)
        XCTAssertEqual(copy.orderedPages.map(\.size), original.orderedPages.map(\.size))
        let objIDs = { (s: DocumentSnapshot) in Set(s.pages.values.flatMap { $0.objects.map(\.id) }) }
        XCTAssertTrue(objIDs(copy).isDisjoint(with: objIDs(original)))
        let layerIDs = { (s: DocumentSnapshot) in Set(s.pages.values.flatMap { $0.inkLayers.map(\.id) }) }
        XCTAssertTrue(layerIDs(copy).isDisjoint(with: layerIDs(original)))
        XCTAssertTrue(Set(copy.document.reviewItems.map(\.id)).isDisjoint(with: original.document.reviewItems.map(\.id)))
        XCTAssertEqual(copy.document.deletedPages.count, 1)
        XCTAssertNotEqual(copy.document.deletedPages[0].id, original.document.deletedPages[0].id)
        XCTAssertNotNil(copy.pages[copy.document.deletedPages[0].id], "deleted page content moved with its new id")
        XCTAssertEqual(copy.document.reviewItems[1].pageID, copy.document.deletedPages[0].id)
        let tape = copy.pages[copy.document.pageIDs[0]]!.objects.first { $0.kind == .tape }!
        XCTAssertEqual(copy.document.reviewItems[0].answerTapeID, tape.id)
        XCTAssertEqual(copy.document.reviewItems[0].pageID, copy.document.pageIDs[0])
        XCTAssertNotNil(copy.revisions[copy.document.revisionHead])
        XCTAssertEqual(copy.revisions[copy.document.revisionHead]!.parentIDs.compactMap { copy.revisions[$0] }.count, 1)
        for page in copy.pages.values { XCTAssertNotNil(copy.revisions[page.revisionID]) }
        XCTAssertEqual(Set(copy.revisions[copy.document.revisionHead]!.changedPageIDs), [copy.document.pageIDs[0], copy.document.pageIDs[2]])

        // Structural equality modulo IDs: re-identifying both with the same seeded generator yields identical values.
        let fixedID = DocumentID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000AAAA")!)
        let a = SeededUUIDs(seed: 42), b = SeededUUIDs(seed: 42)
        XCTAssertEqual(SnapshotReidentifier.copy(original, newDocumentID: fixedID, makeUUID: a.next),
                       SnapshotReidentifier.copy(copy, newDocumentID: fixedID, makeUUID: b.next))
        // And the copy really differs from the original beyond IDs only: same page content.
        XCTAssertEqual(copy.orderedPages.map { $0.objects.map(\.content) }, original.orderedPages.map { $0.objects.map(\.content) })
        XCTAssertEqual(copy.orderedPages.map(\.problem), original.orderedPages.map(\.problem))
        XCTAssertEqual(copy.orderedPages.map(\.isBookmarked), original.orderedPages.map(\.isBookmarked))
    }

    func testLibraryArchiveWithSeveralDocumentsRoundTrips() throws {
        let f1 = Fixture.make(title: "Physics", seed: 1), f2 = Fixture.make(title: "Chemistry", seed: 2)
        var plain = DocumentSnapshot.newNotebook(title: "Quick", pageCount: 2, kind: .quickNote, now: fixtureDate(3))
        plain.document.lastViewedPageIndex = 1
        let course = Folder(name: "Fall", isCourse: true, color: .moss, createdAt: fixtureDate(1))
        let library = LibraryManifest(folders: [course, Folder(name: "Week 1", parentID: course.id, createdAt: fixtureDate(2), sortIndex: 1)],
                                      trash: [TrashEntry(item: .document(DocumentID()), title: "Old", originalFolderID: course.id, deletedAt: fixtureDate(4))],
                                      modifiedAt: fixtureDate(5))
        let url = try makeTempDir().appendingPathComponent("backup.courseleaf")
        var fetchOrder: [DocumentID] = []
        let inputs = [f1, f2].map { f in
            LibraryArchiveWriter.DocumentInput(snapshot: f.snapshot) { asset in fetchOrder.append(f.snapshot.document.id); return try f.provider(asset) }
        } + [LibraryArchiveWriter.DocumentInput(snapshot: plain) { _ in XCTFail("no assets"); return Data() }]
        let manifest = try LibraryArchiveWriter.write(library: library, documents: inputs, includeHistory: true, to: url,
                                                      producer: "Courseleaf Tests 1.0 (1)", clock: ManualClock(start: fixtureDate(9)))
        XCTAssertEqual(manifest.kind, .library)
        // Documents are written sequentially: every asset of the first document precedes the second's.
        let firstIndex = fetchOrder.lastIndex(of: f1.snapshot.document.id)!, secondIndex = fetchOrder.firstIndex(of: f2.snapshot.document.id)!
        XCTAssertLessThan(firstIndex, secondIndex)

        let reader = try ArchiveReader.open(url: url)
        XCTAssertEqual(reader.inventory.kind, .library)
        XCTAssertTrue(reader.inventory.hasLibraryManifest)
        XCTAssertEqual(reader.inventory.documentIDs, [f1.snapshot.document.id, f2.snapshot.document.id, plain.document.id].sorted())
        XCTAssertEqual(reader.library(), library)
        for f in [f1, f2] {
            let (s, assetData) = try reader.document(f.snapshot.document.id)
            XCTAssertEqual(s, f.snapshot)
            for a in s.assets.values { XCTAssertEqual(try assetData(a), f.assetBytes[a.id]) }
        }
        XCTAssertEqual(try reader.document(plain.document.id).snapshot, plain)
        XCTAssertEqual(reader.inventory.documents.map(\.title), reader.inventory.documentIDs.map { id in
            [f1.snapshot, f2.snapshot, plain].first { $0.document.id == id }!.document.title })
    }

    func testLibraryWriterRefusesDuplicateDocumentsAndLeavesNoFile() throws {
        let f = Fixture.make()
        let url = try makeTempDir().appendingPathComponent("dup.courseleaf")
        let inputs = [LibraryArchiveWriter.DocumentInput(snapshot: f.snapshot, assetData: f.provider),
                      LibraryArchiveWriter.DocumentInput(snapshot: f.snapshot, assetData: f.provider)]
        assertArchiveError(try LibraryArchiveWriter.write(library: LibraryManifest(modifiedAt: fixtureDate(0)), documents: inputs, to: url, producer: "t"),
                           .duplicateEntry("documents/\(f.snapshot.document.id)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriterRefusesInvalidSnapshotAndRemovesPartialFile() throws {
        var f = Fixture.make()
        f.snapshot.document.pageIDs.append(PageID())  // listed page without content
        let url = try makeTempDir().appendingPathComponent("bad.courseleaf")
        assertArchiveError(try writeFixtureArchive(f, to: url)) { if case .invalidDocument = $0 { return true } else { return false } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriterRefusesAssetBytesThatDoNotMatchTheRecord() throws {
        let f = Fixture.make()
        let url = try makeTempDir().appendingPathComponent("bad.courseleaf")
        let wrongAsset = f.snapshot.assets.values.sorted { $0.id < $1.id }[0]
        let provider: AssetDataProvider = { asset in
            var d = try f.provider(asset)
            if asset.id == wrongAsset.id { d[0] ^= 0x01 }
            return d
        }
        assertArchiveError(try DocumentArchiveWriter.write(snapshot: f.snapshot, assetData: provider, to: url, producer: "t"),
                           .checksumMismatch("documents/\(f.snapshot.document.id)/" + wrongAsset.relativePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testArchivePathRules() {
        for ok in ["a", "a/b.json", "documents/x/assets/ab/abc.png", "ünï ✓/file", "a.b/c"] {
            XCTAssertNoThrow(try ArchivePath.validate(ok), ok)
        }
        for traversal in ["../x", "a/../b", "..", "/abs", "/", "C:file", "c:/x", "a\\b", "\\\\server\\share", "a\u{0}b", "\u{0}"] {
            assertArchiveError(try ArchivePath.validate(traversal), .pathTraversal(traversal))
        }
        for invalid in ["", ".", "./a", "a/./b", "a//b", "a/", "a\u{1}b", "a\u{7F}", "a\nb", " a", "a/ b", "a /b"] {
            assertArchiveError(try ArchivePath.validate(invalid), .invalidPath(invalid))
        }
        assertArchiveError(try ArchivePath.validate("a/b", listedIn: ["a/c"]), .unlistedEntry("a/b"))
        XCTAssertNoThrow(try ArchivePath.validate("a/b", listedIn: ["a/b"]))
    }
}
