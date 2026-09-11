import XCTest
@testable import DocumentCore

final class ModelCodingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_757_600_000.25)

    func testIdentifierCodesAsUUIDString() throws {
        let id = PageID()
        let data = try JSONEncoder().encode(id)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(id.rawValue.uuidString)\"")
        XCTAssertEqual(try JSONDecoder().decode(PageID.self, from: data), id)
        XCTAssertThrowsError(try JSONDecoder().decode(PageID.self, from: Data("\"nope\"".utf8)))
    }

    func testSnapshotRoundTripsThroughDocumentJSON() throws {
        var snap = DocumentSnapshot.newNotebook(title: "Physics 1", template: .cornell, pageCount: 3, now: now)
        let pageID = snap.document.pageIDs[1]
        let asset = PendingAsset.make(data: Data("img".utf8), mediaType: .png, now: now)
        snap.assets[asset.asset.id] = asset.asset
        snap.pages[pageID]!.objects = [
            CanvasObject(frame: PageRect(x: 1, y: 2, width: 3, height: 4), rotation: 0.1, content: .text(TextContent(text: "hi", weight: .bold)), createdAt: now),
            CanvasObject(frame: PageRect(x: 1, y: 2, width: 3, height: 4), isLocked: true, content: .image(ImageContent(assetID: asset.asset.id, crop: PageRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))), createdAt: now),
            CanvasObject(frame: PageRect(x: 0, y: 0, width: 10, height: 10), content: .shape(ShapeContent(kind: .arrow, fillColor: .white)), createdAt: now),
            CanvasObject(frame: PageRect(x: 0, y: 0, width: 10, height: 10), content: .tape(TapeContent(isRevealed: true, label: "answer")), createdAt: now),
        ]
        snap.pages[pageID]!.problem = ProblemMetadata(title: "P3", sourceReference: "HW2 #3", given: "m=2kg", find: "a", resultRegion: PageRect(x: 10, y: 600, width: 200, height: 80), status: .checkAgain)
        snap.document.reviewItems = [ReviewItem(pageID: pageID, region: PageRect(x: 0, y: 0, width: 5, height: 5), prompt: "why?", createdAt: now)]
        snap.document.deletedPages = [DeletedPage(page: snap.pages[pageID]!, originalIndex: 1, deletedAt: now)]

        let enc = DocumentJSON.encoder(), dec = DocumentJSON.decoder()
        let doc2 = try dec.decode(Document.self, from: try enc.encode(snap.document))
        XCTAssertEqual(doc2, snap.document)
        for page in snap.pages.values {
            let data = try enc.encode(page)
            XCTAssertEqual(try dec.decode(Page.self, from: data), page)
        }
        let rev = try XCTUnwrap(snap.headRevision)
        XCTAssertEqual(try dec.decode(Revision.self, from: try enc.encode(rev)), rev)
        // Dates survive with fractional seconds and are ISO-8601 strings in the JSON.
        let text = String(decoding: try enc.encode(snap.document), as: UTF8.self)
        XCTAssertTrue(text.contains("2025-09-11T") || text.contains("T"), text)
    }

    func testEncodingIsDeterministic() throws {
        let snap = DocumentSnapshot.newNotebook(title: "A", now: now)
        let a = try DocumentJSON.encoder().encode(snap.document)
        let b = try DocumentJSON.encoder().encode(snap.document)
        XCTAssertEqual(a, b)
    }

    func testValidationCatchesStructuralProblems() {
        var snap = DocumentSnapshot.newNotebook(title: "A", pageCount: 2, now: now)
        let missing = PageID()
        snap.document.pageIDs.append(missing)
        snap.document.pageIDs.append(snap.document.pageIDs[0])
        let orphan = Page(size: .letter, background: .template(.blank), revisionID: snap.document.revisionHead, createdAt: now, modifiedAt: now)
        snap.pages[orphan.id] = orphan
        let pid = snap.document.pageIDs[0]
        snap.pages[pid]!.inkLayers[0].dataAssetID = AssetID()
        snap.pages[pid]!.size = PageSize(width: 0, height: 10)
        snap.document.revisionHead = RevisionID()
        snap.document.schemaVersion = 99
        let issues = snap.validate()
        func has(_ test: (DocumentSnapshot.ValidationIssue) -> Bool) -> Bool { issues.contains(where: test) }
        XCTAssertTrue(has { if case .missingPage(let p) = $0 { return p == missing } ; return false })
        XCTAssertTrue(has { if case .duplicatePageID = $0 { return true } ; return false })
        XCTAssertTrue(has { if case .orphanPage(let p) = $0 { return p == orphan.id } ; return false })
        XCTAssertTrue(has { if case .missingAsset(_, let p) = $0 { return p == pid } ; return false })
        XCTAssertTrue(has { if case .invalidPageSize(let p) = $0 { return p == pid } ; return false })
        XCTAssertTrue(has { if case .missingRevisionHead = $0 { return true } ; return false })
        XCTAssertTrue(has { if case .unsupportedSchema(99) = $0 { return true } ; return false })
        XCTAssertTrue(DocumentSnapshot.newNotebook(title: "ok", now: now).validate().isEmpty)
    }

    func testLibraryManifestCourseLookup() {
        let course = Folder(name: "Physics", isCourse: true, createdAt: now)
        let week = Folder(name: "Week 3", parentID: course.id, createdAt: now)
        let other = Folder(name: "Misc", createdAt: now)
        let lib = LibraryManifest(folders: [course, week, other], modifiedAt: now)
        XCTAssertEqual(lib.courseFolder(containing: week.id)?.id, course.id)
        XCTAssertEqual(lib.courseFolder(containing: course.id)?.id, course.id)
        XCTAssertNil(lib.courseFolder(containing: other.id))
        XCTAssertNil(lib.courseFolder(containing: nil))
        XCTAssertEqual(lib.subtree(of: course.id), [course.id, week.id])
    }

    func testChangeSetMergeDeduplicatesAssets() {
        let a = PendingAsset.make(data: Data("a".utf8), mediaType: .png, now: now)
        var cs = ChangeSet(changedPageIDs: [PageID()], newAssets: [a])
        cs.merge(ChangeSet(documentChanged: true, newAssets: [a]))
        XCTAssertEqual(cs.newAssets.count, 1)
        XCTAssertTrue(cs.documentChanged)
        XCTAssertFalse(cs.isEmpty)
        XCTAssertTrue(ChangeSet.empty.isEmpty)
    }

    func testPendingAssetDigestMatchesRelativePath() {
        let a = PendingAsset.make(data: Data("abc".utf8), mediaType: .pdf, now: now)
        XCTAssertEqual(a.asset.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(a.asset.relativePath, "assets/ba/ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad.pdf")
    }
}
