import XCTest
import UIKit
import PencilKit
import DocumentCore
import PageGeometry
import Editing
import Workspace
import Fixtures
@testable import Courseleaf

/// Measurements of the paths this release changed, on the workloads the
/// release brief names: a dense drawing page, an image-heavy notebook and the
/// 300-page PDF fixture.
///
/// **These are simulator numbers.** A simulator has no Apple Pencil input
/// path, a different CPU and GPU, no ProMotion display and its own frame
/// pacing; nothing here is a latency benchmark and nothing here may be quoted
/// as one. What it *is* good for is catching a collapse — a path that went from
/// milliseconds to seconds — and giving the device measurement something to be
/// compared against. Every number measured is attached to the result bundle
/// along with the machine it was measured on, so the record says where it came
/// from.
///
/// The assertions are deliberately loose. A CI runner is shared and variable,
/// and a test that fails because a machine was busy teaches nobody anything;
/// these bounds are set to catch an order-of-magnitude regression.
@MainActor
final class PerformanceProfileTests: XCTestCase {
    private var roots: [URL] = []
    private var suiteNames: [String] = []
    private var windows: [UIWindow] = []
    private var lines: [String] = []

    override func setUp() {
        super.setUp()
        lines = ["## Measured on", "- host: \(Self.hostDescription)"]
    }

    override func tearDown() {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = "performance-profile"
        attachment.lifetime = .keepAlways
        add(attachment)
        for window in windows { window.rootViewController = nil }
        windows = []
        for url in roots { try? FileManager.default.removeItem(at: url) }
        roots = []
        for name in suiteNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        suiteNames = []
        super.tearDown()
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static var hostDescription: String {
        let device = UIDevice.current
        return "\(device.model), \(device.systemName) \(device.systemVersion), "
            + "\(ProcessInfo.processInfo.processorCount) cores, "
            + "simulator=\(isSimulator)"
    }

    /// Resident memory of this process, in bytes.
    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    @discardableResult
    private func record(_ what: String, _ body: () async throws -> Void) async rethrows -> Double {
        let before = residentBytes()
        let start = Date()
        try await body()
        let seconds = Date().timeIntervalSince(start)
        let after = residentBytes()
        let delta = Double(Int64(after) - Int64(before)) / 1_048_576
        lines.append(String(format: "- %@: %.3f s, resident %+.1f MiB (now %.0f MiB)",
                            what, seconds, delta, Double(after) / 1_048_576))
        return seconds
    }

    private func makeEnvironment() throws -> AppEnvironment {
        let name = "PerformanceProfileTests-\(UUID().uuidString)"
        suiteNames.append(name)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Perf-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(base)
        return AppEnvironment(rootURL: root,
                              settings: SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: name))),
                              entitlements: LocalEntitlementStore(),
                              pdfInspector: PDFKitInspector(),
                              imageInspector: ImageIOInspector(),
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

    /// A page's worth of handwriting: `count` short strokes laid out in rows.
    private func denseDrawing(strokes count: Int) -> PKDrawing {
        var all: [PKStroke] = []
        all.reserveCapacity(count)
        let ink = PKInk(.pen, color: .black)
        for index in 0..<count {
            let row = Double(index % 60)
            let column = Double(index / 60)
            let y = 40 + row * 12
            let x = 40 + column * 9
            let points = (0...6).map { step -> PKStrokePoint in
                PKStrokePoint(location: CGPoint(x: x + Double(step) * 1.2, y: y + sin(Double(step)) * 2),
                              timeOffset: Double(step) / 240, size: CGSize(width: 2, height: 2),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            all.append(PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()),
                                transform: .identity, mask: nil))
        }
        return PKDrawing(strokes: all)
    }

    // MARK: Dense drawing page

    func testDenseDrawingPageSerializesAndCommitsOffTheDrawingPath() async throws {
        executionTimeAllowance = 300
        let environment = try makeEnvironment()
        await environment.prepare()
        environment.setRecognitionPaused(true)
        let documentID = try await environment.library.createNotebook(
            title: "Dense", folderID: nil, template: .preset(.lined), pageSize: .letter,
            cover: .default, pageCount: 3)
        let session = try await environment.session(for: documentID)
        let pageID = session.editor.document.pageIDs[0]

        let drawing = denseDrawing(strokes: 2000)
        lines.append("## Dense drawing page")
        lines.append("- workload: \(drawing.strokes.count) strokes on one letter page")

        let serializer = DetachedInkSerializer()
        let encodeSeconds = await record("serialize + SHA-256 (background)") {
            _ = await serializer.encode(drawing)
        }

        let controller = makeController(session: session, pageID: pageID)
        let canvas = try XCTUnwrap(controller.canvas(for: pageID))
        controller.canvasDidBeginUsingTool(canvas)
        canvas.canvasView.drawing = drawing
        canvas.canvasViewDrawingDidChange(canvas.canvasView)

        let commitSeconds = await record("gesture end to durable save (whole barrier)") {
            controller.canvasDidEndUsingTool(canvas)
            _ = await controller.prepareForDocumentSnapshot()
        }
        XCTAssertFalse(controller.hasUncommittedInk)

        // Loose: this is a shared CI machine, and the point is to catch a path
        // that collapsed, not to police a busy runner.
        XCTAssertLessThan(encodeSeconds, 10, "serializing one page of ink should not take seconds")
        XCTAssertLessThan(commitSeconds, 20, "committing one page of ink should not take tens of seconds")
        await environment.shutdown()
    }

