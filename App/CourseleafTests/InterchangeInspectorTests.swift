import XCTest
import UIKit
import DocumentCore
import Fixtures
@testable import Courseleaf

/// `PDFKitInspector` and `ImageIOInspector` against the deterministic fixtures
/// (the same files `Fixtures.MinimalPDFInspector` is tested with on Linux).
final class InterchangeInspectorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try InterchangeTestSupport.makeTemporaryDirectory("InspectorTests")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ data: Data, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testPDFKitInspectorReportsTheSameBoxesAndRotationAsTheMinimalInspector() throws {
        let pdfKit = PDFKitInspector()
        let minimal = MinimalPDFInspector()
        for expectation in FixtureCatalog.alignmentExpectations {
            let url = try write(MinimalPDFWriter.write(pages: [FixtureCatalog.alignmentPage(expectation)]), expectation.file)
            let a = try pdfKit.inspect(fileAt: url)
            let b = try minimal.inspect(fileAt: url)
            XCTAssertEqual(a.pageCount, 1, expectation.label)
            XCTAssertEqual(a.pageCount, b.pageCount, expectation.label)
            XCTAssertFalse(a.isEncrypted)
            let pa = a.pages[0], pb = b.pages[0]
            assertRectsEqual(pa.mediaBox, pb.mediaBox, "\(expectation.label) media box")
            assertRectsEqual(pa.cropBox, pb.cropBox, "\(expectation.label) crop box")
            assertRectsEqual(pa.cropBox, expectation.cropBox, "\(expectation.label) sidecar crop box")
            XCTAssertEqual(pa.rotation, pb.rotation, expectation.label)
            XCTAssertEqual(pa.rotation.rawValue, expectation.rotation, expectation.label)
            XCTAssertEqual(pa.hasText, true, "\(expectation.label): PDFKit should see the label text")
            XCTAssertEqual(pa.source(assetID: AssetID()).displaySize, expectation.displaySize, expectation.label)
        }
    }

    func testPDFKitInspectorReadsOutlineTitlesTextPresenceAndImageOnlyPages() throws {
        let inspector = PDFKitInspector()
        let text = try inspector.inspect(fileAt: write(MinimalPDFWriter.write(pages: FixtureCatalog.textAndOutlinePages()), "text-and-outline.pdf"))
        XCTAssertEqual(text.pageCount, 3)
        XCTAssertEqual(text.outlineTitles, ["Chapter 1: Kinematics", "Chapter 2: Dynamics", "Chapter 3: Energy & Work"])
        XCTAssertEqual(text.pages.map(\.hasText), [true, true, true])

        let imageOnly = try inspector.inspect(fileAt: write(MinimalPDFWriter.write(pages: FixtureCatalog.imageOnlyPages()), "image-only.pdf"))
        XCTAssertEqual(imageOnly.pageCount, 1)
        XCTAssertEqual(imageOnly.pages[0].hasText, false)
        XCTAssertTrue(imageOnly.outlineTitles.isEmpty)

        let long = try inspector.inspect(fileAt: write(MinimalPDFWriter.write(pages: FixtureCatalog.longMixedPages(count: 300)), "long.pdf"))
        XCTAssertEqual(long.pageCount, 300)
        XCTAssertEqual(long.pages[1].mediaBox.size, PageSize(width: 595.276, height: 841.89))
        XCTAssertEqual(long.pages[2].mediaBox.size, PageSize(width: 792, height: 612))
    }

    func testPDFKitInspectorRejectsEncryptedGarbageAndOversizedFiles() throws {
        let encrypted = try write(MinimalPDFWriter.write(pages: FixtureCatalog.textAndOutlinePages(), markEncrypted: true), "encrypted.pdf")
        XCTAssertThrowsError(try PDFKitInspector().inspect(fileAt: encrypted)) { error in
            XCTAssertEqual(error as? PDFInspectionError, .encrypted)
        }
        let garbage = try write(FixtureCatalog.garbageData(), "garbage.pdf")
        XCTAssertThrowsError(try PDFKitInspector().inspect(fileAt: garbage)) { error in
            XCTAssertEqual(error as? PDFInspectionError, .notAPDF)
        }
        let small = try write(MinimalPDFWriter.write(pages: FixtureCatalog.textAndOutlinePages()), "small.pdf")
        let size = try FileManager.default.attributesOfItem(atPath: small.path)[.size] as! Int
        XCTAssertThrowsError(try PDFKitInspector(byteLimit: 10).inspect(fileAt: small)) { error in
            XCTAssertEqual(error as? PDFInspectionError, .tooLarge(bytes: size, limit: 10))
        }
        XCTAssertThrowsError(try PDFKitInspector().inspect(fileAt: directory.appendingPathComponent("missing.pdf")))
    }

    func testImageIOInspectorReadsMinimalPNGAndJPEGDimensions() throws {
        let inspector = ImageIOInspector()
        let png = try inspector.inspect(data: MinimalPNGWriter.sampleImage(width: 37, height: 23))
        XCTAssertEqual(png, ImageInfo(pixelWidth: 37, pixelHeight: 23, mediaType: .png))
        let header = try ImageHeaderInspector().inspect(data: MinimalPNGWriter.sampleImage(width: 37, height: 23))
        XCTAssertEqual(png, header)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let jpegData = UIGraphicsImageRenderer(size: CGSize(width: 50, height: 30), format: format)
            .jpegData(withCompressionQuality: 0.8) { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 30)) }
        XCTAssertEqual(try inspector.inspect(data: jpegData), ImageInfo(pixelWidth: 50, pixelHeight: 30, mediaType: .jpeg))

        XCTAssertThrowsError(try inspector.inspect(data: Data("not an image at all".utf8))) { error in
            XCTAssertEqual(error as? ImageInspectionError, .unsupported)
        }
        XCTAssertThrowsError(try inspector.inspect(data: MinimalPNGWriter.sampleImage(width: 4, height: 4).prefix(20))) { error in
            XCTAssertNotNil(error as? ImageInspectionError)
        }
    }

    private func assertRectsEqual(_ a: PageRect, _ b: PageRect, _ label: String, accuracy: Double = 1e-6) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, label)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, label)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, label)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, label)
    }
}
