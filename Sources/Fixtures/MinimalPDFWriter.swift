import Foundation
import DocumentCore

/// A drawing operation on a fixture page, in PDF user space (origin bottom-left, y up).
public enum PDFDrawOp: Hashable, Sendable {
    /// Helvetica text with its baseline origin at (x, y).
    case text(String, x: Double, y: Double, size: Double)
    /// Filled rectangle in DeviceGray (0 = black, 1 = white).
    case fillRect(PageRect, gray: Double)
    case strokeRect(PageRect, width: Double)
    case line(from: PagePoint, to: PagePoint, width: Double)
}

/// A raw, uncompressed 8-bit RGB image drawn to fill `frame` (PDF user space).
public struct PDFFixtureImage: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// `width * height * 3` bytes, rows top to bottom.
    public var rgb: [UInt8]
    public var frame: PageRect
    public init(width: Int, height: Int, rgb: [UInt8], frame: PageRect) {
        precondition(rgb.count == width * height * 3, "rgb must hold width*height*3 bytes")
        self.width = width; self.height = height; self.rgb = rgb; self.frame = frame
    }
}

/// One page of a fixture PDF. Boxes are PDF user-space rectangles.
public struct PDFFixturePage: Hashable, Sendable {
    public var mediaBox: PageRect
    /// nil omits the /CropBox entry (the crop box then defaults to the media box).
    public var cropBox: PageRect?
    /// /Rotate value in degrees; any multiple of 90 is written verbatim.
    public var rotate: Int
    public var ops: [PDFDrawOp]
    public var image: PDFFixtureImage?
    /// When set, an outline item with this title points at the page.
    public var outlineTitle: String?

    public init(mediaBox: PageRect, cropBox: PageRect? = nil, rotate: Int = 0, ops: [PDFDrawOp] = [],
                image: PDFFixtureImage? = nil, outlineTitle: String? = nil) {
        self.mediaBox = mediaBox; self.cropBox = cropBox; self.rotate = rotate; self.ops = ops
        self.image = image; self.outlineTitle = outlineTitle
    }
}

/// Writes small, valid, entirely uncompressed PDF 1.4 files with a correct
/// cross-reference table. Object layout: 1 catalog, 2 page tree, 3 Helvetica,
/// then per page: page object, content stream, optional image XObject; then
/// an optional outline root and one item per titled page.
public enum MinimalPDFWriter {
    /// Byte offset of every "N 0 obj" the writer emitted, by object number.
    public struct Output: Sendable {
        public var data: Data
        public var objectOffsets: [Int: Int]
        public var xrefOffset: Int
    }

    public static func write(pages: [PDFFixturePage], markEncrypted: Bool = false) -> Data {
        writeDetailed(pages: pages, markEncrypted: markEncrypted).data
    }

