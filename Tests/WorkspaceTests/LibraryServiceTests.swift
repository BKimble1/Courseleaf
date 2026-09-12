import XCTest
import DocumentCore
import Editing
import Fixtures
import Persistence
import Archive
@testable import Workspace

/// End-to-end tests of the app-facing façade against a real library root on
/// disk: packages, catalog, archives and sessions. Every assertion is about
/// what ends up in files or comes back from a fresh service on the same root.
final class LibraryServiceTests: XCTestCase {

    // MARK: - Sessions and saving

    func testCreateEditFlushCloseReopenRestoresEqualSnapshot() async throws {
        let root = try tempDirectory()
        let clock = ManualClock(start: WS.epoch)
        let service = try await makeService(root: root, clock: clock)
        let id = try await service.createNotebook(title: "Physics", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 2)

        let session = try await service.openSession(id) as! DocumentSession
        let ink = PendingAsset.make(data: WS.inkData("stroke-1"), mediaType: .inkDrawing, now: clock.now())
        let edited: DocumentSnapshot = try await MainActor.run {
            let p0 = session.editor.document.pageIDs[0], p1 = session.editor.document.pageIDs[1]
            try session.apply(.addObject(p0, WS.textObject("Newton's second law"), at: nil))
            try session.apply(.setProblem(p1, ProblemMetadata(title: "HW2 #3", given: "m = 2 kg", find: "a", status: .checkAgain)))
            let item = ReviewRules.makeReviewItem(pageID: p1, region: PageRect(x: 10, y: 10, width: 100, height: 50), prompt: "why?", now: clock.now())
            try session.apply(.addReviewItem(item))
            session.addAsset(ink)
            try session.apply(.replaceInk(p0, session.editor.page(p0)!.inkLayers[0].id, dataAssetID: ink.asset.id))
            return session.editor.snapshot
        }
        // Pending asset bytes are served from memory before the commit and have no file URL yet.
        let pendingBytes = try await session.assetData(ink.asset.id)
        XCTAssertEqual(pendingBytes, ink.data)
        let pendingURL = await session.assetURL(ink.asset.id)
        XCTAssertNil(pendingURL)

        try await session.flush()
        let committedURL = await session.assetURL(ink.asset.id)
        XCTAssertEqual(committedURL?.lastPathComponent, "\(ink.asset.sha256).ink")
        XCTAssertEqual(try Data(contentsOf: committedURL!), ink.data, "asset stored byte for byte")
        await service.closeSession(id)
        let openIDs = await service.openSessionIDs
        XCTAssertTrue(openIDs.isEmpty)

        // A fresh service on the same root sees exactly what was edited.
        await service.close()
        let reopened = try await makeService(root: root, clock: clock)
        let session2 = try await reopened.openSession(id) as! DocumentSession
        let restored = await MainActor.run { session2.editor.snapshot }
        XCTAssertEqual(WS.normalized(restored), WS.normalized(edited))
        XCTAssertEqual(restored.document.reviewItems.count, 1)
        XCTAssertEqual(restored.orderedPages[1].problem?.title, "HW2 #3")
        XCTAssertEqual(restored.orderedPages[0].inkLayers[0].dataAssetID, ink.asset.id)
        let bytes = try await session2.assetData(ink.asset.id)
        XCTAssertEqual(bytes, ink.data)
        let summary = try await reopened.document(id)
        XCTAssertEqual(summary.pageCount, 2)
        XCTAssertEqual(summary.pendingReviewCount, 1)
        XCTAssertEqual(summary.firstPageID, restored.document.pageIDs[0])
    }

    func testSaveStatusGoesUnsavedSavingSavedOnlyAfterDurableCommitAndRecordsLatency() async throws {
        let root = try tempDirectory()
        let clock = TickingClock(start: WS.epoch, tick: 0)
        let service = try await makeService(root: root, clock: clock)
        let id = try await service.createNotebook(title: "Status", folderID: nil, template: .grid, pageSize: .a4, cover: .default, pageCount: 1)
        let session = try await service.openSession(id) as! DocumentSession
        let manifestURL = service.store.packageURL(for: id).appendingPathComponent("manifest.json")
        let log = Log<SaveStatus>()
        let manifestHadText = Log<Bool>()
        await MainActor.run {
            session.onSaveStatusChange = { status in
                log.append(status)
                if case .saved = status {
                    // Observable proof that "saved" means the manifest rename is done: the new page file is referenced.
                    let manifest = (try? String(contentsOf: manifestURL)) ?? ""
                    let pageFile = manifest.contains(session.editor.snapshot.document.revisionHead.description)
                    manifestHadText.append(pageFile)
                }
            }
        }
        let initial = await MainActor.run { session.saveStatus }
        XCTAssertTrue(initial.isDurable)

        try await MainActor.run {
            let p0 = session.editor.document.pageIDs[0]
            try session.apply(.addObject(p0, WS.textObject("Status text"), at: nil))
        }
        await waitUntil("unsaved status") { await MainActor.run { session.saveStatus == .unsaved(pendingChanges: 1) } }
        XCTAssertEqual(log.all, [.unsaved(pendingChanges: 1)])
        clock.tick = 0.01
        try await session.flush()
        clock.tick = 0
        let statuses = log.all
        XCTAssertEqual(statuses.count, 3, "\(statuses)")
        XCTAssertEqual(statuses.first, .unsaved(pendingChanges: 1))
        XCTAssertEqual(statuses.dropFirst().first, .saving)
        guard case .saved(_, let latency)? = statuses.last else { return XCTFail("expected saved, got \(String(describing: statuses.last))") }
        XCTAssertGreaterThan(latency, 0, "latency is measured with the injected clock")
        let recorded = await MainActor.run { session.lastCommitLatency }
        XCTAssertNotNil(recorded)
        XCTAssertGreaterThan(recorded ?? 0, 0)
        XCTAssertLessThanOrEqual(recorded ?? 0, latency)
        XCTAssertEqual(manifestHadText.all, [true], "the manifest on disk already names the new revision when 'saved' is published")
        let final = await MainActor.run { session.saveStatus }
        XCTAssertTrue(final.isDurable)
        let count = await MainActor.run { session.commitCount }
        XCTAssertEqual(count, 1)

        // A second commit writes only the changed page file (revision feedback keeps unchanged pages untouched).
        let pagesDir = manifestURL.deletingLastPathComponent().appendingPathComponent("pages")
        let before = WS.files(in: pagesDir).count
        try await MainActor.run { try session.apply(.setTitle("Renamed")) }
        try await session.flush()
        XCTAssertEqual(WS.files(in: pagesDir).count, before, "a metadata-only change writes no page file")
        try await MainActor.run {
            try session.apply(.addObject(session.editor.document.pageIDs[0], WS.textObject("More"), at: nil))
        }
        try await session.flush()
        XCTAssertEqual(WS.files(in: pagesDir).count, before + 1, "one changed page, one new page file")
    }

