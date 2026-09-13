import XCTest
import UIKit
import PencilKit
import DocumentCore
import PageGeometry
import Editing
import Workspace
import Fixtures
@testable import Courseleaf

/// Regressions for the three editing defects that only appear mid-sentence:
/// a serialization result arriving after the drawing it describes is gone, an
/// undo that runs before the stroke it should undo has been recorded, and a
/// page whose ink could not be read being quietly replaced with a blank one.
///
/// Every assertion is on content, not on a flag: where the point is that
/// something was saved, the package is closed and reopened and the restored
/// document is what gets compared.
@MainActor
final class EditorReliabilityTests: XCTestCase {
    private var roots: [URL] = []
    private var suiteNames: [String] = []
    private var windows: [UIWindow] = []

    override func tearDown() {
        for window in windows { window.rootViewController = nil }
        windows = []
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: Harness

    private func makeEnvironment() throws -> AppEnvironment {
        let name = "EditorReliabilityTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorReliability-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(base)
        return AppEnvironment(rootURL: root,
                              settings: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: name))),
                              entitlements: LocalEntitlementStore(),
                              pdfInspector: MinimalPDFInspector(),
                              imageInspector: ImageHeaderInspector(),
                              clock: SystemClock())
    }

    /// The editor the app presents, with a real view hierarchy so the scroll
    /// view, the page pool and the canvases behave as they do on screen.
    private func makeController(session: any DocumentSessioning, pageID: PageID,
                                serializer: any InkSerializing = DetachedInkSerializer()) -> NotebookEditorViewController {
        let controller = NotebookEditorViewController(session: session, initialPageID: pageID,
                                                      inkSerializer: serializer)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        windows.append(window)
        return controller
    }

    private func stroke(y: Double) -> PKDrawing {
        InterchangeTestSupport.horizontalPenStroke(y: y, from: 60, to: 300)
    }

    private func merged(_ drawings: [PKDrawing]) -> PKDrawing {
        PKDrawing(strokes: drawings.flatMap(\.strokes))
    }

    /// Draws on the page the way a finished pen gesture does: the drawing
    /// changes, then the gesture ends, which is the undo boundary.
    private func drawGesture(_ drawing: PKDrawing, on canvas: PageCanvasView,
                             in controller: NotebookEditorViewController) {
        controller.canvasDidBeginUsingTool(canvas)
        canvas.canvasView.drawing = drawing
        canvas.canvasViewDrawingDidChange(canvas.canvasView)
        controller.canvasDidEndUsingTool(canvas)
    }

    /// Polls until `condition` holds or the deadline passes. Views update on a
    /// later run loop than the document does, so a test that asserts on both
    /// has to let the run loop turn.
    private func waitFor(_ description: String, timeout: TimeInterval = 3,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func newNotebook(_ environment: AppEnvironment, pages: Int = 3)
    async throws -> (DocumentID, any DocumentSessioning, PageID) {
        await environment.prepare()
        environment.setRecognitionPaused(true)
        let id = try await environment.library.createNotebook(
            title: "Reliability", folderID: nil, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: pages)
        let session = try await environment.session(for: id)
        return (id, session, session.editor.document.pageIDs[0])
    }

    private func restoredInkAsset(_ environment: AppEnvironment, _ documentID: DocumentID,
                                 _ pageID: PageID) async throws -> AssetID? {
        await environment.closeSession(documentID)
        let reopened = try await environment.session(for: documentID)
        return try XCTUnwrap(reopened.editor.page(pageID)).inkLayers.first?.dataAssetID
    }

    private func strokeCount(ofAsset id: AssetID?, in session: any DocumentSessioning) async throws -> Int {
        guard let id else { return 0 }
        let bytes = try await session.assetData(id)
        let data = try XCTUnwrap(bytes)
        return try PKDrawing(data: data).strokes.count
    }

    // MARK: A — stale serialization

    func testAStaleSerializationCannotOverwriteInkThatReplacedIt() async throws {
        let environment = try makeEnvironment()
        let (documentID, session, pageID) = try await newNotebook(environment)
        let gate = GatedInkSerializer()
        let controller = makeController(session: session, pageID: pageID, serializer: gate)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))

        // A stroke is drawn and its serialization starts, but does not finish.
        let first = stroke(y: 200)
        drawGesture(first, on: canvas, in: controller)
        await gate.waitForEncode(count: 1)

        // Meanwhile the page's drawing is re-established from the document —
        // this is what undo, clear page and a lasso edit all do.
        let replacement = stroke(y: 400)
        let replacementAsset = PendingAsset.make(data: replacement.dataRepresentation(), mediaType: .inkDrawing, now: Date())
        session.addAsset(replacementAsset)
        let layerID = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].id
        try session.apply(.replaceInk(pageID, layerID, dataAssetID: replacementAsset.asset.id))
        canvas.setDrawing(replacement, assetID: replacementAsset.asset.id)

        // Now the older serialization finishes. It describes a drawing that no
        // longer exists, so it must write nothing at all.
        gate.releaseAll()
        await controller.prepareForDocumentSnapshot()

        let live = try XCTUnwrap(session.editor.page(pageID))
        XCTAssertEqual(live.inkLayers[0].dataAssetID, replacementAsset.asset.id,
                       "the late result overwrote ink that had already replaced it")

        let restored = try await restoredInkAsset(environment, documentID, pageID)
        XCTAssertEqual(restored, replacementAsset.asset.id, "and the wrong ink reached disk")
        await environment.shutdown()
    }

    func testStrokesAfterASlowSerializationAreStillSaved() async throws {
        // The defect this replaces: the in-flight commit cleared the page's
        // pending flag on its way out, so every stroke drawn after it was
        // considered already saved and never written.
        let environment = try makeEnvironment()
        let (documentID, session, pageID) = try await newNotebook(environment)
        let gate = GatedInkSerializer()
        let controller = makeController(session: session, pageID: pageID, serializer: gate)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))

        let a = stroke(y: 150)
        drawGesture(a, on: canvas, in: controller)
        await gate.waitForEncode(count: 1)

        // Two more strokes land while the first is still being serialized.
        let ab = merged([a, stroke(y: 250)])
        drawGesture(ab, on: canvas, in: controller)
        let abc = merged([ab, stroke(y: 350)])
        drawGesture(abc, on: canvas, in: controller)

        gate.releaseAll()
        let failure = await controller.prepareForDocumentSnapshot()
        XCTAssertNil(failure, "the barrier reported a save failure: \(String(describing: failure))")

        let restored = try await restoredInkAsset(environment, documentID, pageID)
        let reopened = try await environment.session(for: documentID)
        let count = try await strokeCount(ofAsset: restored, in: reopened)
        XCTAssertEqual(count, 3, "all three strokes have to reach the package, not just the first")
        await environment.shutdown()
    }

    func testEvictingAPageCommitsInkThatHasNotBeenSerializedYet() async throws {
        let environment = try makeEnvironment()
        let (documentID, session, pageID) = try await newNotebook(environment, pages: 6)
        // A serializer that never finishes: the only way this ink can be saved
        // is the synchronous commit eviction performs.
        let gate = GatedInkSerializer()
        let controller = makeController(session: session, pageID: pageID, serializer: gate)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))

        let drawn = merged([stroke(y: 120), stroke(y: 220)])
        drawGesture(drawn, on: canvas, in: controller)
        await gate.waitForEncode(count: 1)
        XCTAssertTrue(controller.hasUncommittedInk)

        // Scroll far enough that the page's canvas is evicted from the pool.
        controller.scrollToPage(5, animated: false)
        controller.view.layoutIfNeeded()
        XCTAssertNil(controller.canvas(for: pageID), "the page should no longer be live")

        gate.releaseAll()
        let failure = await controller.prepareForDocumentSnapshot()
        XCTAssertNil(failure)

        let restored = try await restoredInkAsset(environment, documentID, pageID)
        let reopened = try await environment.session(for: documentID)
        let evictedStrokes = try await strokeCount(ofAsset: restored, in: reopened)
        XCTAssertEqual(evictedStrokes, 2, "eviction must not discard a page's dirty drawing")
        await environment.shutdown()
    }

    // MARK: B — undo

    func testAFirstStrokeCanBeUndoneImmediately() async throws {
        // `performUndo` used to ask the document whether it had anything to undo
        // before committing the stroke that had just been drawn, so this did
        // nothing at all until the save timer happened to have fired.
        let environment = try makeEnvironment()
        let (documentID, session, pageID) = try await newNotebook(environment)
        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))
        let before = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID

        drawGesture(stroke(y: 200), on: canvas, in: controller)
        controller.performUndo()
        controller.applyPendingViewUpdatesNow()

        XCTAssertEqual(try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID, before,
                       "undo immediately after the first stroke has to remove it")
        await waitFor("the canvas has to agree with the document") { canvas.drawing.strokes.isEmpty }

        let failure = await controller.prepareForDocumentSnapshot()
        XCTAssertNil(failure)
        let restored = try await restoredInkAsset(environment, documentID, pageID)
        XCTAssertEqual(restored, before, "the undone state is what reached disk")
        await environment.shutdown()
    }

    func testTwoQuickStrokesAreTwoUndoSteps() async throws {
        // The old 300 ms debounce doubled as a history boundary: two strokes
        // inside the window became one undo, and a pause inside one stroke
        // could split it. The boundary is the end of a gesture now.
        let environment = try makeEnvironment()
        let (_, session, pageID) = try await newNotebook(environment)
        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))

        let a = stroke(y: 150)
        drawGesture(a, on: canvas, in: controller)
        await controller.prepareForDocumentSnapshot()
        let afterFirst = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID

        let ab = merged([a, stroke(y: 250)])
        drawGesture(ab, on: canvas, in: controller)
        await controller.prepareForDocumentSnapshot()
        let afterSecond = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID
        XCTAssertNotEqual(afterFirst, afterSecond)

        controller.performUndo()
        controller.applyPendingViewUpdatesNow()
        XCTAssertEqual(try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID, afterFirst,
                       "the first undo removes only the second stroke")
        await waitFor("one stroke left on the canvas") { canvas.drawing.strokes.count == 1 }

        controller.performUndo()
        controller.applyPendingViewUpdatesNow()
        XCTAssertNil(try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID,
                     "the second undo removes the first stroke")
        await waitFor("no strokes left on the canvas") { canvas.drawing.strokes.isEmpty }
        await environment.shutdown()
    }

    func testUndoingClearPageRestoresTheStrokeThatWasStillOnScreen() async throws {
        let environment = try makeEnvironment()
        let (_, session, pageID) = try await newNotebook(environment)
        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))

        // Drawn but deliberately not given time to be serialized.
        let drawn = merged([stroke(y: 180), stroke(y: 280)])
        drawGesture(drawn, on: canvas, in: controller)

        controller.clearPage(pageID)
        XCTAssertTrue(canvas.drawing.strokes.isEmpty)

        controller.performUndo()
        controller.applyPendingViewUpdatesNow()
        await controller.prepareForDocumentSnapshot()

        let asset = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID
        let restoredStrokes = try await strokeCount(ofAsset: asset, in: session)
        XCTAssertEqual(restoredStrokes, 2,
                       "undoing a clear has to bring back what was on the page, not an older version of it")
        await waitFor("the canvas shows the restored strokes") { canvas.drawing.strokes.count == 2 }
        await environment.shutdown()
    }

    func testTheResponderChainManagerStepsTheDocumentsHistory() async throws {
        // The Edit menu and the iPad three-finger swipe go through the
        // responder chain's UndoManager, which must move the same stack ⌘Z does.
        let environment = try makeEnvironment()
        let (_, session, pageID) = try await newNotebook(environment)
        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))
        let manager = try XCTUnwrap(controller.undoManager)

        drawGesture(stroke(y: 200), on: canvas, in: controller)
        await controller.prepareForDocumentSnapshot()
        let drawn = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID
        XCTAssertNotNil(drawn)
        XCTAssertTrue(manager.canUndo, "the bridge should offer the document's undo")

        manager.undo()
        controller.applyPendingViewUpdatesNow()
        XCTAssertNil(try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID,
                     "the system manager has to step the document, not a stack of its own")
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        controller.applyPendingViewUpdatesNow()
        XCTAssertEqual(try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID, drawn)
        await environment.shutdown()
    }

    func testPencilKitRegistrationsNeverReachTheEditorsUndoManager() async throws {
        // Emptying the editor's manager to tidy up after ink used to take a
        // text box's typing history with it. PencilKit now registers on the
        // canvas's own manager instead.
        let environment = try makeEnvironment()
        let (_, session, pageID) = try await newNotebook(environment)
        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))
        XCTAssertTrue(canvas.canvasHost.undoManager === canvas.canvasHost.inkUndoManager,
                      "the canvas has to answer the responder chain with its own manager")
        XCTAssertFalse(canvas.canvasHost.inkUndoManager === controller.undoManager,
                       "which must not be the editor's")
        _ = session
        await environment.shutdown()
    }

    // MARK: C — unreadable content and the save barrier

    func testAPageWhoseInkCannotBeReadRefusesInputAndKeepsItsAsset() async throws {
        let environment = try makeEnvironment()
        let (documentID, session, pageID) = try await newNotebook(environment)

        // An ink layer pointing at bytes that are not a PKDrawing.
        let broken = PendingAsset.make(data: Data([0x00, 0x01, 0x02]), mediaType: .inkDrawing, now: Date())
        session.addAsset(broken)
        let layerID = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].id
        try session.apply(.replaceInk(pageID, layerID, dataAssetID: broken.asset.id))
        try await session.flush()

        // Stated as a precondition rather than assumed. PencilKit decides what
        // it will refuse, and it is more forgiving than it looks: a short ASCII
        // string comes back as an empty drawing, which would make the rest of
        // this test assert that a page with no ink behaves like a page with no
        // ink. If a future PencilKit accepts these bytes too, this fails here
        // and names the reason instead of passing for the wrong one.
        let probe = PageContentLoader(assets: SessionAssetProvider(session: session))
        guard case .unreadable = await probe.loadDrawing(for: broken.asset.id) else {
            XCTFail("the fixture is supposed to be bytes PencilKit refuses")
            return
        }

        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))
        await waitFor("an undecodable blob must be reported, not turned into a blank page") {
            canvas.inkFailure != nil
        }
        XCTAssertFalse(canvas.canvasView.isUserInteractionEnabled,
                       "writing stays off so the next stroke cannot overwrite what we failed to read")
        XCTAssertFalse(canvas.hasUncommittedDrawing)

        await controller.prepareForDocumentSnapshot()
        let restored = try await restoredInkAsset(environment, documentID, pageID)
        XCTAssertEqual(restored, broken.asset.id, "the page keeps pointing at the bytes we could not read")
        await environment.shutdown()
    }

    func testTheLoaderTellsMissingApartFromUnreadableAndEmpty() async throws {
        let environment = try makeEnvironment()
        let (_, session, _) = try await newNotebook(environment)
        let loader = PageContentLoader(assets: SessionAssetProvider(session: session))

        let good = PendingAsset.make(data: stroke(y: 100).dataRepresentation(), mediaType: .inkDrawing, now: Date())
        session.addAsset(good)
        let bad = PendingAsset.make(data: Data([0x00, 0x01, 0x02]), mediaType: .inkDrawing, now: Date())
        session.addAsset(bad)

        if case .loaded(let drawing) = await loader.loadDrawing(for: good.asset.id) {
            XCTAssertEqual(drawing.strokes.count, 1)
        } else {
            XCTFail("a real drawing should load")
        }
        if case .unreadable = await loader.loadDrawing(for: bad.asset.id) {} else {
            XCTFail("undecodable bytes should be reported as unreadable, not as an empty page")
        }
        if case .missing = await loader.loadDrawing(for: AssetID()) {} else {
            XCTFail("an asset the package does not have should be reported as missing")
        }
        await environment.shutdown()
    }

    func testTheExportBarrierSeesAStrokeThatHasNotLeftTheCanvas() async throws {
        // `session.flush()` alone cannot see a stroke still held in a
        // PKCanvasView, which is why export had to stop calling it directly.
        let environment = try makeEnvironment()
        let (_, session, pageID) = try await newNotebook(environment)
        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))

        drawGesture(merged([stroke(y: 140), stroke(y: 240)]), on: canvas, in: controller)
        XCTAssertTrue(controller.hasUncommittedInk, "the stroke is only in the view at this point")

        let failure = await controller.prepareForDocumentSnapshot()
        XCTAssertNil(failure)
        XCTAssertFalse(controller.hasUncommittedInk)

        let asset = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].dataAssetID
        let committedStrokes = try await strokeCount(ofAsset: asset, in: session)
        XCTAssertEqual(committedStrokes, 2, "the exporter would have read a page without these strokes")
        await environment.shutdown()
    }
}

// MARK: - Test doubles

/// An `InkSerializing` that will not finish until the test says so, so a
/// serialization can still be in flight while the page changes underneath it.
final class GatedInkSerializer: InkSerializing, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var started = 0
    private var isOpen = false

    /// How many encodes have begun.
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }

    func encode(_ drawing: PKDrawing) async -> EncodedInk {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            started += 1
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                pending.append(continuation)
                lock.unlock()
            }
        }
        let data = drawing.dataRepresentation()
        return EncodedInk(data: data, sha256: EditorAssets.sha256Hex(data))
    }

    /// Lets everything through, now and from now on.
    func releaseAll() {
        lock.lock()
        isOpen = true
        let waiting = pending
        pending = []
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    /// Waits until at least `count` encodes have begun.
    func waitForEncode(count: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while startedCount < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
