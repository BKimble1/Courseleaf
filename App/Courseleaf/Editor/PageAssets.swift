import Foundation
import UIKit
import PDFKit
import PencilKit
import DocumentCore
import Editing
import Workspace

// Asset access for the editor views: bytes and file URLs come from the open
// `DocumentSessioning`; decoded images, drawings and PDF documents are held
// in NSCache-bounded caches so eviction under memory pressure is automatic.

@MainActor
protocol PageAssetProviding: AnyObject {
    /// Bytes for an asset. `nil` means the package does not have it; a thrown
    /// error means reading failed. The editor must tell those two apart: one is
    /// a broken reference, the other may succeed on a retry, and neither may be
    /// silently replaced with empty content.
    func assetData(_ id: AssetID) async throws -> Data?
    func assetURL(_ id: AssetID) async -> URL?
}

@MainActor
final class SessionAssetProvider: PageAssetProviding {
    private let session: any DocumentSessioning
    init(session: any DocumentSessioning) { self.session = session }
    func assetData(_ id: AssetID) async throws -> Data? { try await session.assetData(id) }
    func assetURL(_ id: AssetID) async -> URL? { await session.assetURL(id) }
}

/// What a page's ink layer turned out to be. `empty` and `loaded` are content;
/// the other two are failures that must never be written over (§ docs/FORMAT.md
/// — an ink blob is an immutable asset, and losing one loses the page).
enum InkLoadOutcome {
    /// The page references no ink asset: a genuinely blank ink layer.
    case empty
    case loaded(PKDrawing)
    /// The page references an asset the package cannot produce.
    case missing(AssetID)
    /// Bytes were read but the ink engine refused them.
    case unreadable(AssetID, String)

    var drawing: PKDrawing? {
        switch self {
        case .empty: return PKDrawing()
        case .loaded(let drawing): return drawing
        case .missing, .unreadable: return nil
        }
    }

    var failureDescription: String? {
        switch self {
        case .empty, .loaded: return nil
        case .missing: return "This page's handwriting is missing from the notebook file."
        case .unreadable: return "This page's handwriting could not be read."
        }
    }
}

/// Thread-safe cache of PDFKit documents by asset. Drawing a page from
/// several CATiledLayer threads at once goes through `withPage` so one
/// `PDFDocument` is never drawn concurrently.
final class PDFDocumentCache: @unchecked Sendable {
    private let cache = NSCache<NSString, PDFDocument>()
    private let lock = NSLock()
    private var drawLocks: [String: NSLock] = [:]

    init(countLimit: Int = 6) { cache.countLimit = countLimit }

    func document(for assetID: AssetID, url: URL) -> PDFDocument? {
        let key = assetID.description as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let doc = PDFDocument(url: url) else { return nil }
        cache.setObject(doc, forKey: key)
        return doc
    }

    func document(for assetID: AssetID, data: Data) -> PDFDocument? {
        let key = assetID.description as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let doc = PDFDocument(data: data) else { return nil }
        cache.setObject(doc, forKey: key)
        return doc
    }

    func cachedDocument(for assetID: AssetID) -> PDFDocument? {
        cache.object(forKey: assetID.description as NSString)
    }

    /// Runs `body` with exclusive access to the document's drawing.
    func withDrawLock<T>(for assetID: AssetID, _ body: () -> T) -> T {
        lock.lock()
        let drawLock: NSLock
        if let existing = drawLocks[assetID.description] { drawLock = existing } else {
            drawLock = NSLock(); drawLocks[assetID.description] = drawLock
        }
        lock.unlock()
        drawLock.lock(); defer { drawLock.unlock() }
        return body()
    }
}

/// Decoded images and drawings by asset, bounded by cost (bytes).
final class DecodedAssetCache: @unchecked Sendable {
    private let images = NSCache<NSString, UIImage>()
    private let drawings = NSCache<NSString, DrawingBox>()

    final class DrawingBox {
        let drawing: PKDrawing
        init(_ drawing: PKDrawing) { self.drawing = drawing }
    }

    init(imageCostLimit: Int = 96 * 1024 * 1024) {
        images.totalCostLimit = imageCostLimit
        drawings.countLimit = 24
    }

    func image(for id: AssetID) -> UIImage? { images.object(forKey: id.description as NSString) }

    func setImage(_ image: UIImage, for id: AssetID) {
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        images.setObject(image, forKey: id.description as NSString, cost: cost)
    }

    func drawing(for id: AssetID) -> PKDrawing? { drawings.object(forKey: id.description as NSString)?.drawing }

    func setDrawing(_ drawing: PKDrawing, for id: AssetID) {
        drawings.setObject(DrawingBox(drawing), forKey: id.description as NSString)
    }

    func removeAll() { images.removeAllObjects(); drawings.removeAllObjects() }
}

/// Everything the editor needs to show one page's content, resolved from assets.
@MainActor
final class PageContentLoader {
    let assets: any PageAssetProviding
    let pdfDocuments = PDFDocumentCache()
    let decoded = DecodedAssetCache()
    let inkEngine = PencilKitInkEngine()

    init(assets: any PageAssetProviding) { self.assets = assets }

    /// Bytes, or nil for either "not there" or "could not be read". Callers that
    /// have to tell those apart use `loadDrawing(for:)` instead.
    private func assetBytes(_ id: AssetID) async -> Data? {
        do { return try await assets.assetData(id) } catch { return nil }
    }

    func image(for id: AssetID) async -> UIImage? {
        if let cached = decoded.image(for: id) { return cached }
        guard let data = await assetBytes(id) else { return nil }
        let decodedImage = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let image = UIImage(data: data) else { return nil }
            // Force decoding off the main thread.
            return image.preparingForDisplay() ?? image
        }.value
        if let decodedImage { decoded.setImage(decodedImage, for: id) }
        return decodedImage
    }

    func drawing(for id: AssetID) async -> PKDrawing? {
        if case .loaded(let drawing) = await loadDrawing(for: id) { return drawing }
        return nil
    }

    /// Loads a page's ink, keeping the difference between "there is none",
    /// "the bytes are gone" and "the bytes are unreadable". The caller decides
    /// what to show; nothing here invents an empty drawing.
    func loadDrawing(for id: AssetID) async -> InkLoadOutcome {
        if let cached = decoded.drawing(for: id) { return .loaded(cached) }
        let data: Data?
        do {
            data = try await assets.assetData(id)
        } catch {
            return .unreadable(id, "\(error)")
        }
        guard let data else { return .missing(id) }
        do {
            let drawing = try inkEngine.decode(data).drawing
            decoded.setDrawing(drawing, for: id)
            return .loaded(drawing)
        } catch {
            return .unreadable(id, "\(error)")
        }
    }

    func pdfDocument(for id: AssetID) async -> PDFDocument? {
        if let cached = pdfDocuments.cachedDocument(for: id) { return cached }
        if let url = await assets.assetURL(id) {
            return await Task.detached(priority: .userInitiated) { [pdfDocuments] in pdfDocuments.document(for: id, url: url) }.value
        }
        guard let data = await assetBytes(id) else { return nil }
        return await Task.detached(priority: .userInitiated) { [pdfDocuments] in pdfDocuments.document(for: id, data: data) }.value
    }

    func pdfPage(for source: PDFPageSource) async -> PDFPage? {
        guard let document = await pdfDocument(for: source.assetID) else { return nil }
        return document.page(at: source.pageIndex)
    }
}