    func testUndoRedoThroughSessionArePersisted() async throws {
        let root = try tempDirectory()
        let service = try await makeService(root: root)
        let id = try await service.createNotebook(title: "Undo", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)
        let session = try await service.openSession(id) as! DocumentSession
        let p0 = await MainActor.run { session.editor.document.pageIDs[0] }
        try await MainActor.run {
            try session.performGrouped("Two objects") {
                try session.apply(.addObject(p0, WS.textObject("one"), at: nil))
                try session.apply(.addObject(p0, WS.textObject("two"), at: nil))
            }
        }
        try await session.flush()
        await MainActor.run { session.undo() }
        try await session.flush()
        await service.closeSession(id)
        await service.close()
        let again = try await makeService(root: root)
        let s2 = try await again.openSession(id) as! DocumentSession
        let objects = await MainActor.run { s2.editor.page(p0)!.objects.count }
        XCTAssertEqual(objects, 0, "grouped undo removed both objects on disk")
    }

    // MARK: - Import

    func testImportAlignmentFixturesMatchesSidecarGeometry() async throws {
        let root = try tempDirectory(), files = try tempDirectory("fixtures")
        let service = try await makeService(root: root)
        let sidecar = try WS.alignmentSidecar()
        XCTAssertEqual(sidecar.fixtures.count, 8)
        var requests: [ImportRequest] = []
        for e in sidecar.fixtures {
            let url = try WS.fixtureFile(e.file.replacingOccurrences(of: ".pdf", with: ""), in: files)
            requests.append(ImportRequest(sourceURL: url, kind: .pdf, isSecurityScoped: false))
        }
        let progress = Log<ImportProgress>()
        let result = try await service.importFiles(requests, destination: .newNotebook(folderID: nil, title: "Alignment")) { progress.append($0) }
        XCTAssertEqual(result.createdDocumentIDs.count, 1)
        XCTAssertEqual(result.insertedPageIDs.count, 8)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        XCTAssertEqual(progress.all.last?.completedUnits, progress.all.last?.totalUnits)
        XCTAssertGreaterThan(progress.all.count, 8)

        let id = result.createdDocumentIDs[0]
        let session = try await service.openSession(id) as! DocumentSession
        let snapshot = await MainActor.run { session.editor.snapshot }
        XCTAssertEqual(snapshot.document.title, "Alignment")
        XCTAssertEqual(snapshot.document.pageIDs.count, 8)
        for (page, expected) in zip(snapshot.orderedPages, sidecar.fixtures) {
            XCTAssertEqual(page.size, expected.displaySize, expected.label)
            guard case .pdf(let source) = page.background else { return XCTFail("expected a PDF page for \(expected.label)") }
            XCTAssertEqual(source.pageIndex, 0)
            XCTAssertEqual(source.mediaBox, expected.mediaBox, expected.label)
            XCTAssertEqual(source.cropBox, expected.cropBox, expected.label)
            XCTAssertEqual(source.rotation.rawValue, expected.rotation, expected.label)
            let asset = snapshot.assets[source.assetID]!
            XCTAssertEqual(asset.mediaType, .pdf)
            XCTAssertEqual(asset.pageCount, 1)
            XCTAssertEqual(asset.originalFileName, expected.file)
            let stored = try await session.assetData(source.assetID)
            XCTAssertEqual(stored, try Data(contentsOf: files.appendingPathComponent(expected.file)), "original PDF bytes are stored unmodified")
        }
        let summary = try await service.document(id)
        XCTAssertEqual(summary.pageCount, 8)
        let staging = service.store.stagingURL
        XCTAssertEqual(WS.files(in: staging), [], "staging is cleaned up after the import")
    }

    func testImportLong300PagePDFCreatesOnePagePerPDFPage() async throws {
        let root = try tempDirectory(), files = try tempDirectory("fixtures")
        let service = try await makeService(root: root)
        let url = try WS.fixtureFile("long-300-mixed", in: files)
        let result = try await service.importFiles([ImportRequest(sourceURL: url, isSecurityScoped: false)],
                                                   destination: .newNotebook(folderID: nil, title: nil)) { _ in }
        XCTAssertEqual(result.insertedPageIDs.count, 300)
        let session = try await service.openSession(result.createdDocumentIDs[0]) as! DocumentSession
        let snapshot = await MainActor.run { session.editor.snapshot }
        XCTAssertEqual(snapshot.document.title, "long-300-mixed", "title defaults to the file name")
        XCTAssertEqual(snapshot.assets.count, 1)
        XCTAssertEqual(snapshot.assets.values.first?.pageCount, 300)
        for (index, page) in snapshot.orderedPages.enumerated() {
            let expected: PageSize
            switch index % 3 {
            case 0: expected = .letter
            case 1: expected = PageSize(width: 595.276, height: 841.89)
            default: expected = PageSize(width: 792, height: 612)
            }
            XCTAssertEqual(page.size, expected, "page \(index)")
            guard case .pdf(let source) = page.background else { return XCTFail("page \(index) is not PDF-backed") }
            XCTAssertEqual(source.pageIndex, index)
        }
    }

    func testInsertPDFPagesAfterChosenPageKeepsExistingPageIDsInOrder() async throws {
        let root = try tempDirectory(), files = try tempDirectory("fixtures")
        let service = try await makeService(root: root)
        let id = try await service.createNotebook(title: "Notes", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 3)
        let original = try await service.openSession(id) as! DocumentSession
        let originalIDs = await MainActor.run { original.editor.document.pageIDs }
        await service.closeSession(id)

        // Closed document: pages are inserted by a direct commit.
        let url = try WS.fixtureFile("text-and-outline", in: files)
        let result = try await service.importFiles([ImportRequest(sourceURL: url, kind: .pdf, isSecurityScoped: false)],
                                                   destination: .insert(documentID: id, afterPageIndex: 0)) { _ in }
        XCTAssertEqual(result.insertedPageIDs.count, 3)
        XCTAssertTrue(result.createdDocumentIDs.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("Chapter 1: Kinematics") && $0.contains("Chapter 3") }, "outline titles are reported: \(result.warnings)")
        let session = try await service.openSession(id) as! DocumentSession
        var ids = await MainActor.run { session.editor.document.pageIDs }
        XCTAssertEqual(ids, [originalIDs[0]] + result.insertedPageIDs + [originalIDs[1], originalIDs[2]])
        let summary = try await service.document(id)
        XCTAssertEqual(summary.pageCount, 6)

