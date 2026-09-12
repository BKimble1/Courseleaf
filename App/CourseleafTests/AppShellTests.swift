import XCTest
import SwiftUI
import PencilKit
import DocumentCore
import PageGeometry
import Workspace
import Fixtures
@testable import Courseleaf

/// Tests for the SwiftUI shell: the environment, the settings store, the
/// library view model against a real `LibraryService`, and the design-system
/// geometry helpers. Everything asserted is externally observable state
/// (files on disk, defaults, returned geometry), never an internal branch.
final class AppShellTests: XCTestCase {
    private var roots: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeTemporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppShellTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url.deletingLastPathComponent())
        return url
    }

    private func makeScratchDefaults() throws -> UserDefaults {
        let name = "AppShellTests-\(UUID().uuidString)"
        suiteNames.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    /// An environment that uses the portable fixture inspectors, so the tests
    /// never depend on PDFKit or ImageIO behaviour.
    @MainActor
    private func makeEnvironment(root: URL, defaults: UserDefaults) -> AppEnvironment {
        AppEnvironment(rootURL: root,
                       settings: SettingsStore(defaults: defaults),
                       entitlements: LocalEntitlementStore(),
                       pdfInspector: MinimalPDFInspector(),
                       imageInspector: ImageHeaderInspector(),
                       clock: SystemClock())
    }

    // MARK: AppEnvironment

    @MainActor
    func testEnvironmentOpensALibraryAtATemporaryRoot() async throws {
        let root = try makeTemporaryRoot()
        let environment = makeEnvironment(root: root, defaults: try makeScratchDefaults())

        XCTAssertEqual(environment.rootURL.standardizedFileURL, root.standardizedFileURL)
        XCTAssertFalse(environment.didOpenLibrary)

        await environment.prepare()
        XCTAssertTrue(environment.didOpenLibrary, "prepare() must open the library before any screen uses it")

        // The library layout exists on disk and the manifest is readable.
        let manifest = try await environment.library.manifest()
        XCTAssertTrue(manifest.folders.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))

        await environment.shutdown()
    }

    @MainActor
    func testEnvironmentDefaultLibraryRootIsInsideApplicationSupport() {
        let url = AppEnvironment.defaultLibraryRoot()
        XCTAssertEqual(url.lastPathComponent, "Library")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Courseleaf")
        XCTAssertTrue(url.path.contains("Application Support"), "library root must live in Application Support, got \(url.path)")
    }

    @MainActor
    func testEnvironmentReportsServiceFailuresAsAnAlertInsteadOfCrashing() async throws {
        let root = try makeTemporaryRoot()
        let environment = makeEnvironment(root: root, defaults: try makeScratchDefaults())
        await environment.prepare()

        let missing = DocumentID()
        let session = await environment.perform("Could not open") { try await environment.session(for: missing) }
        XCTAssertNil(session)
        XCTAssertNotNil(environment.alert, "a failed service call must surface an alert")
        XCTAssertEqual(environment.alert?.title, "Could not open")

        await environment.shutdown()
    }

    // MARK: SettingsStore

    @MainActor
    func testSettingsDefaults() throws {
        let settings = SettingsStore(defaults: try makeScratchDefaults())
        XCTAssertTrue(settings.pencilOnly, "Pencil-only drawing is the shipped default")
        XCTAssertFalse(settings.fingerDrawing)
        XCTAssertFalse(settings.leftHanded)
        XCTAssertEqual(settings.defaultPaperKind, .lined)
        XCTAssertEqual(settings.defaultPageSize, .letter)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.hasSeenOnboarding)
        XCTAssertEqual(settings.defaultTemplate.kind, .lined)
        XCTAssertEqual(settings.editorInput.drawingPolicy, .pencilOnly)
    }

    @MainActor
    func testSettingsPersistAcrossStores() throws {
        let defaults = try makeScratchDefaults()
        let first = SettingsStore(defaults: defaults)
        first.pencilOnly = false
        first.fingerDrawing = true
        first.leftHanded = true
        first.defaultPaperKind = .cornell
        first.defaultPageSize = .a4
        first.appearance = .dark
        first.hasSeenOnboarding = true

        let second = SettingsStore(defaults: defaults)
        XCTAssertFalse(second.pencilOnly)
        XCTAssertTrue(second.fingerDrawing)
        XCTAssertTrue(second.leftHanded)
        XCTAssertEqual(second.defaultPaperKind, .cornell)
        XCTAssertEqual(second.defaultPageSize, .a4)
        XCTAssertEqual(second.appearance, .dark)
        XCTAssertTrue(second.hasSeenOnboarding)
        XCTAssertEqual(second.defaultTemplate.kind, .cornell)
        XCTAssertEqual(second.editorInput.drawingPolicy, .anyInput, "finger drawing must reach the canvas policy")
    }

    @MainActor
    func testSettingsResetRestoresTheShippedDefaults() throws {
        let settings = SettingsStore(defaults: try makeScratchDefaults())
        settings.pencilOnly = false
        settings.defaultPaperKind = .grid
        settings.resetToDefaults()
        XCTAssertTrue(settings.pencilOnly)
        XCTAssertEqual(settings.defaultPaperKind, .lined)
    }

    // MARK: Library view model against the real service

    @MainActor
    func testLibraryViewModelListsANotebookItCreated() async throws {
        let root = try makeTemporaryRoot()
        let environment = makeEnvironment(root: root, defaults: try makeScratchDefaults())
        await environment.prepare()

        let model = LibraryViewModel()
        model.configure(env: environment)

        let id = await model.createNotebook(title: "Thermodynamics", folderID: nil, template: .preset(.grid),
                                            pageSize: .letter, cover: CoverStyle(palette: .ocean, pattern: .bands),
                                            pageCount: 3)
        let documentID = try XCTUnwrap(id, "creating a notebook must succeed against a fresh library")

        await model.load(scope: .folder(nil))
        let listed = try XCTUnwrap(model.documents.first { $0.id == documentID })
        XCTAssertEqual(listed.title, "Thermodynamics")
        XCTAssertEqual(listed.pageCount, 3)
        XCTAssertEqual(listed.cover.palette, .ocean)
        XCTAssertNil(environment.alert)

        // Sorting reorders the same set of documents, never drops one.
        model.sortOrder = .title
        XCTAssertEqual(Set(model.sortedDocuments.map(\.id)), Set(model.documents.map(\.id)))
        XCTAssertEqual(model.sortedDocuments.count, model.documents.count)

        await environment.shutdown()
    }

    @MainActor
    func testLibraryViewModelCreatesAFolderAndAQuickNote() async throws {
        let root = try makeTemporaryRoot()
        let environment = makeEnvironment(root: root, defaults: try makeScratchDefaults())
        await environment.prepare()

        let model = LibraryViewModel()
        model.configure(env: environment)

        let course = try XCTUnwrap(await model.createFolder(name: "Analysis", parentID: nil, isCourse: true))
        XCTAssertTrue(course.isCourse)

        let noteID = try XCTUnwrap(await model.createQuickNote(template: .preset(.blank)))
        await model.load(scope: .inbox)
        XCTAssertTrue(model.documents.contains { $0.id == noteID }, "a quick note lands in the inbox until it is filed")

        await model.load(scope: .folder(nil))
        XCTAssertTrue(model.folders.contains { $0.folder.id == course.id })

        await environment.shutdown()
    }

    // MARK: Design system geometry

    @MainActor
    func testEveryCoverCombinationProducesGeometry() {
        for palette in CoverStyle.Palette.allCases {
            for pattern in CoverStyle.Pattern.allCases {
                let style = CoverStyle(palette: palette, pattern: pattern)
                let marks = CoverArt.marks(for: style)
                XCTAssertFalse(marks.isEmpty, "\(palette)/\(pattern) produced no marks")
                guard let first = marks.first, case .fill = first else {
                    return XCTFail("\(palette)/\(pattern) must start with the background fill")
                }
                // The spine is always drawn, whatever the pattern.
                let hasSpine = marks.contains { mark in
                    if case .rect(_, _, let width, let height, _) = mark {
                        return abs(width - CoverArt.spineWidth) < 0.0001 && abs(height - 1) < 0.0001
                    }
                    return false
                }
                XCTAssertTrue(hasSpine, "\(palette)/\(pattern) is missing its spine")
            }
        }
        XCTAssertEqual(CoverArt.allStyles.count, CoverStyle.Palette.allCases.count * CoverStyle.Pattern.allCases.count)
    }

    @MainActor
    func testCoverPalettesAreDistinct() {
        let bases = CoverStyle.Palette.allCases.map { Palette.tones(for: $0).base.hexString }
        XCTAssertEqual(Set(bases).count, bases.count, "each cover palette needs its own colour")
    }

    @MainActor
    func testTemplatePreviewGeometryMatchesThePageGeometryModule() {
        for kind in PaperKind.allCases {
            let template = PaperTemplate.preset(kind)
            let primitives = PagePreviewGeometry.primitives(for: template, size: .letter)
            XCTAssertFalse(primitives.isEmpty, "\(kind) produced no primitives")
            XCTAssertEqual(primitives.count, TemplateGeometry.primitives(for: template, size: .letter).count,
                           "the preview must draw exactly what the page geometry defines for \(kind)")
            if kind != .blank {
                XCTAssertGreaterThan(primitives.count, 1, "\(kind) must draw more than the paper rectangle")
            }
        }
    }

    @MainActor
    func testTemplatePreviewFitsThePageIntoItsBox() {
        let scale = PagePreviewGeometry.fitScale(pageSize: .letter, in: CGSize(width: 306, height: 396))
        XCTAssertEqual(scale, 0.5, accuracy: 0.0001)
        XCTAssertEqual(PagePreviewGeometry.fitScale(pageSize: .letter, in: .zero), 1, "an empty box must not divide by zero")
    }

    // MARK: Small shell helpers

    @MainActor
    func testPageSizeChoiceRoundTrips() {
        XCTAssertEqual(PageSizeChoice(pageSize: .letter), .letter)
        XCTAssertEqual(PageSizeChoice(pageSize: .a4), .a4)
        XCTAssertEqual(PageSizeChoice.a4.pageSize, .a4)
    }

    @MainActor
    func testSaveStatusTextSeparatesEveryState() {
        XCTAssertEqual(SaveStatusText.title(.unsaved(pendingChanges: 2)), "Unsaved changes")
        XCTAssertEqual(SaveStatusText.title(.saving), "Saving…")
        XCTAssertEqual(SaveStatusText.title(.saved(at: Date(), latency: 0.1)), "Saved")
        XCTAssertTrue(SaveStatusText.title(.failed(message: "disk full", retryable: true)).contains("disk full"))
        XCTAssertTrue(SaveStatusText.spoken(.failed(message: "disk full", retryable: true)).contains("retry"))
    }

    @MainActor
    func testWorkspaceErrorsAreExplainedInPlainEnglish() {
        let text = AppErrorText.message(for: WorkspaceError.documentNeedsNewerApp(DocumentID(), schemaVersion: 9))
        XCTAssertTrue(text.contains("newer version"))
        XCTAssertTrue(AppErrorText.isRetryable(WorkspaceError.storage("disk full")))
        XCTAssertFalse(AppErrorText.isRetryable(WorkspaceError.cancelled))
    }

    @MainActor
    func testSidebarSelectionMapsToLibraryScopes() {
        XCTAssertEqual(AppRouter.SidebarSelection.recents.libraryScope, .recents)
        XCTAssertEqual(AppRouter.SidebarSelection.favorites.libraryScope, .favorites)
        XCTAssertEqual(AppRouter.SidebarSelection.inbox.libraryScope, .inbox)
        XCTAssertEqual(AppRouter.SidebarSelection.trash.libraryScope, .trash)
        XCTAssertNil(AppRouter.SidebarSelection.review.libraryScope)
        let folderID = FolderID()
        XCTAssertEqual(AppRouter.SidebarSelection.folder(folderID).destinationFolderID, folderID)
    }

    @MainActor
    func testRouterOpensOneNotebookAtATime() {
        let router = AppRouter()
        let first = DocumentID()
        let second = DocumentID()
        router.openNotebook(first, pageIndex: 3)
        XCTAssertEqual(router.openNotebookID, first)
        router.openNotebook(second)
        XCTAssertEqual(router.path.count, 1)
        XCTAssertEqual(router.openNotebookID, second)
        router.closeNotebook()
        XCTAssertNil(router.openNotebookID)
    }
}
