import XCTest
import CoreGraphics
import PDFKit
import UIKit
import DocumentCore
import PageGeometry
import Fixtures
@testable import Courseleaf

/// Export evidence for acceptance A05 (exported geometry matches page space
/// within one PDF point) and A12 (source text stays searchable), plus the tape
/// export policy. Everything asserted here is externally observable: bytes on
/// disk, PDFKit's reading of them, and sampled pixels of the rendered page.
///
/// These run on the iPad simulator in CI (`app-ios-simulator`), because they
/// need PDFKit and CoreGraphics. The portable half of the same guarantee lives
/// in `PageGeometryTests` on Linux.
final class InterchangeExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try InterchangeTestSupport.makeTemporaryDirectory("InterchangeExport")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func export(_ source: InMemoryContentSource, options: ExportOptions, name: String) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        try await PDFExporter(source: source).export(options: options, to: url) { _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "exporter wrote no file")
        return url
    }

    // MARK: A05 — an app object lands where page space says it should

    func testExportPlacesAnObjectWithinOnePointOfItsPageRect() async throws {
        // A 20 pt black square at a known page rect on a plain Letter page.
        let square = PageRect(x: 120, y: 260, width: 20, height: 20)
        let page = InterchangeTestSupport.page(size: .letter, background: .template(.blank),
                                               objects: [InterchangeTestSupport.blackSquare(at: square)])
        let (_, source) = InterchangeTestSupport.makeDocument(pages: [page], assets: [])
        let url = try await export(source, options: ExportOptions(format: .pdf), name: "object.pdf")

        // The exported media box is the page size.
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 612, accuracy: 0.01)
        XCTAssertEqual(bounds.height, 792, accuracy: 0.01)

        let pixels = try PixelSampler.rasterizePDF(at: url, pageIndex: 0, scale: 4)
        // Dark inside.
        XCTAssertLessThan(pixels.luminance(x: square.midX, y: square.midY), 0.25, "square centre should be black")
        // Light one point outside every edge; dark one point inside every edge.
        // Together these bound each edge to within 1 pt of the page-space rect.
        let inset = 1.0
        for (label, outside, inside) in [
            ("left",   PagePoint(x: square.minX - inset, y: square.midY), PagePoint(x: square.minX + inset, y: square.midY)),
            ("right",  PagePoint(x: square.maxX + inset, y: square.midY), PagePoint(x: square.maxX - inset, y: square.midY)),
            ("top",    PagePoint(x: square.midX, y: square.minY - inset), PagePoint(x: square.midX, y: square.minY + inset)),
            ("bottom", PagePoint(x: square.midX, y: square.maxY + inset), PagePoint(x: square.midX, y: square.maxY - inset)),
        ] {
            XCTAssertGreaterThan(pixels.luminance(x: outside.x, y: outside.y), 0.75, "\(label) edge bled outwards past 1 pt")
            XCTAssertLessThan(pixels.luminance(x: inside.x, y: inside.y), 0.25, "\(label) edge fell short by more than 1 pt")
        }
    }

    // MARK: A04/A05 — rotated and cropped source pages composite at the right place

    func testExportKeepsSourcePDFSquareAtItsExpectedPageRectForEveryRotationAndCrop() async throws {
        for expectation in FixtureCatalog.alignmentExpectations {
            let bytes = try FixtureCatalog.data(named: expectation.file.replacingOccurrences(of: ".pdf", with: ""))
            let asset = PendingAsset.make(data: bytes, mediaType: .pdf, originalFileName: expectation.file,
                                          pageCount: 1, now: InterchangeTestSupport.fixedDate)
            let rotation = try XCTUnwrap(PageRotation(degrees: expectation.rotation))
            let pdfSource = PDFPageSource(assetID: asset.asset.id, pageIndex: 0, mediaBox: expectation.mediaBox,
                                          cropBox: expectation.cropBox, rotation: rotation)
            let page = InterchangeTestSupport.page(size: expectation.displaySize, background: .pdf(pdfSource))
            let (_, source) = InterchangeTestSupport.makeDocument(pages: [page], assets: [asset])

            let url = try await export(source, options: ExportOptions(format: .pdf),
                                       name: "aligned-\(expectation.rotation)-\(expectation.file)")
            let document = try XCTUnwrap(PDFDocument(url: url))
            let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, expectation.displaySize.width, accuracy: 0.01, expectation.label)
            XCTAssertEqual(bounds.height, expectation.displaySize.height, accuracy: 0.01, expectation.label)

            // The fixture draws one filled square; the sidecar says where page
            // space puts it. The exported page must agree.
            let target = expectation.expectedPageRect
            let pixels = try PixelSampler.rasterizePDF(at: url, pageIndex: 0, scale: 4)
            XCTAssertLessThan(pixels.luminance(x: target.midX, y: target.midY), 0.35,
                              "\(expectation.label): source square missing at \(target)")
            // 3 pt outside the square is page background, so the square has not
            // drifted. (3 pt rather than 1 pt because the fixture also strokes
            // the crop box and prints labels elsewhere on the page.)
            XCTAssertGreaterThan(pixels.luminance(x: target.midX, y: target.maxY + 3), 0.65,
                                 "\(expectation.label): ink below the square where the page should be blank")
        }
    }

    // MARK: A12 — source text survives export

    func testExportKeepsSourcePDFTextSearchable() async throws {
        let bytes = try FixtureCatalog.data(named: "text-and-outline")
        let asset = PendingAsset.make(data: bytes, mediaType: .pdf, originalFileName: "text-and-outline.pdf",
                                      pageCount: 3, now: InterchangeTestSupport.fixedDate)
        let pages = (0..<3).map { index -> Page in
            let pdfSource = PDFPageSource(assetID: asset.asset.id, pageIndex: index,
                                          mediaBox: FixtureCatalog.letter, cropBox: FixtureCatalog.letter, rotation: .degrees0)
            return InterchangeTestSupport.page(size: .letter, background: .pdf(pdfSource))
        }
        let (_, source) = InterchangeTestSupport.makeDocument(pages: pages, assets: [asset])

        let url = try await export(source, options: ExportOptions(format: .pdf, preserveSourceVectors: true), name: "text.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 3)
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(text.contains("Kinematics"), "source text was rasterized away; got: \(text.prefix(200))")
        XCTAssertTrue(text.contains("displacement"), "body text missing from the export")
        // PDFKit's own search finds it, which is what "searchable" means to a reader.
        XCTAssertFalse(document.findString("Dynamics", withOptions: [.caseInsensitive]).isEmpty)
    }

    func testExportingASubsetOfPagesKeepsOrderAndCount() async throws {
        let squares = [PageRect(x: 40, y: 40, width: 20, height: 20),
                       PageRect(x: 80, y: 80, width: 20, height: 20),
                       PageRect(x: 120, y: 120, width: 20, height: 20)]
        let pages = squares.map { InterchangeTestSupport.page(size: .letter, background: .template(.blank),
                                                              objects: [InterchangeTestSupport.blackSquare(at: $0)]) }
        let (_, source) = InterchangeTestSupport.makeDocument(pages: pages, assets: [])

        let url = try await export(source, options: ExportOptions(format: .pdf, pageIDs: [pages[2].id, pages[0].id]), name: "subset.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        // Selected pages export in document order, not in the order given.
        let first = try PixelSampler.rasterizePDF(at: url, pageIndex: 0, scale: 4)
        XCTAssertLessThan(first.luminance(x: squares[0].midX, y: squares[0].midY), 0.25)
        let second = try PixelSampler.rasterizePDF(at: url, pageIndex: 1, scale: 4)
        XCTAssertLessThan(second.luminance(x: squares[2].midX, y: squares[2].midY), 0.25)
    }

    // MARK: Tape export policy

    func testTapeExportPolicyDecidesWhetherAnswersAreCovered() async throws {
        let answer = PageRect(x: 150, y: 300, width: 60, height: 30)
        let tape = CanvasObject(frame: answer, content: .tape(TapeContent(color: RGBAColor(hex: "#202020")!, isRevealed: false)),
                                createdAt: InterchangeTestSupport.fixedDate)
        let page = InterchangeTestSupport.page(size: .letter, background: .template(.blank), objects: [tape])
        let (_, source) = InterchangeTestSupport.makeDocument(pages: [page], assets: [])

        // Hidden tape is drawn as shown, and drawn when covering everything.
        for policy in [TapeExportPolicy.asShown, .coverAll] {
            let url = try await export(source, options: ExportOptions(format: .pdf, tape: policy), name: "tape-\(policy.rawValue).pdf")
            let pixels = try PixelSampler.rasterizePDF(at: url, pageIndex: 0, scale: 4)
            XCTAssertLessThan(pixels.luminance(x: answer.midX, y: answer.midY), 0.4, "\(policy.rawValue) should cover the answer")
        }
        // Revealing omits it, so the page shows through.
        let revealed = try await export(source, options: ExportOptions(format: .pdf, tape: .revealAll), name: "tape-reveal.pdf")
        let pixels = try PixelSampler.rasterizePDF(at: revealed, pageIndex: 0, scale: 4)
        XCTAssertGreaterThan(pixels.luminance(x: answer.midX, y: answer.midY), 0.7, "revealAll should omit the tape")

        // A tape the student already revealed is omitted under .asShown but drawn under .coverAll.
        var revealedTape = tape
        revealedTape.content = .tape(TapeContent(color: RGBAColor(hex: "#202020")!, isRevealed: true))
        let shownPage = InterchangeTestSupport.page(size: .letter, background: .template(.blank), objects: [revealedTape])
        let (_, shownSource) = InterchangeTestSupport.makeDocument(pages: [shownPage], assets: [])
        let asShown = try await export(shownSource, options: ExportOptions(format: .pdf, tape: .asShown), name: "tape-revealed-asshown.pdf")
        XCTAssertGreaterThan(try PixelSampler.rasterizePDF(at: asShown, pageIndex: 0, scale: 4).luminance(x: answer.midX, y: answer.midY), 0.7)
        let coverAll = try await export(shownSource, options: ExportOptions(format: .pdf, tape: .coverAll), name: "tape-revealed-coverall.pdf")
        XCTAssertLessThan(try PixelSampler.rasterizePDF(at: coverAll, pageIndex: 0, scale: 4).luminance(x: answer.midX, y: answer.midY), 0.4)
    }

    // MARK: Ink

    func testInkIsCompositedAtItsPageCoordinates() async throws {
        // One horizontal stroke across the middle of the page.
        let drawing = InterchangeTestSupport.horizontalPenStroke(y: 400, from: 100, to: 300, width: 10)
        let inkAsset = PendingAsset.make(data: drawing.dataRepresentation(), mediaType: .inkDrawing,
                                         now: InterchangeTestSupport.fixedDate)
        let layer = InkLayer(engine: .pencilKit, dataAssetID: inkAsset.asset.id)
        let page = InterchangeTestSupport.page(size: .letter, background: .template(.blank), inkLayers: [layer])
        let (_, source) = InterchangeTestSupport.makeDocument(pages: [page], assets: [inkAsset])

        let url = try await export(source, options: ExportOptions(format: .pdf, inkRasterScale: 3), name: "ink.pdf")
        let pixels = try PixelSampler.rasterizePDF(at: url, pageIndex: 0, scale: 4)
        XCTAssertLessThan(pixels.minimumLuminance(x: 200, y: 400, radiusPixels: 3), 0.4, "stroke missing at its page position")
        XCTAssertGreaterThan(pixels.luminance(x: 200, y: 360), 0.8, "ink drawn far from where it was made")
        XCTAssertGreaterThan(pixels.luminance(x: 450, y: 400), 0.8, "stroke extended past its end point")
    }
}
