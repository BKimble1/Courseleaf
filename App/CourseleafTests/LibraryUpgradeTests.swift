import XCTest
import UIKit
import PencilKit
import DocumentCore
import PageGeometry
import Editing
import Persistence
import Workspace
import Fixtures
@testable import Courseleaf

/// Opening a library that the *shipped* build created.
///
/// This release changed no persisted document format — the one storage change
/// is to `UserDefaults` preferences, covered by `EditorToolStateMigrationTests`
/// — and this is where that claim is checked rather than asserted in a commit
/// message. A package written at the shipped schema version is opened with the
/// current code and every piece of it is compared back.
@MainActor
final class LibraryUpgradeTests: XCTestCase {
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private func makeEnvironment(at root: URL) throws -> AppEnvironment {
        let name = "LibraryUpgradeTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return AppEnvironment(rootURL: root,
                              settings: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: name))),
                              entitlements: LocalEntitlementStore(),
                              pdfInspector: MinimalPDFInspector(),
                              imageInspector: ImageHeaderInspector(),
                              clock: SystemClock())
    }

    private func makeRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryUpgrade-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(base)
        return root
    }

    // MARK: The format itself

    func testTheDocumentSchemaVersionIsUnchangedFromTheShippedBuild() {
        // Pinned deliberately. A release that changes either of these numbers
        // has to change this test too, which is the point: it cannot happen by
        // accident in a release that claims to have changed no format.
        XCTAssertEqual(DocumentSchema.current, 1, "the shipped build writes schema 1")
        XCTAssertEqual(DocumentSchema.oldestReadable, 1, "and reads nothing older")
        XCTAssertTrue(DocumentSchema.isReadable(1))
        XCTAssertFalse(DocumentSchema.isReadable(2), "a future schema is refused, not guessed at")
    }

    // MARK: A library from the shipped build

    func testALibraryBuiltByTheShippedVersionOpensWithEverythingIntact() async throws {
        let root = try makeRoot()

        // --- Written the way the shipped build writes it -------------------
        let first = try makeEnvironment(at: root)
        await first.prepare()
        first.setRecognitionPaused(true)

        let course = try await first.library.createFolder(name: "Thermodynamics", parentID: nil, isCourse: true)
        let documentID = try await first.library.createNotebook(
            title: "Problem set 3", folderID: course.id, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 3)
        let session = try await first.session(for: documentID)
        let pageIDs = session.editor.document.pageIDs
        let pageID = pageIDs[1]

        let ink = PendingAsset.make(data: InterchangeTestSupport.horizontalPenStroke(y: 220, from: 60, to: 320).dataRepresentation(),
                                    mediaType: .inkDrawing, now: Date())
        session.addAsset(ink)
        let layerID = try XCTUnwrap(session.editor.page(pageID)).inkLayers[0].id
        try session.apply(.replaceInk(pageID, layerID, dataAssetID: ink.asset.id))

        let note = CanvasObject(frame: PageRect(x: 60, y: 90, width: 220, height: 30),
                                content: .text(TextContent(text: "dQ = T dS")), createdAt: Date())
        let tape = CanvasObject(frame: PageRect(x: 60, y: 300, width: 140, height: 40),
                                content: .tape(TapeContent()), createdAt: Date())
        try session.apply(.addObjects(pageID, [note, tape]))
        try session.apply(.setPageBookmark(pageIDs[2], true))
        try session.apply(.addReviewItem(ReviewItem(pageID: pageID, region: PageRect(x: 60, y: 300, width: 140, height: 40),
                                                    prompt: "Second law?", answerTapeID: tape.id, createdAt: Date())))
        try await session.flush()
        await first.closeSession(documentID)
        await first.shutdown()

        // --- The manifest on disk is the shipped format --------------------
        let manifestURL = try XCTUnwrap(try locateManifest(under: root))
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["formatVersion"] as? Int, 1,
                       "a package this build writes has to still be a version-1 package")

        // --- Opened by this build ------------------------------------------
        let second = try makeEnvironment(at: root)
        await second.prepare()
        second.setRecognitionPaused(true)

        let documents = try await second.library.documents(in: .folder(course.id))
        XCTAssertEqual(documents.map(\.title), ["Problem set 3"], "the notebook is still filed under its course")

        let reopened = try await second.session(for: documentID)
        XCTAssertEqual(reopened.editor.document.pageIDs, pageIDs, "same pages, same order")

        let page = try XCTUnwrap(reopened.editor.page(pageID))
        XCTAssertEqual(page.inkLayers[0].dataAssetID, ink.asset.id, "the ink layer still points at its blob")
        let bytes = try await reopened.assetData(ink.asset.id)
        let data = try XCTUnwrap(bytes)
        XCTAssertEqual(try PKDrawing(data: data).strokes.count, 1, "and the blob is still a readable drawing")

        XCTAssertEqual(page.objects.count, 2)
        guard case .text(let text)? = page.object(note.id)?.content else { return XCTFail("the text box is gone") }
        XCTAssertEqual(text.text, "dQ = T dS")
        XCTAssertNotNil(page.object(tape.id), "the answer tape is still there")
        XCTAssertTrue(try XCTUnwrap(reopened.editor.page(pageIDs[2])).isBookmarked, "bookmarks survive")

        let queue = try await second.library.reviewQueue(courseID: course.id)
        let item = try XCTUnwrap(queue.first { $0.documentID == documentID })
        XCTAssertEqual(item.item.prompt, "Second law?")
        XCTAssertEqual(item.item.answerTapeID, tape.id, "the review item still knows which tape covers its answer")
        XCTAssertEqual(item.courseName, "Thermodynamics")

        await second.shutdown()
    }

    func testTheEditorOpensAShippedLibraryWithoutTouchingIt() async throws {
        // Opening a notebook must not be an edit. A release that changed the
        // editor's saving path could easily rewrite every page it displayed.
        let root = try makeRoot()
        let first = try makeEnvironment(at: root)
        await first.prepare()
        first.setRecognitionPaused(true)
        let documentID = try await first.library.createNotebook(
            title: "Untouched", folderID: nil, template: .preset(.grid), pageSize: .letter,
            cover: .default, pageCount: 3)
        let session = try await first.session(for: documentID)
        try await session.flush()
        let before = session.editor.snapshot
        await first.closeSession(documentID)
        await first.shutdown()

        let second = try makeEnvironment(at: root)
        await second.prepare()
        second.setRecognitionPaused(true)
        let reopened = try await second.session(for: documentID)
        let pageID = reopened.editor.document.pageIDs[0]

        let controller = NotebookEditorViewController(session: reopened, initialPageID: pageID)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        // Let any asynchronous ink load settle.
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(controller.hasUncommittedInk, "simply looking at a page is not an edit")
        for id in reopened.editor.document.pageIDs {
            XCTAssertEqual(reopened.editor.page(id)?.inkLayers.first?.dataAssetID,
                           before.pages[id]?.inkLayers.first?.dataAssetID,
                           "opening the notebook rewrote page \(id)")
        }
        window.rootViewController = nil
        await second.shutdown()
    }

    /// The newest `manifest.json` under the library root.
    private func locateManifest(under root: URL) throws -> URL? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var found: [URL] = []
        for case let url as URL in walker where url.lastPathComponent == "manifest.json" {
            found.append(url)
        }
        return found.sorted { $0.path.count < $1.path.count }.first
    }
}
