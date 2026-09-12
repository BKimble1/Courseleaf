import Foundation
import DocumentCore

/// `PDFInspecting` for the uncompressed PDFs the fixture writer produces (and
/// any other PDF whose page tree and outlines are stored unfiltered). It uses
/// the cross-reference table to locate objects, so a damaged table is
/// reported as `.corrupt` rather than silently reconstructed.
public struct MinimalPDFInspector: PDFInspecting {
    /// Files larger than this are rejected with `.tooLarge`.
    public var byteLimit: Int
    public init(byteLimit: Int = 64 * 1024 * 1024) { self.byteLimit = byteLimit }

    public func inspect(fileAt url: URL) throws -> PDFFileInfo {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw PDFInspectionError.corrupt("unreadable file: \(error)") }
        return try inspect(data: data)
    }

    public func inspect(data: Data) throws -> PDFFileInfo {
        guard data.count <= byteLimit else { throw PDFInspectionError.tooLarge(bytes: data.count, limit: byteLimit) }
        let bytes = [UInt8](data)
        // Header: "%PDF-" must appear within the first 1024 bytes (the spec allows leading junk).
        let head = Array(bytes.prefix(1024))
        guard PDFXrefChecker.range(of: Array("%PDF-".utf8), in: head, from: 0) != nil else { throw PDFInspectionError.notAPDF }

        let table: PDFXrefChecker.Table
        do { table = try PDFXrefChecker.validate(data) } catch let e as PDFXrefError { throw PDFInspectionError.corrupt(e.description) }
        catch { throw PDFInspectionError.corrupt("\(error)") }

        let trailer: [String: PDFObject]
        do {
            var p = PDFObjectParser(bytes: bytes, cursor: table.trailerRange.lowerBound)
            guard let d = try p.parseObject().dictionaryValue else { throw PDFInspectionError.corrupt("trailer is not a dictionary") }
            trailer = d
        } catch let e as PDFInspectionError { throw e } catch { throw PDFInspectionError.corrupt("trailer: \(error)") }

        let resolver = Resolver(bytes: bytes, table: table)
        let isEncrypted = trailer["Encrypt"] != nil

        guard let root = trailer["Root"], let catalog = try resolver.resolve(root).dictionaryValue else {
            throw PDFInspectionError.corrupt("missing /Root catalog")
        }
        guard let pagesRef = catalog["Pages"], let pagesRoot = try resolver.resolve(pagesRef).dictionaryValue else {
            throw PDFInspectionError.corrupt("catalog has no /Pages")
        }

        var pages: [PDFPageInfo] = []
        var visited = Set<String>()
        try walk(node: pagesRoot, ref: pagesRef, inherited: Inherited(), depth: 0, resolver: resolver, visited: &visited, pages: &pages)
        guard !pages.isEmpty else { throw PDFInspectionError.corrupt("page tree has no pages") }
        if let count = pagesRoot["Count"]?.intValue, count != pages.count {
            throw PDFInspectionError.corrupt("page tree /Count \(count) does not match \(pages.count) leaf pages")
        }

        var titles: [String] = []
        if let outlinesRef = catalog["Outlines"], let outlines = try resolver.resolve(outlinesRef).dictionaryValue {
            var seen = Set<String>()
            try collectOutlineTitles(from: outlines["First"], resolver: resolver, depth: 0, seen: &seen, into: &titles)
        }
        return PDFFileInfo(pageCount: pages.count, pages: pages, isEncrypted: isEncrypted, outlineTitles: titles)
    }

    // MARK: Page tree

    struct Inherited {
        var mediaBox: PageRect? = nil
        var cropBox: PageRect? = nil
        var rotate: Int? = nil
    }

    private func walk(node: [String: PDFObject], ref: PDFObject, inherited: Inherited, depth: Int, resolver: Resolver,
                      visited: inout Set<String>, pages: inout [PDFPageInfo]) throws {
        guard depth < 64 else { throw PDFInspectionError.corrupt("page tree too deep") }
        if case .reference(let n, let g) = ref {
            let key = "\(n)_\(g)"
            guard !visited.contains(key) else { throw PDFInspectionError.corrupt("cyclic page tree at object \(n)") }
            visited.insert(key)
        }
        var inh = inherited
        if let mb = node["MediaBox"] { inh.mediaBox = try rect(resolver.resolve(mb), name: "MediaBox", resolver: resolver) }
        if let cb = node["CropBox"] { inh.cropBox = try rect(resolver.resolve(cb), name: "CropBox", resolver: resolver) }
        if let r = node["Rotate"] {
            guard let v = try resolver.resolve(r).intValue else { throw PDFInspectionError.corrupt("/Rotate is not an integer") }
            inh.rotate = v
        }
        let type = node["Type"]?.nameValue
        if type == "Pages" || (type == nil && node["Kids"] != nil) {
            guard let kids = try resolver.resolve(node["Kids"] ?? .array([])).arrayValue else {
                throw PDFInspectionError.corrupt("/Kids is not an array")
            }
            for kid in kids {
                guard let kidDict = try resolver.resolve(kid).dictionaryValue else { throw PDFInspectionError.corrupt("page tree kid is not a dictionary") }
                try walk(node: kidDict, ref: kid, inherited: inh, depth: depth + 1, resolver: resolver, visited: &visited, pages: &pages)
            }
            return
        }
        guard type == "Page" || type == nil else { throw PDFInspectionError.corrupt("unexpected /Type /\(type ?? "") in page tree") }
        guard let media = inh.mediaBox, media.width > 0, media.height > 0 else {
            throw PDFInspectionError.corrupt("page \(pages.count) has no usable /MediaBox")
        }
        let crop = inh.cropBox.flatMap { media.intersection($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? media
        guard let rotation = PageRotation(degrees: inh.rotate ?? 0) else {
            throw PDFInspectionError.corrupt("page \(pages.count) has /Rotate \(inh.rotate ?? 0), not a multiple of 90")
        }
        let hasText = try contentHasText(node["Contents"], resolver: resolver)
        pages.append(PDFPageInfo(index: pages.count, mediaBox: media, cropBox: crop, rotation: rotation, hasText: hasText))
    }

    private func rect(_ obj: PDFObject, name: String, resolver: Resolver) throws -> PageRect {
        guard let arr = obj.arrayValue, arr.count == 4 else { throw PDFInspectionError.corrupt("/\(name) is not a 4-number array") }
        var v: [Double] = []
        for item in arr {
            guard let n = try resolver.resolve(item).number, n.isFinite else { throw PDFInspectionError.corrupt("/\(name) contains a non-number") }
            v.append(n)
        }
        return PageRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
    }

    /// True when any content stream contains a text-showing operator (Tj, TJ, ', ").
    private func contentHasText(_ contents: PDFObject?, resolver: Resolver) throws -> Bool {
        guard let contents else { return false }
        let resolved = try resolver.resolve(contents)
        var streams: [PDFObject] = []
        if let arr = resolved.arrayValue { for item in arr { streams.append(try resolver.resolve(item)) } } else { streams = [resolved] }
        for s in streams {
            guard case .stream(let dict, let range) = s else { continue }
            if dict["Filter"] != nil { return false } // compressed: unknown; the app's PDFKit inspector answers this
            let body = Array(resolver.bytes[range])
            if containsTextOperator(body) { return true }
        }
        return false
    }

    private func containsTextOperator(_ body: [UInt8]) -> Bool {
        // Scan tokens outside strings for Tj / TJ / ' / " operators.
        var i = 0, inString = false, depth = 0
        while i < body.count {
            let b = body[i]
            if inString {
                if b == 0x5C { i += 2; continue }
                if b == 0x28 { depth += 1 } else if b == 0x29 { depth -= 1; if depth == 0 { inString = false } }
                i += 1; continue
            }
            if b == 0x28 { inString = true; depth = 1; i += 1; continue }
            if b == 0x54, i + 1 < body.count, body[i + 1] == 0x6A || body[i + 1] == 0x4A {
                let before = i == 0 || !PDFObjectParser.isRegular(body[i - 1])
                let after = i + 2 >= body.count || !PDFObjectParser.isRegular(body[i + 2])
                if before && after { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: Outlines

    private func collectOutlineTitles(from first: PDFObject?, resolver: Resolver, depth: Int, seen: inout Set<String>, into titles: inout [String]) throws {
        guard depth < 32 else { return }
        var current = first
        var steps = 0
        while let ref = current, steps < 10_000 {
            steps += 1
            if case .reference(let n, let g) = ref {
                let key = "\(n)_\(g)"
                if seen.contains(key) { return }
                seen.insert(key)
            }
            guard let item = try resolver.resolve(ref).dictionaryValue else { return }
            if let t = item["Title"], let s = try resolver.resolve(t).stringBytes { titles.append(PDFTextString.decode(s)) }
            try collectOutlineTitles(from: item["First"], resolver: resolver, depth: depth + 1, seen: &seen, into: &titles)
            current = item["Next"]
        }
    }

    // MARK: Object resolution

    final class Resolver {
        let bytes: [UInt8]
        let table: PDFXrefChecker.Table
        private var cache: [Int: PDFObject] = [:]
        init(bytes: [UInt8], table: PDFXrefChecker.Table) { self.bytes = bytes; self.table = table }

        func resolve(_ obj: PDFObject) throws -> PDFObject {
            var current = obj
            var hops = 0
            while case .reference(let n, _) = current {
                hops += 1
                guard hops < 32 else { throw PDFInspectionError.corrupt("reference chain too long at object \(n)") }
                if let cached = cache[n] { current = cached; continue }
                guard let entry = table.entries[n] else { return .null }
                do {
                    var parser = PDFObjectParser(bytes: bytes, cursor: entry.offset)
                    let (num, _, value) = try parser.parseIndirectObject()
                    guard num == n else { throw PDFInspectionError.corrupt("object \(n) offset points at object \(num)") }
                    cache[n] = value
                    current = value
                } catch let e as PDFInspectionError { throw e } catch { throw PDFInspectionError.corrupt("object \(n): \(error)") }
            }
            return current
        }
    }
}
