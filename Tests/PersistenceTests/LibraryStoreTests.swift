import XCTest
import DocumentCore
@testable import Persistence

final class LibraryStoreTests: XCTestCase {
    let now = Support.now

    private func makeLibrary(fileSystem: any FileSystem = LocalFileSystem()) async throws -> LibraryStore {
        let root = try tempDirectory("Library").appendingPathComponent("Library")
        let library = LibraryStore(rootURL: root, fileSystem: fileSystem, clock: ManualClock(start: now))
        try await library.open()
        return library
    }

    func testOpenCreatesLayoutAndClearsStaging() async throws {
        let library = try await makeLibrary()
        for name in ["Documents", "Trash", "Catalog", "Previews", "Staging"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("library.json").path))
        let staging = try await library.stagingDirectory()
        XCTAssertTrue(staging.path.hasPrefix(library.rootURL.appendingPathComponent("Staging").path))
        try Data("partial".utf8).write(to: staging.appendingPathComponent("import.pdf"))
        let staging2 = try await library.stagingDirectory()
        XCTAssertNotEqual(staging, staging2)
        let reopened = LibraryStore(rootURL: library.rootURL, clock: ManualClock(start: now))
        try await reopened.open()
        XCTAssertEqual(Support.files(in: library.rootURL.appendingPathComponent("Staging")), [])
    }

    func testLibraryManifestIsReplacedAtomicallyWithLKGFallback() async throws {
        let fs = FaultInjectingFileSystem()
        let library = try await makeLibrary(fileSystem: fs)
        let physics = try await library.createFolder(name: "Physics", parentID: nil, isCourse: true)
        fs.resetCounters()
        _ = try await library.createFolder(name: "Week 1", parentID: physics.id)
        let kinds = fs.mutatingOperations.map(\.kind)
        XCTAssertEqual(kinds, [.write, .syncFile, .copyOrLink, .replaceItem, .replaceItem, .syncDirectory], "\(fs.mutatingOperations)")
        XCTAssertTrue(fs.mutatingOperations[0].path.hasSuffix("library.json.tmp"))
        XCTAssertTrue(fs.mutatingOperations[3].path.hasSuffix("library.lkg.json"))
        XCTAssertTrue(fs.mutatingOperations[4].path.hasSuffix("/library.json"))
        XCTAssertEqual(Support.files(in: library.rootURL).filter { $0.hasSuffix(".tmp") }, [])

        let lkg = try DocumentJSON.decoder().decode(LibraryManifest.self, from: Data(contentsOf: library.lkgManifestURL))
        XCTAssertEqual(lkg.folders.map(\.name), ["Physics"])
        let current = try DocumentJSON.decoder().decode(LibraryManifest.self, from: Data(contentsOf: library.manifestURL))
        XCTAssertEqual(current.folders.map(\.name), ["Physics", "Week 1"])

        // A torn library.json falls back to the last known good manifest.
        try Data("{\"folders\": [".utf8).write(to: library.manifestURL)
        let reopened = LibraryStore(rootURL: library.rootURL, clock: ManualClock(start: now))
        let manifest = try await reopened.open()
        XCTAssertEqual(manifest.folders.map(\.name), ["Physics"])
        // Neither readable -> a clear error, not a silently empty library.
        try Data("nope".utf8).write(to: library.lkgManifestURL)
        let broken = LibraryStore(rootURL: library.rootURL, clock: ManualClock(start: now))
        do { try await broken.open(); XCTFail("expected invalidLibraryRoot") }
        catch let error as PersistenceError { if case .invalidLibraryRoot = error {} else { XCTFail("\(error)") } }

        // A failed save leaves the previous manifest in place.
        let fs2 = FaultInjectingFileSystem()
        let lib2 = try await makeLibrary(fileSystem: fs2)
        _ = try await lib2.createFolder(name: "A", parentID: nil)
        let steps = fs2.mutatingOperationCount
        for step in 0..<6 {
            fs2.resetCounters(); fs2.failStep(step, with: PersistenceError.diskFull)
            do { _ = try await lib2.createFolder(name: "B\(step)", parentID: nil); XCTFail("expected failure") }
            catch let error as PersistenceError { XCTAssertEqual(error, .diskFull) }
            fs2.clearFaults()
            let fresh = LibraryStore(rootURL: lib2.rootURL, clock: ManualClock(start: now))
            let names = try await fresh.open().folders.map(\.name)
            XCTAssertTrue(names == ["A"] || (step >= 4 && names == ["A", "B\(step)"]), "step \(step): \(names)")
        }
        _ = steps
    }

    func testCreateListRenameMoveFavoriteCover() async throws {
        let library = try await makeLibrary()
        let (snapshot, assets) = Support.makeSnapshot(title: "Chem")
        let store = try await library.createDocument(snapshot: snapshot, assets: assets)
        XCTAssertEqual(store.packageURL.path, library.rootURL.appendingPathComponent("Documents/\(snapshot.document.id).courseleafdoc").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.packageURL.appendingPathComponent("manifest.json").path))
        let fs = FaultInjectingFileSystem(logsReads: true)
        let listingLibrary = LibraryStore(rootURL: library.rootURL, fileSystem: fs, clock: ManualClock(start: now))
        try await listingLibrary.open()
        fs.resetCounters()
        let listed = try await listingLibrary.listDocuments()
        XCTAssertEqual(listed.map(\.id), [snapshot.document.id])
        XCTAssertEqual(listed[0].pageCount, 3)
        XCTAssertEqual(listed[0].document.title, "Chem")
        XCTAssertFalse(listed[0].needsNewerApp)
        XCTAssertFalse(fs.log.contains { $0.kind == .read && $0.path.contains("/pages/") }, "listing must not load page files")

        let folder = try await library.createFolder(name: "Chemistry", parentID: nil, isCourse: true)
        try await library.rename(snapshot.document.id, to: "Chem 101")
        try await library.move(snapshot.document.id, toFolder: folder.id)
        try await library.setFavorite(snapshot.document.id, true)
        try await library.setCover(snapshot.document.id, CoverStyle(palette: .moss, pattern: .dots))
        let after = try await library.listing(snapshot.document.id)
        XCTAssertEqual(after.document.title, "Chem 101")
        XCTAssertEqual(after.document.folderID, folder.id)
        XCTAssertTrue(after.document.isFavorite)
        XCTAssertEqual(after.document.cover, CoverStyle(palette: .moss, pattern: .dots))
        // The page content is untouched and the package still opens cleanly with the metadata change.
        let (_, opened) = try await library.openDocument(snapshot.document.id)
        XCTAssertTrue(opened.report.isClean, "\(opened.report)")
        XCTAssertEqual(opened.snapshot.document.title, "Chem 101")
        XCTAssertEqual(Support.normalized(opened.snapshot).pages, Support.normalized(snapshot).pages)
        XCTAssertEqual(opened.snapshot.headRevision?.changedPageIDs, [])
        do { try await library.move(snapshot.document.id, toFolder: FolderID()); XCTFail("unknown folder") }
        catch let error as PersistenceError { if case .notFound = error {} else { XCTFail("\(error)") } }
    }

    func testNewerFormatIsListedAsNeedsNewerAppAndNeverOpened() async throws {
        let library = try await makeLibrary()
        let (snapshot, assets) = Support.makeSnapshot(title: "Future")
        let store = try await library.createDocument(snapshot: snapshot, assets: assets)
        let manifestURL = store.packageURL.appendingPathComponent("manifest.json")
        let text = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        try Data(text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 2").utf8).write(to: manifestURL)
        let listed = try await library.listDocuments()
        XCTAssertEqual(listed.count, 1)
        XCTAssertTrue(listed[0].needsNewerApp)
        XCTAssertEqual(listed[0].schemaVersion, 2)
        XCTAssertEqual(listed[0].document.title, "Future")
        XCTAssertEqual(listed[0].pageCount, 3)
        do { _ = try await library.openDocument(snapshot.document.id); XCTFail("expected unsupportedSchema") }
        catch let error as PersistenceError { XCTAssertEqual(error, .unsupportedSchema(version: 2)) }
        do { try await library.rename(snapshot.document.id, to: "x"); XCTFail("expected unsupportedSchema") }
        catch let error as PersistenceError { XCTAssertEqual(error, .unsupportedSchema(version: 2)) }
    }

    func testTrashRestorePurgeAndEmptyTrash() async throws {
        let library = try await makeLibrary()
        let folder = try await library.createFolder(name: "Bio", parentID: nil)
        var (snapshot, assets) = Support.makeSnapshot(title: "Cells")
        snapshot.document.folderID = folder.id
        _ = try await library.createDocument(snapshot: snapshot, assets: assets)
        let (other, otherAssets) = Support.makeSnapshot(title: "Other")
        _ = try await library.createDocument(snapshot: other, assets: otherAssets)
        let id = snapshot.document.id

        let entry = try await library.delete(id)
        XCTAssertEqual(entry.item, .document(id))
        XCTAssertEqual(entry.title, "Cells")
        XCTAssertEqual(entry.originalFolderID, folder.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("Documents/\(id).courseleafdoc").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("Trash/\(id).courseleafdoc/manifest.json").path))
        let afterDelete = try await library.listDocuments()
        XCTAssertEqual(afterDelete.map(\.id), [other.document.id])
        let entries = try await library.trashEntries()
        XCTAssertEqual(entries.map(\.id), [entry.id])
        let trashed = try await library.listTrashedDocuments()
        XCTAssertEqual(trashed.map(\.id), [id])
        do { _ = try await library.openDocument(id); XCTFail("trashed document must not open from Documents/") }
        catch let error as PersistenceError { if case .packageNotFound = error {} else { XCTFail("\(error)") } }
        // The trash survives a relaunch (library.json).
        let relaunched = LibraryStore(rootURL: library.rootURL, clock: ManualClock(start: now))
        let relaunchedManifest = try await relaunched.open()
        XCTAssertEqual(relaunchedManifest.trash.map(\.id), [entry.id])

        try await library.restore(trashEntryID: entry.id)
        let entriesAfterRestore = try await library.trashEntries()
        XCTAssertEqual(entriesAfterRestore, [])
        let afterRestore = try await library.listDocuments()
        XCTAssertEqual(Set(afterRestore.map(\.id)), [id, other.document.id])
        let (_, restored) = try await library.openDocument(id)
        XCTAssertEqual(Support.normalized(restored.snapshot), Support.normalized(snapshot))
        XCTAssertEqual(restored.snapshot.document.folderID, folder.id)
        XCTAssertEqual(restored.snapshot.pages.count, 3)

        // Purge removes the bytes for good.
        let entry2 = try await library.delete(id)
        try await library.purge(trashEntryID: entry2.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("Trash/\(id).courseleafdoc").path))
        let entriesAfterPurge = try await library.trashEntries()
        XCTAssertEqual(entriesAfterPurge, [])
        do { try await library.restore(trashEntryID: entry2.id); XCTFail("purged entry") }
        catch let error as PersistenceError { if case .notFound = error {} else { XCTFail("\(error)") } }

        _ = try await library.delete(other.document.id)
        try await library.emptyTrash()
        XCTAssertEqual(Support.files(in: library.rootURL.appendingPathComponent("Trash")), [])
        let afterEmpty = try await library.listDocuments()
        XCTAssertEqual(afterEmpty, [])
        let report = try await library.storageReport()
        XCTAssertEqual(report.trashBytes, 0)
        XCTAssertEqual(report.documentBytes, 0)
    }

    func testDeletingAFolderTrashesItsSubtreeAndRestoreBringsItBack() async throws {
        let library = try await makeLibrary()
        let course = try await library.createFolder(name: "Physics", parentID: nil, isCourse: true)
        let week = try await library.createFolder(name: "Week 1", parentID: course.id)
        let unrelated = try await library.createFolder(name: "Art", parentID: nil)
        var (a, aAssets) = Support.makeSnapshot(title: "Lecture 1"); a.document.folderID = course.id
        var (b, bAssets) = Support.makeSnapshot(title: "Lecture 2"); b.document.folderID = week.id
        var (c, cAssets) = Support.makeSnapshot(title: "Sketches"); c.document.folderID = unrelated.id
        for (s, assets) in [(a, aAssets), (b, bAssets), (c, cAssets)] { _ = try await library.createDocument(snapshot: s, assets: assets) }

        let entry = try await library.deleteFolder(course.id)
        guard case .folder(let folder, let ids) = entry.item else { return XCTFail("expected folder entry") }
        XCTAssertEqual(folder.id, course.id)
        XCTAssertEqual(Set(ids), [a.document.id, b.document.id])
        XCTAssertEqual(entry.title, "Physics")
        let foldersAfterDelete = try await library.folders()
        XCTAssertEqual(foldersAfterDelete.map(\.name), ["Art"])
        let documentsAfterDelete = try await library.listDocuments()
        XCTAssertEqual(documentsAfterDelete.map(\.id), [c.document.id])
        for id in ids {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.rootURL.appendingPathComponent("Trash/\(id).courseleafdoc/manifest.json").path))
        }

        try await library.restore(trashEntryID: entry.id)
        let foldersAfterRestore = try await library.folders()
        XCTAssertEqual(Set(foldersAfterRestore.map(\.name)), ["Art", "Physics"])
        let documentsAfterRestore = try await library.listDocuments()
        XCTAssertEqual(Set(documentsAfterRestore.map(\.id)), [a.document.id, b.document.id, c.document.id])
        let listingA = try await library.listing(a.document.id)
        XCTAssertEqual(listingA.document.folderID, course.id)
        // Its subfolder no longer exists, so the document is refiled into the restored folder.
        let listingB = try await library.listing(b.document.id)
        XCTAssertEqual(listingB.document.folderID, course.id)
        let entriesAfterRestore = try await library.trashEntries()
        XCTAssertEqual(entriesAfterRestore, [])

        // Purging a folder entry removes every package it carried.
        let entry2 = try await library.deleteFolder(course.id)
        try await library.purge(trashEntryID: entry2.id)
        XCTAssertEqual(Support.files(in: library.rootURL.appendingPathComponent("Trash")), [])
        let documentsAfterPurge = try await library.listDocuments()
        XCTAssertEqual(documentsAfterPurge.map(\.id), [c.document.id])
    }

    func testDuplicateYieldsDistinctIdentifiersAndEqualContent() async throws {
        let library = try await makeLibrary()
        let (snapshot, assets) = Support.makeSnapshot(title: "Original")
        _ = try await library.createDocument(snapshot: snapshot, assets: assets)
        let copyID = try await library.duplicate(snapshot.document.id)
        XCTAssertNotEqual(copyID, snapshot.document.id)
        let (sourceStore, source) = try await library.openDocument(snapshot.document.id)
        let (copyStore, copy) = try await library.openDocument(copyID)
        XCTAssertTrue(copy.report.isClean, "\(copy.report)")
        XCTAssertEqual(copy.snapshot.document.title, "Original")
        XCTAssertEqual(copy.snapshot.document.pageIDs.count, 3)
        XCTAssertTrue(Set(copy.snapshot.document.pageIDs).isDisjoint(with: source.snapshot.document.pageIDs))
        XCTAssertTrue(Set(copy.snapshot.revisions.keys).isDisjoint(with: source.snapshot.revisions.keys))
        XCTAssertEqual(copy.snapshot.assets, source.snapshot.assets, "assets are content-addressed and keep their ids")
        for (sid, cid) in zip(source.snapshot.document.pageIDs, copy.snapshot.document.pageIDs) {
            let s = source.snapshot.pages[sid]!, c = copy.snapshot.pages[cid]!
            XCTAssertEqual(c.size, s.size); XCTAssertEqual(c.background, s.background); XCTAssertEqual(c.problem, s.problem)
            XCTAssertEqual(c.objects.map(\.content), s.objects.map(\.content))
            XCTAssertEqual(c.objects.map(\.frame), s.objects.map(\.frame))
            XCTAssertTrue(Set(c.objects.map(\.id)).isDisjoint(with: s.objects.map(\.id)))
            XCTAssertEqual(c.inkLayers.map(\.dataAssetID), s.inkLayers.map(\.dataAssetID))
            XCTAssertTrue(Set(c.inkLayers.map(\.id)).isDisjoint(with: s.inkLayers.map(\.id)))
        }
        // Review item references were rewritten consistently.
        let sItem = source.snapshot.document.reviewItems[0], cItem = copy.snapshot.document.reviewItems[0]
        XCTAssertNotEqual(sItem.id, cItem.id)
        XCTAssertEqual(copy.snapshot.pageIndex(cItem.pageID), source.snapshot.pageIndex(sItem.pageID))
        let cTape = copy.snapshot.pages[cItem.pageID]!.objects.first { $0.id == cItem.answerTapeID }
        XCTAssertNotNil(cTape); XCTAssertEqual(cTape?.kind, .tape)
        for id in source.snapshot.assets.keys {
            let copyData = try await copyStore.assetData(id)
            let sourceData = try await sourceStore.assetData(id)
            XCTAssertEqual(copyData, sourceData)
            XCTAssertNotNil(copyData)
        }
        let all = try await library.listDocuments()
        XCTAssertEqual(all.count, 2)
    }

    func testStorageReportCountsBytesPerCategory() async throws {
        let library = try await makeLibrary()
        let (snapshot, assets) = Support.makeSnapshot()
        _ = try await library.createDocument(snapshot: snapshot, assets: assets)
        try Data(repeating: 7, count: 1000).write(to: library.catalogURL.appendingPathComponent("catalog.sqlite"))
        try FileManager.default.createDirectory(at: library.previewsURL.appendingPathComponent("x"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 250).write(to: library.previewsURL.appendingPathComponent("x/p.png"))
        let report = try await library.storageReport()
        XCTAssertGreaterThan(report.documentBytes, assets.reduce(0) { $0 + $1.data.count })
        XCTAssertEqual(report.catalogBytes, 1000)
        XCTAssertEqual(report.previewBytes, 250)
        XCTAssertEqual(report.trashBytes, 0)
        XCTAssertNotNil(report.availableBytes)
    }
}
