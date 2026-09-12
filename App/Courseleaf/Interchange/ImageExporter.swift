import Foundation
import UIKit
import DocumentCore
import Workspace

/// Renders one page to a `UIImage` with `UIGraphicsImageRenderer`, using the
/// same compositing as the PDF export (`PageCompositor`). The image is
/// `page.size × options.inkRasterScale` pixels (2× = 144 dpi by default) and
/// opaque (paper colour or white behind everything), so PNG and JPEG output
/// look alike. The source PDF page is always rasterized here; text is pixels.
struct ImageExporter: Sendable {
    let source: any ExportContentSource
    var jpegQuality: CGFloat = 0.9

    init(session: any DocumentSessioning) { self.source = SessionContentSource(session: session) }
    init(source: any ExportContentSource) { self.source = source }

    func export(pageID: PageID, options: ExportOptions) async throws -> UIImage {
        let snapshot = await source.snapshot()
        guard let page = snapshot.pages[pageID] else { throw ExportError.pageNotFound(pageID) }
        let input = try await ExportPageLoader(source: source).input(for: page)
        let compositeOptions = CompositeOptions(options)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Self.render(input, options: compositeOptions)
        }.value
    }

    /// Encoded bytes for `options.format` (`.png` or `.jpeg`).
    func exportData(pageID: PageID, options: ExportOptions) async throws -> Data {
        let image = try await export(pageID: pageID, options: options)
        switch options.format {
        case .png:
            guard let data = image.pngData() else { throw ExportError.renderFailed("PNG encoding failed") }
            return data
        case .jpeg:
            guard let data = image.jpegData(compressionQuality: jpegQuality) else { throw ExportError.renderFailed("JPEG encoding failed") }
            return data
        case .pdf, .archive:
            throw ExportError.unsupportedFormat(options.format)
        }
    }

    /// Writes every selected page as `<stem>-<n>.<ext>` inside `directory`; returns the files in page order.
    func export(options: ExportOptions, into directory: URL, stem: String, progress: @escaping (Double) -> Void) async throws -> [URL] {
        let snapshot = await source.snapshot()
        let pages = try PDFExporter.selectedPages(snapshot, options.pageIDs)
        let ext = options.format == .jpeg ? "jpg" : "png"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            let data = try await exportData(pageID: page.id, options: options)
            let url = directory.appendingPathComponent("\(stem)-\(index + 1).\(ext)")
            do { try data.write(to: url, options: .atomic) } catch { throw ExportError.writeFailed(error.localizedDescription) }
            urls.append(url)
            progress(Double(index + 1) / Double(pages.count))
        }
        return urls
    }

    static func render(_ input: ExportPageInput, options: CompositeOptions) throws -> UIImage {
        let size = input.pageSize
        guard size.width > 0, size.height > 0 else { throw ExportError.renderFailed("empty page size") }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = CGFloat(max(options.inkRasterScale, 0.25))
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            PageCompositor.draw(input, in: ctx, options: options)
        }
    }
}
