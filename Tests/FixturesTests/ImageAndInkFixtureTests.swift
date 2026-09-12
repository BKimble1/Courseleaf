import XCTest
import DocumentCore
@testable import Fixtures

final class ImageFixtureTests: XCTestCase {
    func testPNGWriterOutputIsParsedByHeaderInspector() throws {
        let png = MinimalPNGWriter.write(width: 5, height: 3, rgba: [UInt8](repeating: 0x80, count: 5 * 3 * 4))
        let info = try ImageHeaderInspector().inspect(data: png)
        XCTAssertEqual(info, ImageInfo(pixelWidth: 5, pixelHeight: 3, mediaType: .png))
        // Structure: signature, IHDR(13), IDAT, IEND with correct CRCs.
        let b = [UInt8](png)
        XCTAssertEqual(Array(b[0..<8]), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(Array(b[12..<16]), Array("IHDR".utf8))
        let ihdrCRC = UInt32(b[29]) << 24 | UInt32(b[30]) << 16 | UInt32(b[31]) << 8 | UInt32(b[32])
        XCTAssertEqual(ihdrCRC, CRC32.checksum(Data(b[12..<29])))
        XCTAssertEqual(Array(b.suffix(12)), [0, 0, 0, 0] + Array("IEND".utf8) + [0xAE, 0x42, 0x60, 0x82])
        // IDAT payload: zlib header 78 01, one final stored block of 3 × (1 + 20) = 63 bytes.
        let idatLength = Int(b[33]) << 24 | Int(b[34]) << 16 | Int(b[35]) << 8 | Int(b[36])
        XCTAssertEqual(Array(b[37..<41]), Array("IDAT".utf8))
        XCTAssertEqual(idatLength, 2 + 5 + 63 + 4)
        XCTAssertEqual(Array(b[41..<48]), [0x78, 0x01, 0x01, 63, 0, 0xC0, 0xFF])
        // Adler-32 of 63 bytes: 3 zero filter bytes + 60 × 0x80.
        let raw = (0..<3).flatMap { _ in [UInt8(0)] + [UInt8](repeating: 0x80, count: 20) }
        let adler = MinimalPNGWriter.adler32(raw)
        XCTAssertEqual(Array(b[(41 + 7 + 63)..<(41 + 7 + 63 + 4)]), MinimalPNGWriter.be32(adler))
        // Deterministic.
        XCTAssertEqual(MinimalPNGWriter.sampleImage(width: 32, height: 24), MinimalPNGWriter.sampleImage(width: 32, height: 24))
        XCTAssertEqual(try ImageHeaderInspector().inspect(data: try FixtureCatalog.data(named: "sample-png")),
                       ImageInfo(pixelWidth: 32, pixelHeight: 24, mediaType: .png))
    }

    func testLargePNGUsesMultipleStoredBlocks() throws {
        // 200 × 100 RGBA = 80 100 raw bytes → two stored blocks (65535 + 14565).
        let png = MinimalPNGWriter.write(width: 200, height: 100, rgba: [UInt8](repeating: 7, count: 200 * 100 * 4))
        let info = try ImageHeaderInspector().inspect(data: png)
        XCTAssertEqual(info.pixelWidth, 200); XCTAssertEqual(info.pixelHeight, 100)
        let b = [UInt8](png)
        // First block header (non-final, LEN 65535).
        XCTAssertEqual(Array(b[43..<48]), [0x00, 0xFF, 0xFF, 0x00, 0x00])
        // Second block header (final, LEN 14565 = 0x38E5).
        let second = 43 + 5 + 65535
        XCTAssertEqual(Array(b[second..<second + 5]), [0x01, 0xE5, 0x38, 0x1A, 0xC7])
    }

    func testJPEGHeadersAreParsedAndOthersRejected() throws {
        // SOI, APP0 (length 16), SOF0: length 17, precision 8, height 0x0100 = 256, width 0x0140 = 320, 3 components.
        var jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10] + [UInt8](repeating: 0, count: 14)
        jpeg += [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0x00, 0x01, 0x40, 0x03] + [UInt8](repeating: 0, count: 9)
        jpeg += [0xFF, 0xD9]
        XCTAssertEqual(try ImageHeaderInspector().inspect(data: Data(jpeg)), ImageInfo(pixelWidth: 320, pixelHeight: 256, mediaType: .jpeg))
        // Progressive (SOF2) with a fill byte before the marker.
        var progressive: [UInt8] = [0xFF, 0xD8, 0xFF, 0xFF, 0xC2, 0x00, 0x0B, 0x08, 0x00, 0x10, 0x00, 0x20, 0x01, 0, 0, 0]
        progressive += [0xFF, 0xD9]
        XCTAssertEqual(try ImageHeaderInspector().inspect(data: Data(progressive)), ImageInfo(pixelWidth: 32, pixelHeight: 16, mediaType: .jpeg))
        // JPEG with no frame header → corrupt.
        XCTAssertThrowsError(try ImageHeaderInspector().inspect(data: Data([0xFF, 0xD8, 0xFF, 0xD9]))) { XCTAssertEqual($0 as? ImageInspectionError, .corrupt) }
        // Truncated PNG → corrupt.
        XCTAssertThrowsError(try ImageHeaderInspector().inspect(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]))) {
            XCTAssertEqual($0 as? ImageInspectionError, .corrupt)
        }
        // GIF, PDF bytes, empty → unsupported.
        XCTAssertThrowsError(try ImageHeaderInspector().inspect(data: Data("GIF89a".utf8))) { XCTAssertEqual($0 as? ImageInspectionError, .unsupported) }
        XCTAssertThrowsError(try ImageHeaderInspector().inspect(data: FixtureCatalog.truncatedData())) { XCTAssertEqual($0 as? ImageInspectionError, .unsupported) }
        XCTAssertThrowsError(try ImageHeaderInspector().inspect(data: Data())) { XCTAssertEqual($0 as? ImageInspectionError, .unsupported) }
    }
}

