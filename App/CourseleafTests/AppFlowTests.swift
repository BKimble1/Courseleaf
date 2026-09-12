import XCTest
import UIKit
import PencilKit
import PDFKit
import DocumentCore
import PageGeometry
import Editing
import Workspace
import Fixtures
@testable import Courseleaf

/// End-to-end simulator evidence for the flows a student actually performs:
/// undo after a mixed-selection move (A09) driven through the real editor view
/// controller, image export, printing, the review queue, and library search.
///
/// These exist because the portable suite can only prove the engine underneath.
/// A09 in `DocumentEditorTests` shows `DocumentEditor` groups and undoes
/// correctly; it says nothing about whether the view controller's undo path
/// reaches it. That gap is what this file closes, so each test drives the same
/// object the app puts on screen and asserts document state, files on disk or
/// sampled pixels — never an internal branch.
@MainActor
final class AppFlowTests: XCTestCase {
    private var roots: [URL] = []
    private var suiteNames: [String] = []
    private var scratchDirectories: [URL] = []

    override func tearDown() {
        for url in roots + scratchDirectories { try? FileManager.default.removeItem(at: url) }
        roots = []; scratchDirectories = []
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: Fixtures

    private func makeTemporaryRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppFlowTests-\(UUID().uuidString)", isDirectory: true)
        let url = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(base)
        return url
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppFlowScratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchDirectories.append(url)
        return url
    }