        // Open document: pages go through the session (one undo step) and are committed on flush.
        let png = try WS.fixtureFile("sample-png", in: files)
        let second = try await service.importFiles([ImportRequest(sourceURL: png, kind: .image, isSecurityScoped: false)],
                                                   destination: .insert(documentID: id, afterPageIndex: nil)) { _ in }
        ids = await MainActor.run { session.editor.document.pageIDs }
        XCTAssertEqual(ids.first, second.insertedPageIDs.first, "nil inserts at the front")
        XCTAssertEqual(Array(ids.dropFirst()), [originalIDs[0]] + result.insertedPageIDs + [originalIDs[1], originalIDs[2]])
        let canUndo = await MainActor.run { session.canUndo }
        XCTAssertTrue(canUndo)
        let durable = await MainActor.run { session.saveStatus.isDurable }
        XCTAssertTrue(durable, "import through a session is flushed")
        let atEnd = try await service.importFiles([ImportRequest(sourceURL: url, kind: .pdf, isSecurityScoped: false)],
                                                  destination: .insert(documentID: id, afterPageIndex: 6)) { _ in }
        ids = await MainActor.run { session.editor.document.pageIDs }
        XCTAssertEqual(Array(ids.suffix(3)), atEnd.insertedPageIDs, "pageCount-1 appends at the end")
        XCTAssertTrue(atEnd.warnings.contains { $0.contains("already imported") }, "duplicate asset is warned about, not blocked: \(atEnd.warnings)")
        await service.closeSession(id)
        let listed = try await service.document(id)
        XCTAssertEqual(listed.pageCount, 10)
    }

    func testImportImageCreatesLetterWidthPageKeepingAspect() async throws {
        let root = try tempDirectory(), files = try tempDirectory("fixtures")
        let service = try await makeService(root: root)
        let png = try WS.fixtureFile("sample-png", in: files)   // 32 x 24
        let result = try await service.importFiles([ImportRequest(sourceURL: png, isSecurityScoped: false)],
                                                   destination: .newNotebook(folderID: nil, title: "Scan")) { _ in }
        let session = try await service.openSession(result.createdDocumentIDs[0]) as! DocumentSession
        let snapshot = await MainActor.run { session.editor.snapshot }
        XCTAssertEqual(snapshot.orderedPages.count, 1)
        let page = snapshot.orderedPages[0]
        XCTAssertEqual(page.size.width, 612)
        XCTAssertEqual(page.size.height, 459, accuracy: 0.001)
        guard case .image(let assetID) = page.background else { return XCTFail("expected an image page") }
        XCTAssertEqual(snapshot.assets[assetID]?.mediaType, .png)
        let stored = try await session.assetData(assetID)
        XCTAssertEqual(stored, try Data(contentsOf: png))
    }

    func testMalformedAndEncryptedPDFsFailWithoutCreatingADocument() async throws {
        let root = try tempDirectory(), files = try tempDirectory("fixtures")
        let service = try await makeService(root: root)
        let documentsDir = service.store.documentsURL
        for name in ["malformed-garbage", "malformed-truncated", "malformed-bad-xref", "encrypted-marker"] {
            let url = try WS.fixtureFile(name, in: files)
            await XCTAssertThrowsWorkspaceError(
                try await service.importFiles([ImportRequest(sourceURL: url, kind: .pdf, isSecurityScoped: false)],
                                              destination: .newNotebook(folderID: nil, title: nil)) { _ in },
                { error in
                    switch error {
                    case .importFailed, .unsupportedFile: return true
                    default: return false
                    }
                }, "for \(name)")
            let docs = try await service.documents(in: .folder(nil))
            XCTAssertTrue(docs.isEmpty, "\(name) must not create a document")
            XCTAssertEqual(WS.files(in: documentsDir), [], "\(name) left a package behind")
        }
        // A bad file in the middle of a batch cancels the whole batch.
        let good = try WS.fixtureFile("alignment-0-0x0", in: files), bad = try WS.fixtureFile("malformed-garbage", in: files)
        await XCTAssertThrowsWorkspaceError(
            try await service.importFiles([ImportRequest(sourceURL: good, isSecurityScoped: false), ImportRequest(sourceURL: bad, isSecurityScoped: false)],
                                          destination: .newNotebook(folderID: nil, title: nil)) { _ in })
        XCTAssertEqual(WS.files(in: documentsDir), [])
        let staging = service.store.stagingURL
        XCTAssertEqual(WS.files(in: staging), [], "staging is cleared after a failed import")
        // Not a PDF at all, with a lying extension.
        let fake = files.appendingPathComponent("notes.pdf")
        try Data("hello".utf8).write(to: fake)
        await XCTAssertThrowsWorkspaceError(
            try await service.importFiles([ImportRequest(sourceURL: fake, isSecurityScoped: false)],
                                          destination: .newNotebook(folderID: nil, title: nil)) { _ in },
            { if case .unsupportedFile = $0 { return true }; return false })
    }

    func testImportCancellationLeavesLibraryUnchanged() async throws {
        let root = try tempDirectory(), files = try tempDirectory("fixtures")
        let service = try await makeService(root: root)
        let url = try WS.fixtureFile("long-300-mixed", in: files)
        let box = Log<Task<ImportResult, Error>>()
        let registered = DispatchSemaphore(value: 0)
        let task = Task<ImportResult, Error> {
            try await service.importFiles([ImportRequest(sourceURL: url, isSecurityScoped: false)],
                                          destination: .newNotebook(folderID: nil, title: nil)) { _ in
                registered.wait()          // the task handle is stored before the import reports its first step
                box.all.first?.cancel()    // cancel as soon as it does
            }
        }
        box.append(task)
        registered.signal()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as WorkspaceError {
            XCTAssertEqual(error, .cancelled)
        }
        let docs = try await service.documents(in: .folder(nil))
        XCTAssertTrue(docs.isEmpty)
        let documentsDir = service.store.documentsURL
        XCTAssertEqual(WS.files(in: documentsDir), [])
    }

    // MARK: - Archives

    func testExportArchiveAndRestoreAsCopyIsEqualModuloIdentifiers() async throws {
        let root = try tempDirectory(), out = try tempDirectory("export")
        let clock = ManualClock(start: WS.epoch)
        let service = try await makeService(root: root, clock: clock)
        let course = try await service.createFolder(name: "Physics", parentID: nil, isCourse: true)
        let id = try await service.createNotebook(title: "A13", folderID: course.id, template: .cornell, pageSize: .letter, cover: CoverStyle(palette: .moss, pattern: .dots), pageCount: 3)
        let session = try await service.openSession(id) as! DocumentSession
        let ink = PendingAsset.make(data: WS.inkData("a13"), mediaType: .inkDrawing, now: clock.now())
        let png = PendingAsset.make(data: MinimalPNGWriter.sampleImage(width: 8, height: 8), mediaType: .png, originalFileName: "d.png", now: clock.now())
        let original: DocumentSnapshot = try await MainActor.run {
            let ids = session.editor.document.pageIDs
            session.addAsset(ink); session.addAsset(png)
            try session.apply(.replaceInk(ids[0], session.editor.page(ids[0])!.inkLayers[0].id, dataAssetID: ink.asset.id))
            try session.apply(.addObject(ids[0], WS.textObject("F = ma"), at: nil))
            try session.apply(.addObject(ids[1], CanvasObject(frame: PageRect(x: 50, y: 60, width: 120, height: 90), content: .image(ImageContent(assetID: png.asset.id)), createdAt: clock.now()), at: nil))
            let tape = CanvasObject(frame: PageRect(x: 300, y: 500, width: 200, height: 40), content: .tape(TapeContent(label: "answer")), createdAt: clock.now())
            try session.apply(.addObject(ids[1], tape, at: nil))
            try session.apply(.setProblem(ids[1], ProblemMetadata(title: "HW3 #1", sourceReference: "Ch. 2", given: "v0 = 3", find: "x(t)", resultRegion: PageRect(x: 1, y: 2, width: 3, height: 4), status: .understood)))
            let item = ReviewRules.makeReviewItem(pageID: ids[1], region: PageRect(x: 0, y: 0, width: 5, height: 5), prompt: "why?", answerTapeID: tape.id, now: clock.now())
            try session.apply(.addReviewItem(item))
            try session.apply(.markReviewed(item.id, at: clock.now()))
            try session.apply(.reopenReview(item.id, at: clock.now()))
            let whole = ReviewRules.makeReviewItem(pageID: ids[2], prompt: nil, now: clock.now())
            try session.apply(.addReviewItem(whole))
            try session.apply(.setPageBookmark(ids[2], true))
            try session.apply(.deletePage(ids[2]))
            return session.editor.snapshot
        }
        let archiveURL = out.appendingPathComponent("a13.courseleaf")
        try await service.exportArchive(documentIDs: [id], to: archiveURL) { _ in }   // flushes the open session first
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let inventory = try ArchiveReader.inventory(url: archiveURL)
        XCTAssertEqual(inventory.kind, .document)
        XCTAssertEqual(inventory.documentIDs, [id])

        let result = try await service.importFiles([ImportRequest(sourceURL: archiveURL, kind: .archive, isSecurityScoped: false)],
                                                   destination: .newNotebook(folderID: course.id, title: nil)) { _ in }
        XCTAssertEqual(result.createdDocumentIDs.count, 1)
        let copyID = result.createdDocumentIDs[0]
        XCTAssertNotEqual(copyID, id, "restored as a copy")
        let copySession = try await service.openSession(copyID) as! DocumentSession
        let copy = await MainActor.run { copySession.editor.snapshot }
        XCTAssertEqual(WS.fingerprint(copy), WS.fingerprint(original))
        XCTAssertEqual(copy.document.folderID, course.id)
        XCTAssertEqual(copy.document.cover, original.document.cover)
        XCTAssertEqual(copy.document.reviewItems.map(\.state), [.pending, .pending])
        XCTAssertEqual(copy.document.reviewItems[0].history.map(\.action), [.added, .markedReviewed, .reopened])
        XCTAssertNotEqual(Set(copy.document.pageIDs), Set(original.document.pageIDs))
        XCTAssertNotEqual(copy.document.reviewItems[0].id, original.document.reviewItems[0].id)
        XCTAssertEqual(copy.orderedPages[1].problem, original.orderedPages[1].problem)
        let tapeID = copy.document.reviewItems[0].answerTapeID
        XCTAssertNotNil(tapeID)
        XCTAssertNotNil(copy.orderedPages[1].object(tapeID!), "tape reference was remapped to the copied object")
        let inkBytes = try await copySession.assetData(ink.asset.id)
        XCTAssertEqual(inkBytes, ink.data)
        let queue = try await service.reviewQueue(courseID: course.id)
        XCTAssertEqual(queue.filter { $0.documentID == copyID }.count, 1, "only the live page's item is queued; the deleted page's item waits in the trash")

        // A damaged archive is refused and creates nothing.
        var bytes = try Data(contentsOf: archiveURL)
        let entry = try ZipReader(url: archiveURL).entries.first { $0.name.hasSuffix("manifest.json") }!
        bytes[Int(entry.dataOffset) + 2] ^= 0xFF
        let damaged = out.appendingPathComponent("damaged.courseleaf")
        try bytes.write(to: damaged)
        let before = try await service.documents(in: .folder(course.id)).count
        await XCTAssertThrowsWorkspaceError(
            try await service.importFiles([ImportRequest(sourceURL: damaged, isSecurityScoped: false)], destination: .newNotebook(folderID: nil, title: nil)) { _ in },
            { if case .archive = $0 { return true }; return false })
        let after = try await service.documents(in: .folder(course.id)).count
        XCTAssertEqual(after, before)
    }

    func testBackupIsValidatedAndRestoresInBothModes() async throws {
        let root = try tempDirectory(), out = try tempDirectory("backup")
        let service = try await makeService(root: root)
        let course = try await service.createFolder(name: "Chemistry", parentID: nil, isCourse: true)
        let sub = try await service.createFolder(name: "Labs", parentID: course.id, isCourse: false)
        let a = try await service.createNotebook(title: "Lab 1", folderID: sub.id, template: .lined, pageSize: .letter, cover: .default, pageCount: 2)
        let b = try await service.createNotebook(title: "Lecture", folderID: course.id, template: .grid, pageSize: .a4, cover: .default, pageCount: 1)
        let session = try await service.openSession(a) as! DocumentSession
        try await MainActor.run {
            try session.apply(.addObject(session.editor.document.pageIDs[0], WS.textObject("titration"), at: nil))
        }
        // No flush: backup must flush open sessions itself.
        let backupURL = out.appendingPathComponent("library.courseleaf")
        let report = try await service.backupLibrary(to: backupURL) { _ in }
        XCTAssertTrue(report.validated)
        XCTAssertEqual(report.documentCount, 2)
        XCTAssertEqual(report.archiveURL, backupURL)
        XCTAssertEqual(report.byteCount, try Data(contentsOf: backupURL).count)
        let inventory = try ArchiveReader.inventory(url: backupURL)
        XCTAssertEqual(inventory.kind, .library)
        XCTAssertTrue(inventory.hasLibraryManifest)
        XCTAssertEqual(Set(inventory.documentIDs), [a, b])
        let reader = try ArchiveReader.open(url: backupURL)
        XCTAssertEqual(reader.library()?.folders.map(\.id).sorted(), [course.id, sub.id].sorted())
        let archivedA = try reader.document(a).snapshot
        XCTAssertEqual(archivedA.orderedPages[0].objects.count, 1, "the unsaved edit was flushed before the backup")
        await service.closeSession(a)

        // addCopies into the same library: two new documents, folders kept.
        let copies = try await service.restoreLibrary(from: backupURL, mode: .addCopies) { _ in }
        XCTAssertEqual(copies.restoredDocumentIDs.count, 2)
        XCTAssertTrue(copies.skippedDocumentIDs.isEmpty)
        XCTAssertEqual(copies.restoredFolderCount, 0)
        XCTAssertTrue(Set(copies.restoredDocumentIDs).isDisjoint(with: [a, b]))
        let inSub = try await service.documents(in: .folder(sub.id))
        XCTAssertEqual(inSub.count, 2, "the copy stays filed in the same folder")
        XCTAssertEqual(Set(inSub.map(\.title)), ["Lab 1"])

        // restoreMissing into a fresh library: original ids and folders come back.
        let root2 = try tempDirectory("restore")
        let fresh = try await makeService(root: root2)
        let restored = try await fresh.restoreLibrary(from: backupURL, mode: .restoreMissing) { _ in }
        XCTAssertEqual(Set(restored.restoredDocumentIDs), [a, b])
        XCTAssertEqual(restored.restoredFolderCount, 2)
        let folders = try await fresh.folders(in: nil)
        XCTAssertEqual(folders.map(\.folder.id), [course.id])
        XCTAssertEqual(folders[0].subfolderCount, 1)
        XCTAssertEqual(folders[0].documentCount, 1)
        let freshA = try await fresh.document(a)
        XCTAssertEqual(freshA.folderID, sub.id)
        XCTAssertEqual(freshA.pageCount, 2)
        // Running it again skips everything that exists.
        let again = try await fresh.restoreLibrary(from: backupURL, mode: .restoreMissing) { _ in }
        XCTAssertTrue(again.restoredDocumentIDs.isEmpty)
        XCTAssertEqual(Set(again.skippedDocumentIDs), [a, b])
        // Purge one document, restore it alone.
        try await fresh.delete(b)
        let entry = try await fresh.trashEntries()[0]
        try await fresh.purge(trashEntryID: entry.id)
        let partial = try await fresh.restoreLibrary(from: backupURL, mode: .restoreMissing) { _ in }
        XCTAssertEqual(partial.restoredDocumentIDs, [b])
        XCTAssertEqual(partial.skippedDocumentIDs, [a])
        let hits = try await fresh.search("titration", scope: .library)
        XCTAssertEqual(hits.hits.map(\.documentID), [a], "restored documents are searchable")

        // A failed restore never modifies the library.
        var bytes = try Data(contentsOf: backupURL)
        let pageEntry = try ZipReader(url: backupURL).entries.first { $0.name.hasSuffix(".json") && $0.name.contains("pages/") }!
        bytes[Int(pageEntry.dataOffset) + 2] ^= 0x0F
        let damaged = out.appendingPathComponent("damaged.courseleaf")
        try bytes.write(to: damaged)
        let documentsDir = fresh.store.documentsURL
        let filesBefore = WS.files(in: documentsDir)
        let manifestBefore = try Data(contentsOf: root2.appendingPathComponent("library.json"))
        await XCTAssertThrowsWorkspaceError(try await fresh.restoreLibrary(from: damaged, mode: .addCopies) { _ in },
                                            { if case .archive = $0 { return true }; return false })
        XCTAssertEqual(WS.files(in: documentsDir), filesBefore)
        XCTAssertEqual(try Data(contentsOf: root2.appendingPathComponent("library.json")), manifestBefore)
        let staging = fresh.store.stagingURL
        XCTAssertEqual(WS.files(in: staging), [])
    }

    // MARK: - Trash

    func testTrashRestoreAndPurgeThroughTheService() async throws {
        let root = try tempDirectory()
        let service = try await makeService(root: root)
        let id = try await service.createNotebook(title: "Bin", folderID: nil, template: .blank, pageSize: .letter, cover: .default, pageCount: 1)
        let session = try await service.openSession(id) as! DocumentSession
        try await MainActor.run { try session.apply(.addObject(session.editor.document.pageIDs[0], WS.textObject("keep me"), at: nil)) }
        try await service.delete(id)   // closes the session first
        let closed = await MainActor.run { session.isClosed }
        XCTAssertTrue(closed)
        let documentsDir = service.store.documentsURL, trashDir = service.store.trashURL
        XCTAssertEqual(WS.files(in: documentsDir), [])
        XCTAssertEqual(WS.files(in: trashDir), ["\(id).courseleafdoc"])
        let root0 = try await service.documents(in: .folder(nil))
        XCTAssertTrue(root0.isEmpty)
        let trashed = try await service.documents(in: .trash)
        XCTAssertEqual(trashed.map(\.id), [id])
        let entries = try await service.trashEntries()
        XCTAssertEqual(entries.count, 1)
        let none = try await service.search("keep", scope: .library)
        XCTAssertTrue(none.hits.isEmpty, "trashed documents are not searchable")
        await XCTAssertThrowsWorkspaceError(try await service.openSession(id), { $0 == .documentNotFound(id) })

        try await service.restore(trashEntryID: entries[0].id)
        XCTAssertEqual(WS.files(in: documentsDir), ["\(id).courseleafdoc"])
        let back = try await service.documents(in: .folder(nil))
        XCTAssertEqual(back.map(\.id), [id])
        let found = try await service.search("keep", scope: .library)
        XCTAssertEqual(found.hits.count, 1, "the flushed edit survived the round trip through the trash")
        let s2 = try await service.openSession(id) as! DocumentSession
        let objects = await MainActor.run { s2.editor.page(s2.editor.document.pageIDs[0])!.objects.count }
        XCTAssertEqual(objects, 1)

        try await service.delete(id)
        let entry = try await service.trashEntries()[0]
        try await service.purge(trashEntryID: entry.id)
        XCTAssertEqual(WS.files(in: trashDir), [])
        let empty = try await service.trashEntries()
        XCTAssertTrue(empty.isEmpty)

        let other = try await service.createNotebook(title: "Other", folderID: nil, template: .blank, pageSize: .letter, cover: .default, pageCount: 1)
        try await service.delete(other)
        try await service.emptyTrash()
        XCTAssertEqual(WS.files(in: trashDir), [])
        let all = try await service.documents(in: .recents)
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Search

    func testSearchTypedHitsRecognizedRecordsInvalidationAndScopes() async throws {
        let root = try tempDirectory()
        let clock = ManualClock(start: WS.epoch)
        let service = try await makeService(root: root, clock: clock)
        let folderA = try await service.createFolder(name: "A", parentID: nil, isCourse: true)
        let folderB = try await service.createFolder(name: "B", parentID: nil, isCourse: true)
        let docA = try await service.createNotebook(title: "Alpha", folderID: folderA.id, template: .lined, pageSize: .letter, cover: .default, pageCount: 2)
        let docB = try await service.createNotebook(title: "Beta", folderID: folderB.id, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)

        let sessionA = try await service.openSession(docA) as! DocumentSession
        let sessionB = try await service.openSession(docB) as! DocumentSession
        let (pageA0, pageA1) = await MainActor.run { (sessionA.editor.document.pageIDs[0], sessionA.editor.document.pageIDs[1]) }
        try await MainActor.run {
            try sessionA.apply(.addObject(pageA0, WS.textObject("entropy always increases"), at: nil))
            try sessionB.apply(.addObject(sessionB.editor.document.pageIDs[0], WS.textObject("entropy of mixing"), at: nil))
        }
        try await sessionA.flush(); try await sessionB.flush()

        // Typed text is searchable immediately after the commit.
        let typed = try await service.search("entropy", scope: .library)
        XCTAssertEqual(Set(typed.hits.map(\.documentID)), [docA, docB])
        XCTAssertEqual(typed.hits.map(\.kind), [.typed, .typed])
        XCTAssertEqual(typed.notYetIndexedPageCount, 3, "no page has been recognized yet")
        XCTAssertEqual(typed.failedPageCount, 0)
        XCTAssertFalse(typed.isIndexingInProgress)

        // Recognized text is recorded for the page's current revision.
        let needing = await sessionA.pagesNeedingRecognition()
        XCTAssertEqual(Set(needing), [pageA0, pageA1])
        let status = await sessionA.indexStatus(for: pageA0)
        XCTAssertEqual(status?.recognized, .notIndexed)
        await sessionA.recordSearchRecords([], for: pageA0, kind: .recognized, state: .queued)
        let inProgress = try await service.search("entropy", scope: .library)
        XCTAssertTrue(inProgress.isIndexingInProgress)
        let record = SearchRecord(documentID: docA, pageID: pageA0, revisionID: status!.revisionID, kind: .recognized,
                                  text: "handwritten thermodynamics", bounds: PageRect(x: 10, y: 20, width: 100, height: 12), confidence: 0.8)
        await sessionA.recordSearchRecords([record], for: pageA0, kind: .recognized, state: .indexed)
        await sessionA.recordSearchRecords([], for: pageA1, kind: .recognized, state: .failed)
        let recognized = try await service.search("thermodynamics", scope: .library)
        XCTAssertEqual(recognized.hits.count, 1)
        XCTAssertEqual(recognized.hits[0].kind, .recognized)
        XCTAssertEqual(recognized.hits[0].bounds, PageRect(x: 10, y: 20, width: 100, height: 12))
        XCTAssertEqual(recognized.hits[0].pageIndex, 0)
        XCTAssertEqual(recognized.notYetIndexedPageCount, 1, "only Beta's page is still unindexed")
        XCTAssertEqual(recognized.failedPageCount, 1)
        XCTAssertFalse(recognized.isIndexingInProgress)
        let remaining = await sessionA.pagesNeedingRecognition()
        XCTAssertTrue(remaining.isEmpty)

        // A new ink revision invalidates the recognized record; the page needs recognition again.
        let ink = PendingAsset.make(data: WS.inkData("new-strokes"), mediaType: .inkDrawing, now: clock.now())
        try await MainActor.run {
            sessionA.addAsset(ink)
            try sessionA.apply(.replaceInk(pageA0, sessionA.editor.page(pageA0)!.inkLayers[0].id, dataAssetID: ink.asset.id))
        }
        try await sessionA.flush()
        let stale = try await service.search("thermodynamics", scope: .library)
        XCTAssertTrue(stale.hits.isEmpty, "recognized text of an older revision is gone")
        XCTAssertEqual(stale.notYetIndexedPageCount, 2, "the re-inked page counts as not yet indexed again")
        let stillTyped = try await service.search("entropy", scope: .document(docA))
        XCTAssertEqual(stillTyped.hits.count, 1, "typed text is re-indexed with the commit")
        let needingAgain = await sessionA.pagesNeedingRecognition()
        XCTAssertEqual(needingAgain, [pageA0])
        let newStatus = await sessionA.indexStatus(for: pageA0)
        XCTAssertNotEqual(newStatus?.revisionID, status?.revisionID)

        // Scopes.
        let scopedA = try await service.search("entropy", scope: .folder(folderA.id))
        XCTAssertEqual(scopedA.hits.map(\.documentID), [docA])
        XCTAssertEqual(scopedA.notYetIndexedPageCount, 1)
        let scopedB = try await service.search("entropy", scope: .document(docB))
        XCTAssertEqual(scopedB.hits.map(\.documentID), [docB])
        let title = try await service.search("Beta", scope: .library)
        XCTAssertEqual(title.hits.map(\.kind), [.title])
        let nothing = try await service.search("photosynthesis", scope: .library)
        XCTAssertTrue(nothing.hits.isEmpty)
        XCTAssertEqual(nothing.notYetIndexedPageCount, 2, "'not yet indexed' is reported separately from 'no matches'")
        let blank = try await service.search("   ", scope: .library)
        XCTAssertTrue(blank.hits.isEmpty)

        // Renaming while open updates the title index through the session's commit.
        try await service.rename(docB, to: "Gamma")
        let renamed = try await service.search("Gamma", scope: .library)
        XCTAssertEqual(renamed.hits.map(\.documentID), [docB])
        let summary = try await service.document(docB)
        XCTAssertEqual(summary.title, "Gamma")
    }

    // MARK: - Review queue

    func testReviewQueuePerCourseAndUnfiledWithMarkAndReopen() async throws {
        let root = try tempDirectory()
        let clock = ManualClock(start: WS.epoch)
        let service = try await makeService(root: root, clock: clock)
        let physics = try await service.createFolder(name: "Physics", parentID: nil, isCourse: true)
        let week = try await service.createFolder(name: "Week 1", parentID: physics.id, isCourse: false)
        let maths = try await service.createFolder(name: "Maths", parentID: nil, isCourse: true)
        let inWeek = try await service.createNotebook(title: "Kinematics", folderID: week.id, template: .lined, pageSize: .letter, cover: .default, pageCount: 2)
        let inMaths = try await service.createNotebook(title: "Algebra", folderID: maths.id, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)
        let unfiled = try await service.createNotebook(title: "Loose", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)

        var items: [DocumentID: ReviewItem] = [:]
        for (offset, id) in [inWeek, inMaths, unfiled].enumerated() {
            let session = try await service.openSession(id) as! DocumentSession
            let item: ReviewItem = try await MainActor.run {
                let page = session.editor.document.pageIDs[0]
                try session.apply(.setProblem(page, ProblemMetadata(title: "Problem \(offset)", status: .checkAgain)))
                let item = ReviewRules.makeReviewItem(pageID: page, prompt: "prompt \(offset)", now: clock.now().addingTimeInterval(Double(offset)))
                try session.apply(.addReviewItem(item))
                return item
            }
            items[id] = item
            await service.closeSession(id)
        }

        let physicsQueue = try await service.reviewQueue(courseID: physics.id)
        XCTAssertEqual(physicsQueue.map(\.documentID), [inWeek], "subfolders of the course contribute")
        XCTAssertEqual(physicsQueue[0].courseID, physics.id)
        XCTAssertEqual(physicsQueue[0].courseName, "Physics")
        XCTAssertEqual(physicsQueue[0].problemTitle, "Problem 0")
        XCTAssertEqual(physicsQueue[0].problemStatus, .checkAgain)
        XCTAssertEqual(physicsQueue[0].item.prompt, "prompt 0")
        XCTAssertEqual(physicsQueue[0].pageIndex, 0)
        let mathsQueue = try await service.reviewQueue(courseID: maths.id)
        XCTAssertEqual(mathsQueue.map(\.documentID), [inMaths])
        let everything = try await service.reviewQueue(courseID: nil)
        XCTAssertEqual(everything.map(\.documentID), [inWeek, inMaths, unfiled], "oldest first, unfiled notebooks included")
        XCTAssertNil(everything[2].courseID)
        await XCTAssertThrowsWorkspaceError(try await service.reviewQueue(courseID: FolderID()), { if case .folderNotFound = $0 { return true }; return false })

        // Mark reviewed while the document is closed: opened, applied, committed, closed.
        try await service.markReviewed(items[inWeek]!.id, in: inWeek)
        let afterMark = try await service.reviewQueue(courseID: physics.id)
        XCTAssertTrue(afterMark.isEmpty)
        let openIDs = await service.openSessionIDs
        XCTAssertTrue(openIDs.isEmpty)
        let reopenedSession = try await service.openSession(inWeek) as! DocumentSession
        let stored = await MainActor.run { reopenedSession.editor.document.reviewItems[0] }
        XCTAssertEqual(stored.state, .reviewed)
        XCTAssertEqual(stored.history.map(\.action), [.added, .markedReviewed])
        XCTAssertNotNil(stored.lastReviewedAt)
        let summary = try await service.document(inWeek)
        XCTAssertEqual(summary.pendingReviewCount, 0)

        // Reopen while the document is open: routed through the session.
        try await service.reopenReview(items[inWeek]!.id, in: inWeek)
        let live = await MainActor.run { reopenedSession.editor.document.reviewItems[0] }
        XCTAssertEqual(live.state, .pending)
        XCTAssertEqual(live.history.map(\.action), [.added, .markedReviewed, .reopened])
        let durable = await MainActor.run { reopenedSession.saveStatus.isDurable }
        XCTAssertTrue(durable)
        let back = try await service.reviewQueue(courseID: physics.id)
        XCTAssertEqual(back.map(\.id), [items[inWeek]!.id])
        await service.closeSession(inWeek)
        await service.close()
        let fresh = try await makeService(root: root, clock: clock)
        let persisted = try await fresh.openSession(inWeek) as! DocumentSession
        let state = await MainActor.run { persisted.editor.document.reviewItems[0].state }
        XCTAssertEqual(state, .pending)
    }

    // MARK: - Catalog

    func testCatalogDeletedThenRebuiltAnswersIdenticalQueries() async throws {
        let root = try tempDirectory()
        let clock = ManualClock(start: WS.epoch)
        let service = try await makeService(root: root, clock: clock)
        let course = try await service.createFolder(name: "Bio", parentID: nil, isCourse: true)
        let a = try await service.createNotebook(title: "Cells", folderID: course.id, template: .lined, pageSize: .letter, cover: .default, pageCount: 2)
        let b = try await service.createNotebook(title: "Genes", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)
        try await service.setFavorite(b, true)
        let session = try await service.openSession(a) as! DocumentSession
        try await MainActor.run {
            let page = session.editor.document.pageIDs[1]
            try session.apply(.addObject(page, WS.textObject("mitochondria"), at: nil))
            try session.apply(.addReviewItem(ReviewRules.makeReviewItem(pageID: page, prompt: "organelles", now: clock.now())))
        }
        await service.closeSession(a)
        let quick = try await service.createQuickNote(template: .dotted)

        func queries(_ s: LibraryService) async throws -> (docs: [DocumentSummary], favorites: [DocumentID], inbox: [DocumentID], hits: [SearchHit], queue: [ReviewQueueEntry], folders: [FolderSummary]) {
            var docs = try await s.documents(in: .folder(nil))
            docs += try await s.documents(in: .folder(course.id))
            return (docs, try await s.documents(in: .favorites).map(\.id), try await s.documents(in: .inbox).map(\.id),
                    try await s.search("mitochondria", scope: .library).hits, try await s.reviewQueue(courseID: nil), try await s.folders(in: nil))
        }
        let before = try await queries(service)
        XCTAssertEqual(before.docs.map(\.id), [b, a])
        XCTAssertEqual(before.favorites, [b])
        XCTAssertEqual(before.inbox, [quick])
        XCTAssertEqual(before.hits.count, 1)
        XCTAssertEqual(before.queue.count, 1)
        XCTAssertEqual(before.folders[0].documentCount, 1)
        await service.close()

        let catalogFile = service.catalogFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogFile.path))
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: catalogFile.path + suffix) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogFile.path))

        let rebuilt = try await makeService(root: root, clock: clock)
        let available = await rebuilt.isCatalogAvailable
        XCTAssertTrue(available)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogFile.path), "the catalog file was recreated")
        let after = try await queries(rebuilt)
        XCTAssertEqual(after.docs, before.docs)
        XCTAssertEqual(after.favorites, before.favorites)
        XCTAssertEqual(after.inbox, before.inbox)
        XCTAssertEqual(after.hits, before.hits)
        XCTAssertEqual(after.queue, before.queue)
        XCTAssertEqual(after.folders, before.folders)

        // Garbage in the file: rebuilt on open as well.
        await rebuilt.close()
        try Data("not a database".utf8).write(to: catalogFile)
        let recovered = try await makeService(root: root, clock: clock)
        let afterGarbage = try await queries(recovered)
        XCTAssertEqual(afterGarbage.hits, before.hits)
        XCTAssertEqual(afterGarbage.docs, before.docs)

        // Explicit rebuild gives the same answers too, and a session that was open during the rebuild keeps indexing.
        let open = try await recovered.openSession(a) as! DocumentSession
        let progress = Log<ImportProgress>()
        try await recovered.rebuildCatalog { progress.append($0) }
        XCTAssertEqual(progress.all.last?.completedUnits, 3)
        XCTAssertEqual(progress.all.last?.totalUnits, 3)
        let afterRebuild = try await queries(recovered)
        XCTAssertEqual(afterRebuild.hits, before.hits)
        XCTAssertEqual(afterRebuild.queue, before.queue)
        try await MainActor.run { try open.apply(.addObject(open.editor.document.pageIDs[0], WS.textObject("ribosome"), at: nil)) }
        try await open.flush()
        let indexedAfterRebuild = try await recovered.search("ribosome", scope: .library)
        XCTAssertEqual(indexedAfterRebuild.hits.map(\.documentID), [a], "commits after a rebuild reach the new catalog")
        await recovered.closeSession(a)
        let storage = try await recovered.storageReport()
        XCTAssertGreaterThan(storage.documentBytes, 0)
        XCTAssertGreaterThan(storage.catalogBytes, 0)
        XCTAssertEqual(storage.trashBytes, 0)
    }

    func testDocumentNeedingANewerAppIsListedButCannotBeOpened() async throws {
        let root = try tempDirectory()
        let clock = ManualClock(start: WS.epoch)
        let service = try await makeService(root: root, clock: clock)
        let id = try await service.createNotebook(title: "Future", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 2)
        let ok = try await service.createNotebook(title: "Present", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)
        await service.close()
        let packageURL = service.store.packageURL(for: id)
        for name in ["manifest.json", "manifest.lkg.json"] {
            let url = packageURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try String(contentsOf: url)
            let newer = text.replacingOccurrences(of: "\"formatVersion\"\\s*:\\s*1\\b", with: "\"formatVersion\" : \(DocumentSchema.current + 1)", options: .regularExpression)
            XCTAssertNotEqual(newer, text)
            try newer.write(to: url, atomically: true, encoding: .utf8)
        }

        let fresh = try await makeService(root: root, clock: clock)
        let docs = try await fresh.documents(in: .folder(nil))
        XCTAssertEqual(docs.map(\.id), [id, ok])
        XCTAssertTrue(docs[0].needsNewerApp)
        XCTAssertEqual(docs[0].title, "Future", "the title is still shown")
        XCTAssertEqual(docs[0].pageCount, 2)
        XCTAssertFalse(docs[1].needsNewerApp)
        let single = try await fresh.document(id)
        XCTAssertTrue(single.needsNewerApp)
        await XCTAssertThrowsWorkspaceError(try await fresh.openSession(id), { $0 == .documentNeedsNewerApp(id, schemaVersion: DocumentSchema.current + 1) })
        await XCTAssertThrowsWorkspaceError(try await fresh.duplicate(id), { if case .documentNeedsNewerApp = $0 { return true }; return false })
        await XCTAssertThrowsWorkspaceError(try await fresh.exportArchive(documentIDs: [id], to: root.appendingPathComponent("x.courseleaf")) { _ in },
                                            { if case .documentNeedsNewerApp = $0 { return true }; return false })
        // The other document is unaffected.
        let session = try await fresh.openSession(ok) as! DocumentSession
        let title = await MainActor.run { session.editor.document.title }
        XCTAssertEqual(title, "Present")
        let header = try PackageManifest.decodeHeader(try Data(contentsOf: packageURL.appendingPathComponent("manifest.json")))
        XCTAssertEqual(header.formatVersion, DocumentSchema.current + 1, "never rewritten by this build")
    }

    // MARK: - Library operations

    func testMoveRenameFavoriteCoverAndDuplicateWhileOpenAndClosed() async throws {
        let root = try tempDirectory()
        let service = try await makeService(root: root)
        let folder = try await service.createFolder(name: "Target", parentID: nil, isCourse: false)
        let id = try await service.createNotebook(title: "Original", folderID: nil, template: .lined, pageSize: .letter, cover: .default, pageCount: 1)
        // Closed: metadata commits.
        try await service.rename(id, to: "Renamed")
        try await service.move(id, toFolder: folder.id)
        try await service.setFavorite(id, true)
        try await service.setCover(id, CoverStyle(palette: .clay, pattern: .weave))
        var summary = try await service.document(id)
        XCTAssertEqual(summary.title, "Renamed")
        XCTAssertEqual(summary.folderID, folder.id)
        XCTAssertTrue(summary.isFavorite)
        XCTAssertEqual(summary.cover.palette, .clay)
        let inFolder = try await service.documents(in: .folder(folder.id)).map(\.id)
        XCTAssertEqual(inFolder, [id])
        await XCTAssertThrowsWorkspaceError(try await service.move(id, toFolder: FolderID()), { if case .folderNotFound = $0 { return true }; return false })

        // Open: routed through the session and committed, and the session's own state agrees.
        let session = try await service.openSession(id) as! DocumentSession
        try await MainActor.run { try session.apply(.addObject(session.editor.document.pageIDs[0], WS.textObject("edit"), at: nil)) }
        try await service.move(id, toFolder: nil)
        try await service.rename(id, to: "Open rename")
        try await service.setFavorite(id, false)
        let live = await MainActor.run { (session.editor.document.folderID, session.editor.document.title, session.editor.document.isFavorite) }
        XCTAssertNil(live.0); XCTAssertEqual(live.1, "Open rename"); XCTAssertFalse(live.2)
        summary = try await service.document(id)
        XCTAssertNil(summary.folderID)
        XCTAssertEqual(summary.title, "Open rename")
        XCTAssertFalse(summary.isFavorite)
        // A later commit from the session keeps the move (the editor was told about it).
        try await MainActor.run { try session.apply(.addObject(session.editor.document.pageIDs[0], WS.textObject("more"), at: nil)) }
        try await session.flush()
        await service.closeSession(id)
        summary = try await service.document(id)
        XCTAssertNil(summary.folderID)
        let listing = try await service.store.listing(id)
        XCTAssertNil(listing.document.folderID)

        let copy = try await service.duplicate(id)
        XCTAssertNotEqual(copy, id)
        let copySummary = try await service.document(copy)
        XCTAssertEqual(copySummary.title, "Open rename copy")
        XCTAssertEqual(copySummary.pageCount, 1)
        let copySession = try await service.openSession(copy) as! DocumentSession
        let objects = await MainActor.run { copySession.editor.orderedObjectsCount }
        XCTAssertEqual(objects, 2)

        try await service.deleteFolder(folder.id)
        let folders = try await service.folders(in: nil)
        XCTAssertTrue(folders.isEmpty)
        await XCTAssertThrowsWorkspaceError(try await service.createFolder(name: "x", parentID: folder.id, isCourse: false), { $0 == .folderNotFound(folder.id) })
        await XCTAssertThrowsWorkspaceError(try await service.document(DocumentID()), { if case .documentNotFound = $0 { return true }; return false })
    }
}

private extension DocumentEditor {
    var orderedObjectsCount: Int { snapshot.orderedPages.reduce(0) { $0 + $1.objects.count } }
}
