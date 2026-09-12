import XCTest
import DocumentCore
@testable import Fixtures

final class PDFFixtureTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("courseleaf-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testWriterOutputHasHeaderAndPassesXrefChecker() throws {
        let out = MinimalPDFWriter.writeDetailed(pages: FixtureCatalog.textAndOutlinePages())
        XCTAssertTrue(out.data.starts(with: Array("%PDF-1.4\n".utf8)))
        XCTAssertTrue(String(decoding: out.data.suffix(6), as: UTF8.self).hasSuffix("%%EOF\n"))
        let table = try PDFXrefChecker.validate(out.data)
        // 1 catalog, 2 pages, 3 font, 3 × (page + content), outlines root + 3 items = 13 objects.
        XCTAssertEqual(table.entries.count, 13)
        for (num, off) in out.objectOffsets {
            XCTAssertEqual(table.entries[num]?.offset, off)
            let head = String(decoding: out.data[off..<min(off + 12, out.data.count)], as: UTF8.self)
            XCTAssertTrue(head.hasPrefix("\(num) 0 obj"), head)
        }
        // startxref points at "xref".
        XCTAssertEqual(String(decoding: out.data[out.xrefOffset..<out.xrefOffset + 4], as: UTF8.self), "xref")
    }

    func testXrefCheckerRejectsShiftedOffsets() {
        XCTAssertThrowsError(try PDFXrefChecker.validate(FixtureCatalog.badXrefData())) { error in
            guard case PDFXrefError.objectOffsetMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try PDFXrefChecker.validate(Data("no xref here".utf8))) { error in
            XCTAssertEqual(error as? PDFXrefError, .missingStartxref)
        }
    }

    func testInspectorRoundTripsBoxesRotationOutlineAndText() throws {
        let crop = PageRect(x: 36, y: 54, width: 504, height: 666)
        let pages = [
            PDFFixturePage(mediaBox: FixtureCatalog.letter, cropBox: crop, rotate: 90, ops: [.text("Hello (PDF) \\ world", x: 72, y: 700, size: 12)], outlineTitle: "Intro (part 1)"),
            PDFFixturePage(mediaBox: FixtureCatalog.a4, rotate: 270, ops: [.fillRect(PageRect(x: 10, y: 10, width: 20, height: 20), gray: 0.5)]),
            PDFFixturePage(mediaBox: FixtureCatalog.letterLandscape, cropBox: PageRect(x: -50, y: -50, width: 2000, height: 2000), rotate: 180, ops: [], outlineTitle: "Ünïcode ✓"),
            PDFFixturePage(mediaBox: FixtureCatalog.letter, rotate: 450, ops: [.line(from: PagePoint(x: 0, y: 0), to: PagePoint(x: 100, y: 100), width: 2)]),
        ]
        let data = MinimalPDFWriter.write(pages: pages)
        try PDFXrefChecker.validate(data)
        let url = try write(data, "roundtrip.pdf")
        let info = try MinimalPDFInspector().inspect(fileAt: url)
        XCTAssertEqual(info.pageCount, 4)
        XCTAssertFalse(info.isEncrypted)
        XCTAssertEqual(info.outlineTitles, ["Intro (part 1)", "Ünïcode ✓"])

        XCTAssertEqual(info.pages[0].index, 0)
        XCTAssertEqual(info.pages[0].mediaBox, FixtureCatalog.letter)
        XCTAssertEqual(info.pages[0].cropBox, crop)
        XCTAssertEqual(info.pages[0].rotation, .degrees90)
        XCTAssertEqual(info.pages[0].hasText, true)

        XCTAssertEqual(info.pages[1].mediaBox.width, 595.276, accuracy: 1e-9)
        XCTAssertEqual(info.pages[1].mediaBox.height, 841.89, accuracy: 1e-9)
        XCTAssertEqual(info.pages[1].cropBox, info.pages[1].mediaBox, "missing CropBox defaults to MediaBox")
        XCTAssertEqual(info.pages[1].rotation, .degrees270)
        XCTAssertEqual(info.pages[1].hasText, false)

        XCTAssertEqual(info.pages[2].cropBox, FixtureCatalog.letterLandscape, "oversized CropBox is clipped to MediaBox")
        XCTAssertEqual(info.pages[2].rotation, .degrees180)

        XCTAssertEqual(info.pages[3].rotation, .degrees90, "/Rotate 450 normalizes to 90")
        XCTAssertEqual(info.pages[3].hasText, false)
    }

    func testInspectorInheritsBoxesAndRotateThroughParentNodes() throws {
        // Hand-written page tree: attributes live on the intermediate /Pages node, the leaf has none.
        let pdf = """
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 2 /MediaBox [0 0 612 792] /Rotate 180 >> endobj
        3 0 obj << /Type /Pages /Parent 2 0 R /Kids [4 0 R 5 0 R] /Count 2 /CropBox [10 20 300 400] >> endobj
        4 0 obj << /Type /Page /Parent 3 0 R >> endobj
        5 0 obj << /Type /Page /Parent 3 0 R /Rotate 90 /MediaBox [0 0 200 100] >> endobj
        """
        let data = try assembleWithXref(pdf)
        let info = try MinimalPDFInspector().inspect(data: data)
        XCTAssertEqual(info.pageCount, 2)
        XCTAssertEqual(info.pages[0].mediaBox, PageRect(x: 0, y: 0, width: 612, height: 792))
        XCTAssertEqual(info.pages[0].cropBox, PageRect(x: 10, y: 20, width: 290, height: 380))
        XCTAssertEqual(info.pages[0].rotation, .degrees180)
        XCTAssertEqual(info.pages[0].hasText, false)
        // The leaf overrides MediaBox and Rotate; the inherited CropBox is clipped to the new MediaBox.
        XCTAssertEqual(info.pages[1].mediaBox, PageRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(info.pages[1].cropBox, PageRect(x: 10, y: 20, width: 190, height: 80))
        XCTAssertEqual(info.pages[1].rotation, .degrees90)
    }

    func testInspectorReportsEncryptMarker() throws {
        let data = MinimalPDFWriter.write(pages: FixtureCatalog.textAndOutlinePages(), markEncrypted: true)
        try PDFXrefChecker.validate(data)
        let info = try MinimalPDFInspector().inspect(data: data)
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.pageCount, 3)
    }

    func testInspectorReadsImageOnlyAndLongMixedFixtures() throws {
        let image = try MinimalPDFInspector().inspect(data: try FixtureCatalog.data(named: "image-only"))
        XCTAssertEqual(image.pageCount, 1)
        XCTAssertEqual(image.pages[0].hasText, false)
        XCTAssertTrue(image.outlineTitles.isEmpty)

        let long = try MinimalPDFInspector().inspect(fileAt: try write(try FixtureCatalog.data(named: "long-300-mixed"), "long.pdf"))
        XCTAssertEqual(long.pageCount, 300)
        XCTAssertEqual(long.pages.map(\.index), Array(0..<300))
        XCTAssertEqual(long.pages[0].mediaBox, FixtureCatalog.letter)
        XCTAssertEqual(long.pages[1].mediaBox, FixtureCatalog.a4)
        XCTAssertEqual(long.pages[2].mediaBox, FixtureCatalog.letterLandscape)
        XCTAssertEqual(long.pages[299].mediaBox, FixtureCatalog.letterLandscape)
        XCTAssertTrue(long.pages.allSatisfy { $0.hasText == true })
    }

    func testInspectorRejectsMalformedFixturesWithTheRightErrors() throws {
        let inspector = MinimalPDFInspector()
        XCTAssertThrowsError(try inspector.inspect(fileAt: try write(FixtureCatalog.garbageData(), "garbage.pdf"))) { error in
            XCTAssertEqual(error as? PDFInspectionError, .notAPDF)
        }
        XCTAssertThrowsError(try inspector.inspect(data: Data())) { error in
            XCTAssertEqual(error as? PDFInspectionError, .notAPDF)
        }
        XCTAssertThrowsError(try inspector.inspect(fileAt: try write(FixtureCatalog.truncatedData(), "truncated.pdf"))) { error in
            guard case PDFInspectionError.corrupt = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try inspector.inspect(fileAt: try write(FixtureCatalog.badXrefData(), "bad-xref.pdf"))) { error in
            guard case PDFInspectionError.corrupt(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("does not point"), message)
        }
        // A PDF whose page tree is broken (catalog points at a missing object).
        let broken = try assembleWithXref("""
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 9 0 R >> endobj
        """)
        XCTAssertThrowsError(try inspector.inspect(data: broken)) { error in
            guard case PDFInspectionError.corrupt = error else { return XCTFail("\(error)") }
        }
        // A missing file is reported as corrupt, not as a crash.
        XCTAssertThrowsError(try inspector.inspect(fileAt: tempDir.appendingPathComponent("nope.pdf")))
        // Size limit.
        XCTAssertThrowsError(try MinimalPDFInspector(byteLimit: 10).inspect(data: FixtureCatalog.truncatedData())) { error in
            guard case PDFInspectionError.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testNumberFormattingIsLocaleIndependentAndCompact() {
        XCTAssertEqual(MinimalPDFWriter.num(612), "612")
        XCTAssertEqual(MinimalPDFWriter.num(595.276), "595.276")
        XCTAssertEqual(MinimalPDFWriter.num(-0.5), "-0.5")
        XCTAssertEqual(MinimalPDFWriter.num(0.00004), "0")
        XCTAssertEqual(MinimalPDFWriter.num(14.4), "14.4")
    }

    /// Appends a correct xref table and trailer to a hand-written body (objects one per line, Root = 1 0 R).
    func assembleWithXref(_ body: String) throws -> Data {
        var bytes = Array(body.utf8)
        if bytes.last != 0x0A { bytes.append(0x0A) }
        var offsets: [Int: Int] = [:]
        var maxNum = 0
        var i = 0
        while i < bytes.count {
            var c = i
            if let n = PDFXrefChecker.readInt(bytes, &c), PDFXrefChecker.matches(bytes, at: c, Array(" 0 obj".utf8)), i == 0 || bytes[i - 1] == 0x0A {
                offsets[n] = i; maxNum = max(maxNum, n)
            }
            i += 1
        }
        let xref = bytes.count
        var tail = "xref\n0 \(maxNum + 1)\n0000000000 65535 f \n"
        for n in 1...maxNum {
            let off = offsets[n] ?? 0
            tail += (offsets[n] == nil ? "0000000000 00000 f \n" : String(off).leftPadded(to: 10) + " 00000 n \n")
        }
        tail += "trailer\n<< /Size \(maxNum + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        bytes += Array(tail.utf8)
        return Data(bytes)
    }
}
