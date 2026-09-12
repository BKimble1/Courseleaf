import XCTest
import DocumentCore
@testable import Catalog

final class CatalogDatabaseTests: XCTestCase {
    typealias F = CatalogFixtures

    /// A small library: a course "Physics" with a sub-folder, a plain folder, and an unfiled notebook.
    struct Library {
        var manifest: LibraryManifest
        var physics: Folder
        var physicsWeek1: Folder
        var art: Folder
        var mechanics: DocumentSnapshot   // in physics
        var waves: DocumentSnapshot       // in physics/week1
        var sketches: DocumentSnapshot    // in art
        var loose: DocumentSnapshot       // unfiled notebook
        var quick: DocumentSnapshot       // unfiled quick note
        var all: [DocumentSnapshot] { [mechanics, waves, sketches, loose, quick] }
        var allIDs: Set<DocumentID> { Set(all.map(\.document.id)) }

        static func make() -> Library {
            let physics = Folder(name: "Physics", isCourse: true, createdAt: F.epoch, sortIndex: 0)
            let week1 = Folder(name: "Week 1", parentID: physics.id, createdAt: F.epoch, sortIndex: 1)
            let art = Folder(name: "Art", isCourse: false, createdAt: F.epoch, sortIndex: 2)
            var mechanics = F.notebook(title: "Mechanics notes", folderID: physics.id, pageCount: 3,
                                       texts: [0: "Newton's second law F = ma", 1: "Friction and inclined planes"], created: 0)
            F.addProblem(&mechanics, index: 1, title: "Block on a ramp", status: .checkAgain)
            F.addReview(&mechanics, index: 1, prompt: "Why does the block slide?", created: 100, region: PageRect(x: 50, y: 60, width: 300, height: 200))
            F.addReview(&mechanics, index: 0, prompt: "State the second law", created: 50)
            F.addReview(&mechanics, index: 2, prompt: "already done", created: 10, state: .reviewed)
            F.makePDFPage(&mechanics, index: 2)
            var waves = F.notebook(title: "Waves and optics", folderID: week1.id, pageCount: 2, texts: [0: "Snell's law of refraction"], created: 1_000)
            F.addReview(&waves, index: 0, prompt: "Derive Snell", created: 75)
            let sketches = F.notebook(title: "Sketchbook", folderID: art.id, pageCount: 1, texts: [0: "Charcoal study of hands"], isFavorite: true, created: 2_000)
            var loose = F.notebook(title: "Loose ideas", pageCount: 1, texts: [0: "Newton fractal experiment"], created: 3_000)
            F.addReview(&loose, index: 0, prompt: "unfiled review", created: 5)
            let quick = F.notebook(title: "Quick capture", pageCount: 1, texts: [0: "Buy graph paper"], kind: .quickNote, created: 4_000)
            let manifest = LibraryManifest(folders: [physics, week1, art], modifiedAt: F.epoch)
            return Library(manifest: manifest, physics: physics, physicsWeek1: week1, art: art,
                           mechanics: mechanics, waves: waves, sketches: sketches, loose: loose, quick: quick)
        }
    }

    // MARK: Rebuild and listing

