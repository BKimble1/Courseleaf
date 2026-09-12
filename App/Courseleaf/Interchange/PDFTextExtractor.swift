import Foundation
import PDFKit
import DocumentCore
import PageGeometry
import Workspace

/// Extracts the real text of an imported PDF page as `SearchRecord`s of kind
/// `.pdfText`, one per line, with bounds converted from PDF user space to page
/// space through `PageMapping` (so rotated and cropped pages highlight in the
/// right place, §3). Pages whose background is not a PDF yield no records.
struct PDFTextExtractor: Sendable {
    let source: any ExportContentSource
    /// Lines longer than this are truncated; keeps the index bounded on pathological files.
    var maximumLineLength = 2000

    init(session: any DocumentSessioning) { self.source = SessionContentSource(session: session) }
    init(source: any ExportContentSource) { self.source = source }

    /// Records for `pageID`: nil when the page is not a PDF page (nothing to
    /// extract), an empty array for a PDF page without a text layer (a scan).
    func records(for pageID: PageID) async throws -> [SearchRecord]? {
        let snapshot = await source.snapshot()
        guard let page = snapshot.pages[pageID] else { throw ExportError.pageNotFound(pageID) }
        guard case .pdf(let sourcePage) = page.background else { return nil }
        let document = try await pdfDocument(sourcePage.assetID, pageID: pageID)
        try Task.checkCancellation()
        return Self.records(in: document, source: sourcePage, page: page, documentID: snapshot.document.id, language: snapshot.document.language,
                            maximumLineLength: maximumLineLength)
    }

    /// Pure conversion, usable with any opened `PDFDocument`.
    static func records(in document: PDFDocument, source: PDFPageSource, page: Page, documentID: DocumentID, language: String,
                        maximumLineLength: Int = 2000) -> [SearchRecord] {
        guard let pdfPage = document.page(at: source.pageIndex) else { return [] }
        let mapping = PageMapping(source: source)
        // One selection over the whole page (PDF user space), split into lines.
        guard let whole = pdfPage.selection(for: pdfPage.bounds(for: .mediaBox)) else { return [] }
        var out: [SearchRecord] = []
        for line in whole.selectionsByLine() {
            guard let raw = line.string else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = text.count > maximumLineLength ? String(text.prefix(maximumLineLength)) : text
            let userBounds = IXGeometry.pageRect(line.bounds(for: pdfPage))
            let pageBounds = userBounds.isEmpty ? nil : mapping.pageRect(fromPDFUser: userBounds).intersection(mapping.pageBounds)
            out.append(SearchRecord(documentID: documentID, pageID: page.id, revisionID: page.revisionID, kind: .pdfText,
                                    text: clipped, bounds: pageBounds, language: language, confidence: nil))
        }
        return out
    }

    /// True when the PDF page has no text layer (a scan); the recognizer then reads the background too.
    static func pageHasText(_ document: PDFDocument, pageIndex: Int) -> Bool {
        guard let page = document.page(at: pageIndex), let text = page.string else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func pdfDocument(_ assetID: AssetID, pageID: PageID) async throws -> PDFDocument {
        if let url = await source.assetURL(assetID), let document = PDFDocument(url: url) { return document }
        guard let data = try await source.assetData(assetID) else { throw ExportError.missingAsset(assetID, pageID: pageID) }
        guard let document = PDFDocument(data: data) else { throw ExportError.unreadableAsset(assetID, reason: "not a readable PDF") }
        return document
    }
}
