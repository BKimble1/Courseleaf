import XCTest
import UIKit
import PencilKit
import DocumentCore
import PageGeometry
import Editing
import Workspace
import Fixtures
@testable import Courseleaf

/// Two things a student asks for and used to be told "no" quietly: taking them
/// to the part of the page they searched for, and showing them the answer they
/// asked to reveal.
@MainActor
final class DeepLinkAndReviewTests: XCTestCase {
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

    private func makeEnvironment() throws -> AppEnvironment {
        let name = "DeepLinkTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepLink-\(UUID().uuidString)", isDirectory: true)
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

    private func present(_ controller: UIViewController) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        windows.append(window)
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 4,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    // MARK: Deep links

    func testTheRouterCarriesAHighlightAndTheEditorShowsIt() async throws {
        let environment = try makeEnvironment()
        await environment.prepare()
        environment.setRecognitionPaused(true)
        let documentID = try await environment.library.createNotebook(
            title: "Thermo", folderID: nil, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 4)
        let session = try await environment.session(for: documentID)
        let pageIDs = session.editor.document.pageIDs
        let target = pageIDs[2]
        let region = PageRect(x: 90, y: 260, width: 180, height: 40)

        // What a search result or a review item does.
        environment.router.openNotebook(documentID, pageIndex: 2, highlight: region)
        guard case .notebook(let routed)? = environment.router.path.last else {
            return XCTFail("the router should have pushed a notebook target")
        }
        XCTAssertEqual(routed.pageIndex, 2)
        XCTAssertEqual(routed.highlight, region, "the router has always carried this")

        // The editor built with that target has to act on it — which is the hop
        // that was missing: NotebookScreen read `pageIndex` and dropped
        // `highlight` on the floor.
        let controller = NotebookEditorViewController(session: session, initialPageID: target,
                                                      initialHighlight: routed.highlight)
        present(controller)

        await waitFor("the requested region is highlighted on the requested page") {
            controller.canvas(for: target)?.overlay.highlightRect == CGRect(region)
        }
        XCTAssertEqual(controller.currentPageID, target, "and it is the page the caller asked for")
        await environment.shutdown()
    }

    func testTheHighlightIsClearedAndDoesNotFollowTheStudentToAnotherPage() async throws {
        let environment = try makeEnvironment()
        await environment.prepare()
        environment.setRecognitionPaused(true)
        let documentID = try await environment.library.createNotebook(
            title: "Thermo", folderID: nil, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 4)
        let session = try await environment.session(for: documentID)
        let pageIDs = session.editor.document.pageIDs
        let first = pageIDs[0]
        let second = pageIDs[1]

        let controller = NotebookEditorViewController(session: session, initialPageID: first)
        present(controller)

        controller.revealSearchHit(pageID: first, region: PageRect(x: 40, y: 40, width: 100, height: 20))
        await waitFor("the first hit is shown") { controller.canvas(for: first)?.overlay.highlightRect != nil }

        // A second navigation must not leave the first highlight behind.
        controller.revealSearchHit(pageID: second, region: PageRect(x: 40, y: 300, width: 100, height: 20))
        await waitFor("the second hit is shown") { controller.canvas(for: second)?.overlay.highlightRect != nil }
        XCTAssertNil(controller.canvas(for: first)?.overlay.highlightRect,
                     "the earlier highlight has to go with the earlier search")
        await environment.shutdown()
    }

    // MARK: Review preview

    /// A notebook with a black square on page 1 and a tape covering it.
    private func makeReviewNotebook(_ environment: AppEnvironment)
    async throws -> (DocumentID, any DocumentSessioning, PageID, ObjectID, PageRect) {
        await environment.prepare()
        environment.setRecognitionPaused(true)
        let documentID = try await environment.library.createNotebook(
            title: "Problem set", folderID: nil, template: .preset(.blank), pageSize: .letter,
            cover: .default, pageCount: 2)
        let session = try await environment.session(for: documentID)
        let pageID = session.editor.document.pageIDs[0]
        let answerRect = PageRect(x: 100, y: 200, width: 160, height: 60)

        let answer = CanvasObject(frame: answerRect,
                                  content: .shape(ShapeContent(kind: .rectangle, strokeColor: .black,
                                                               strokeWidth: 0, fillColor: .black)),
                                  createdAt: Date())
        let tape = CanvasObject(frame: answerRect, content: .tape(TapeContent()), createdAt: Date())
        try session.apply(.addObjects(pageID, [answer, tape]))
        try session.apply(.addReviewItem(ReviewItem(pageID: pageID, region: answerRect,
                                                    prompt: "What is the result?",
                                                    answerTapeID: tape.id, createdAt: Date())))
        try await session.flush()
        return (documentID, session, pageID, tape.id, answerRect)
    }