    public static func writeDetailed(pages: [PDFFixturePage], markEncrypted: Bool = false) -> Output {
        precondition(!pages.isEmpty, "a PDF needs at least one page")
        var out = [UInt8]()
        out += Array("%PDF-1.4\n".utf8)
        out += [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A] // binary comment line

        // Assign object numbers up front so references are known.
        let catalogNum = 1, pagesNum = 2, fontNum = 3
        var next = 4
        var pageNums: [Int] = [], contentNums: [Int] = [], imageNums: [Int?] = []
        for page in pages {
            pageNums.append(next); next += 1
            contentNums.append(next); next += 1
            if page.image != nil { imageNums.append(next); next += 1 } else { imageNums.append(nil) }
        }
        let titled = pages.indices.filter { pages[$0].outlineTitle != nil }
        var outlinesNum: Int? = nil
        var itemNums: [Int] = []
        if !titled.isEmpty {
            outlinesNum = next; next += 1
            for _ in titled { itemNums.append(next); next += 1 }
        }
        let objectCount = next - 1

        var offsets: [Int: Int] = [:]
        func emit(_ num: Int, _ body: [UInt8]) {
            offsets[num] = out.count
            out += Array("\(num) 0 obj\n".utf8)
            out += body
            out += Array("\nendobj\n".utf8)
        }
        func emit(_ num: Int, _ body: String) { emit(num, Array(body.utf8)) }

        var catalog = "<< /Type /Catalog /Pages \(pagesNum) 0 R"
        if let o = outlinesNum { catalog += " /Outlines \(o) 0 R /PageMode /UseOutlines" }
        catalog += " >>"
        emit(catalogNum, catalog)

        let kids = pageNums.map { "\($0) 0 R" }.joined(separator: " ")
        emit(pagesNum, "<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        emit(fontNum, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")

        for (i, page) in pages.enumerated() {
            var dict = "<< /Type /Page /Parent \(pagesNum) 0 R /MediaBox \(rect(page.mediaBox))"
            if let crop = page.cropBox { dict += " /CropBox \(rect(crop))" }
            if page.rotate != 0 { dict += " /Rotate \(page.rotate)" }
            dict += " /Resources << /Font << /F1 \(fontNum) 0 R >>"
            if let im = imageNums[i] { dict += " /XObject << /Im1 \(im) 0 R >>" }
            dict += " >> /Contents \(contentNums[i]) 0 R >>"
            emit(pageNums[i], dict)

            var content = ""
            for op in page.ops { content += contentOp(op) }
            if let image = page.image, imageNums[i] != nil {
                let f = image.frame.standardized
                content += "q \(num(f.width)) 0 0 \(num(f.height)) \(num(f.minX)) \(num(f.minY)) cm /Im1 Do Q\n"
            }
            let contentBytes = Array(content.utf8)
            var stream = Array("<< /Length \(contentBytes.count) >>\nstream\n".utf8)
            stream += contentBytes
            stream += Array("endstream".utf8)
            emit(contentNums[i], stream)

            if let image = page.image, let im = imageNums[i] {
                var s = Array(("<< /Type /XObject /Subtype /Image /Width \(image.width) /Height \(image.height)"
                               + " /ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(image.rgb.count) >>\nstream\n").utf8)
                s += image.rgb
                s += Array("\nendstream".utf8)
                emit(im, s)
            }
        }

        if let o = outlinesNum {
            emit(o, "<< /Type /Outlines /First \(itemNums.first!) 0 R /Last \(itemNums.last!) 0 R /Count \(itemNums.count) >>")
            for (k, pageIndex) in titled.enumerated() {
                var item = "<< /Title \(literalString(pages[pageIndex].outlineTitle ?? "")) /Parent \(o) 0 R"
                if k > 0 { item += " /Prev \(itemNums[k - 1]) 0 R" }
                if k + 1 < itemNums.count { item += " /Next \(itemNums[k + 1]) 0 R" }
                item += " /Dest [\(pageNums[pageIndex]) 0 R /Fit] >>"
                emit(itemNums[k], item)
            }
        }

        let xrefOffset = out.count
        out += Array("xref\n0 \(objectCount + 1)\n".utf8)
        out += Array("0000000000 65535 f \n".utf8)
        for n in 1...objectCount {
            let off = offsets[n]!
            out += Array((String(repeating: "0", count: 10 - String(off).count) + String(off) + " 00000 n \n").utf8)
        }
        var trailer = "trailer\n<< /Size \(objectCount + 1) /Root \(catalogNum) 0 R"
        if markEncrypted {
            // Structurally complete standard-security dictionary (RC4 40-bit, all-zero keys) so third-party
            // parsers report the file as encrypted; the content itself is *not* encrypted. Fixture use only.
            let zeros32 = String(repeating: "00", count: 32), id16 = String(repeating: "00", count: 16)
            trailer += " /Encrypt << /Filter /Standard /V 1 /R 2 /Length 40 /P -1 /O <\(zeros32)> /U <\(zeros32)> >>"
            trailer += " /ID [<\(id16)> <\(id16)>]"
        }
        trailer += " >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out += Array(trailer.utf8)
        return Output(data: Data(out), objectOffsets: offsets, xrefOffset: xrefOffset)
    }

    // MARK: Formatting

    static func contentOp(_ op: PDFDrawOp) -> String {
        switch op {
        case .text(let s, let x, let y, let size):
            return "BT /F1 \(num(size)) Tf \(num(x)) \(num(y)) Td \(literalString(s)) Tj ET\n"
        case .fillRect(let r, let gray):
            let s = r.standardized
            return "q \(num(gray)) g \(num(s.minX)) \(num(s.minY)) \(num(s.width)) \(num(s.height)) re f Q\n"
        case .strokeRect(let r, let width):
            let s = r.standardized
            return "q \(num(width)) w \(num(s.minX)) \(num(s.minY)) \(num(s.width)) \(num(s.height)) re S Q\n"
        case .line(let a, let b, let width):
            return "q \(num(width)) w \(num(a.x)) \(num(a.y)) m \(num(b.x)) \(num(b.y)) l S Q\n"
        }
    }

