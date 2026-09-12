import Foundation
import UIKit
import PDFKit
import PencilKit
import DocumentCore
import PageGeometry

// NSCache-bounded page thumbnails rendered off the main thread. Keys include
// the page's modification date so an edited page gets a fresh thumbnail and
// the old one simply ages out. Previews are disposable (docs/ARCHITECTURE.md §2).

@MainActor
final class ThumbnailCache {
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]
    private var waiting: [PendingRender] = []
    private var activeRenders = 0
    private var latestKeyByPage: [PageID: String] = [:]
    let loader: PageContentLoader

    init(loader: PageContentLoader, countLimit: Int = 240, costLimitBytes: Int = 48 * 1024 * 1024) {
        self.loader = loader
        cache.countLimit = countLimit
        cache.totalCostLimit = costLimitBytes
    }

    static func key(for page: Page, size: CGSize) -> String {
        "\(page.id)-\(page.modifiedAt.timeIntervalSinceReferenceDate)-\(Int(size.width))x\(Int(size.height))"
    }

    /// The cached image, if already rendered for this page state and size.
    func cachedImage(for page: Page, size: CGSize) -> UIImage? {
        cache.object(forKey: Self.key(for: page, size: size) as NSString)
    }

    func invalidate(pageID: PageID) {
        if let key = latestKeyByPage[pageID] { cache.removeObject(forKey: key as NSString) }
        latestKeyByPage[pageID] = nil
    }

    func removeAll() {
        cache.removeAllObjects()
        latestKeyByPage.removeAll()
        waiting.removeAll()
    }

    // Bounding the work, not just the cache.
    //
    // Every request used to start its own unstructured `Task`, so flicking
    // through a long notebook queued one full-page render per page it passed,
    // all of them decoding ink and rasterizing PDF at once and none of them
    // cancellable. The cache was bounded; the work was not. Renders now run at
    // most `maxConcurrentRenders` at a time, and requests that have not started
    // sit in a bounded queue where a newer one can displace the oldest — a
    // thumbnail nobody is looking at any more is not worth a core.
    static let maxConcurrentRenders = 2
    static let maxQueuedRenders = 12

    private struct PendingRender {
        var key: String
        var page: Page
        var size: CGSize
    }

    /// Renders (or returns) the thumbnail; `completion` runs on the main actor
    /// with nil when the page could not be rendered.
    func requestImage(for page: Page, size: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) {
        let key = Self.key(for: page, size: size)
        if let cached = cache.object(forKey: key as NSString) { completion(cached); return }
        if inFlight[key] != nil { inFlight[key]?.append(completion); return }
        inFlight[key] = [completion]
        latestKeyByPage[page.id] = key
        enqueue(PendingRender(key: key, page: page, size: size))
    }

    private func enqueue(_ render: PendingRender) {
        waiting.append(render)
        if waiting.count > Self.maxQueuedRenders {
            // Drop the oldest request rather than the newest: the newest is the
            // page on screen now.
            let dropped = waiting.removeFirst()
            finish(key: dropped.key, image: nil)
        }
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard activeRenders < Self.maxConcurrentRenders, !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        activeRenders += 1
        Task { [weak self] in
            guard let self else { return }
            let image = await self.render(page: next.page, size: next.size)
            if let image {
                let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
                self.cache.setObject(image, forKey: next.key as NSString, cost: cost)
            }
            self.activeRenders -= 1
            self.finish(key: next.key, image: image)
            self.startNextIfPossible()
        }
    }

    private func finish(key: String, image: UIImage?) {
        let waiters = inFlight.removeValue(forKey: key) ?? []
        for waiter in waiters { waiter(image) }
    }

    /// Requests that have not started yet.
    var queuedRenderCount: Int { waiting.count }
    var activeRenderCount: Int { activeRenders }

    private func render(page: Page, size: CGSize) async -> UIImage? {
        let input = await PageContentResolver.resolve(page: page, loader: loader, wantsInk: true, wantsImages: true)
        let scale = UIScreen.main.scale
        return await Task.detached(priority: .utility) {
            PageRenderer.renderPage(input, size: size, scale: min(scale, 2))
        }.value
    }
}

/// Turns a `Page` into a `PageRenderInput` by resolving its assets.
enum PageContentResolver {
    @MainActor
    static func background(for page: Page, loader: PageContentLoader) async -> PageBackgroundContent {
        switch page.background {
        case .template(let template):
            let primitives = TemplateGeometry.primitives(for: template, size: page.size)
            return .template(primitives, paperColor: template.paperColor)
        case .pdf(let source):
            if let pdfPage = await loader.pdfPage(for: source) {
                return .pdf(pdfPage, mapping: PageMapping(source: source), assetID: source.assetID, documents: loader.pdfDocuments)
            }
            return .empty(paperColor: .white)
        case .image(let id):
            if let image = await loader.image(for: id) { return .image(image) }
            return .empty(paperColor: .white)
        }
    }

    @MainActor
    static func resolve(page: Page, loader: PageContentLoader, wantsInk: Bool, wantsImages: Bool) async -> PageRenderer.PageRenderInput {
        let background = await background(for: page, loader: loader)
        var images: [ObjectID: UIImage] = [:]
        if wantsImages {
            for object in page.objects {
                if case .image(let content) = object.content, let image = await loader.image(for: content.assetID) {
                    images[object.id] = image
                }
            }
        }
        var drawing: PKDrawing?
        if wantsInk, let layer = page.inkLayers.first(where: { $0.isVisible && $0.dataAssetID != nil }),
           let id = layer.dataAssetID {
            drawing = await loader.drawing(for: id)
        }
        return PageRenderer.PageRenderInput(page: page, background: background, images: images, drawing: drawing)
    }
}
