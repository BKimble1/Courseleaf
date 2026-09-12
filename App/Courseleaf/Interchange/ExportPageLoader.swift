import Foundation
import CoreGraphics
import ImageIO
import UIKit
import PencilKit
import DocumentCore
import PageGeometry

/// Resolves a `Page` into an `ExportPageInput`: opens the source PDF or image,
/// decodes image objects and ink blobs. Loaded documents are cached per asset
/// for the lifetime of the loader so a 300-page export opens its PDF once.
final class ExportPageLoader {
    let source: any ExportContentSource
    private var pdfDocuments: [AssetID: CGPDFDocument] = [:]
    private var images: [AssetID: CGImage] = [:]

    init(source: any ExportContentSource) { self.source = source }

    func input(for page: Page) async throws -> ExportPageInput {
        try Task.checkCancellation()
        let background: ExportBackground
        switch page.background {
        case .template(let template):
            background = .template(template)
        case .image(let assetID):
            background = .image(try await image(assetID, pageID: page.id))
        case .pdf(let sourcePage):
            let document = try await pdfDocument(sourcePage.assetID, pageID: page.id)
            guard let cgPage = document.page(at: sourcePage.pageIndex + 1) else {
                throw ExportError.sourcePageMissing(sourcePage.assetID, pageIndex: sourcePage.pageIndex)
            }
            background = .pdf(page: cgPage, document: document, mapping: PageMapping(source: sourcePage))
        }

        var objectImages: [ObjectID: CGImage] = [:]
        for object in page.objects {
            if case .image(let content) = object.content {
                objectImages[object.id] = try await image(content.assetID, pageID: page.id)
            }
        }

        var drawings: [PKDrawing] = []
        for layer in page.inkLayers where layer.isVisible {
            guard let assetID = layer.dataAssetID else { continue }
            guard layer.engine == .pencilKit else { continue } // other engines have no renderer in the app
            guard let data = try await source.assetData(assetID) else { throw ExportError.missingAsset(assetID, pageID: page.id) }
            do { drawings.append(try PKDrawing(data: data)) }
            catch { throw ExportError.unreadableAsset(assetID, reason: "ink data is not a PencilKit drawing") }
        }
        return ExportPageInput(page: page, background: background, images: objectImages, inkDrawings: drawings)
    }

    // MARK: Assets

    func pdfDocument(_ assetID: AssetID, pageID: PageID) async throws -> CGPDFDocument {
        if let cached = pdfDocuments[assetID] { return cached }
        let document: CGPDFDocument?
        if let url = await source.assetURL(assetID) {
            document = CGPDFDocument(url as CFURL)
        } else if let data = try await source.assetData(assetID), let provider = CGDataProvider(data: data as CFData) {
            document = CGPDFDocument(provider)
        } else {
            throw ExportError.missingAsset(assetID, pageID: pageID)
        }
        guard let document else { throw ExportError.unreadableAsset(assetID, reason: "not a readable PDF") }
        if document.isEncrypted && !document.isUnlocked {
            throw ExportError.unreadableAsset(assetID, reason: "the source PDF is encrypted")
        }
        pdfDocuments[assetID] = document
        return document
    }

    func image(_ assetID: AssetID, pageID: PageID) async throws -> CGImage {
        if let cached = images[assetID] { return cached }
        let data: Data
        if let url = await source.assetURL(assetID), let mapped = try? Data(contentsOf: url, options: [.mappedIfSafe]) {
            data = mapped
        } else if let bytes = try await source.assetData(assetID) {
            data = bytes
        } else {
            throw ExportError.missingAsset(assetID, pageID: pageID)
        }
        guard let uiImage = UIImage(data: data), let cg = uiImage.ixNormalizedOrientation().cgImage else {
            throw ExportError.unreadableAsset(assetID, reason: "not a decodable image")
        }
        images[assetID] = cg
        return cg
    }
}