    static func rect(_ r: PageRect) -> String {
        let s = r.standardized
        return "[\(num(s.minX)) \(num(s.minY)) \(num(s.maxX)) \(num(s.maxY))]"
    }

    /// Locale-independent PDF number: integers without a fraction, otherwise up to 4 decimals.
    public static func num(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        var scaled = (abs(v) * 10_000).rounded()
        var digits = String(Int64(scaled))
        while digits.count < 5 { digits = "0" + digits }
        var intPart = String(digits.dropLast(4))
        var frac = String(digits.suffix(4))
        while frac.hasSuffix("0") { frac.removeLast() }
        if frac.isEmpty { scaled = 0; return (v < 0 ? "-" : "") + intPart }
        if intPart.isEmpty { intPart = "0" }
        return (v < 0 ? "-" : "") + intPart + "." + frac
    }

    /// PDF literal string with escapes; non-ASCII characters are written as octal escapes of their UTF-8 bytes
    /// (fine for fixture labels; the inspector decodes them back).
    static func literalString(_ s: String) -> String {
        var out = "("
        for byte in s.utf8 {
            switch byte {
            case 0x28: out += "\\("
            case 0x29: out += "\\)"
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x20...0x7E: out += String(UnicodeScalar(byte))
            default: out += "\\" + String(byte, radix: 8).leftPadded(to: 3)
            }
        }
        return out + ")"
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}

// MARK: - Cross-reference checker

public enum PDFXrefError: Error, Equatable, CustomStringConvertible {
    case missingStartxref
    case badStartxrefOffset(Int)
    case malformedXref(String)
    case objectOffsetMismatch(object: Int, offset: Int)
    case missingTrailer

    public var description: String {
        switch self {
        case .missingStartxref: return "startxref keyword not found"
        case .badStartxrefOffset(let o): return "startxref offset \(o) does not point at an xref table"
        case .malformedXref(let m): return "malformed xref: \(m)"
        case .objectOffsetMismatch(let n, let o): return "xref offset \(o) for object \(n) does not point at '\(n) 0 obj'"
        case .missingTrailer: return "trailer dictionary not found after xref table"
        }
    }
}

/// Validates the cross-reference table of an uncompressed PDF: every in-use
/// entry's byte offset must point exactly at `N G obj`.
public enum PDFXrefChecker {
    public struct Table: Equatable, Sendable {
        /// Object number → (offset, generation) for in-use entries.
        public var entries: [Int: (offset: Int, generation: Int)]
        public var trailerRange: Range<Int>
        public static func == (l: Table, r: Table) -> Bool {
            l.trailerRange == r.trailerRange && l.entries.count == r.entries.count &&
            l.entries.allSatisfy { r.entries[$0.key].map { $0 == $1 } ?? false }
        }
    }

    @discardableResult
    public static func validate(_ data: Data) throws -> Table {
        let bytes = [UInt8](data)
        let table = try parseTable(bytes)
        for (num, entry) in table.entries {
            let expected = Array("\(num) \(entry.generation) obj".utf8)
            guard entry.offset >= 0, entry.offset + expected.count <= bytes.count,
                  Array(bytes[entry.offset..<entry.offset + expected.count]) == expected else {
                throw PDFXrefError.objectOffsetMismatch(object: num, offset: entry.offset)
            }
        }
        return table
    }

