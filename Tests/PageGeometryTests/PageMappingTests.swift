import XCTest
import DocumentCore
import Fixtures
@testable import PageGeometry

final class PageMappingTests: XCTestCase {
    // Media box Letter; crop box [36 54 540 720] (504 × 666, origin (36, 54)).
    let media = PageRect(x: 0, y: 0, width: 612, height: 792)
    let crop = PageRect(x: 36, y: 54, width: 504, height: 666)
    // The PDF user-space probe point.
    let probe = PagePoint(x: 100, y: 150)

    func mapping(_ r: PageRotation) -> PageMapping {
        PageMapping(source: PDFPageSource(assetID: AssetID(), pageIndex: 0, mediaBox: media, cropBox: crop, rotation: r))
    }
    func assertPoint(_ p: PagePoint, _ x: Double, _ y: Double, accuracy: Double = 1e-9, line: UInt = #line) {
        XCTAssertEqual(p.x, x, accuracy: accuracy, "x", line: line)
        XCTAssertEqual(p.y, y, accuracy: accuracy, "y", line: line)
    }

    // Rotate 0: X = x − cx0 = 100 − 36 = 64;  Y = cy1 − y = 720 − 150 = 570.
    func testRotate0WithCropOrigin() {
        let m = mapping(.degrees0)
        XCTAssertEqual(m.pageSize, PageSize(width: 504, height: 666))
        assertPoint(m.pagePoint(fromPDFUser: probe), 64, 570)
        // Crop corners: bottom-left of the crop (36,54) is the page's bottom-left (0, 666); top-left (36,720) is the origin.
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 36, y: 54)), 0, 666)
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 36, y: 720)), 0, 0)
    }

    // Rotate 90 (clockwise on display): X = y − cy0 = 150 − 54 = 96;  Y = x − cx0 = 100 − 36 = 64. Size swaps to 666 × 504.
    func testRotate90WithCropOrigin() {
        let m = mapping(.degrees90)
        XCTAssertEqual(m.pageSize, PageSize(width: 666, height: 504))
        assertPoint(m.pagePoint(fromPDFUser: probe), 96, 64)
        // The un-rotated bottom-left corner (36,54) becomes the displayed top-left (0,0).
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 36, y: 54)), 0, 0)
        // The un-rotated top-left (36,720) becomes the displayed top-right (666, 0).
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 36, y: 720)), 666, 0)
    }

    // Rotate 180: X = cx1 − x = 540 − 100 = 440;  Y = y − cy0 = 150 − 54 = 96.
    func testRotate180WithCropOrigin() {
        let m = mapping(.degrees180)
        XCTAssertEqual(m.pageSize, PageSize(width: 504, height: 666))
        assertPoint(m.pagePoint(fromPDFUser: probe), 440, 96)
        // The un-rotated bottom-right corner (540,54) becomes the displayed top-left.
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 540, y: 54)), 0, 0)
    }

    // Rotate 270 (counter-clockwise on display): X = cy1 − y = 720 − 150 = 570;  Y = cx1 − x = 540 − 100 = 440.
    func testRotate270WithCropOrigin() {
        let m = mapping(.degrees270)
        XCTAssertEqual(m.pageSize, PageSize(width: 666, height: 504))
        assertPoint(m.pagePoint(fromPDFUser: probe), 570, 440)
        // The un-rotated top-right corner (540,720) becomes the displayed top-left.
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 540, y: 720)), 0, 0)
        // The un-rotated top-left (36,720) becomes the displayed bottom-left (0, 504).
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 36, y: 720)), 0, 504)
    }

    func testRoundTripsWithin1e9ForEveryRotation() {
        let samples = [PagePoint(x: 100, y: 150), PagePoint(x: 36, y: 54), PagePoint(x: 540, y: 720), PagePoint(x: 123.456, y: 654.321), PagePoint(x: -10, y: 1000)]
        for r in PageRotation.allCases {
            let m = mapping(r)
            XCTAssertTrue(m.pdfUserToPage.concatenating(m.pageToPDFUser).isApproximatelyEqual(to: .identity, tolerance: 1e-9), "\(r)")
            for p in samples {
                let back = m.pdfUserPoint(fromPage: m.pagePoint(fromPDFUser: p))
                assertPoint(back, p.x, p.y)
                let forward = m.pagePoint(fromPDFUser: m.pdfUserPoint(fromPage: p))
                assertPoint(forward, p.x, p.y)
            }
            // The crop box always maps onto exactly the page bounds.
            let bounds = m.pageRect(fromPDFUser: crop)
            XCTAssertEqual(bounds.minX, 0, accuracy: 1e-9); XCTAssertEqual(bounds.minY, 0, accuracy: 1e-9)
            XCTAssertEqual(bounds.width, m.pageSize.width, accuracy: 1e-9); XCTAssertEqual(bounds.height, m.pageSize.height, accuracy: 1e-9)
        }
    }

    func testCropBoxIsIntersectedWithMediaBoxAndDisplaySizeMatchesModel() {
        let oversized = PageRect(x: -100, y: -100, width: 1000, height: 1000)
        let source = PDFPageSource(assetID: AssetID(), pageIndex: 0, mediaBox: media, cropBox: oversized, rotation: .degrees90)
        let m = PageMapping(source: source)
        XCTAssertEqual(m.cropBox, media)
        XCTAssertEqual(m.pageSize, PageSize(width: 792, height: 612))
        // A crop box that misses the media box entirely falls back to the media box.
        let disjoint = PDFPageSource(assetID: AssetID(), pageIndex: 0, mediaBox: media, cropBox: PageRect(x: 5000, y: 5000, width: 10, height: 10), rotation: .degrees0)
        XCTAssertEqual(PageMapping(source: disjoint).pageSize, PageSize(width: 612, height: 792))
        // For a well-formed source, pageSize agrees with the model's displaySize.
        for r in PageRotation.allCases {
            let s = PDFPageSource(assetID: AssetID(), pageIndex: 0, mediaBox: media, cropBox: crop, rotation: r)
            XCTAssertEqual(PageMapping(source: s).pageSize, s.displaySize)
        }
    }

    func testTemplateMappingIsPlainYFlip() {
        let m = PageMapping(templateSize: .letter)
        XCTAssertEqual(m.pageSize, .letter)
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 0, y: 792)), 0, 0)
        assertPoint(m.pagePoint(fromPDFUser: PagePoint(x: 612, y: 0)), 612, 792)
        assertPoint(m.pdfUserPoint(fromPage: PagePoint(x: 100, y: 100)), 100, 692)
    }

    // MARK: Alignment fixtures (acceptance A04/A05)

    /// The sidecar's hand-derived rectangles, the inspector's reading of the
    /// generated PDF bytes and PageMapping must all agree.
    func testAlignmentFixturesAgreeWithSidecarWithin1e9() throws {
        let sidecar = try DocumentJSON.decoder().decode(AlignmentSidecar.self, from: FixtureCatalog.alignmentSidecarData())
        XCTAssertEqual(sidecar.fixtures.count, 8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("courseleaf-align-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FixtureCatalog.writeAll(to: dir)

        for e in sidecar.fixtures {
            let url = dir.appendingPathComponent(e.file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), e.file)
            let info = try MinimalPDFInspector().inspect(fileAt: url)
            XCTAssertEqual(info.pageCount, 1, e.file)
            let page = info.pages[0]
            XCTAssertEqual(page.mediaBox, e.mediaBox, e.file)
            XCTAssertEqual(page.cropBox, e.cropBox, e.file)
            XCTAssertEqual(page.rotation.rawValue, e.rotation, e.file)

            // Mapping derived from the file as the importer would build it.
            let mapping = PageMapping(source: page.source(assetID: AssetID()))
            XCTAssertEqual(mapping.pageSize.width, e.displaySize.width, accuracy: 1e-9, e.file)
            XCTAssertEqual(mapping.pageSize.height, e.displaySize.height, accuracy: 1e-9, e.file)
            let got = mapping.pageRect(fromPDFUser: e.squareUserRect)
            XCTAssertEqual(got.minX, e.expectedPageRect.minX, accuracy: 1e-9, e.file)
            XCTAssertEqual(got.minY, e.expectedPageRect.minY, accuracy: 1e-9, e.file)
            XCTAssertEqual(got.width, e.expectedPageRect.width, accuracy: 1e-9, e.file)
            XCTAssertEqual(got.height, e.expectedPageRect.height, accuracy: 1e-9, e.file)
            XCTAssertTrue(mapping.pageBounds.contains(got), "\(e.file): square must lie inside the page")
            // And back: exporting the page-space rect returns the drawn user-space square.
            let back = mapping.pdfUserRect(fromPage: got)
            XCTAssertEqual(back.minX, e.squareUserRect.minX, accuracy: 1e-9, e.file)
            XCTAssertEqual(back.minY, e.squareUserRect.minY, accuracy: 1e-9, e.file)
        }
    }
}

