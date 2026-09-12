import Foundation
import CoreGraphics
import UIKit
import DocumentCore
import PageGeometry
import Workspace

/// Renders a **presentation PDF** of a document with `UIGraphicsPDFRenderer`.
///
/// For every selected page, in document order, a PDF page whose media box is
/// the page's display size (page space, §3) is begun and the page is composited
/// back to front exactly as on screen (§4):
///
/// 1. Background — a source PDF page drawn as **vector content** through
///    `CGContext.drawPDFPage` under `PageMapping.pdfUserToPage` (crop origin
///    removed, `/Rotate` applied), the paper template's primitives, or the
///    full-page image;
/// 2. image objects; 3. ink, rasterized from `PKDrawing` at
///    `ExportOptions.inkRasterScale` pixels per point and placed in page space;
/// 4. text objects as Core Text (vector, searchable), shapes as paths and tape
///    according to `TapeExportPolicy`.
///
/// **Preserved from the source PDF:** the page content stream as vectors —
/// text stays selectable and searchable, fonts and images are embedded by
/// Quartz, the crop box and rotation are baked in so the exported page looks
/// like the page in the editor.
///
/// **Not preserved:** link annotations, outlines/bookmarks, form fields,
/// existing annotation appearances, metadata other than the title, page
/// labels and any interactivity (docs/PRODUCT_SPEC.md §6, acceptance A12).
/// Courseleaf annotations are drawn content, not editable PDF annotations.
/// Ink is always raster.
///
/// The file is written to a temporary location and moved to `url` only when
/// every page rendered, so a cancelled or failed export never leaves a partial
/// file at the destination. Rendering runs off the main actor; cancel the
/// surrounding `Task` to stop between pages.
struct PDFExporter: Sendable {
    let source: any ExportContentSource
    /// PDF metadata creator string.
    var creator = "Courseleaf"

    init(session: any DocumentSessioning) { self.source = SessionContentSource(session: session) }
    init(source: any ExportContentSource) { self.source = source }

    /// Exports `options.pageIDs` (nil = every live page) as one PDF at `url`.
    /// `progress` is called on an arbitrary thread with 0...1 after each page.
    func export(options: ExportOptions, to url: URL, progress: @escaping (Double) -> Void) async throws {
        guard options.format == .pdf else { throw ExportError.unsupportedFormat(options.format) }
        let snapshot = await source.snapshot()
        let pages = try Self.selectedPages(snapshot, options.pageIDs)
        let loader = ExportPageLoader(source: source)
        var inputs: [ExportPageInput] = []
        inputs.reserveCapacity(pages.count)
        for page in pages {
            inputs.append(try await loader.input(for: page))
        }
        let title = snapshot.document.title
        let compositeOptions = CompositeOptions(options)
        let creator = self.creator
        try Task.checkCancellation()

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseleafExport-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("pdf")
        try await Task.detached(priority: .userInitiated) {
            try Self.render(inputs, title: title, creator: creator, options: compositeOptions, to: temporary, progress: progress)
        }.value
        do {
            try Self.move(temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Renders straight into a `Data` (share sheet previews, tests). Same compositing.
    func exportData(options: ExportOptions) async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CourseleafExport-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await export(options: options, to: url, progress: { _ in })
        return try Data(contentsOf: url)
    }

    // MARK: Rendering

    static func selectedPages(_ snapshot: DocumentSnapshot, _ ids: [PageID]?) throws -> [Page] {
        let pages: [Page]
        if let ids {
            // Validate every requested id, then emit in document order: the
            // caller's ordering is a selection, not a page order.
            for id in ids where snapshot.pages[id] == nil || !snapshot.document.pageIDs.contains(id) {
                throw ExportError.pageNotFound(id)
            }
            let wanted = Set(ids)
            pages = snapshot.document.pageIDs.filter { wanted.contains($0) }.compactMap { snapshot.pages[$0] }
        } else {
            pages = snapshot.orderedPages
        }
        guard !pages.isEmpty else { throw ExportError.noPagesSelected }
        return pages
    }

    private static func render(_ inputs: [ExportPageInput], title: String, creator: String, options: CompositeOptions,
                               to url: URL, progress: @escaping (Double) -> Void) throws {
        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [kCGPDFContextCreator as String: creator]
        if !title.isEmpty { info[kCGPDFContextTitle as String] = title }
        format.documentInfo = info
        let renderer = UIGraphicsPDFRenderer(bounds: inputs.first?.pageRect ?? CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        var failure: Error?
        try? FileManager.default.removeItem(at: url)
        do {
            try renderer.writePDF(to: url) { context in
                for (index, input) in inputs.enumerated() {
                    if Task.isCancelled { failure = CancellationError(); return }
                    context.beginPage(withBounds: input.pageRect, pageInfo: [:])
                    PageCompositor.draw(input, in: context.cgContext, options: options)
                    progress(Double(index + 1) / Double(inputs.count))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ExportError.writeFailed(error.localizedDescription)
        }
        if let failure {
            try? FileManager.default.removeItem(at: url)
            throw failure
        }
    }

    /// Moves the finished file over `destination` (replacing an existing file atomically when possible).
    static func move(_ temporary: URL, to destination: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }
}