final class InkFixtureTests: XCTestCase {
    func testDenseDrawingHasExactlyNStrokesAndIsDeterministic() throws {
        for n in [0, 1, 7, 100, 500] {
            let d = InkFixtures.denseDrawing(strokeCount: n, seed: 42)
            XCTAssertEqual(d.strokeCount, n)
            XCTAssertEqual(d, InkFixtures.denseDrawing(strokeCount: n, seed: 42))
            let bytes = try ReferenceInkEngine().encode(d)
            XCTAssertEqual(bytes, try ReferenceInkEngine().encode(InkFixtures.denseDrawing(strokeCount: n, seed: 42)))
            XCTAssertEqual(try ReferenceInkEngine().decode(bytes), d)
            if n > 0 {
                XCTAssertTrue(PageRect(origin: .zero, size: .letter).contains(d.bounds), "\(n) strokes: \(d.bounds)")
                XCTAssertTrue(d.strokes.allSatisfy { $0.points.count == 8 && $0.mask == nil })
            }
        }
        XCTAssertNotEqual(InkFixtures.denseDrawing(strokeCount: 20, seed: 1), InkFixtures.denseDrawing(strokeCount: 20, seed: 2))
        // Strokes are spread over the page, not stacked: the 500-stroke drawing covers most of it.
        let dense = InkFixtures.denseDrawing(strokeCount: 500, seed: 7)
        XCTAssertGreaterThan(dense.bounds.width, 500); XCTAssertGreaterThan(dense.bounds.height, 700)
        // Catalog fixture bytes are stable across generations.
        XCTAssertEqual(try FixtureCatalog.data(named: "dense-ink-500"), try FixtureCatalog.data(named: "dense-ink-500"))
    }