final class CanvasAndExportGeometryTests: XCTestCase {
    func testCanvasMappingAppliesZoomAndOffset() {
        let c = CanvasMapping(zoomScale: 2, contentOffset: PagePoint(x: 100, y: 50))
        // page (10, 20) → (10·2 − 100, 20·2 − 50) = (−80, −10)
        let p = c.canvasPoint(fromPage: PagePoint(x: 10, y: 20))
        XCTAssertEqual(p.x, -80, accuracy: 1e-12); XCTAssertEqual(p.y, -10, accuracy: 1e-12)
        let back = c.pagePoint(fromCanvas: p)
        XCTAssertEqual(back.x, 10, accuracy: 1e-12); XCTAssertEqual(back.y, 20, accuracy: 1e-12)
        // Visible page region of a 400×300 viewport: (100..500)/2 × (50..350)/2.
        let visible = c.visiblePageRect(viewportSize: PageSize(width: 400, height: 300))
        XCTAssertEqual(visible.minX, 50, accuracy: 1e-12); XCTAssertEqual(visible.minY, 25, accuracy: 1e-12)
        XCTAssertEqual(visible.width, 200, accuracy: 1e-12); XCTAssertEqual(visible.height, 150, accuracy: 1e-12)
        // Page origin in a continuous layout shifts the result.
        let cont = CanvasMapping(zoomScale: 1, contentOffset: .zero, pageOrigin: PagePoint(x: 0, y: 800))
        XCTAssertEqual(cont.canvasPoint(fromPage: PagePoint(x: 5, y: 5)).y, 805, accuracy: 1e-12)
        // At zoom 1 with no offset, canvas == page.
        XCTAssertTrue(PageMapping(templateSize: .letter).pageToCanvas(scale: 1, offset: .zero).isIdentity)
    }