    private func makeController(session: any DocumentSessioning, pageID: PageID) -> NotebookEditorViewController {
        let controller = NotebookEditorViewController(session: session, initialPageID: pageID)
        present(controller)
        return controller
    }

    // MARK: The 300-page PDF

    func testTheThreeHundredPagePDFOpensWithAtMostThreeLiveCanvases() async throws {
        // Importing 300 pages and laying out an editor over them is the
        // heaviest thing in the suite; the default per-test allowance is not
        // meant for it, and a timeout here would say nothing about the code.
        executionTimeAllowance = 600
        let environment = try makeEnvironment()
        await environment.prepare()
        environment.setRecognitionPaused(true)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("Perf-pdf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        roots.append(scratch)
        let pdf = scratch.appendingPathComponent("long-300-mixed.pdf")
        try FixtureCatalog.data(named: "long-300-mixed").write(to: pdf)

        lines.append("## 300-page mixed PDF")
        lines.append(String(format: "- workload: %@ (%.1f MiB on disk)", pdf.lastPathComponent,
                            Double((try? Data(contentsOf: pdf).count) ?? 0) / 1_048_576))

        var documentID: DocumentID?
        let importSeconds = await record("import (one page per PDF page)") {
            let result = try? await environment.library.importFiles(
                [ImportRequest(sourceURL: pdf, kind: .pdf, isSecurityScoped: false)],
                destination: .newNotebook(folderID: nil, title: "Long"), progress: { _ in })
            documentID = result?.createdDocumentIDs.first
        }
        let id = try XCTUnwrap(documentID)
        let session = try await environment.session(for: id)
        XCTAssertEqual(session.editor.document.pageIDs.count, 300, "one page per PDF page")

        var controller: NotebookEditorViewController?
        let openSeconds = await record("open in the editor and lay out") {
            controller = self.makeController(session: session, pageID: session.editor.document.pageIDs[0])
        }
        let editor = try XCTUnwrap(controller)

        let scrollSeconds = await record("scroll through 30 pages") {
            for index in stride(from: 0, to: 300, by: 10) {
                editor.scrollToPage(index, animated: false)
                editor.view.layoutIfNeeded()
            }
        }

        // The bounded live-page pool is the whole point of the design, and this
        // is the one assertion here that is a real limit rather than a bound on
        // how slow a shared machine may be.
        let live = editor.livePageCanvasCount
        lines.append("- live PKCanvasView instances after scrolling: \(live)")
        XCTAssertLessThanOrEqual(live, 3, "the page pool must stay bounded however far the student scrolls")
        XCTAssertLessThan(importSeconds, 300)
        XCTAssertLessThan(openSeconds, 60)
        XCTAssertLessThan(scrollSeconds, 120)
        await environment.shutdown()
    }

    // MARK: Image-heavy notebook

    func testAnImageHeavyNotebookScrollsWithoutHoldingEveryPageLive() async throws {
        executionTimeAllowance = 300
        let environment = try makeEnvironment()
        await environment.prepare()
        environment.setRecognitionPaused(true)
        let documentID = try await environment.library.createNotebook(
            title: "Images", folderID: nil, template: .preset(.blank), pageSize: .letter,
            cover: .default, pageCount: 24)
        let session = try await environment.session(for: documentID)

        // A real JPEG-sized bitmap per page, not a 1x1 placeholder.
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 700))
        let data = renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 700))
            UIColor.white.setFill()
            for i in 0..<40 { context.fill(CGRect(x: i * 22, y: 0, width: 8, height: 700)) }
        }
        lines.append("## Image-heavy notebook")
        lines.append(String(format: "- workload: 24 pages, one %.0f KiB image each", Double(data.count) / 1024))

        for pageID in session.editor.document.pageIDs {
            let asset = PendingAsset.make(data: data, mediaType: .png, now: Date())
            session.addAsset(asset)
            let object = CanvasObject(frame: PageRect(x: 40, y: 60, width: 480, height: 380),
                                      content: .image(ImageContent(assetID: asset.asset.id)), createdAt: Date())
            try session.apply(.addObject(pageID, object, at: nil))
        }
        try await session.flush()

        let controller = makeController(session: session, pageID: session.editor.document.pageIDs[0])
        let scrollSeconds = await record("scroll through 24 image pages") {
            for index in 0..<24 {
                controller.scrollToPage(index, animated: false)
                controller.view.layoutIfNeeded()
            }
        }
        let live = controller.livePageCanvasCount
        lines.append("- live PKCanvasView instances after scrolling: \(live)")
        XCTAssertLessThanOrEqual(live, 3)
        XCTAssertLessThan(scrollSeconds, 120)
        await environment.shutdown()
    }
}
