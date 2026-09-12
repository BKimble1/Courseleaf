import Foundation
import PDFKit
import DocumentCore

/// `PDFInspecting` backed by PDFKit. Reads page geometry, rotation, text
/// presence and outline titles from a file **without rendering it**:
///
/// - Nothing in the document is executed: PDFKit does not evaluate document
///   JavaScript when a `PDFDocument` is opened, and this inspector never
///   creates a `PDFView`, never reads annotations and never resolves link or
///   go-to actions. Outline items are only asked for their `label`.
/// - Files larger than `byteLimit` (1 GiB by default) are refused with
///   `.tooLarge` before anything is opened.
/// - Encrypted files are refused with `.encrypted` whether or not they open
///   with an empty user password: the product does not import encrypted PDFs
///   (docs/PRODUCT_SPEC.md §3.6). A file PDFKit cannot open whose trailer
///   carries `/Encrypt` is reported as encrypted rather than corrupt.
/// - Boxes are returned in PDF user space as stored (origin bottom-left, y up);
///   the crop box is intersected with the media box, falling back to the media
///   box when they do not overlap, matching `Fixtures.MinimalPDFInspector`.
struct PDFKitInspector: PDFInspecting {
    /// Files above this size are rejected with `PDFInspectionError.tooLarge`.
    var byteLimit: Int
    /// When true, `PDFPageInfo.hasText` is filled by asking PDFKit for each page's text.
    var reportsTextPresence: Bool

    init(byteLimit: Int = 1 << 30, reportsTextPresence: Bool = true) {
        self.byteLimit = byteLimit
        self.reportsTextPresence = reportsTextPresence
    }

    func inspect(fileAt url: URL) throws -> PDFFileInfo {
        let size = try fileSize(at: url)
        guard size <= byteLimit else { throw PDFInspectionError.tooLarge(bytes: size, limit: byteLimit) }
        guard headerLooksLikePDF(url) else { throw PDFInspectionError.notAPDF }
        let trailerMentionsEncrypt = trailerHasEncrypt(url)

        guard let document = PDFDocument(url: url) else {
            throw trailerMentionsEncrypt ? PDFInspectionError.encrypted : PDFInspectionError.corrupt("PDFKit could not open the file")
        }
        if document.isLocked || document.isEncrypted || trailerMentionsEncrypt {
            throw PDFInspectionError.encrypted
        }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw PDFInspectionError.corrupt("the document has no pages") }

        var pages: [PDFPageInfo] = []
        pages.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { throw PDFInspectionError.corrupt("page \(index + 1) could not be read") }
            let media = IXGeometry.pageRect(page.bounds(for: .mediaBox))
            guard media.width > 0, media.height > 0, media.isFinite else {
                throw PDFInspectionError.corrupt("page \(index + 1) has no usable /MediaBox")
            }
            let storedCrop = IXGeometry.pageRect(page.bounds(for: .cropBox))
            let crop = media.intersection(storedCrop).flatMap { $0.isEmpty ? nil : $0 } ?? media
            guard let rotation = PageRotation(degrees: page.rotation) else {
                throw PDFInspectionError.corrupt("page \(index + 1) has /Rotate \(page.rotation), not a multiple of 90")
            }
            var hasText: Bool? = nil
            if reportsTextPresence {
                let text = page.string ?? ""
                hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            pages.append(PDFPageInfo(index: index, mediaBox: media, cropBox: crop, rotation: rotation, hasText: hasText))
        }

        return PDFFileInfo(pageCount: pageCount, pages: pages, isEncrypted: false, outlineTitles: outlineTitles(of: document))
    }

    // MARK: Outline

    /// Depth-first outline titles (document order). Bounded in depth and count so a
    /// malicious outline cannot loop or explode.
    private func outlineTitles(of document: PDFDocument) -> [String] {
        guard let root = document.outlineRoot else { return [] }
        var titles: [String] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ item: PDFOutline, depth: Int) {
            guard depth < 32, titles.count < 10_000 else { return }
            let id = ObjectIdentifier(item)
            guard !visited.contains(id) else { return }
            visited.insert(id)
            for i in 0..<item.numberOfChildren {
                guard let child = item.child(at: i) else { continue }
                if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                    titles.append(label)
                }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return titles
    }

    // MARK: File checks

    private func fileSize(at url: URL) throws -> Int {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values.isDirectory == true { throw PDFInspectionError.notAPDF }
            if let size = values.fileSize { return size }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? NSNumber)?.intValue ?? 0
        } catch let error as PDFInspectionError {
            throw error
        } catch {
            throw PDFInspectionError.corrupt("unreadable file: \(error.localizedDescription)")
        }
    }

    /// `%PDF-` must appear within the first 1024 bytes (the specification allows leading junk).
    private func headerLooksLikePDF(_ url: URL) -> Bool {
        guard let head = readBytes(url, offset: 0, count: 1024) else { return false }
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    /// Whether the last 4 KiB (where the trailer of a non-linearized file lives) mention `/Encrypt`.
    private func trailerHasEncrypt(_ url: URL) -> Bool {
        guard let size = try? fileSize(at: url) else { return false }
        let count = min(size, 4096)
        guard let tail = readBytes(url, offset: UInt64(size - count), count: count) else { return false }
        return tail.range(of: Data("/Encrypt".utf8)) != nil
    }

    private func readBytes(_ url: URL, offset: UInt64, count: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }
}