    func testPartiallyErasedSampleKeepsMasksThroughTransformAndRoundTrip() throws {
        let d = InkFixtures.partiallyErasedSample()
        XCTAssertEqual(d, InkFixtures.partiallyErasedSample())
        XCTAssertEqual(d.strokeCount, 3)
        XCTAssertNil(d.strokes[0].mask)
        XCTAssertNotNil(d.strokes[1].mask)
        XCTAssertNotNil(d.strokes[2].mask)
        // The erased half of stroke 1 (x ≥ 200) is not visible; the left half is.
        let visible1 = d.strokes[1].visiblePagePoints
        XCTAssertFalse(visible1.isEmpty)
        XCTAssertTrue(visible1.allSatisfy { $0.x < 200 })
        XCTAssertEqual(visible1.count, 10)
        // Stroke 2 was moved down 100 pt after erasing: its visible points sit at y = 400 and skip the erased span.
        let visible2 = d.strokes[2].visiblePagePoints
        XCTAssertTrue(visible2.allSatisfy { $0.y == 400 })
        XCTAssertFalse(visible2.contains { $0.x >= 140 && $0.x <= 220 })
        XCTAssertLessThan(visible2.count, d.strokes[2].points.count)
        // Recoloring keeps the mask and the same visible geometry.
        let recolored = d.recoloringStrokes([1, 2], to: .white)
        XCTAssertEqual(recolored.strokes[1].visiblePagePoints, visible1)
        XCTAssertEqual(recolored.strokes[2].visiblePagePoints, visible2)
        // Serialization round trip.
        let engine = ReferenceInkEngine()
        XCTAssertEqual(try engine.decode(try engine.encode(d)), d)
    }
}

final class FixtureCatalogTests: XCTestCase {
    func testCatalogWritesEveryNamedFixtureUnderTwoMegabytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("courseleaf-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try FixtureCatalog.writeAll(to: dir)
        XCTAssertEqual(urls.count, FixtureCatalog.all.count)
        let expected = ["alignment-0-0x0.pdf", "alignment-0-36x54.pdf", "alignment-90-0x0.pdf", "alignment-90-36x54.pdf",
                        "alignment-180-0x0.pdf", "alignment-180-36x54.pdf", "alignment-270-0x0.pdf", "alignment-270-36x54.pdf",
                        "alignment.json", "long-300-mixed.pdf", "text-and-outline.pdf", "image-only.pdf",
                        "malformed/truncated.pdf", "malformed/garbage.pdf", "malformed/bad-xref.pdf", "sample.png"]
        var total = 0
        for rel in expected {
            let url = dir.appendingPathComponent(rel)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), rel)
        }
        for url in urls {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
            XCTAssertGreaterThan(size, 0, url.lastPathComponent)
            total += size
        }
        XCTAssertLessThan(total, 2 * 1024 * 1024)
        // Every PDF except the malformed ones validates and inspects; names are unique.
        XCTAssertEqual(Set(FixtureCatalog.all.map(\.name)).count, FixtureCatalog.all.count)
        for f in FixtureCatalog.all where f.relativePath.hasSuffix(".pdf") && !f.relativePath.hasPrefix("malformed/") {
            let data = try Data(contentsOf: dir.appendingPathComponent(f.relativePath))
            XCTAssertNoThrow(try PDFXrefChecker.validate(data), f.name)
            XCTAssertNoThrow(try MinimalPDFInspector().inspect(data: data), f.name)
        }
        // Generation is byte-for-byte deterministic.
        for f in FixtureCatalog.all {
            XCTAssertEqual(try f.generate(), try Data(contentsOf: dir.appendingPathComponent(f.relativePath)), f.name)
        }
        // The sidecar decodes with the document JSON decoder.
        let sidecar = try DocumentJSON.decoder().decode(AlignmentSidecar.self, from: try Data(contentsOf: dir.appendingPathComponent("alignment.json")))
        XCTAssertEqual(sidecar.fixtures.map(\.file).sorted(), expected.filter { $0.hasPrefix("alignment-") }.sorted())
        XCTAssertThrowsError(try FixtureCatalog.data(named: "does-not-exist"))
    }

    func testTextAndOutlineFixtureContainsTitles() throws {
        let info = try MinimalPDFInspector().inspect(data: try FixtureCatalog.data(named: "text-and-outline"))
        XCTAssertEqual(info.pageCount, 3)
        XCTAssertEqual(info.outlineTitles, ["Chapter 1: Kinematics", "Chapter 2: Dynamics", "Chapter 3: Energy & Work"])
        XCTAssertTrue(info.pages.allSatisfy { $0.hasText == true })
    }
}