    func testRebuildFromSnapshotsThenQuery() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)

            await assertEqual(try await catalog.folders().map(\.name), ["Physics", "Week 1", "Art"], backend)
            let physics = try await catalog.documents(in: .folder(lib.physics.id))
            XCTAssertEqual(physics.map(\.title), ["Mechanics notes"], backend)
            XCTAssertEqual(physics[0].pageCount, 3, backend)
            XCTAssertEqual(physics[0].pendingReviewCount, 2, "reviewed items are not pending")
            XCTAssertEqual(physics[0].firstPageID, lib.mechanics.document.pageIDs[0], backend)
            XCTAssertEqual(physics[0].cover, lib.mechanics.document.cover, backend)
            XCTAssertEqual(physics[0].createdAt, lib.mechanics.document.createdAt, backend)
            XCTAssertFalse(physics[0].needsNewerApp, backend)
            await assertEqual(try await catalog.documents(in: .folder(lib.physicsWeek1.id)).map(\.title), ["Waves and optics"], backend)
            await assertEqual(try await catalog.documents(in: .folder(nil)).map(\.title), ["Loose ideas"], "root excludes inbox quick notes")
            await assertEqual(try await catalog.documents(in: .inbox).map(\.title), ["Quick capture"], backend)
            await assertEqual(try await catalog.documents(in: .favorites).map(\.title), ["Sketchbook"], backend)
            await assertEqual(try await catalog.documents(in: .recents(limit: 2)).map(\.title), ["Quick capture", "Loose ideas"], "newest modified first")
            await assertEqual(try await catalog.documents(in: .all).count, 5, backend)
            await assertEqual(try await catalog.documentCount(inFolder: lib.physics.id), 1, backend)
            await assertEqual(try await catalog.documentCount(inFolder: nil), 1, backend)

            let pages = try await catalog.pages(in: lib.mechanics.document.id)
            XCTAssertEqual(pages.map(\.pageIndex), [0, 1, 2], backend)
            XCTAssertEqual(pages.map(\.id), lib.mechanics.document.pageIDs, backend)
            XCTAssertEqual(pages[1].problemTitle, "Block on a ramp", backend)
            XCTAssertEqual(pages[1].problemStatus, .checkAgain, backend)
            XCTAssertTrue(pages[1].isProblem, backend)
            XCTAssertFalse(pages[0].isProblem, backend)

            let hits = try await catalog.search("newton")
            XCTAssertEqual(hits.map(\.documentTitle), ["Loose ideas", "Mechanics notes"], "same kind: bm25 prefers the shorter fragment")
            XCTAssertEqual(hits.map(\.kind), [.typed, .typed], backend)
            let mechanicsHit = try XCTUnwrap(hits.first { $0.documentID == lib.mechanics.document.id })
            XCTAssertEqual(mechanicsHit.pageIndex, 0, backend)
            XCTAssertEqual(mechanicsHit.pageID, lib.mechanics.document.pageIDs[0], backend)
            XCTAssertEqual(mechanicsHit.revisionID, lib.mechanics.document.revisionHead, backend)
            XCTAssertEqual(mechanicsHit.bounds, PageRect(x: 72, y: 100, width: 200, height: 40), "typed bounds are the object frame")
            XCTAssertTrue(mechanicsHit.snippet.contains("Newton"), mechanicsHit.snippet)
            await assertEqual(try await catalog.search("newton", documentIDs: [lib.mechanics.document.id]).map(\.documentTitle), ["Mechanics notes"], backend)
            await assertEqual(try await catalog.search("waves").map(\.kind), [.title], "document titles are indexed")
            await assertEqual(try await catalog.search("ramp").map(\.kind), [.typed], "problem titles are indexed as typed text")
        }
    }

    func testUpsertIsIdempotent() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.upsertFolders(lib.manifest)
            try await catalog.upsertDocument(lib.mechanics)
            let recognized = F.record(lib.mechanics, index: 0, kind: .recognized, text: "handwritten torque", confidence: 0.9)
            try await catalog.setSearchRecords([recognized], pageID: recognized.pageID, kind: .recognized, state: .indexed)
            let before = try await snapshotState(catalog, lib)

            try await catalog.upsertDocument(lib.mechanics)
            try await catalog.upsertDocument(lib.mechanics)
            let after = try await snapshotState(catalog, lib)
            XCTAssertEqual(before, after, backend)
            await assertEqual(try await catalog.search("torque").map(\.kind), [.recognized], "unchanged revision keeps recognized records")
            await assertEqual(try await catalog.indexStatus(pageID: recognized.pageID)?.recognized, .indexed, backend)
            await assertEqual(try await catalog.search("newton").count, 1, "no duplicate typed records after repeated upserts")
        }
    }

    func testEditingPageRevisionDropsStaleRecognizedRecordsButKeepsTyped() async throws {
        try await withEachBackend { catalog, backend in
            var lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            let page0 = lib.mechanics.document.pageIDs[0]
            let page1 = lib.mechanics.document.pageIDs[1]
            try await catalog.setSearchRecords([F.record(lib.mechanics, index: 0, kind: .recognized, text: "handwritten torque")],
                                               pageID: page0, kind: .recognized, state: .indexed)
            try await catalog.setSearchRecords([F.record(lib.mechanics, index: 1, kind: .recognized, text: "handwritten normal force")],
                                               pageID: page1, kind: .recognized, state: .indexed)
            await assertEqual(try await catalog.search("handwritten").count, 2, backend)
            let docScope: Set<DocumentID> = [lib.mechanics.document.id]
            let notIndexedBefore = try await catalog.notYetIndexedCount(documentIDs: docScope)
            XCTAssertEqual(notIndexedBefore, 1, "page 2 (PDF) is still unindexed; pages 0 and 1 are recognized")

            let newRevision = F.editPage(&lib.mechanics, index: 0, appending: "Momentum p = mv")
            try await catalog.upsertDocument(lib.mechanics)

            let stale = try await catalog.search("torque")
            XCTAssertTrue(stale.isEmpty, "recognized records of the old revision are gone: \(stale)")
            await assertEqual(try await catalog.search("normal").map(\.pageID), [page1], "the untouched page keeps its recognized text")
            await assertEqual(try await catalog.search("momentum").map(\.revisionID), [newRevision], backend)
            await assertEqual(try await catalog.search("newton", documentIDs: docScope).map(\.revisionID), [newRevision], "typed records follow the new revision")
            let status = try await catalog.indexStatus(pageID: page0)
            XCTAssertEqual(status?.recognized, .notIndexed, backend)
            XCTAssertEqual(status?.pdfText, .notApplicable, "template pages never wait for PDF text")
            XCTAssertEqual(status?.revisionID, newRevision, backend)
            await assertEqual(try await catalog.indexStatus(pageID: page1)?.recognized, .indexed, backend)
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: docScope), 2, backend)
            await assertEqual(try await catalog.pagesNeedingRecognition(documentID: lib.mechanics.document.id),
                           [lib.mechanics.document.pageIDs[2], page0], "oldest unrecognized first; the re-edited page goes to the back")

            // A recognizer that finishes late with the old revision must not resurrect stale text.
            let old = SearchRecord(documentID: lib.mechanics.document.id, pageID: page0, revisionID: lib.mechanics.revisions.keys.first { $0 != newRevision }!,
                                   kind: .recognized, text: "handwritten torque")
            try await catalog.setSearchRecords([old], pageID: page0, kind: .recognized, state: .indexed)
            await assertTrue(try await catalog.search("torque").isEmpty, backend)
        }
    }

    func testSearchDistinguishesNoMatchesFromNotYetIndexed() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            let scope: Set<DocumentID> = [lib.mechanics.document.id]
            let pdfPage = lib.mechanics.document.pageIDs[2]
            // Every page needs recognition; only the PDF page needs PDF text.
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: scope), 3, backend)
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: lib.allIDs), 8, backend)
            await assertEqual(try await catalog.notYetIndexedCount(), 8, backend)
            await assertEqual(try await catalog.failedCount(documentIDs: scope), 0, backend)
            await assertTrue(try await catalog.search("kinematics", documentIDs: scope).isEmpty, backend)

            try await catalog.setSearchRecords([F.record(lib.mechanics, index: 2, kind: .pdfText, text: "Chapter 4: Kinematics in two dimensions")],
                                               pageID: pdfPage, kind: .pdfText, state: .indexed)
            await assertEqual(try await catalog.search("kinematics", documentIDs: scope).map(\.kind), [.pdfText], backend)
            await assertEqual(try await catalog.indexStatus(pageID: pdfPage)?.pdfText, .indexed, backend)
            await assertEqual(try await catalog.indexStatus(pageID: pdfPage)?.recognized, .notIndexed, backend)
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: scope), 3, "recognition is still pending on all three pages")

            for index in 0..<3 {
                try await catalog.setSearchRecords([], pageID: lib.mechanics.document.pageIDs[index], kind: .recognized,
                                                   state: index == 1 ? .failed : .indexed, error: index == 1 ? "no text found" : nil)
            }
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: scope), 0, backend)
            await assertEqual(try await catalog.failedCount(documentIDs: scope), 1, backend)
            await assertEqual(try await catalog.indexStatus(pageID: lib.mechanics.document.pageIDs[1])?.lastError, "no text found", backend)
            await assertTrue(try await catalog.search("kinematics", documentIDs: [lib.waves.document.id]).isEmpty, "scope filters hits")
            await assertTrue(try await catalog.search("nothing-here", documentIDs: scope).isEmpty, "zero hits once indexed")
            await assertTrue(try await catalog.search("   ").isEmpty, backend)

            // Queued pages count as not yet indexed too.
            try await catalog.setSearchRecords([], pageID: pdfPage, kind: .recognized, state: .queued)
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: scope), 1, backend)
        }
    }

    func testReviewQueuePerCourseSubtreeAndUnfiled() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            let subtree = lib.manifest.subtree(of: lib.physics.id)
            XCTAssertEqual(subtree, [lib.physics.id, lib.physicsWeek1.id])

            let course = try await catalog.reviewQueue(folderIDs: subtree, includeUnfiled: false)
            XCTAssertEqual(course.map(\.prompt), ["State the second law", "Derive Snell", "Why does the block slide?"], "oldest first across the subtree")
            XCTAssertEqual(course.map(\.documentTitle), ["Mechanics notes", "Waves and optics", "Mechanics notes"], backend)
            XCTAssertEqual(course.map(\.pageIndex), [0, 0, 1], backend)
            XCTAssertEqual(course[2].problemTitle, "Block on a ramp", backend)
            XCTAssertEqual(course[2].problemStatus, .checkAgain, backend)
            XCTAssertEqual(course[2].region, PageRect(x: 50, y: 60, width: 300, height: 200), backend)
            XCTAssertNil(course[0].problemTitle, backend)
            XCTAssertEqual(course[0].createdAt, F.date(50), backend)
            XCTAssertEqual(course[0].reviewItem.state, .pending, backend)
            XCTAssertEqual(course.map(\.folderID), [lib.physics.id, lib.physicsWeek1.id, lib.physics.id], backend)

            let onlyTop = try await catalog.reviewQueue(folderIDs: [lib.physics.id], includeUnfiled: false)
            XCTAssertEqual(onlyTop.map(\.prompt), ["State the second law", "Why does the block slide?"], backend)
            await assertTrue(try await catalog.reviewQueue(folderIDs: [lib.art.id], includeUnfiled: false).isEmpty, backend)
            await assertEqual(try await catalog.reviewQueue(folderIDs: [], includeUnfiled: true).map(\.prompt), ["unfiled review"], backend)
            await assertEqual(try await catalog.reviewQueue(folderIDs: nil, includeUnfiled: true).map(\.prompt),
                           ["unfiled review", "State the second law", "Derive Snell", "Why does the block slide?"], backend)
            await assertEqual(try await catalog.reviewQueue(folderIDs: nil, includeUnfiled: false).count, 3, backend)
        }
    }

    func testReviewQueueCarriesTheAnswerTapeAndReviewedItemsOnRequest() async throws {
        try await withEachBackend { catalog, backend in
            var lib = Library.make()
            let tape = ObjectID()
            F.addReview(&lib.loose, index: 0, prompt: "with a tape", created: 6, answerTapeID: tape)
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)

            // The queue reveals the answer straight from the row, so losing the
            // tape reference here makes the reveal do nothing.
            let unfiled = try await catalog.reviewQueue(folderIDs: [], includeUnfiled: true)
            XCTAssertEqual(unfiled.map(\.prompt), ["unfiled review", "with a tape"], backend)
            XCTAssertEqual(unfiled[1].answerTapeID, tape, backend)
            XCTAssertEqual(unfiled[1].reviewItem.answerTapeID, tape, "the projection carries it too")
            XCTAssertNil(unfiled[0].answerTapeID, "an item the student gave no tape has none")

            let pending = try await catalog.reviewQueue(folderIDs: [lib.physics.id], includeUnfiled: false)
            XCTAssertEqual(pending.map(\.prompt), ["State the second law", "Why does the block slide?"], "reviewed items stay out by default")
            let withReviewed = try await catalog.reviewQueue(folderIDs: [lib.physics.id], includeUnfiled: false, includeReviewed: true)
            XCTAssertEqual(withReviewed.map(\.prompt), ["already done", "State the second law", "Why does the block slide?"], "oldest first")
            XCTAssertEqual(withReviewed[0].state, .reviewed, backend)
            XCTAssertEqual(withReviewed[0].reviewItem.state, .reviewed, backend)
        }
    }

    func testRankingOrderTitleTypedPDFTextRecognized() async throws {
        try await withEachBackend { catalog, backend in
            var recognizedDoc = F.notebook(title: "Recognized only", pageCount: 1, created: 0)
            F.makePDFPage(&recognizedDoc, index: 0)
            var pdfDoc = F.notebook(title: "PDF only", pageCount: 1, created: 1)
            F.makePDFPage(&pdfDoc, index: 0)
            let typedDoc = F.notebook(title: "Typed only", pageCount: 1, texts: [0: "entropy of an ideal gas"], created: 2)
            let titleDoc = F.notebook(title: "Entropy lecture", pageCount: 1, created: 3)
            let manifest = LibraryManifest(modifiedAt: F.epoch)
            // Insert in the reverse of the expected order so rowid cannot explain the result.
            try await catalog.rebuild(manifest: manifest, snapshots: [recognizedDoc, pdfDoc, typedDoc, titleDoc])
            try await catalog.setSearchRecords([F.record(recognizedDoc, index: 0, kind: .recognized, text: "entropy entropy entropy scribbled", confidence: 0.4)],
                                               pageID: recognizedDoc.document.pageIDs[0], kind: .recognized, state: .indexed)
            try await catalog.setSearchRecords([F.record(pdfDoc, index: 0, kind: .pdfText, text: "entropy entropy printed")],
                                               pageID: pdfDoc.document.pageIDs[0], kind: .pdfText, state: .indexed)

            let hits = try await catalog.search("entropy")
            XCTAssertEqual(hits.map(\.kind), [.title, .typed, .pdfText, .recognized], backend)
            XCTAssertEqual(hits.map(\.documentTitle), ["Entropy lecture", "Typed only", "PDF only", "Recognized only"], backend)

            // Within one kind, bm25 orders the better match first regardless of insertion order.
            let weak = F.notebook(title: "Weak", pageCount: 1, texts: [0: "the photon is a particle of light whose energy is proportional to its frequency"], created: 4)
            let strong = F.notebook(title: "Strong", pageCount: 1, texts: [0: "photon photon photon"], created: 5)
            try await catalog.upsertDocument(weak)
            try await catalog.upsertDocument(strong)
            let photon = try await catalog.search("photon")
            XCTAssertEqual(photon.map(\.documentTitle), ["Strong", "Weak"], backend)
            XCTAssertLessThan(photon[0].rank, photon[1].rank, backend)
        }
    }

    func testFTSSpecialCharactersAndQuotes() async throws {
        try await withEachBackend { catalog, backend in
            let doc = F.notebook(title: "Notes: \"Quoted\" (draft) OR NOT", pageCount: 2,
                                 texts: [0: "He said \"hello world\" and left", 1: "x^2 + y:z NEAR(a b) - 42"], created: 0)
            try await catalog.rebuild(manifest: LibraryManifest(modifiedAt: F.epoch), snapshots: [doc])
            let cases: [(String, Int)] = [
                ("\"hello\"", 1), ("\"", 0), ("\"\"", 0), ("hello \"world", 1), ("say \"hello world\"", 0),
                ("OR", 1), ("NOT", 1), ("AND", 1), ("NEAR(a", 1), ("a b)", 1), ("(draft)", 1), ("x^2", 1),
                ("y:z", 1), ("42", 1), ("-", 0), ("*", 0), ("hel*", 1), ("quoted", 1), ("title:notes", 0),
                ("world hello", 1), ("héllo", 1), ("{[}]", 0), ("\\", 0),
            ]
            for (query, expected) in cases {
                let hits: [SearchHitRow]
                do { hits = try await catalog.search(query) } catch { return XCTFail("query \(query) threw \(error) [\(backend)]") }
                XCTAssertEqual(hits.count, expected, "query \(query) [\(backend)]")
            }
            let styled = try await catalog.search("hello", snippet: SnippetStyle(highlightStart: "[", highlightEnd: "]"))
            XCTAssertEqual(styled.count, 1, backend)
            XCTAssertTrue(styled[0].snippet.contains("[hello]"), styled[0].snippet)
        }
    }

    func testInMemoryAndOnDiskProduceIdenticalResults() async throws {
        let lib = Library.make()
        let dir = TemporaryDirectory()
        let memory = try CatalogDatabase.inMemory()
        let disk = try CatalogDatabase.open(at: dir.file("Catalog/catalog.sqlite"))
        XCTAssertEqual(memory.location, .memory)
        XCTAssertEqual(disk.location, .file(dir.file("Catalog/catalog.sqlite")))
        for catalog in [memory, disk] {
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            try await catalog.setSearchRecords([F.record(lib.mechanics, index: 2, kind: .pdfText, text: "printed lecture text")],
                                               pageID: lib.mechanics.document.pageIDs[2], kind: .pdfText, state: .indexed)
        }
        let a = try await snapshotState(memory, lib), b = try await snapshotState(disk, lib)
        XCTAssertEqual(a, b)
        await assertGreaterThan(try await disk.storageSizeInBytes(), 0)
        await assertGreaterThan(try await memory.storageSizeInBytes(), 0)
        withExtendedLifetime(dir) {}
    }

    func testDeletingTheCatalogAndRebuildingYieldsIdenticalResults() async throws {
        let lib = Library.make()
        let dir = TemporaryDirectory()
        let url = dir.file("catalog.sqlite")
        let first = try CatalogDatabase.open(at: url)
        try await first.rebuild(manifest: lib.manifest, snapshots: lib.all)
        // Simulate incremental use: a header update and a stray document later removed.
        var renamed = lib.sketches.document; renamed.title = "Sketchbook renamed"
        try await first.upsertDocumentHeader(renamed, pageCount: 1)
        let stray = F.notebook(title: "Stray", pageCount: 1, created: 9)
        try await first.upsertDocument(stray)
        try await first.removeDocument(stray.document.id)
        let expected = try await snapshotState(first, lib)
        await assertEqual(try await first.search("renamed").map(\.kind), [.title])
        await assertTrue(try await first.search("stray").isEmpty)
        try await first.checkpoint()
        await first.close()

        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let second = try CatalogDatabase.open(at: url)
        await assertTrue(try await second.documents(in: .all).isEmpty, "a fresh file starts empty")
        var snapshots = lib.all
        snapshots[2].document.title = "Sketchbook renamed"
        try await second.rebuild(manifest: lib.manifest, snapshots: snapshots.reversed())
        await assertEqual(try await snapshotState(second, lib), expected)
        await assertEqual(try await second.integrityCheck(), [])
        withExtendedLifetime(dir) {}
    }

    func testNeedsNewerAppDocumentsAreListedButFlagged() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            var future = lib.waves
            future.document.schemaVersion = DocumentSchema.current + 1
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all, needsNewerApp: [future.document.id])
            var listed = try await catalog.documents(in: .folder(lib.physicsWeek1.id))
            XCTAssertEqual(listed.map(\.title), ["Waves and optics"], backend)
            XCTAssertTrue(listed[0].needsNewerApp, backend)
            await assertFalse(try await catalog.documents(in: .folder(lib.physics.id))[0].needsNewerApp, backend)

            // The header path (what a scan of an unreadable package can provide) flags it too.
            try await catalog.upsertDocumentHeader(future.document, pageCount: 2, needsNewerApp: true)
            listed = try await catalog.documents(in: .folder(lib.physicsWeek1.id))
            XCTAssertTrue(listed[0].needsNewerApp, backend)
            XCTAssertEqual(listed[0].schemaVersion, DocumentSchema.current + 1, backend)
            await assertEqual(try await catalog.document(future.document.id)?.needsNewerApp, true, backend)
            try await catalog.upsertDocument(lib.waves)
            await assertEqual(try await catalog.document(future.document.id)?.needsNewerApp, false, "a readable snapshot clears the flag")
        }
    }

    func testIntegrityCheckPassesAfterHeavyUse() async throws {
        let dir = TemporaryDirectory()
        let catalog = try CatalogDatabase.open(at: dir.file("catalog.sqlite"))
        var lib = Library.make()
        try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
        for round in 0..<5 {
            F.editPage(&lib.mechanics, index: round % 3, appending: "round \(round)", at: Double(round + 1) * 10)
            try await catalog.upsertDocument(lib.mechanics)
            try await catalog.setSearchRecords([F.record(lib.mechanics, index: round % 3, kind: .recognized, text: "ink \(round)")],
                                               pageID: lib.mechanics.document.pageIDs[round % 3], kind: .recognized, state: .indexed)
        }
        try await catalog.removeDocument(lib.quick.document.id)
        try await catalog.reset()
        try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
        await assertEqual(try await catalog.integrityCheck(), [])
        await assertEqual(try await catalog.search("round").count, 5)
        withExtendedLifetime(dir) {}
    }

    // MARK: Smaller behaviours

    func testRemoveDocumentDropsEverythingDerived() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            let id = lib.mechanics.document.id
            try await catalog.setSearchRecords([F.record(lib.mechanics, index: 0, kind: .recognized, text: "gone soon")],
                                               pageID: lib.mechanics.document.pageIDs[0], kind: .recognized, state: .indexed)
            try await catalog.removeDocument(id)
            await assertNil(try await catalog.document(id), backend)
            await assertTrue(try await catalog.pages(in: id).isEmpty, backend)
            await assertTrue(try await catalog.search("newton", documentIDs: [id]).isEmpty, backend)
            await assertTrue(try await catalog.search("gone").isEmpty, backend)
            await assertTrue(try await catalog.search("mechanics").isEmpty, backend)
            await assertEqual(try await catalog.notYetIndexedCount(documentIDs: [id]), 0, backend)
            await assertTrue(try await catalog.reviewQueue(folderIDs: [lib.physics.id], includeUnfiled: false).isEmpty, backend)
            await assertNil(try await catalog.indexStatus(pageID: lib.mechanics.document.pageIDs[0]), backend)
            await assertThrowsError(try await catalog.setSearchRecords([], pageID: lib.mechanics.document.pageIDs[0], kind: .recognized, state: .indexed)) {
                XCTAssertEqual($0 as? CatalogError, .pageNotFound(lib.mechanics.document.pageIDs[0]), backend)
            }
            await assertEqual(try await catalog.search("newton").map(\.documentTitle), ["Loose ideas"], "other documents are untouched")
        }
    }

    func testHeaderUpsertUpdatesListingAndTitleSearchOnly() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            var doc = lib.mechanics.document
            doc.title = "Classical mechanics"
            doc.folderID = lib.art.id
            doc.isFavorite = true
            doc.lastOpenedAt = F.date(9_999)
            try await catalog.upsertDocumentHeader(doc, pageCount: 3)
            let row = try await catalog.document(doc.id)
            XCTAssertEqual(row?.title, "Classical mechanics", backend)
            XCTAssertEqual(row?.folderID, lib.art.id, backend)
            XCTAssertEqual(row?.isFavorite, true, backend)
            XCTAssertEqual(row?.lastOpenedAt, F.date(9_999), backend)
            XCTAssertEqual(row?.pendingReviewCount, 2, backend)
            await assertEqual(try await catalog.documents(in: .recents(limit: 1)).map(\.title), ["Classical mechanics"], "opening moves it to the front of recents")
            await assertEqual(try await catalog.search("classical").map(\.kind), [.title], backend)
            await assertTrue(try await catalog.search("mechanics notes").isEmpty, "the old title record is gone")
            await assertEqual(try await catalog.search("newton", documentIDs: [doc.id]).count, 1, "typed records survive a header update")
            await assertEqual(try await catalog.pages(in: doc.id).count, 3, backend)
            await assertEqual(try await catalog.reviewQueue(folderIDs: [lib.art.id], includeUnfiled: false).count, 2, "the queue follows the new folder")

            // A header for a document the catalog has never seen is listed with no pages.
            let unseen = F.notebook(title: "Header only", pageCount: 4, created: 7)
            try await catalog.upsertDocumentHeader(unseen.document, pageCount: 4)
            let unseenRow = try await catalog.document(unseen.document.id)
            XCTAssertEqual(unseenRow?.pageCount, 4, backend)
            XCTAssertNil(unseenRow?.firstPageID, backend)
            await assertTrue(try await catalog.search("header").isEmpty, "no page to anchor a title record on yet")
        }
    }

    func testUpsertFoldersReplacesTreeAndDropsTrashedDocuments() async throws {
        try await withEachBackend { catalog, backend in
            var lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            lib.manifest.folders.removeAll { $0.id == lib.art.id }
            lib.manifest.folders[0].name = "Physics 101"
            lib.manifest.trash = [
                TrashEntry(item: .document(lib.loose.document.id), title: "Loose ideas", originalFolderID: nil, deletedAt: F.epoch),
                TrashEntry(item: .folder(lib.art, documentIDs: [lib.sketches.document.id]), title: "Art", originalFolderID: nil, deletedAt: F.epoch),
            ]
            try await catalog.upsertFolders(lib.manifest)
            await assertEqual(try await catalog.folders().map(\.name), ["Physics 101", "Week 1"], backend)
            await assertEqual(try await catalog.folders()[0], lib.manifest.folders[0], backend)
            await assertNil(try await catalog.document(lib.loose.document.id), backend)
            await assertNil(try await catalog.document(lib.sketches.document.id), backend)
            await assertTrue(try await catalog.search("charcoal").isEmpty, backend)
            await assertEqual(try await catalog.documents(in: .all).count, 3, backend)
        }
    }

    func testDeletedPagesLeaveTheCatalog() async throws {
        try await withEachBackend { catalog, backend in
            var lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            let removed = lib.mechanics.document.pageIDs[1]
            try await catalog.setSearchRecords([F.record(lib.mechanics, index: 1, kind: .recognized, text: "scribble on ramp page")],
                                               pageID: removed, kind: .recognized, state: .indexed)
            let page = lib.mechanics.pages[removed]!
            lib.mechanics.document.pageIDs.remove(at: 1)
            lib.mechanics.document.deletedPages = [DeletedPage(page: page, originalIndex: 1, deletedAt: F.date(500))]
            try await catalog.upsertDocument(lib.mechanics)
            await assertEqual(try await catalog.pages(in: lib.mechanics.document.id).map(\.pageIndex), [0, 1], backend)
            await assertEqual(try await catalog.document(lib.mechanics.document.id)?.pageCount, 2, backend)
            await assertTrue(try await catalog.search("friction").isEmpty, "typed text of a deleted page is not searchable")
            await assertTrue(try await catalog.search("scribble").isEmpty, backend)
            await assertNil(try await catalog.indexStatus(pageID: removed), backend)
            await assertEqual(try await catalog.reviewQueue(folderIDs: nil, includeUnfiled: true).map(\.prompt),
                           ["unfiled review", "State the second law", "Derive Snell"], "review items on the deleted page leave the queue")
            await assertEqual(try await catalog.document(lib.mechanics.document.id)?.pendingReviewCount, 1, backend)
        }
    }

    func testRebuildIsAtomic() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            let before = try await snapshotState(catalog, lib)
            // Two snapshots with the same page ID violate the pages primary key; the whole rebuild must roll back.
            var clash = F.notebook(title: "Clash", pageCount: 1, created: 1)
            let borrowed = lib.loose.document.pageIDs[0]
            clash.document.pageIDs = [borrowed]
            clash.pages = [borrowed: lib.loose.pages[borrowed]!]
            await assertThrowsError(try await catalog.rebuild(manifest: LibraryManifest(modifiedAt: F.epoch), snapshots: [lib.loose, clash]), backend)
            await assertEqual(try await snapshotState(catalog, lib), before, "nothing changed [\(backend)]")
            await assertNil(try await catalog.document(clash.document.id), backend)
        }
    }

    func testResetEmptiesEverything() async throws {
        try await withEachBackend { catalog, backend in
            let lib = Library.make()
            try await catalog.rebuild(manifest: lib.manifest, snapshots: lib.all)
            try await catalog.reset()
            await assertTrue(try await catalog.folders().isEmpty, backend)
            await assertTrue(try await catalog.documents(in: .all).isEmpty, backend)
            await assertTrue(try await catalog.search("newton").isEmpty, backend)
            await assertEqual(try await catalog.notYetIndexedCount(), 0, backend)
            await assertTrue(try await catalog.reviewQueue(folderIDs: nil, includeUnfiled: true).isEmpty, backend)
            await assertEqual(try await catalog.integrityCheck(), [], backend)
        }
    }

    func testFTS5CheckAndClosedHandle() async throws {
        let catalog = try CatalogDatabase.inMemory()
        await assertTrue(await catalog.isOpen)
        await catalog.close()
        await assertFalse(await catalog.isOpen)
        await assertThrowsError(try await catalog.documents(in: .all)) { XCTAssertEqual($0 as? CatalogError, .closed) }
    }

    // MARK: Helpers

    /// Everything observable about a library, for equality comparisons across backends and rebuilds.
    struct State: Equatable {
        var folders: [Folder]
        var documents: [CatalogScope: [DocumentRow]]
        var pages: [DocumentID: [PageRow]]
        var queue: [[ReviewQueueRow]]
        var searches: [String: [SearchHitRow]]
        var statuses: [PageID: PageIndexStatus?]
        var notIndexed: Int
        var failed: Int
    }

    func snapshotState(_ catalog: CatalogDatabase, _ lib: Library) async throws -> State {
        let scopes: [CatalogScope] = [.folder(nil), .folder(lib.physics.id), .folder(lib.physicsWeek1.id), .folder(lib.art.id), .recents(limit: 10), .favorites, .inbox, .all]
        var documents: [CatalogScope: [DocumentRow]] = [:]
        for scope in scopes { documents[scope] = try await catalog.documents(in: scope) }
        var pages: [DocumentID: [PageRow]] = [:]
        for id in lib.allIDs { pages[id] = try await catalog.pages(in: id) }
        var searches: [String: [SearchHitRow]] = [:]
        for q in ["newton", "law", "sketch", "printed", "torque", "quick", "s"] { searches[q] = try await catalog.search(q) }
        var statuses: [PageID: PageIndexStatus?] = [:]
        for snapshot in lib.all { for id in snapshot.document.pageIDs { statuses[id] = try await catalog.indexStatus(pageID: id) } }
        return State(
            folders: try await catalog.folders(), documents: documents, pages: pages,
            queue: [try await catalog.reviewQueue(folderIDs: nil, includeUnfiled: true),
                    try await catalog.reviewQueue(folderIDs: lib.manifest.subtree(of: lib.physics.id), includeUnfiled: false)],
            searches: searches, statuses: statuses,
            notIndexed: try await catalog.notYetIndexedCount(), failed: try await catalog.failedCount())
    }
}