    private func makeEnvironment() throws -> AppEnvironment {
        let name = "AppFlowTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return AppEnvironment(rootURL: try makeTemporaryRoot(),
                              settings: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: name))),
                              entitlements: LocalEntitlementStore(),
                              pdfInspector: MinimalPDFInspector(),
                              imageInspector: ImageHeaderInspector(),
                              clock: SystemClock())
    }

    private func text(_ string: String, at rect: PageRect) -> CanvasObject {
        CanvasObject(frame: rect, content: .text(TextContent(text: string)), createdAt: Date())
    }

    private func shape(at rect: PageRect) -> CanvasObject {
        CanvasObject(frame: rect, content: .shape(ShapeContent(kind: .rectangle, strokeColor: .black, strokeWidth: 0, fillColor: .black)),
                     createdAt: Date())
    }

    private func tape(at rect: PageRect) -> CanvasObject {
        CanvasObject(frame: rect, content: .tape(TapeContent()), createdAt: Date())
    }

    /// A one-page PNG asset, so an image object has real bytes behind it.
    private func pngAsset() -> PendingAsset {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let data = renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return PendingAsset.make(data: data, mediaType: .png, originalFileName: "swatch.png", now: Date())
    }

    // MARK: A09 — one undo restores the exact prior state, through the editor

    func testGroupedMoveOfMixedSelectionUndoesInOneStepThroughTheEditorViewController() async throws {
        let environment = try makeEnvironment()
        await environment.prepare()

        let documentID = try await environment.library.createNotebook(
            title: "Mechanics", folderID: nil, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 2)
        let session = try await environment.session(for: documentID)
        let pageID = session.editor.document.pageIDs[0]
        let untouchedID = session.editor.document.pageIDs[1]

        // Text, image, shape and ink on one page: the mixed selection A09 names.
        let picture = pngAsset()
        session.addAsset(picture)
        let textObject = text("entropy", at: PageRect(x: 40, y: 60, width: 120, height: 24))
        let imageObject = CanvasObject(frame: PageRect(x: 200, y: 300, width: 80, height: 60),
                                       content: .image(ImageContent(assetID: picture.asset.id)), createdAt: Date())
        let shapeObject = shape(at: PageRect(x: 320, y: 500, width: 40, height: 40))
        try session.apply(.addObjects(pageID, [textObject, imageObject, shapeObject]))
        let firstInk = PendingAsset.make(data: InterchangeTestSupport.horizontalPenStroke(y: 200, from: 50, to: 300).dataRepresentation(),
                                         mediaType: .inkDrawing, now: Date())
        session.addAsset(firstInk)
        let layerID = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].id
        try session.apply(.replaceInk(pageID, layerID, dataAssetID: firstInk.asset.id))
        try await session.flush()

        // The editor the app actually presents, with its view loaded so the
        // scroll view, page pool and responder chain are all real.
        let controller = NotebookEditorViewController(session: session, initialPageID: pageID)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = controller
        window.isHidden = false
        controller.view.layoutIfNeeded()

        let before = session.editor.snapshot
        let untouchedBefore = try XCTUnwrap(before.pages[untouchedID])
        XCTAssertFalse(session.canUndo, "a freshly opened editor has nothing to undo")

        // Move all three objects and replace the ink in one grouped operation,
        // exactly as the selection controller does for a drag.
        let secondInk = PendingAsset.make(data: InterchangeTestSupport.horizontalPenStroke(y: 240, from: 50, to: 300).dataRepresentation(),
                                          mediaType: .inkDrawing, now: Date())
        session.addAsset(secondInk)
        controller.performDocumentOperation("Move Selection") {
            try session.apply(.transformObjects(pageID, [textObject.id, imageObject.id, shapeObject.id],
                                                .translation(x: 30, y: -12)))
            try session.apply(.replaceInk(pageID, layerID, dataAssetID: secondInk.asset.id))
        }

        let moved = session.editor.snapshot
        XCTAssertNotEqual(moved, before)
        let movedPage = try XCTUnwrap(session.editor.page(pageID))
        XCTAssertEqual(try XCTUnwrap(movedPage.object(textObject.id)).frame,
                       PageRect(x: 70, y: 48, width: 120, height: 24))
        XCTAssertEqual(try XCTUnwrap(movedPage.object(imageObject.id)).frame,
                       PageRect(x: 230, y: 288, width: 80, height: 60))
        XCTAssertEqual(try XCTUnwrap(movedPage.object(shapeObject.id)).frame,
                       PageRect(x: 350, y: 488, width: 40, height: 40))
        XCTAssertEqual(movedPage.inkLayers[0].dataAssetID, secondInk.asset.id)
        XCTAssertTrue(session.canUndo)

        // One undo, through the view controller, restores the whole group.
        controller.performUndo()
        XCTAssertEqual(session.editor.snapshot, before, "one undo must restore the exact prior snapshot")
        XCTAssertEqual(session.editor.page(untouchedID), untouchedBefore, "the other page is untouched throughout")
        XCTAssertFalse(session.canUndo)
        XCTAssertTrue(session.canRedo)

        controller.performRedo()
        XCTAssertEqual(session.editor.snapshot, moved, "redo re-applies the same group")

        // And it survives the round trip to disk: the undo was a real edit.
        controller.performUndo()
        try await session.flush()
        await environment.closeSession(documentID)
        let reopened = try await environment.session(for: documentID)
        let reopenedPage = try XCTUnwrap(reopened.editor.page(pageID))
        XCTAssertEqual(try XCTUnwrap(reopenedPage.object(textObject.id)).frame, textObject.frame,
                       "the undone position is what reached disk")
        XCTAssertEqual(try XCTUnwrap(reopenedPage.object(shapeObject.id)).frame, shapeObject.frame)
        // The ink layer points at whatever the editor held after the undo. It is
        // compared to the live value rather than to `firstInk` because a live
        // PencilKit canvas may re-encode an identical drawing into a new blob,
        // which is not the thing this test is about.
        XCTAssertEqual(reopenedPage.inkLayers[0].dataAssetID,
                       try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID)

        window.isHidden = true
        await environment.shutdown()
    }

    // MARK: Image export

    func testImageExportRendersTheObjectAtItsPageRectAndEncodesPNGAndJPEG() async throws {
        // A black square at a known rect on a blank Letter page, exported as an
        // image rather than a PDF: the same geometry claim as A05, one format on.
        let square = PageRect(x: 120, y: 260, width: 20, height: 20)
        let page = InterchangeTestSupport.page(size: .letter, background: .template(.blank),
                                               objects: [InterchangeTestSupport.blackSquare(at: square)])
        let (_, source) = InterchangeTestSupport.makeDocument(pages: [page], assets: [])
        let exporter = ImageExporter(source: source)

        let image = try await exporter.export(pageID: page.id, options: ExportOptions(format: .png, inkRasterScale: 2))
        XCTAssertEqual(image.size.width, 612, accuracy: 0.5)
        XCTAssertEqual(image.size.height, 792, accuracy: 0.5)
        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, 1224, "2x raster scale means 2x pixels")
        XCTAssertEqual(cgImage.height, 1584)

        let pixels = PixelSampler(cgImage: cgImage, scale: 2)
        XCTAssertLessThan(pixels.luminance(x: square.midX, y: square.midY), 0.25, "square centre should be black")
        XCTAssertGreaterThan(pixels.luminance(x: 20, y: 20), 0.75, "the page ground stays light")
        // Each edge lands within a point of where page space puts it.
        for (label, outside, inside) in [
            ("left",   PagePoint(x: square.minX - 1, y: square.midY), PagePoint(x: square.minX + 1, y: square.midY)),
            ("right",  PagePoint(x: square.maxX + 1, y: square.midY), PagePoint(x: square.maxX - 1, y: square.midY)),
            ("top",    PagePoint(x: square.midX, y: square.minY - 1), PagePoint(x: square.midX, y: square.minY + 1)),
            ("bottom", PagePoint(x: square.midX, y: square.maxY + 1), PagePoint(x: square.midX, y: square.maxY - 1)),
        ] {
            XCTAssertGreaterThan(pixels.luminance(x: outside.x, y: outside.y), 0.75, "\(label) edge bled outwards past 1 pt")
            XCTAssertLessThan(pixels.luminance(x: inside.x, y: inside.y), 0.25, "\(label) edge fell short by more than 1 pt")
        }

        // Both encodings produce readable files of the right pixel size.
        let png = try await exporter.exportData(pageID: page.id, options: ExportOptions(format: .png, inkRasterScale: 2))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        let jpeg = try await exporter.exportData(pageID: page.id, options: ExportOptions(format: .jpeg, inkRasterScale: 2))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker")
        XCTAssertEqual(try XCTUnwrap(UIImage(data: png)?.cgImage).width, 1224)
        XCTAssertEqual(try XCTUnwrap(UIImage(data: jpeg)?.cgImage).width, 1224)

        // A PDF request through the image exporter is refused rather than guessed at.
        do {
            _ = try await exporter.exportData(pageID: page.id, options: ExportOptions(format: .pdf))
            XCTFail("exporting a PDF through ImageExporter must fail")
        } catch let error as ExportError {
            XCTAssertEqual(error, ExportError.unsupportedFormat(.pdf))
        }
    }

    func testImageExportWritesOnePerSelectedPageInDocumentOrder() async throws {
        let pages = (0..<3).map { index in
            InterchangeTestSupport.page(size: .letter, background: .template(.blank),
                                        objects: [InterchangeTestSupport.blackSquare(
                                            at: PageRect(x: 100 + Double(index) * 50, y: 100, width: 20, height: 20))])
        }
        let (_, source) = InterchangeTestSupport.makeDocument(pages: pages, assets: [])
        let directory = try makeScratchDirectory()

        // Ask for pages 2 and 0, in that order: the export is a selection, not a reordering.
        var progress: [Double] = []
        let urls = try await ImageExporter(source: source).export(
            options: ExportOptions(format: .png, pageIDs: [pages[2].id, pages[0].id]),
            into: directory, stem: "notes") { progress.append($0) }

        XCTAssertEqual(urls.map(\.lastPathComponent), ["notes-1.png", "notes-2.png"])
        XCTAssertEqual(progress, [0.5, 1.0])
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNotNil(UIImage(contentsOfFile: url.path))
        }
        // First file is page 0 (square at x=100), second is page 2 (x=200).
        // A PNG read back from disk has no scale of its own, so the sampler is
        // told the export's raster scale rather than trusting UIImage.scale.
        func sampler(_ url: URL) throws -> PixelSampler {
            PixelSampler(cgImage: try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage), scale: 2)
        }
        let first = try sampler(urls[0])
        XCTAssertLessThan(first.luminance(x: 110, y: 110), 0.25)
        XCTAssertGreaterThan(first.luminance(x: 210, y: 110), 0.75)
        let second = try sampler(urls[1])
        XCTAssertLessThan(second.luminance(x: 210, y: 110), 0.25)
    }

    // MARK: Printing

    func testAnExportedPDFIsPrintableAndAnImageFileIsNotOfferedToThePrinter() async throws {
        try XCTSkipUnless(UIPrintInteractionController.isPrintingAvailable,
                          "printing is unavailable on this simulator runtime")
        let page = InterchangeTestSupport.page(size: .letter, background: .template(.lined),
                                               objects: [InterchangeTestSupport.blackSquare(at: PageRect(x: 100, y: 100, width: 30, height: 30))])
        let (_, source) = InterchangeTestSupport.makeDocument(pages: [page], assets: [])
        let directory = try makeScratchDirectory()

        // The printed copy is the exported presentation copy, so what the
        // printer is handed must be exactly what PDFExporter wrote.
        let pdfURL = directory.appendingPathComponent("print.pdf")
        try await PDFExporter(source: source).export(options: ExportOptions(format: .pdf), to: pdfURL) { _ in }
        XCTAssertTrue(UIPrintInteractionController.canPrint(pdfURL),
                      "the system must accept the exported PDF as a printable item")
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: pdfURL)).pageCount, 1)

        // A file the printer cannot take is reported, not sent.
        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("not a document the printer takes".utf8).write(to: textURL)
        XCTAssertFalse(UIPrintInteractionController.canPrint(textURL))
        do {
            _ = try await PrintCoordinator.print(pdfAt: textURL, from: .view(UIView(), rect: nil))
            XCTFail("printing a non-printable file must throw")
        } catch let error as PrintError {
            XCTAssertEqual(error, PrintError.notPrintable(textURL))
            XCTAssertEqual(error.errorDescription, "notes.txt cannot be printed.")
        }
    }

    // MARK: Review queue

    func testReviewQueueScopesToACourseAndMarksReviewedAndRevealsTheAnswerTape() async throws {
        let environment = try makeEnvironment()
        await environment.prepare()

        let physics = try await environment.library.createFolder(name: "Physics", parentID: nil, isCourse: true)
        let maths = try await environment.library.createFolder(name: "Maths", parentID: nil, isCourse: true)
        let kinematics = try await environment.library.createNotebook(
            title: "Kinematics", folderID: physics.id, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 1)
        let algebra = try await environment.library.createNotebook(
            title: "Algebra", folderID: maths.id, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 1)

        // One problem page per course, each with an answer tape under review.
        var physicsItem: ReviewItem!
        for (documentID, title) in [(kinematics, "Projectile"), (algebra, "Quadratics")] {
            let session = try await environment.session(for: documentID)
            let pageID = session.editor.document.pageIDs[0]
            let answer = tape(at: PageRect(x: 60, y: 400, width: 300, height: 60))
            try session.apply(.addObject(pageID, answer, at: nil))
            try session.apply(.setProblem(pageID, ProblemMetadata(title: title, status: .checkAgain)))
            let item = ReviewRules.makeReviewItem(pageID: pageID, prompt: "Redo \(title)",
                                                  answerTapeID: answer.id, now: Date())
            try session.apply(.addReviewItem(item))
            if documentID == kinematics { physicsItem = item }
            try await session.flush()
            await environment.closeSession(documentID)
        }

        let model = ReviewQueueViewModel()
        model.configure(env: environment)
        await model.load()
        XCTAssertEqual(model.courses.map(\.name), ["Maths", "Physics"], "courses are listed alphabetically")
        XCTAssertEqual(model.pendingCount, 2, "both courses contribute to the unscoped queue")

        model.selectedCourseID = physics.id
        await model.load()
        XCTAssertEqual(model.visibleEntries.map(\.documentID), [kinematics])
        let entry = try XCTUnwrap(model.visibleEntries.first)
        XCTAssertEqual(entry.problemTitle, "Projectile")
        XCTAssertEqual(entry.item.prompt, "Redo Projectile")
        XCTAssertEqual(entry.courseName, "Physics")

        // The tape starts covered; revealing it is a real, persisted edit.
        let coveredBefore = await model.isTapeRevealed(entry)
        XCTAssertEqual(coveredBefore, false)
        let revealed = await model.setTapeRevealed(true, for: entry)
        XCTAssertTrue(revealed)
        let revealedAfter = await model.isTapeRevealed(entry)
        XCTAssertEqual(revealedAfter, true)
        XCTAssertNil(environment.alert)

        // Marking reviewed takes the item out of the pending queue and keeps
        // its history; reopening puts it back.
        await model.markReviewed(entry)
        XCTAssertTrue(model.visibleEntries.isEmpty, "a reviewed item leaves the pending queue")
        XCTAssertEqual(model.pendingCount, 0)
        model.showsReviewed = true
        let reviewed = try XCTUnwrap(model.visibleEntries.first { $0.item.id == physicsItem.id })
        XCTAssertEqual(reviewed.item.state, .reviewed)
        // The whole session is in the item's history, in order: it was added,
        // its answer was revealed, then it was marked reviewed.
        XCTAssertEqual(reviewed.item.history.map(\.action), [.added, .revealed, .markedReviewed])
        XCTAssertNotNil(reviewed.item.lastReviewedAt)

        await model.reopen(reviewed)
        model.showsReviewed = false
        XCTAssertEqual(model.visibleEntries.map(\.item.id), [physicsItem.id])
        XCTAssertEqual(model.pendingCount, 1)
        XCTAssertNil(environment.alert)

        await environment.shutdown()
    }

    // MARK: Library search

    func testSearchGroupsHitsByNotebookHonoursScopeAndSeparatesNotYetIndexed() async throws {
        let environment = try makeEnvironment()
        await environment.prepare()

        let thermo = try await environment.library.createFolder(name: "Thermo", parentID: nil, isCourse: true)
        let alpha = try await environment.library.createNotebook(
            title: "Alpha", folderID: thermo.id, template: .preset(.lined), pageSize: .letter, cover: .default, pageCount: 2)
        let beta = try await environment.library.createNotebook(
            title: "Beta", folderID: nil, template: .preset(.lined), pageSize: .letter, cover: .default, pageCount: 1)

        let alphaSession = try await environment.session(for: alpha)
        try alphaSession.apply(.addObject(alphaSession.editor.document.pageIDs[0],
                                          text("entropy always increases", at: PageRect(x: 72, y: 100, width: 200, height: 40)), at: nil))
        try alphaSession.apply(.addObject(alphaSession.editor.document.pageIDs[1],
                                          text("entropy of mixing", at: PageRect(x: 72, y: 100, width: 200, height: 40)), at: nil))
        try await alphaSession.flush()
        let betaSession = try await environment.session(for: beta)
        try betaSession.apply(.addObject(betaSession.editor.document.pageIDs[0],
                                         text("entropy in one line", at: PageRect(x: 72, y: 100, width: 200, height: 40)), at: nil))
        try await betaSession.flush()

        let model = SearchViewModel()
        model.configure(env: environment)
        XCTAssertFalse(model.hasSearched, "an empty query has not searched, which is not the same as no matches")

        model.query = "entropy"
        model.search(debounceMilliseconds: 0)
        try await waitUntil("the library search returns") { model.hasSearched && !model.isSearching }

        XCTAssertNil(model.unavailableReason)
        XCTAssertEqual(Set(model.groups.map(\.documentID)), [alpha, beta])
        let alphaGroup = try XCTUnwrap(model.groups.first { $0.documentID == alpha })
        XCTAssertEqual(alphaGroup.documentTitle, "Alpha")
        XCTAssertEqual(alphaGroup.hits.count, 2, "both pages of Alpha match, grouped under one notebook")
        XCTAssertEqual(Set(alphaGroup.hits.map(\.kind)), [.typed])
        // Nothing has been through handwriting recognition, and that is stated
        // rather than being indistinguishable from "no match".
        XCTAssertEqual(model.notYetIndexedCount, 3)
        XCTAssertEqual(model.failedCount, 0)
        XCTAssertFalse(model.isIndexing)

        // Scoping to the course drops the unfiled notebook.
        model.scope = .folder(thermo.id)
        model.search(debounceMilliseconds: 0)
        try await waitUntil("the scoped search returns") { model.groups.count == 1 }
        XCTAssertEqual(model.groups.map(\.documentID), [alpha])

        // A query that matches nothing is an empty result, not an error.
        model.query = "thermodynamics"
        model.search(debounceMilliseconds: 0)
        try await waitUntil("the miss returns") { model.groups.isEmpty && model.hasSearched }
        XCTAssertNil(model.unavailableReason)
        XCTAssertNil(environment.alert)

        // Clearing the query clears the results without running a search.
        model.query = "   "
        model.search(debounceMilliseconds: 0)
        XCTAssertFalse(model.hasSearched)
        XCTAssertTrue(model.groups.isEmpty)

        await environment.shutdown()
    }

    // MARK: Helpers

    /// Polls `condition` on the main actor. The view models above finish their
    /// work in a detached task, so there is no completion handler to await; a
    /// fixed sleep would be either flaky or slow.
    private func waitUntil(_ what: String, timeout: TimeInterval = 10,
                           _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