    private func entry(for documentID: DocumentID, environment: AppEnvironment) async throws -> ReviewQueueEntry {
        let queue = try await environment.library.reviewQueue(courseID: nil)
        return try XCTUnwrap(queue.first { $0.documentID == documentID })
    }

    func testReviewRendersThePageAndTheTapeStateItIsActuallyIn() async throws {
        let environment = try makeEnvironment()
        let (documentID, session, pageID, tapeID, region) = try await makeReviewNotebook(environment)
        let item = try await entry(for: documentID, environment: environment)

        // Covered: the preview must be a picture of the page, not a placeholder.
        guard case .ready(let covered) = await ReviewPagePreviewRenderer.render(entry: item, env: environment, width: 600) else {
            return XCTFail("review must show the page it is asking about")
        }
        XCTAssertGreaterThan(covered.size.width, 10)
        XCTAssertGreaterThan(covered.size.height, 10)

        // Revealed: the same page drawn again has to actually look different,
        // because the tape is what was hiding the answer.
        try session.apply(.setTapeRevealed(pageID, tapeID, true))
        try await session.flush()
        guard case .ready(let revealed) = await ReviewPagePreviewRenderer.render(entry: item, env: environment, width: 600) else {
            return XCTFail("the revealed page must still render")
        }
        XCTAssertNotEqual(covered.pngData(), revealed.pngData(),
                          "revealing the answer has to change what review shows")
        _ = region
        await environment.shutdown()
    }

    func testThePreviewIsCroppedToTheItemsRegionWithSomeContextAroundIt() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let region = PageRect(x: 100, y: 200, width: 160, height: 60)
        let crop = ReviewPagePreviewRenderer.cropRect(for: region, in: page)

        XCTAssertLessThan(crop.minX, region.minX, "there is context to the left")
        XCTAssertGreaterThan(crop.maxX, region.maxX, "and to the right")
        XCTAssertTrue(page.contains(crop), "the crop never leaves the page")
        XCTAssertLessThan(crop.width, page.width, "and it is a crop, not the whole page")

        // An item with no region shows the whole page.
        XCTAssertEqual(ReviewPagePreviewRenderer.cropRect(for: nil, in: page), page)
        // A region larger than the page is clamped rather than overflowing.
        let huge = PageRect(x: -500, y: -500, width: 5000, height: 5000)
        XCTAssertTrue(page.contains(ReviewPagePreviewRenderer.cropRect(for: huge, in: page)))
    }

    func testTheRenderIsBoundedSoASmallRegionOnALargePageCannotAskForAHugeBitmap() {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let tiny = CGRect(x: 300, y: 400, width: 6, height: 6)
        let geometry = ReviewPagePreviewRenderer.renderGeometry(pageRect: page, crop: tiny, targetWidth: 900)
        XCTAssertLessThanOrEqual(max(geometry.renderSize.width, geometry.renderSize.height), 3000,
                                 "a 6-point region at 900 points wide would otherwise be a 90,000-point page")
        XCTAssertGreaterThan(geometry.renderSize.width, 0)
    }

    func testADeletedSourcePageIsExplainedRatherThanShownAsABlankBox() async throws {
        let environment = try makeEnvironment()
        let (documentID, session, pageID, _, _) = try await makeReviewNotebook(environment)
        let item = try await entry(for: documentID, environment: environment)

        try session.apply(.deletePage(pageID))
        try await session.flush()

        guard case .unavailable(let message) = await ReviewPagePreviewRenderer.render(entry: item, env: environment, width: 600) else {
            return XCTFail("a deleted page must be explained, not rendered as nothing")
        }
        XCTAssertFalse(message.isEmpty)
        await environment.shutdown()
    }

    func testOpeningTheSourcePageFromReviewCarriesTheRegion() async throws {
        let environment = try makeEnvironment()
        let (documentID, _, _, _, region) = try await makeReviewNotebook(environment)
        let item = try await entry(for: documentID, environment: environment)

        environment.router.openNotebook(item.documentID, pageIndex: item.pageIndex, highlight: item.item.region)
        guard case .notebook(let routed)? = environment.router.path.last else {
            return XCTFail("review should push a notebook target")
        }
        XCTAssertEqual(routed.documentID, documentID)
        XCTAssertEqual(routed.highlight, region, "so the editor can show the work, not just the page")
        await environment.shutdown()
    }
}