    func testSourcePageTransformPlacesRotatedPageContentAtPageOrigin() {
        let media = PageRect(x: 0, y: 0, width: 612, height: 792)
        let crop = PageRect(x: 36, y: 54, width: 504, height: 666)
        let m = PageMapping(source: PDFPageSource(assetID: AssetID(), pageIndex: 0, mediaBox: media, cropBox: crop, rotation: .degrees90))
        // Top-left-origin export context equals page space.
        let t = ExportGeometry.sourcePageTransform(m)
        XCTAssertEqual(t, m.pdfUserToPage)
        // Bottom-left-origin (PDF) context of size 666 × 504: user (100,150) → page (96,64) → (96, 504 − 64 = 440).
        let f = ExportGeometry.sourcePageTransform(m, orientation: .bottomLeftYUp)
        let p = f.apply(PagePoint(x: 100, y: 150))
        XCTAssertEqual(p.x, 96, accuracy: 1e-9); XCTAssertEqual(p.y, 440, accuracy: 1e-9)
        // Raster scale 2: page (96,64) → (192,128).
        let s = ExportGeometry.sourcePageTransform(m, scale: 2).apply(PagePoint(x: 100, y: 150))
        XCTAssertEqual(s.x, 192, accuracy: 1e-9); XCTAssertEqual(s.y, 128, accuracy: 1e-9)
    }

    func testObjectTransformMatchesCanvasObjectTransformAndFlips() {
        let obj = CanvasObject(frame: PageRect(x: 100, y: 200, width: 50, height: 20), content: .text(TextContent(text: "hi")), createdAt: Date(timeIntervalSince1970: 0))
        let t = ExportGeometry.objectTransform(obj, pageSize: .letter)
        XCTAssertEqual(t, obj.transform)
        // Unit-square corner (1,1) → page (150, 220) → flipped (150, 792 − 220 = 572).
        let flipped = ExportGeometry.objectTransform(obj, pageSize: .letter, orientation: .bottomLeftYUp).apply(PagePoint(x: 1, y: 1))
        XCTAssertEqual(flipped.x, 150, accuracy: 1e-9); XCTAssertEqual(flipped.y, 572, accuracy: 1e-9)
        let b = ExportGeometry.objectBounds(obj, pageSize: .letter, orientation: .bottomLeftYUp)
        XCTAssertEqual(b.minY, 572, accuracy: 1e-9); XCTAssertEqual(b.maxY, 592, accuracy: 1e-9)
    }

    func testTapePolicyAndCompositingBands() {
        let hidden = TapeContent(isRevealed: false), shown = TapeContent(isRevealed: true)
        XCTAssertTrue(ExportGeometry.shouldDrawTape(hidden, policy: .asShown))
        XCTAssertFalse(ExportGeometry.shouldDrawTape(shown, policy: .asShown))
        XCTAssertTrue(ExportGeometry.shouldDrawTape(shown, policy: .coverAll))
        XCTAssertFalse(ExportGeometry.shouldDrawTape(hidden, policy: .revealAll))

        let now = Date(timeIntervalSince1970: 0)
        let frame = PageRect(x: 0, y: 0, width: 10, height: 10)
        let tape = CanvasObject(frame: frame, content: .tape(hidden), createdAt: now)
        let text = CanvasObject(frame: frame, content: .text(TextContent(text: "t")), createdAt: now)
        let image = CanvasObject(frame: frame, content: .image(ImageContent(assetID: AssetID())), createdAt: now)
        let shape = CanvasObject(frame: frame, content: .shape(ShapeContent(kind: .line)), createdAt: now)
        let objects = [tape, text, image, shape]
        XCTAssertEqual(ExportGeometry.objectsBelowInk(objects).map(\.id), [image.id])
        XCTAssertEqual(ExportGeometry.objectsAboveInk(objects, tape: .asShown).map(\.id), [text.id, shape.id, tape.id], "tape last")
        XCTAssertEqual(ExportGeometry.objectsAboveInk(objects, tape: .revealAll).map(\.id), [text.id, shape.id])
    }
}