    /// Parses the xref table(s) reachable from the final `startxref` (following /Prev) without checking offsets.
    public static func parseTable(_ bytes: [UInt8]) throws -> Table {
        guard let sx = lastRange(of: Array("startxref".utf8), in: bytes) else { throw PDFXrefError.missingStartxref }
        var cursor = sx.upperBound
        skipWhitespace(bytes, &cursor)
        guard let start = readInt(bytes, &cursor) else { throw PDFXrefError.missingStartxref }
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var trailerRange: Range<Int>? = nil
        var seen = Set<Int>()
        var xrefStart = start
        while true {
            guard !seen.contains(xrefStart) else { throw PDFXrefError.malformedXref("cyclic /Prev chain") }
            seen.insert(xrefStart)
            guard xrefStart >= 0, xrefStart + 4 <= bytes.count, Array(bytes[xrefStart..<xrefStart + 4]) == Array("xref".utf8) else {
                throw PDFXrefError.badStartxrefOffset(xrefStart)
            }
            cursor = xrefStart + 4
            // Subsections until "trailer".
            while true {
                skipWhitespace(bytes, &cursor)
                if matches(bytes, at: cursor, Array("trailer".utf8)) { break }
                guard let first = readInt(bytes, &cursor) else { throw PDFXrefError.malformedXref("expected subsection start at \(cursor)") }
                skipWhitespace(bytes, &cursor)
                guard let count = readInt(bytes, &cursor), count >= 0 else { throw PDFXrefError.malformedXref("expected subsection count at \(cursor)") }
                skipWhitespace(bytes, &cursor)
                for i in 0..<count {
                    guard cursor + 18 <= bytes.count else { throw PDFXrefError.malformedXref("truncated entry for object \(first + i)") }
                    let entry = bytes[cursor..<cursor + 18]
                    let text = String(decoding: entry, as: UTF8.self)
                    let parts = text.split(separator: " ")
                    guard parts.count == 3, parts[0].count == 10, parts[1].count == 5,
                          let off = Int(parts[0]), let gen = Int(parts[1]), parts[2] == "n" || parts[2] == "f" else {
                        throw PDFXrefError.malformedXref("bad entry '\(text)' for object \(first + i)")
                    }
                    cursor += 18
                    // Entry terminator: exactly two bytes (" \n", " \r", "\r\n"); tolerate a single newline.
                    var term = 0
                    while term < 2, cursor < bytes.count, [0x20, 0x0A, 0x0D].contains(bytes[cursor]) { cursor += 1; term += 1 }
                    if parts[2] == "n", entries[first + i] == nil { entries[first + i] = (off, gen) }
                }
            }
            let trailerKeywordEnd = cursor + 7
            var end = trailerKeywordEnd
            guard let dictStart = range(of: Array("<<".utf8), in: bytes, from: trailerKeywordEnd) else { throw PDFXrefError.missingTrailer }
            guard let dictEnd = matchingDictEnd(bytes, from: dictStart.lowerBound) else { throw PDFXrefError.missingTrailer }
            end = dictEnd
            if trailerRange == nil { trailerRange = dictStart.lowerBound..<end }
            // Follow /Prev when present.
            let trailerBytes = Array(bytes[dictStart.lowerBound..<end])
            if let prevRange = range(of: Array("/Prev".utf8), in: trailerBytes, from: 0) {
                var c = prevRange.upperBound
                skipWhitespace(trailerBytes, &c)
                if let prev = readInt(trailerBytes, &c) { xrefStart = prev; continue }
            }
            break
        }
        guard let tr = trailerRange else { throw PDFXrefError.missingTrailer }
        return Table(entries: entries, trailerRange: tr)
    }

    // MARK: byte helpers (shared with the inspector)

    static func isWhitespace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 || b == 0x0C || b == 0x00 }
    static func skipWhitespace(_ bytes: [UInt8], _ cursor: inout Int) { while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 } }
    static func readInt(_ bytes: [UInt8], _ cursor: inout Int) -> Int? {
        var value = 0, digits = 0
        while cursor < bytes.count, bytes[cursor] >= 0x30, bytes[cursor] <= 0x39 {
            value = value * 10 + Int(bytes[cursor] - 0x30); cursor += 1; digits += 1
            if digits > 18 { return nil }
        }
        return digits > 0 ? value : nil
    }
    static func matches(_ bytes: [UInt8], at index: Int, _ pattern: [UInt8]) -> Bool {
        index >= 0 && index + pattern.count <= bytes.count && Array(bytes[index..<index + pattern.count]) == pattern
    }
    static func range(of pattern: [UInt8], in bytes: [UInt8], from: Int) -> Range<Int>? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var i = max(from, 0)
        while i + pattern.count <= bytes.count {
            if bytes[i] == pattern[0], matches(bytes, at: i, pattern) { return i..<i + pattern.count }
            i += 1
        }
        return nil
    }
    static func lastRange(of pattern: [UInt8], in bytes: [UInt8]) -> Range<Int>? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var i = bytes.count - pattern.count
        while i >= 0 {
            if bytes[i] == pattern[0], matches(bytes, at: i, pattern) { return i..<i + pattern.count }
            i -= 1
        }
        return nil
    }
    /// Index just past the `>>` that closes the dictionary opening at `start` (nesting-aware, string-unaware).
    static func matchingDictEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0, i = start
        while i + 1 < bytes.count {
            if bytes[i] == 0x3C, bytes[i + 1] == 0x3C { depth += 1; i += 2; continue }
            if bytes[i] == 0x3E, bytes[i + 1] == 0x3E { depth -= 1; i += 2; if depth == 0 { return i }; continue }
            i += 1
        }
        return nil
    }
}
